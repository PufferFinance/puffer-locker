// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ERC20Votes } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Nonces } from "@openzeppelin/contracts/utils/Nonces.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/**
 * @title PufferLocker
 * @notice Lock-based ERC20 token that grants voting power according to lock duration,
 *         compatible with OpenZeppelin ERC20Votes with time-based voting power expiry.
 *
 * This contract allows users to lock Puffer tokens for a specified duration.
 * In return, they receive vlPUFFER tokens that represent voting power.
 * The amount of vlPUFFER tokens received is proportional to the amount of Puffer tokens locked
 * and the lock duration, with each week of lock time multiplying the voting power.
 *
 * Key features:
 * - Voting power automatically expires when locks expire, without requiring transactions
 * - Multiple locks per user with independent expiration times
 * - Delegation of voting power to other addresses including a Puffer team address
 * - Epoch-based tracking system for potential governance snapshots
 */
contract PufferLocker is ERC20, ERC20Permit, ERC20Votes, Ownable, Pausable, ReentrancyGuardTransient {
    // ------------------------ ERRORS ------------------------
    error ZeroValue();
    error NoExistingLock();
    error LockNotExpired();
    error FutureLockTimeRequired();
    error ExceedsMaxLockTime();
    error InvalidLockId();
    error TransfersDisabled();
    error InvalidEpoch();
    error EmergencyUnlockNotEnabled();
    error NotEnoughActiveLocksForDeletion();

    // ------------------------ STRUCTS ------------------------
    struct Lock {
        uint256 amount; // Amount of PUFFER tokens locked
        uint256 end; // Timestamp when the lock expires
        uint256 vlTokenAmount; // Amount of vlPUFFER tokens minted for this lock
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
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event UserRemoved(address indexed user);
    event EpochCheckpointWarning(uint256 currentProcessedEpoch, uint256 targetEpoch);
    event Relock(
        address indexed provider,
        uint256 indexed lockId,
        uint256 value,
        uint256 newLocktime,
        uint256 newVlTokenAmount,
        uint256 ts
    );

    // ------------------------ STATE VARIABLES ------------------------
    // Puffer token address is known and constant
    IERC20 public constant PUFFER = IERC20(0x4d1C297d39C5c1277964D0E3f8Aa901493664530);
    uint256 public constant MAX_LOCK_TIME = 2 * 365 days; // 2 years
    uint256 public constant EPOCH_DURATION = 1 weeks;
    uint256 public constant MAX_CHECKPOINTS_PER_TX = 50; // Maximum checkpoints to process in a single transaction
    uint256 public constant MAX_PAGINATION_SIZE = 100; // Maximum items to return in paginated functions
    uint256 public lockedSupply; // Total tokens locked as collateral
    address public immutable PUFFER_TEAM;

    // Epoch tracking
    uint256 public currentEpoch;
    mapping(uint256 epochId => uint256 timestamp) public epochTimestamps;

    // Time when the contract was deployed (epoch 0)
    uint256 public immutable genesisTime;

    // User locks and related data
    mapping(address user => mapping(uint256 lockId => Lock lockData)) public userLocks;
    mapping(address user => uint256 count) public userLockCount;
    mapping(address user => uint256 activeCount) public userActiveLockCount;
    mapping(address user => uint256 balance) public userVlTokenBalance;

    // Array of all users that have created locks
    address[] private _allUsers;
    // Mapping to track if an address is already in the _allUsers array
    mapping(address user => bool isRegistered) private _isUser;
    // Mapping to track user's index in _allUsers array
    mapping(address user => uint256 arrayIndex) private _userIndex;

    // Use SafeERC20 for token operations
    using SafeERC20 for IERC20;

    // ------------------------ CONSTRUCTOR ------------------------
    constructor(address pufferTeam) ERC20("vlPUFFER", "vlPUFFER") ERC20Permit("vlPUFFER") Ownable(msg.sender) {
        PUFFER_TEAM = pufferTeam;
        genesisTime = block.timestamp;

        // Initialize epoch 0
        epochTimestamps[0] = block.timestamp;
        currentEpoch = 0;
    }

    // ------------------------ MODIFIERS ------------------------
    modifier nonZeroValue(uint256 value) {
        if (value == 0) revert ZeroValue();
        _;
    }

    modifier validUnlockTime(uint256 unlockTime) {
        uint256 alignedUnlockTime = (unlockTime / EPOCH_DURATION) * EPOCH_DURATION;
        if (alignedUnlockTime <= block.timestamp) revert FutureLockTimeRequired();
        if (alignedUnlockTime > block.timestamp + MAX_LOCK_TIME) revert ExceedsMaxLockTime();
        _;
    }

    modifier validLockId(address user, uint256 lockId) {
        if (lockId >= userLockCount[user]) revert InvalidLockId();
        _;
    }

    modifier validEpoch(uint256 epoch) {
        if (epoch > getCurrentEpoch()) revert InvalidEpoch();
        _;
    }

    // ------------------------ ADMIN FUNCTIONS ------------------------

    /**
     * @notice Pause the contract
     * @dev Can only be called by the contract owner
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the contract
     * @dev Can only be called by the contract owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Process epoch transitions manually
     * @dev Used to process transitions when there might be too many epochs to process in a single transaction
     * @param maxCheckpoints Maximum number of checkpoints to process
     */
    function processEpochTransitions(uint256 maxCheckpoints) external onlyOwner {
        if (maxCheckpoints == 0 || maxCheckpoints > MAX_CHECKPOINTS_PER_TX) {
            maxCheckpoints = MAX_CHECKPOINTS_PER_TX;
        }

        _checkpointEpoch(maxCheckpoints);
    }

    // ------------------------ INTERNAL FUNCTIONS ------------------------

    /**
     * @notice Checks if we've moved to a new epoch and updates epoch data
     * @dev This is called automatically before state-changing operations
     */
    function _checkpointEpoch() internal {
        _checkpointEpoch(MAX_CHECKPOINTS_PER_TX);
    }

    /**
     * @notice Checks if we've moved to a new epoch and updates epoch data with a limit on checkpoints
     * @param maxCheckpoints Maximum number of checkpoints to process
     */
    function _checkpointEpoch(uint256 maxCheckpoints) internal {
        uint256 currentEpochStart = epochTimestamps[currentEpoch];
        uint256 currentTime = block.timestamp;

        // Check if we've moved to a new epoch
        if (currentTime >= currentEpochStart + EPOCH_DURATION) {
            // Calculate how many epochs have passed
            uint256 epochsPassed = (currentTime - currentEpochStart) / EPOCH_DURATION;

            // Limit the number of checkpoints to create
            uint256 checkpointsToCreate = epochsPassed > maxCheckpoints ? maxCheckpoints : epochsPassed;

            if (checkpointsToCreate == 0) return;

            // Create checkpoints for each epoch
            for (uint256 i = 0; i < checkpointsToCreate; i++) {
                uint256 newEpoch = currentEpoch + 1;
                uint256 newEpochTime = currentEpochStart + EPOCH_DURATION * (i + 1);

                // Save the checkpoint
                epochTimestamps[newEpoch] = newEpochTime;

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
     * @notice Calculate active (non-expired) voting power for a user at the current time
     * @param user Address of the user
     * @return Total active voting power of the user
     */
    function _calculateActiveBalanceOf(address user) internal view returns (uint256) {
        uint256 activeBalance = 0;
        uint256 userLockCount_ = userLockCount[user];

        for (uint256 i = 0; i < userLockCount_; i++) {
            Lock memory lock = userLocks[user][i];

            // Only count locks that haven't expired
            if (lock.amount > 0 && block.timestamp < lock.end) {
                activeBalance += lock.vlTokenAmount;
            }
        }

        return activeBalance;
    }

    /**
     * @notice Calculate active (non-expired) voting power for a user at a specific timestamp
     * @param user Address of the user
     * @param timestamp Timestamp at which to calculate the balance
     * @return Active voting power of the user at the specified timestamp
     */
    function _calculateActiveBalanceOfAt(address user, uint256 timestamp) internal view returns (uint256) {
        uint256 activeBalance = 0;
        uint256 userLockCount_ = userLockCount[user];

        for (uint256 i = 0; i < userLockCount_; i++) {
            Lock memory lock = userLocks[user][i];

            // Only count locks that were active at the specified timestamp
            if (lock.amount > 0 && timestamp < lock.end) {
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
     * @param timestamp Timestamp at which to calculate the supply
     * @return Total active voting power across all users at the specified timestamp
     */
    function _calculateTotalActiveSupplyAt(uint256 timestamp) internal view returns (uint256) {
        uint256 activeSupply = 0;
        uint256 userCount = _allUsers.length;

        for (uint256 i = 0; i < userCount; i++) {
            address user = _allUsers[i];
            activeSupply += _calculateActiveBalanceOfAt(user, timestamp);
        }

        return activeSupply;
    }

    /**
     * @notice Remove a user from the tracking array
     * @param user Address of the user to remove
     */
    function _removeUser(address user) internal {
        if (!_isUser[user]) return;

        uint256 index = _userIndex[user];
        uint256 lastIndex = _allUsers.length - 1;

        // Only proceed if the user actually has no active locks
        if (userActiveLockCount[user] > 0) revert NotEnoughActiveLocksForDeletion();

        // If the user is not the last element, move the last element to their position
        if (index != lastIndex) {
            address lastUser = _allUsers[lastIndex];
            _allUsers[index] = lastUser;
            _userIndex[lastUser] = index;
        }

        // Remove the last element
        _allUsers.pop();

        // Update the user's status
        _isUser[user] = false;

        emit UserRemoved(user);
    }

    /**
     * @notice Internal implementation of lock creation logic
     * @param value Amount of PUFFER tokens to lock
     * @param unlockTime Timestamp when the lock will expire
     * @return lockId The ID of the newly created lock
     */
    function _createLock(uint256 value, uint256 unlockTime) internal returns (uint256 lockId) {
        uint256 alignedUnlockTime = (unlockTime / EPOCH_DURATION) * EPOCH_DURATION;

        // Calculate number of epochs
        uint256 numEpochs = (alignedUnlockTime - block.timestamp) / EPOCH_DURATION;

        // Calculate vlToken amount
        uint256 vlTokenAmount = value * numEpochs;

        // Get next lock ID
        lockId = userLockCount[msg.sender]++;

        // Create the lock
        Lock memory newLock = Lock({ amount: value, end: alignedUnlockTime, vlTokenAmount: vlTokenAmount });

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
        lockedSupply = supplyBefore + value;

        // Mint vlTokens but with time-expiry built into the balanceOf and totalSupply functions
        _mint(msg.sender, vlTokenAmount);

        // If this is the first mint and the user hasn't delegated yet,
        // delegate to themselves by default
        if (delegates(msg.sender) == address(0)) {
            _delegate(msg.sender, msg.sender);
        }

        emit Deposit(msg.sender, lockId, value, alignedUnlockTime, vlTokenAmount, block.timestamp);
        emit Supply(supplyBefore, lockedSupply);

        return lockId;
    }

    // ------------------------ PUBLIC / EXTERNAL FUNCTIONS ------------------------

    /**
     * @notice Create a new lock by depositing `value` tokens until `unlockTime`.
     * @param value Amount of PUFFER tokens to lock
     * @param unlockTime Timestamp when the lock will expire
     * @return lockId The ID of the newly created lock
     */
    function createLock(uint256 value, uint256 unlockTime)
        external
        nonReentrant
        whenNotPaused
        nonZeroValue(value)
        validUnlockTime(unlockTime)
        returns (uint256 lockId)
    {
        // Update epoch if needed
        _checkpointEpoch();

        // Transfer PUFFER tokens to this contract using SafeERC20
        PUFFER.safeTransferFrom(msg.sender, address(this), value);

        // Create the lock
        return _createLock(value, unlockTime);
    }

    /**
     * @notice Create a new lock with permit, allowing approval and locking in a single transaction
     * @param value Amount of PUFFER tokens to lock
     * @param unlockTime Timestamp when the lock will expire
     * @param deadline Timestamp until which the signature is valid
     * @param v Recovery byte of the signature
     * @param r First 32 bytes of the signature
     * @param s Second 32 bytes of the signature
     * @return lockId The ID of the newly created lock
     */
    function createLockWithPermit(uint256 value, uint256 unlockTime, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        nonReentrant
        whenNotPaused
        nonZeroValue(value)
        validUnlockTime(unlockTime)
        returns (uint256 lockId)
    {
        // Update epoch if needed
        _checkpointEpoch();

        // Call permit function on PUFFER token
        IERC20Permit(address(PUFFER)).permit(msg.sender, address(this), value, deadline, v, r, s);

        // Transfer PUFFER tokens to this contract using SafeERC20
        PUFFER.safeTransferFrom(msg.sender, address(this), value);

        // Create the lock
        return _createLock(value, unlockTime);
    }

    /**
     * @notice Relock tokens from an expired lock for a new duration
     * @param lockId The ID of the expired lock to relock
     * @param unlockTime New timestamp when the lock will expire
     */
    function relockExpiredLock(uint256 lockId, uint256 unlockTime)
        external
        nonReentrant
        whenNotPaused
        validLockId(msg.sender, lockId)
        validUnlockTime(unlockTime)
    {
        // Update epoch if needed
        _checkpointEpoch();

        Lock storage lock = userLocks[msg.sender][lockId];

        if (lock.amount == 0) revert NoExistingLock();
        if (block.timestamp < lock.end) revert LockNotExpired();

        uint256 amount = lock.amount;
        uint256 oldVlTokenAmount = lock.vlTokenAmount;

        uint256 alignedUnlockTime = (unlockTime / EPOCH_DURATION) * EPOCH_DURATION;

        // Calculate number of epochs for the new lock
        uint256 numEpochs = (alignedUnlockTime - block.timestamp) / EPOCH_DURATION;

        // Calculate new vlToken amount
        uint256 newVlTokenAmount = amount * numEpochs;

        // Update the lock with new end time and token amount
        lock.end = alignedUnlockTime;
        lock.vlTokenAmount = newVlTokenAmount;

        // Update user's vlToken balance
        userVlTokenBalance[msg.sender] = userVlTokenBalance[msg.sender] - oldVlTokenAmount + newVlTokenAmount;

        // Mint new voting power tokens
        _mint(msg.sender, newVlTokenAmount);

        // Burn old tokens (note: voting power might already be 0 due to expiry)
        _burn(msg.sender, oldVlTokenAmount);

        // Emit events
        emit Relock(msg.sender, lockId, amount, alignedUnlockTime, newVlTokenAmount, block.timestamp);
    }

    /**
     * @notice Withdraw tokens from an expired lock
     * @param lockId The ID of the lock to withdraw from
     */
    function withdraw(uint256 lockId) external nonReentrant whenNotPaused validLockId(msg.sender, lockId) {
        // Update epoch if needed
        _checkpointEpoch();

        // Get lock data in memory instead of storage reference
        Lock memory lock = userLocks[msg.sender][lockId];

        if (lock.amount == 0) revert NoExistingLock();
        if (block.timestamp < lock.end) revert LockNotExpired();

        uint256 value = lock.amount;
        uint256 vlTokenValue = lock.vlTokenAmount;

        // Reset the lock using delete (more gas efficient than setting each field to 0)
        delete userLocks[msg.sender][lockId];

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

        // Transfer PUFFER tokens back to user using SafeERC20
        PUFFER.safeTransfer(msg.sender, value);

        emit Withdraw(msg.sender, lockId, value, block.timestamp);
        emit Supply(supplyBefore, lockedSupply);
    }

    /**
     * @notice Emergency withdraw function that works even during shutdown
     * @param lockId The ID of the lock to withdraw from
     */
    function emergencyWithdraw(uint256 lockId) external nonReentrant validLockId(msg.sender, lockId) {
        // This function can be used even when the contract is paused
        if (!paused()) revert EmergencyUnlockNotEnabled();

        // Get lock data in memory instead of storage reference
        Lock memory lock = userLocks[msg.sender][lockId];

        if (lock.amount == 0) revert NoExistingLock();

        uint256 value = lock.amount;
        uint256 vlTokenValue = lock.vlTokenAmount;

        // Reset the lock using delete (more gas efficient than setting each field to 0)
        delete userLocks[msg.sender][lockId];

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

        // Transfer PUFFER tokens back to user using SafeERC20
        PUFFER.safeTransfer(msg.sender, value);

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
     * @param user Address of the user
     * @param lockId ID of the lock to query
     * @return Lock struct containing the lock details
     */
    function getLock(address user, uint256 lockId) external view validLockId(user, lockId) returns (Lock memory) {
        return userLocks[user][lockId];
    }

    /**
     * @notice Get the total number of locks for a user
     * @param user Address of the user
     * @return Number of locks created by the user
     */
    function getLockCount(address user) external view returns (uint256) {
        return userLockCount[user];
    }

    /**
     * @notice Get the total number of active locks for a user
     * @param user Address of the user
     * @return Number of active locks for the user
     */
    function getActiveLockCount(address user) external view returns (uint256) {
        return userActiveLockCount[user];
    }

    /**
     * @notice Get locks for a user with pagination
     * @param user Address of the user
     * @param offset Starting index for pagination
     * @param limit Maximum number of locks to return
     * @return Array of Lock structs for the user
     */
    function getLocks(address user, uint256 offset, uint256 limit) external view returns (Lock[] memory) {
        uint256 count = userLockCount[user];

        if (offset >= count) {
            return new Lock[](0);
        }

        // Limit to MAX_PAGINATION_SIZE
        if (limit > MAX_PAGINATION_SIZE) {
            limit = MAX_PAGINATION_SIZE;
        }

        // Adjust limit if it would exceed available locks
        uint256 available = count - offset;
        limit = limit > available ? available : limit;

        Lock[] memory locks = new Lock[](limit);

        for (uint256 i = 0; i < limit; i++) {
            locks[i] = userLocks[user][offset + i];
        }

        return locks;
    }

    /**
     * @notice Get all locks for a user (for backward compatibility, may hit gas limits for users with many locks)
     * @param user Address of the user
     * @return Array of Lock structs for the user
     */
    function getAllLocks(address user) external view returns (Lock[] memory) {
        uint256 count = userLockCount[user];
        Lock[] memory locks = new Lock[](count);

        for (uint256 i = 0; i < count; i++) {
            locks[i] = userLocks[user][i];
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
     * @param user Address of the user
     * @param offset Starting index for pagination
     * @param limit Maximum number of lock IDs to return
     * @return Array of lock IDs that have expired but not yet withdrawn
     */
    function getExpiredLocks(address user, uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        uint256 count = userLockCount[user];

        if (offset >= count) {
            return new uint256[](0);
        }

        // Limit to MAX_PAGINATION_SIZE
        if (limit > MAX_PAGINATION_SIZE) {
            limit = MAX_PAGINATION_SIZE;
        }

        // First pass to count expired locks
        uint256 expiredCount = 0;
        for (uint256 i = offset; i < count && i < offset + limit; i++) {
            Lock memory lock = userLocks[user][i];
            if (lock.amount > 0 && block.timestamp >= lock.end) {
                expiredCount++;
            }
        }

        // Second pass to fill the array
        uint256[] memory expiredLockIds = new uint256[](expiredCount);
        uint256 index = 0;
        for (uint256 i = offset; i < count && i < offset + limit; i++) {
            Lock memory lock = userLocks[user][i];
            if (lock.amount > 0 && block.timestamp >= lock.end) {
                expiredLockIds[index] = i;
                index++;
            }
        }

        return expiredLockIds;
    }

    /**
     * @notice Get all expired locks for a user (for backward compatibility)
     * @param user Address of the user
     * @return Array of lock IDs that have expired but not yet withdrawn
     */
    function getExpiredLocks(address user) external view returns (uint256[] memory) {
        uint256 count = userLockCount[user];
        uint256[] memory expiredLockIds = new uint256[](count);
        uint256 expiredCount = 0;

        for (uint256 i = 0; i < count; i++) {
            Lock memory lock = userLocks[user][i];
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
        uint256 epochsPassed = (block.timestamp - genesisTime) / EPOCH_DURATION;
        return epochsPassed;
    }

    /**
     * @notice Calculate the timestamp of a specific epoch
     * @param epoch Epoch number to query
     * @return Timestamp when the epoch starts
     */
    function getEpochTimestamp(uint256 epoch) public view validEpoch(epoch) returns (uint256) {
        return epochTimestamps[epoch] > 0 ? epochTimestamps[epoch] : genesisTime + (epoch * EPOCH_DURATION);
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
     * @param epoch Epoch number to query
     * @return Active voting power of the account at the specified epoch
     */
    function balanceOfAtEpoch(address account, uint256 epoch) public view validEpoch(epoch) returns (uint256) {
        uint256 timestamp = getEpochTimestamp(epoch);
        return _calculateActiveBalanceOfAt(account, timestamp);
    }

    /**
     * @notice Returns the total active voting power at a specific epoch
     * @param epoch Epoch number to query
     * @return Total active voting power across all users at the specified epoch
     */
    function totalSupplyAtEpoch(uint256 epoch) public view validEpoch(epoch) returns (uint256) {
        uint256 timestamp = getEpochTimestamp(epoch);
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

    // ------------------------ OVERRIDES REQUIRED BY SOLIDITY ------------------------

    /**
     * @dev Override the _update function to disable transfers of vlPUFFER tokens.
     * vlPUFFER tokens represent specific locks and cannot be transferred as they
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
