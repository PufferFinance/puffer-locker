// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PufferLocker
 * @notice Lock-based ERC20 token that grants voting power according to lock duration,
 *         compatible with OpenZeppelin ERC20Votes with time-based voting power expiry.
 *
 * This contract allows users to lock Puffer tokens for a specified duration.
 * In return, they receive vlPuffer tokens that represent voting power.
 * The amount of vlPuffer tokens received is proportional to the amount of Puffer tokens locked
 * and the lock duration, with each week of lock time multiplying the voting power.
 *
 * Key features:
 * - Voting power automatically expires when locks expire, without requiring transactions
 * - Multiple locks per user with independent expiration times
 * - Delegation of voting power to other addresses including a Puffer team address
 * - Epoch-based tracking system for potential governance snapshots
 */
contract PufferLocker is ERC20, ERC20Permit, ERC20Votes, ReentrancyGuard, Ownable {
    // ------------------------ ERRORS ------------------------
    error ZeroValue();
    error NoExistingLock();
    error LockExpired();
    error LockNotExpired();
    error FutureLockTimeRequired();
    error ExceedsMaxLockTime();
    error MustExtendBeyondCurrentLock();
    error TransferFailed();
    error InvalidLockId();
    error TransfersDisabled();
    error InvalidEpoch();
    error ContractPaused();
    error TooManyCheckpoints();
    error InvalidPaginationParameters();
    error EmergencyUnlockNotEnabled();
    error NotEnoughActiveLocksForDeletion();

    // ------------------------ STRUCTS ------------------------
    struct Lock {
        uint256 amount; // Amount of PUFFER tokens locked
        uint256 end; // Timestamp when the lock expires
        uint256 vlTokenAmount; // Amount of vlPuffer tokens minted for this lock
    }

    struct EpochPoint {
        uint256 timestamp; // Epoch start timestamp
        uint256 totalSupply; // Total voting power at epoch start
    }

    // ------------------------ EVENTS ------------------------
    event Deposit(
        address indexed provider,
        uint256 indexed lockId,
        uint256 value,
        uint256 locktime,
        uint256 vlTokenAmount,
        uint256 ts
    );
    event Withdraw(address indexed provider, uint256 indexed lockId, uint256 value, uint256 ts);
    event Supply(uint256 prevSupply, uint256 supply);
    event DelegatedToPufferTeam(address indexed delegator);
    event EpochTransition(uint256 indexed epochId, uint256 timestamp, uint256 totalSupply);
    event EmergencyShutdownEnabled(address indexed admin);
    event EmergencyShutdownDisabled(address indexed admin);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event UserRemoved(address indexed user);
    event EpochCheckpointWarning(uint256 currentProcessedEpoch, uint256 targetEpoch);

    // ------------------------ STATE VARIABLES ------------------------
    IERC20 public immutable PUFFER;
    uint256 public immutable MAX_LOCK_TIME = 2 * 365 days; // 2 years
    uint256 public constant EPOCH_DURATION = 1 weeks;
    uint256 public constant MAX_CHECKPOINTS_PER_TX = 50; // Maximum checkpoints to process in a single transaction
    uint256 public constant MAX_PAGINATION_SIZE = 100; // Maximum items to return in paginated functions
    uint256 public lockedSupply; // Total tokens locked as collateral
    address public immutable PUFFER_TEAM;

    // Epoch tracking
    uint256 public currentEpoch;
    mapping(uint256 => EpochPoint) public epochPoints;

    // Time when the contract was deployed (epoch 0)
    uint256 public immutable genesisTime;

    // User address => lock ID => Lock details
    mapping(address => mapping(uint256 => Lock)) public userLocks;
    // User address => number of locks created (also used as next lock ID)
    mapping(address => uint256) public userLockCount;
    // User address => number of active locks (locks with amount > 0)
    mapping(address => uint256) public userActiveLockCount;
    // User address => total vlPuffer balance including expired locks
    mapping(address => uint256) public userVlTokenBalance;

    // Array of all users that have created locks
    address[] private _allUsers;
    // Mapping to track if an address is already in the _allUsers array
    mapping(address => bool) private _isUser;
    // Mapping to track user's index in _allUsers array
    mapping(address => uint256) private _userIndex;

    // Emergency shutdown flag
    bool public emergencyShutdownActive;

    // ------------------------ CONSTRUCTOR ------------------------
    constructor(IERC20 _puffer, address _pufferTeam)
        ERC20("vlPuffer", "vlPuffer")
        ERC20Permit("vlPuffer")
        Ownable(msg.sender)
    {
        PUFFER = _puffer;
        PUFFER_TEAM = _pufferTeam;
        genesisTime = block.timestamp;

        // Initialize epoch 0
        epochPoints[0] = EpochPoint({timestamp: block.timestamp, totalSupply: 0});
        currentEpoch = 0;
        emergencyShutdownActive = false;
    }

    // ------------------------ MODIFIERS ------------------------
    modifier nonZeroValue(uint256 _value) {
        if (_value == 0) revert ZeroValue();
        _;
    }

    modifier validUnlockTime(uint256 _unlockTime) {
        uint256 unlockTime = (_unlockTime / EPOCH_DURATION) * EPOCH_DURATION;
        if (unlockTime <= block.timestamp) revert FutureLockTimeRequired();
        if (unlockTime > block.timestamp + MAX_LOCK_TIME) revert ExceedsMaxLockTime();
        _;
    }

    modifier validLockId(address _user, uint256 _lockId) {
        if (_lockId >= userLockCount[_user]) revert InvalidLockId();
        _;
    }

    modifier validEpoch(uint256 _epoch) {
        if (_epoch > getCurrentEpoch()) revert InvalidEpoch();
        _;
    }

    modifier whenNotPaused() {
        if (emergencyShutdownActive) revert ContractPaused();
        _;
    }

    // ------------------------ ADMIN FUNCTIONS ------------------------

    /**
     * @notice Enable emergency shutdown mode
     * @dev Can only be called by the contract owner
     */
    function enableEmergencyShutdown() external onlyOwner {
        emergencyShutdownActive = true;
        emit EmergencyShutdownEnabled(msg.sender);
    }

    /**
     * @notice Disable emergency shutdown mode
     * @dev Can only be called by the contract owner
     */
    function disableEmergencyShutdown() external onlyOwner {
        emergencyShutdownActive = false;
        emit EmergencyShutdownDisabled(msg.sender);
    }

    /**
     * @notice Process epoch transitions manually
     * @dev Used to process transitions when there might be too many epochs to process in a single transaction
     * @param _maxCheckpoints Maximum number of checkpoints to process
     */
    function processEpochTransitions(uint256 _maxCheckpoints) external {
        if (_maxCheckpoints == 0 || _maxCheckpoints > MAX_CHECKPOINTS_PER_TX) {
            _maxCheckpoints = MAX_CHECKPOINTS_PER_TX;
        }

        _checkpointEpoch(_maxCheckpoints);
    }

    // ------------------------ PUBLIC / EXTERNAL FUNCTIONS ------------------------

    /**
     * @notice Checks if we've moved to a new epoch and updates epoch data
     * @dev This is called automatically before state-changing operations
     */
    function _checkpointEpoch() internal {
        _checkpointEpoch(MAX_CHECKPOINTS_PER_TX);
    }

    /**
     * @notice Checks if we've moved to a new epoch and updates epoch data with a limit on checkpoints
     * @param _maxCheckpoints Maximum number of checkpoints to process
     */
    function _checkpointEpoch(uint256 _maxCheckpoints) internal {
        uint256 currentEpochStart = epochPoints[currentEpoch].timestamp;
        uint256 currentTime = block.timestamp;

        // Check if we've moved to a new epoch
        if (currentTime >= currentEpochStart + EPOCH_DURATION) {
            // Calculate how many epochs have passed
            uint256 epochsPassed = (currentTime - currentEpochStart) / EPOCH_DURATION;

            // Limit the number of checkpoints to create
            uint256 checkpointsToCreate = epochsPassed > _maxCheckpoints ? _maxCheckpoints : epochsPassed;

            if (checkpointsToCreate == 0) return;

            // Create checkpoints for each epoch
            for (uint256 i = 0; i < checkpointsToCreate; i++) {
                uint256 newEpoch = currentEpoch + 1;
                uint256 newEpochTime = currentEpochStart + EPOCH_DURATION * (i + 1);

                // Save the checkpoint
                epochPoints[newEpoch] = EpochPoint({
                    timestamp: newEpochTime,
                    totalSupply: 0 // This will be properly calculated when needed
                });

                emit EpochTransition(newEpoch, newEpochTime, 0);

                // Update the current epoch
                currentEpoch = newEpoch;
            }

            // If we've processed the maximum number of checkpoints but there are more epochs to process,
            // emit a warning that more processing is needed
            if (checkpointsToCreate < epochsPassed) {
                emit EpochCheckpointWarning(currentEpoch, currentEpoch + (epochsPassed - checkpointsToCreate));
            }
        }
    }

    /**
     * @notice Create a new lock by depositing `_value` tokens until `_unlockTime`.
     * @param _value Amount of PUFFER tokens to lock
     * @param _unlockTime Timestamp when the lock will expire
     * @return lockId The ID of the newly created lock
     */
    function createLock(uint256 _value, uint256 _unlockTime)
        external
        nonReentrant
        whenNotPaused
        nonZeroValue(_value)
        validUnlockTime(_unlockTime)
        returns (uint256 lockId)
    {
        // Update epoch if needed
        _checkpointEpoch();

        uint256 unlockTime = (_unlockTime / EPOCH_DURATION) * EPOCH_DURATION;

        // Calculate number of epochs
        uint256 numEpochs = (unlockTime - block.timestamp) / EPOCH_DURATION;

        // Calculate vlToken amount
        uint256 vlTokenAmount = _value * numEpochs;

        // Get next lock ID
        lockId = userLockCount[msg.sender]++;

        // Create the lock
        Lock memory newLock = Lock({amount: _value, end: unlockTime, vlTokenAmount: vlTokenAmount});

        userLocks[msg.sender][lockId] = newLock;
        userActiveLockCount[msg.sender]++;

        // Update user's vlToken balance
        userVlTokenBalance[msg.sender] += vlTokenAmount;

        // Add user to _allUsers array if not already added
        if (!_isUser[msg.sender]) {
            _userIndex[msg.sender] = _allUsers.length;
            _allUsers.push(msg.sender);
            _isUser[msg.sender] = true;
        }

        // Update locked supply
        uint256 supplyBefore = lockedSupply;
        lockedSupply = supplyBefore + _value;

        // Mint vlTokens but with time-expiry built into the balanceOf and totalSupply functions
        _mint(msg.sender, vlTokenAmount);

        // If this is the first mint and the user hasn't delegated yet,
        // delegate to themselves by default
        if (delegates(msg.sender) == address(0)) {
            _delegate(msg.sender, msg.sender);
        }

        // Transfer PUFFER tokens to this contract
        bool ok = PUFFER.transferFrom(msg.sender, address(this), _value);
        if (!ok) revert TransferFailed();

        emit Deposit(msg.sender, lockId, _value, unlockTime, vlTokenAmount, block.timestamp);
        emit Supply(supplyBefore, lockedSupply);

        return lockId;
    }

    /**
     * @notice Withdraw tokens from an expired lock
     * @param _lockId The ID of the lock to withdraw from
     */
    function withdraw(uint256 _lockId) external nonReentrant whenNotPaused validLockId(msg.sender, _lockId) {
        // Update epoch if needed
        _checkpointEpoch();

        Lock storage lock = userLocks[msg.sender][_lockId];

        if (lock.amount == 0) revert NoExistingLock();
        if (block.timestamp < lock.end) revert LockNotExpired();

        uint256 value = lock.amount;
        uint256 vlTokenValue = lock.vlTokenAmount;

        // Reset the lock (prevent reentrancy)
        lock.amount = 0;
        lock.end = 0;
        lock.vlTokenAmount = 0;

        // Update user's vlToken balance and active lock count
        userVlTokenBalance[msg.sender] -= vlTokenValue;
        userActiveLockCount[msg.sender]--;

        // If user has no more active locks, remove from tracking
        if (userActiveLockCount[msg.sender] == 0) {
            _removeUser(msg.sender);
        }

        // Update locked supply
        uint256 supplyBefore = lockedSupply;
        lockedSupply = supplyBefore - value;

        // Burn vlTokens (note: voting power might already be 0 due to expiry)
        _burn(msg.sender, vlTokenValue);

        // Transfer PUFFER tokens back to user
        bool ok = PUFFER.transfer(msg.sender, value);
        if (!ok) revert TransferFailed();

        emit Withdraw(msg.sender, _lockId, value, block.timestamp);
        emit Supply(supplyBefore, lockedSupply);
    }

    /**
     * @notice Emergency withdraw function that works even during shutdown
     * @param _lockId The ID of the lock to withdraw from
     */
    function emergencyWithdraw(uint256 _lockId) external nonReentrant validLockId(msg.sender, _lockId) {
        // This function can be used even when the contract is paused
        if (!emergencyShutdownActive) revert EmergencyUnlockNotEnabled();

        Lock storage lock = userLocks[msg.sender][_lockId];

        if (lock.amount == 0) revert NoExistingLock();

        uint256 value = lock.amount;
        uint256 vlTokenValue = lock.vlTokenAmount;

        // Reset the lock (prevent reentrancy)
        lock.amount = 0;
        lock.end = 0;
        lock.vlTokenAmount = 0;

        // Update user's vlToken balance and active lock count
        userVlTokenBalance[msg.sender] -= vlTokenValue;
        userActiveLockCount[msg.sender]--;

        // If user has no more active locks, remove from tracking
        if (userActiveLockCount[msg.sender] == 0) {
            _removeUser(msg.sender);
        }

        // Update locked supply
        uint256 supplyBefore = lockedSupply;
        lockedSupply = supplyBefore - value;

        // Burn vlTokens
        _burn(msg.sender, vlTokenValue);

        // Transfer PUFFER tokens back to user
        bool ok = PUFFER.transfer(msg.sender, value);
        if (!ok) revert TransferFailed();

        emit EmergencyWithdraw(msg.sender, value);
        emit Supply(supplyBefore, lockedSupply);
    }

    /**
     * @notice Delegate voting power to the Puffer team
     */
    function delegateToPufferTeam() external whenNotPaused {
        _delegate(msg.sender, PUFFER_TEAM);
        emit DelegatedToPufferTeam(msg.sender);
    }

    /**
     * @notice Get a user's lock details by lock ID
     * @param _user Address of the user
     * @param _lockId ID of the lock to query
     * @return Lock struct containing the lock details
     */
    function getLock(address _user, uint256 _lockId) external view validLockId(_user, _lockId) returns (Lock memory) {
        return userLocks[_user][_lockId];
    }

    /**
     * @notice Get the total number of locks for a user
     * @param _user Address of the user
     * @return Number of locks created by the user
     */
    function getLockCount(address _user) external view returns (uint256) {
        return userLockCount[_user];
    }

    /**
     * @notice Get the total number of active locks for a user
     * @param _user Address of the user
     * @return Number of active locks for the user
     */
    function getActiveLockCount(address _user) external view returns (uint256) {
        return userActiveLockCount[_user];
    }

    /**
     * @notice Get locks for a user with pagination
     * @param _user Address of the user
     * @param _offset Starting index for pagination
     * @param _limit Maximum number of locks to return
     * @return Array of Lock structs for the user
     */
    function getLocks(address _user, uint256 _offset, uint256 _limit) external view returns (Lock[] memory) {
        uint256 count = userLockCount[_user];

        if (_offset >= count) {
            return new Lock[](0);
        }

        // Limit to MAX_PAGINATION_SIZE
        if (_limit > MAX_PAGINATION_SIZE) {
            _limit = MAX_PAGINATION_SIZE;
        }

        // Adjust limit if it would exceed available locks
        uint256 available = count - _offset;
        _limit = _limit > available ? available : _limit;

        Lock[] memory locks = new Lock[](_limit);

        for (uint256 i = 0; i < _limit; i++) {
            locks[i] = userLocks[_user][_offset + i];
        }

        return locks;
    }

    /**
     * @notice Get all locks for a user (for backward compatibility, may hit gas limits for users with many locks)
     * @param _user Address of the user
     * @return Array of Lock structs for the user
     */
    function getAllLocks(address _user) external view returns (Lock[] memory) {
        uint256 count = userLockCount[_user];
        Lock[] memory locks = new Lock[](count);

        for (uint256 i = 0; i < count; i++) {
            locks[i] = userLocks[_user][i];
        }

        return locks;
    }

    /**
     * @notice Get current total locked supply (collateral tokens)
     * @return Total amount of PUFFER tokens locked in the contract
     */
    function totalLockedSupply() external view returns (uint256) {
        return lockedSupply;
    }

    /**
     * @notice Get expired locks for a user with pagination
     * @param _user Address of the user
     * @param _offset Starting index for pagination
     * @param _limit Maximum number of lock IDs to return
     * @return Array of lock IDs that have expired but not yet withdrawn
     */
    function getExpiredLocks(address _user, uint256 _offset, uint256 _limit) external view returns (uint256[] memory) {
        uint256 count = userLockCount[_user];

        if (_offset >= count) {
            return new uint256[](0);
        }

        // Limit to MAX_PAGINATION_SIZE
        if (_limit > MAX_PAGINATION_SIZE) {
            _limit = MAX_PAGINATION_SIZE;
        }

        // First pass to count expired locks
        uint256 expiredCount = 0;
        for (uint256 i = _offset; i < count && i < _offset + _limit; i++) {
            Lock memory lock = userLocks[_user][i];
            if (lock.amount > 0 && block.timestamp >= lock.end) {
                expiredCount++;
            }
        }

        // Second pass to fill the array
        uint256[] memory expiredLockIds = new uint256[](expiredCount);
        uint256 index = 0;
        for (uint256 i = _offset; i < count && i < _offset + _limit; i++) {
            Lock memory lock = userLocks[_user][i];
            if (lock.amount > 0 && block.timestamp >= lock.end) {
                expiredLockIds[index] = i;
                index++;
            }
        }

        return expiredLockIds;
    }

    /**
     * @notice Get all expired locks for a user (for backward compatibility)
     * @param _user Address of the user
     * @return Array of lock IDs that have expired but not yet withdrawn
     */
    function getExpiredLocks(address _user) external view returns (uint256[] memory) {
        uint256 count = userLockCount[_user];
        uint256[] memory expiredLockIds = new uint256[](count);
        uint256 expiredCount = 0;

        for (uint256 i = 0; i < count; i++) {
            Lock memory lock = userLocks[_user][i];
            if (lock.amount > 0 && block.timestamp >= lock.end) {
                expiredLockIds[expiredCount] = i;
                expiredCount++;
            }
        }

        // Resize the array to only include expired locks
        assembly {
            mstore(expiredLockIds, expiredCount)
        }

        return expiredLockIds;
    }

    /**
     * @notice Calculate the current epoch number
     * @return Current epoch number based on time passed since contract deployment
     */
    function getCurrentEpoch() public view returns (uint256) {
        if (block.timestamp <= genesisTime) {
            return 0;
        }

        uint256 epochsPassed = (block.timestamp - genesisTime) / EPOCH_DURATION;
        return epochsPassed;
    }

    /**
     * @notice Calculate the timestamp of a specific epoch
     * @param _epoch Epoch number to query
     * @return Timestamp when the epoch starts
     */
    function getEpochTimestamp(uint256 _epoch) public view validEpoch(_epoch) returns (uint256) {
        return genesisTime + (_epoch * EPOCH_DURATION);
    }

    /**
     * @notice Calculate active (non-expired) voting power for a user at the current time
     * @param _user Address of the user
     * @return Total active voting power of the user
     */
    function _calculateActiveBalanceOf(address _user) internal view returns (uint256) {
        uint256 activeBalance = 0;
        uint256 userLockCount_ = userLockCount[_user];

        for (uint256 i = 0; i < userLockCount_; i++) {
            Lock memory lock = userLocks[_user][i];

            // Only count locks that haven't expired
            if (lock.amount > 0 && block.timestamp < lock.end) {
                activeBalance += lock.vlTokenAmount;
            }
        }

        return activeBalance;
    }

    /**
     * @notice Calculate active (non-expired) voting power for a user at a specific timestamp
     * @param _user Address of the user
     * @param _timestamp Timestamp at which to calculate the balance
     * @return Active voting power of the user at the specified timestamp
     */
    function _calculateActiveBalanceOfAt(address _user, uint256 _timestamp) internal view returns (uint256) {
        uint256 activeBalance = 0;
        uint256 userLockCount_ = userLockCount[_user];

        for (uint256 i = 0; i < userLockCount_; i++) {
            Lock memory lock = userLocks[_user][i];

            // Only count locks that were active at the specified timestamp
            if (lock.amount > 0 && _timestamp < lock.end) {
                activeBalance += lock.vlTokenAmount;
            }
        }

        return activeBalance;
    }

    /**
     * @notice Calculate total active (non-expired) voting power at the current time
     * @return Total active voting power across all users
     */
    function _calculateTotalActiveSupply() internal view returns (uint256) {
        uint256 activeSupply = 0;
        uint256 userCount = _allUsers.length;

        for (uint256 i = 0; i < userCount; i++) {
            address user = _allUsers[i];
            activeSupply += _calculateActiveBalanceOf(user);
        }

        return activeSupply;
    }

    /**
     * @notice Calculate total active (non-expired) voting power at a specific timestamp
     * @param _timestamp Timestamp at which to calculate the supply
     * @return Total active voting power across all users at the specified timestamp
     */
    function _calculateTotalActiveSupplyAt(uint256 _timestamp) internal view returns (uint256) {
        uint256 activeSupply = 0;
        uint256 userCount = _allUsers.length;

        for (uint256 i = 0; i < userCount; i++) {
            address user = _allUsers[i];
            activeSupply += _calculateActiveBalanceOfAt(user, _timestamp);
        }

        return activeSupply;
    }

    /**
     * @notice Returns the active (non-expired) voting power of an account
     * @param account Address of the account
     * @return Active voting power of the account
     */
    function balanceOf(address account) public view override returns (uint256) {
        // Using the standard ERC20 balanceOf first
        uint256 rawBalance = super.balanceOf(account);

        if (rawBalance == 0) {
            return 0;
        }

        // Calculate only the active portion
        return _calculateActiveBalanceOf(account);
    }

    /**
     * @notice Returns the total active (non-expired) voting power
     * @return Total active voting power across all users
     */
    function totalSupply() public view override returns (uint256) {
        // Using the standard ERC20 totalSupply first
        uint256 rawSupply = super.totalSupply();

        if (rawSupply == 0) {
            return 0;
        }

        // Calculate only the active portion
        return _calculateTotalActiveSupply();
    }

    /**
     * @notice Returns the active voting power of an account at a specific epoch
     * @param account Address of the account
     * @param _epoch Epoch number to query
     * @return Active voting power of the account at the specified epoch
     */
    function balanceOfAtEpoch(address account, uint256 _epoch) public view validEpoch(_epoch) returns (uint256) {
        uint256 timestamp = getEpochTimestamp(_epoch);
        return _calculateActiveBalanceOfAt(account, timestamp);
    }

    /**
     * @notice Returns the total active voting power at a specific epoch
     * @param _epoch Epoch number to query
     * @return Total active voting power across all users at the specified epoch
     */
    function totalSupplyAtEpoch(uint256 _epoch) public view validEpoch(_epoch) returns (uint256) {
        uint256 timestamp = getEpochTimestamp(_epoch);
        return _calculateTotalActiveSupplyAt(timestamp);
    }

    /**
     * @notice Get raw vlToken balance (including expired tokens)
     * @param account Address of the account
     * @return Total vlToken balance of the account, including expired tokens
     */
    function getRawBalance(address account) external view returns (uint256) {
        return super.balanceOf(account);
    }

    /**
     * @notice Returns the address delegated to by a specific account
     * @param account Address of the account
     * @return Address to which the account has delegated its voting power
     */
    function getDelegatee(address account) external view returns (address) {
        return delegates(account);
    }

    /**
     * @notice Get the total number of users that have created locks
     * @return Total number of users
     */
    function getTotalUsers() external view returns (uint256) {
        return _allUsers.length;
    }

    /**
     * @notice Remove a user from the tracking array
     * @param _user Address of the user to remove
     */
    function _removeUser(address _user) internal {
        if (!_isUser[_user]) return;

        uint256 index = _userIndex[_user];
        uint256 lastIndex = _allUsers.length - 1;

        // Only proceed if the user actually has no active locks
        if (userActiveLockCount[_user] > 0) revert NotEnoughActiveLocksForDeletion();

        // If the user is not the last element, move the last element to their position
        if (index != lastIndex) {
            address lastUser = _allUsers[lastIndex];
            _allUsers[index] = lastUser;
            _userIndex[lastUser] = index;
        }

        // Remove the last element
        _allUsers.pop();

        // Update the user's status
        _isUser[_user] = false;

        emit UserRemoved(_user);
    }

    // ------------------------ OVERRIDES REQUIRED BY SOLIDITY ------------------------

    /**
     * @dev Override the _update function to disable transfers of vlPuffer tokens.
     * vlPuffer tokens represent specific locks and cannot be transferred as they
     * are tied to the user's locked PUFFER tokens.
     */
    function _update(address from, address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        // Allow minting (from = address(0)) and burning (to = address(0))
        if (from == address(0) || to == address(0)) {
            super._update(from, to, amount);
        } else {
            // Block transfers between users
            revert TransfersDisabled();
        }
    }

    function nonces(address owner) public view virtual override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }
}
