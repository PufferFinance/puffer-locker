// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ERC20Votes } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Nonces } from "@openzeppelin/contracts/utils/Nonces.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

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
 * - Delegation of voting power to other addresses
 * - Epoch-based tracking system for potential governance snapshots
 * - Two-step ownership transfer for enhanced security
 */
contract PufferLocker is ERC20, ERC20Permit, ERC20Votes, Ownable2Step, Pausable {
    // ------------------------ ERRORS ------------------------
    error ZeroValue();
    error NoExistingLock();
    error LockNotExpired();
    error FutureLockTimeRequired();
    error ExceedsMaxLockTime();
    error InvalidLockId();
    error TransfersDisabled();
    error InvalidEpoch();

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
    event EpochTransition(uint256 indexed epochId, uint256 timestamp, uint256 totalSupply);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event Relock(
        address indexed provider,
        uint256 indexed lockId,
        uint256 value,
        uint256 newLocktime,
        uint256 newVlTokenAmount,
        uint256 ts
    );

    // ------------------------ STATE VARIABLES ------------------------
    // Puffer token address is set in constructor and immutable
    IERC20 public immutable PUFFER;
    uint256 private constant MAX_LOCK_TIME = 2 * 365 days; // 2 years
    uint256 private constant EPOCH_DURATION = 2 weeks;
    uint256 public immutable genesisTime; // Time when the contract was deployed (epoch 0)
    uint256 public currentEpoch;
    uint256 public activeVotingSupply; // Globally active (non-expired) voting supply. Cheap O(1) totalSupply.
    uint256 public lockedSupply; // Total tokens locked as collateral

    // Amount of vlPUFFER that expires at the given epoch id (relative to genesisTime)
    mapping(uint256 epochId => uint256 amount) private _epochExpiringSupply;

    // User locks and related data - changed from mapping to array
    mapping(address user => Lock[] locks) public userLocks;
    mapping(address user => uint256 balance) public userVlTokenBalance;

    // Use SafeERC20 for token operations
    using SafeERC20 for IERC20;

    // ------------------------ CONSTRUCTOR ------------------------
    constructor(address pufferToken) ERC20("vlPUFFER", "vlPUFFER") ERC20Permit("vlPUFFER") Ownable(msg.sender) {
        PUFFER = IERC20(pufferToken);
        genesisTime = block.timestamp;
    }

    // ------------------------ MODIFIERS ------------------------
    modifier validUnlockTime(uint256 unlockTime) {
        uint256 alignedUnlockTime = _alignToEpoch(unlockTime);
        if (alignedUnlockTime <= block.timestamp) revert FutureLockTimeRequired();
        if (alignedUnlockTime > block.timestamp + MAX_LOCK_TIME) revert ExceedsMaxLockTime();
        _;
    }

    modifier validLockId(address user, uint256 lockId) {
        if (lockId >= userLocks[user].length) revert InvalidLockId();
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

    // ------------------------ INTERNAL FUNCTIONS ------------------------

    /**
     * @notice Aligns a timestamp to the nearest epoch boundary
     * @param timestamp The timestamp to align
     * @return The timestamp aligned to the epoch boundary
     */
    function _alignToEpoch(uint256 timestamp) internal pure returns (uint256) {
        return (timestamp / EPOCH_DURATION) * EPOCH_DURATION;
    }

    /**
     * @notice Checks if we've moved to a new epoch and updates epoch data
     * @dev This is called automatically before state-changing operations
     */
    function _checkpointEpoch() internal {
        uint256 currentTime = block.timestamp;
        uint256 currentEpochStart = genesisTime + (currentEpoch * EPOCH_DURATION);

        // Check if we've moved to a new epoch
        if (currentTime >= currentEpochStart + EPOCH_DURATION) {
            // Calculate how many epochs have passed
            uint256 epochsPassed = (currentTime - currentEpochStart) / EPOCH_DURATION;

            // Create checkpoints for each epoch
            for (uint256 i = 0; i < epochsPassed; i++) {
                currentEpoch++;
                uint256 newEpochTime = currentEpochStart + EPOCH_DURATION * (i + 1);

                // ---- Supply expiration ----
                uint256 expiringAmount = _epochExpiringSupply[currentEpoch];
                if (expiringAmount != 0) {
                    activeVotingSupply -= expiringAmount;
                    delete _epochExpiringSupply[currentEpoch];
                }

                emit EpochTransition(currentEpoch, newEpochTime, activeVotingSupply);
            }
        }
    }

    /**
     * @notice Calculate active (non-expired) voting power for a user at the current time
     * @param user Address of the user
     * @return Total active voting power of the user
     */
    function _calculateActiveBalanceOf(address user) internal view returns (uint256) {
        return _calculateActiveBalanceOfAt(user, block.timestamp);
    }

    /**
     * @notice Calculate active (non-expired) voting power for a user at a specific timestamp
     * @param user Address of the user
     * @param timestamp Timestamp at which to calculate the balance
     * @return Active voting power of the user at the specified timestamp
     */
    function _calculateActiveBalanceOfAt(address user, uint256 timestamp) internal view returns (uint256) {
        uint256 activeBalance = 0;
        Lock[] storage userLocksArray = userLocks[user];
        uint256 userLockCount = userLocksArray.length;

        for (uint256 i = 0; i < userLockCount; i++) {
            Lock storage lock = userLocksArray[i];

            // Only count locks that were active at the specified timestamp
            if (lock.amount > 0 && timestamp < lock.end) {
                activeBalance += lock.vlTokenAmount;
            }
        }

        return activeBalance;
    }

    /**
     * @notice Calculate active voting power at an arbitrary timestamp by
     *         summing amounts scheduled to expire after that time.
     * @dev This loops over at most MAX_LOCK_TIME / EPOCH_DURATION (≈52)
     *      buckets so it is always bounded.
     */
    function _calculateTotalActiveSupplyAt(uint256 timestamp) internal view returns (uint256) {
        uint256 startEpoch = (timestamp - genesisTime) / EPOCH_DURATION;
        uint256 maxEpoch = startEpoch + (MAX_LOCK_TIME / EPOCH_DURATION);

        uint256 activeSupply = 0;
        for (uint256 e = startEpoch + 1; e <= maxEpoch; e++) {
            activeSupply += _epochExpiringSupply[e];
        }
        return activeSupply;
    }

    /**
     * @notice Internal implementation of lock creation logic
     * @param value Amount of PUFFER tokens to lock
     * @param unlockTime Timestamp when the lock will expire
     * @return lockId The ID of the newly created lock
     */
    function _createLock(uint256 value, uint256 unlockTime) internal returns (uint256 lockId) {
        uint256 alignedUnlockTime = _alignToEpoch(unlockTime);

        // Calculate number of epochs
        uint256 numEpochs = (alignedUnlockTime - block.timestamp) / EPOCH_DURATION;

        // Calculate vlToken amount
        uint256 vlTokenAmount = value * numEpochs;

        // Create the lock
        Lock memory newLock = Lock({ amount: value, end: alignedUnlockTime, vlTokenAmount: vlTokenAmount });

        // Add to user's locks array and get lock ID
        userLocks[msg.sender].push(newLock);
        lockId = userLocks[msg.sender].length - 1;

        // Update user's vlToken balance
        userVlTokenBalance[msg.sender] += vlTokenAmount;

        // ---- Epoch supply tracking ----
        uint256 endEpochId = (alignedUnlockTime - genesisTime) / EPOCH_DURATION;
        _epochExpiringSupply[endEpochId] += vlTokenAmount;
        activeVotingSupply += vlTokenAmount;

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

    /**
     * @notice Internal helper function to execute common withdrawal logic
     * @param lockId The ID of the lock to withdraw from
     * @param lock The lock storage reference
     * @return value The amount of PUFFER tokens withdrawn
     */
    function _executeWithdrawal(uint256 lockId, Lock storage lock) private returns (uint256 value) {
        value = lock.amount;
        uint256 vlTokenValue = lock.vlTokenAmount;

        // Update user's vlToken balance
        userVlTokenBalance[msg.sender] -= vlTokenValue;

        // Update locked supply
        uint256 supplyBefore = lockedSupply;
        lockedSupply = supplyBefore - value;

        // Burn vlTokens
        _burn(msg.sender, vlTokenValue);

        // Transfer PUFFER tokens back to user using SafeERC20
        PUFFER.safeTransfer(msg.sender, value);

        // Optimize the array by moving the last element to the position of the deleted lock
        uint256 lastLockIndex = userLocks[msg.sender].length - 1;
        if (lockId != lastLockIndex) {
            userLocks[msg.sender][lockId] = userLocks[msg.sender][lastLockIndex];
        }
        userLocks[msg.sender].pop();

        emit Supply(supplyBefore, lockedSupply);
    }

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

    // ------------------------ EXTERNAL & PUBLIC FUNCTIONS ------------------------

    /**
     * @notice Create a new lock by depositing `value` tokens until `unlockTime`.
     * @param value Amount of PUFFER tokens to lock
     * @param unlockTime Timestamp when the lock will expire
     * @return lockId The ID of the newly created lock
     */
    function createLock(uint256 value, uint256 unlockTime)
        external
        whenNotPaused
        validUnlockTime(unlockTime)
        returns (uint256 lockId)
    {
        if (value == 0) revert ZeroValue();

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
        whenNotPaused
        validUnlockTime(unlockTime)
        returns (uint256 lockId)
    {
        if (value == 0) revert ZeroValue();

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

        // Align unlock time to epoch boundary and calculate epochs
        uint256 alignedUnlockTime = _alignToEpoch(unlockTime);
        uint256 numEpochs = (alignedUnlockTime - block.timestamp) / EPOCH_DURATION;

        // Calculate new vlToken amount
        uint256 newVlTokenAmount = amount * numEpochs;

        // Update the lock with new end time and token amount
        lock.end = alignedUnlockTime;
        lock.vlTokenAmount = newVlTokenAmount;

        // Update user's vlToken balance
        userVlTokenBalance[msg.sender] = userVlTokenBalance[msg.sender] - oldVlTokenAmount + newVlTokenAmount;

        // ---- Epoch supply tracking ----
        // Note: lock.end is updated later, so store old end epoch prior
        uint256 newEndEpochId = (alignedUnlockTime - genesisTime) / EPOCH_DURATION;

        // Only add the new voting power because the old one has already expired and
        // was removed from activeVotingSupply when its epoch passed.
        _epochExpiringSupply[newEndEpochId] += newVlTokenAmount;
        activeVotingSupply += newVlTokenAmount;

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
    function withdraw(uint256 lockId) external whenNotPaused validLockId(msg.sender, lockId) {
        // Update epoch if needed
        _checkpointEpoch();

        Lock storage lock = userLocks[msg.sender][lockId];

        if (lock.amount == 0) revert NoExistingLock();
        if (block.timestamp < lock.end) revert LockNotExpired();

        // Execute the common withdrawal logic and get the withdrawn amount
        uint256 value = _executeWithdrawal(lockId, lock);

        emit Withdraw(msg.sender, lockId, value, block.timestamp);
    }

    /**
     * @notice Emergency withdraw function that works even during shutdown
     * @param lockId The ID of the lock to withdraw from
     */
    function emergencyWithdraw(uint256 lockId) external whenPaused validLockId(msg.sender, lockId) {
        Lock storage lock = userLocks[msg.sender][lockId];

        if (lock.amount == 0) revert NoExistingLock();

        // Execute the common withdrawal logic and get the withdrawn amount
        uint256 value = _executeWithdrawal(lockId, lock);

        emit EmergencyWithdraw(msg.sender, value);
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
        return userLocks[user].length;
    }

    /**
     * @notice Get all locks for a user
     * @param user Address of the user
     * @return Array of Lock structs for the user
     */
    function getAllLocks(address user) external view returns (Lock[] memory) {
        return userLocks[user];
    }
    
    /**
     * @notice Get current total locked supply (collateral tokens)
     * @return Total amount of PUFFER tokens locked in the contract
     */
    function totalLockedSupply() external view returns (uint256) {
        return lockedSupply;
    }

    /**
     * @notice Get all expired locks for a user
     * @param user Address of the user
     * @return Array of lock IDs that have expired but not yet withdrawn
     */
    function getExpiredLocks(address user) external view returns (uint256[] memory) {
        Lock[] storage userLocksArray = userLocks[user];
        uint256 count = userLocksArray.length;
        uint256[] memory expiredLockIds = new uint256[](count);
        uint256 expiredCount = 0;

        for (uint256 i = 0; i < count; i++) {
            Lock storage lock = userLocksArray[i];
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
     * @return epoch Current epoch number based on time passed since contract deployment
     */
    function getCurrentEpoch() public view returns (uint256 epoch) {
        epoch = (block.timestamp - genesisTime) / EPOCH_DURATION;
    }

    /**
     * @notice Calculate the timestamp of a specific epoch
     * @param epoch Epoch number to query
     * @return Timestamp when the epoch starts
     */
    function getEpochTimestamp(uint256 epoch) public view validEpoch(epoch) returns (uint256) {
        return genesisTime + (epoch * EPOCH_DURATION);
    }

    /**
     * @notice Returns the active (non-expired) voting power of an account
     * @param account Address of the account
     * @return Active voting power of the account
     */
    function balanceOf(address account) public view override returns (uint256) {
        if (super.balanceOf(account) == 0) {
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
        if (super.totalSupply() == 0) {
            return 0;
        }

        // Calculate only the active portion
        return _calculateTotalActiveSupplyAt(block.timestamp);
    }

    /**
     * @notice Returns the active voting power of an account at a specific epoch
     * @param account Address of the account
     * @param epoch Epoch number to query
     * @return Active voting power of the account at the specified epoch
     */
    function balanceOfAtEpoch(address account, uint256 epoch) public view validEpoch(epoch) returns (uint256) {
        return _calculateActiveBalanceOfAt(account, getEpochTimestamp(epoch));
    }

    /**
     * @notice Returns the total active voting power at a specific epoch
     * @param epoch Epoch number to query
     * @return Total active voting power across all users at the specified epoch
     */
    function totalSupplyAtEpoch(uint256 epoch) public view validEpoch(epoch) returns (uint256) {
        return _calculateTotalActiveSupplyAt(getEpochTimestamp(epoch));
    }

    /**
     * @notice Get raw vlToken balance (including expired tokens)
     * @param account Address of the account
     * @return Total vlToken balance of the account, including expired tokens
     */
    function getRawBalance(address account) external view returns (uint256) {
        return super.balanceOf(account);
    }

    // ------------------------ OVERRIDES REQUIRED BY SOLIDITY ------------------------

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
