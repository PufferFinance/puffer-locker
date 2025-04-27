// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title PufferLocker
 * @notice Lock-based ERC20 token that grants voting power according to lock duration, 
 *         compatible with OpenZeppelin ERC20Votes.
 */
contract PufferLocker is ERC20, ERC20Permit, ERC20Votes, ReentrancyGuard {
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

    // ------------------------ STRUCTS ------------------------
    struct Lock {
        uint256 amount;        // Amount of PUFFER tokens locked
        uint256 end;           // Timestamp when the lock expires
        uint256 vlTokenAmount; // Amount of vlPuffer tokens minted for this lock
    }

    // ------------------------ EVENTS ------------------------
    event Deposit(address indexed provider, uint256 indexed lockId, uint256 value, uint256 locktime, uint256 vlTokenAmount, uint256 ts);
    event Withdraw(address indexed provider, uint256 indexed lockId, uint256 value, uint256 ts);
    event Supply(uint256 prevSupply, uint256 supply);

    // ------------------------ STATE VARIABLES ------------------------
    IERC20 public immutable PUFFER;
    uint256 public immutable MAX_LOCK_TIME = 2 * 365 days; // 2 years
    uint256 public constant EPOCH_DURATION = 1 weeks;
    uint256 public lockedSupply;

    // User address => lock ID => Lock details
    mapping(address => mapping(uint256 => Lock)) public userLocks;
    // User address => number of locks created (also used as next lock ID)
    mapping(address => uint256) public userLockCount;
    // User address => total vlPuffer balance
    mapping(address => uint256) public userVlTokenBalance;

    // ------------------------ CONSTRUCTOR ------------------------
    constructor(IERC20 _puffer)
        ERC20("vlPuffer", "vlPuffer")
        ERC20Permit("vlPuffer")
    {
        PUFFER = _puffer;
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

    // ------------------------ PUBLIC / EXTERNAL FUNCTIONS ------------------------

    /**
     * @notice Create a new lock by depositing `_value` tokens until `_unlockTime`.
     * @return lockId The ID of the newly created lock
     */
    function createLock(uint256 _value, uint256 _unlockTime) 
        external 
        nonReentrant
        nonZeroValue(_value) 
        validUnlockTime(_unlockTime) 
        returns (uint256 lockId)
    {
        uint256 unlockTime = (_unlockTime / EPOCH_DURATION) * EPOCH_DURATION;
        
        // Calculate number of epochs
        uint256 numEpochs = (unlockTime - block.timestamp) / EPOCH_DURATION;
        
        // Calculate vlToken amount
        uint256 vlTokenAmount = _value * numEpochs;
        
        // Get next lock ID
        lockId = userLockCount[msg.sender]++;
        
        // Create the lock
        Lock memory newLock = Lock({
            amount: _value,
            end: unlockTime,
            vlTokenAmount: vlTokenAmount
        });
        
        userLocks[msg.sender][lockId] = newLock;
        
        // Update user's vlToken balance
        userVlTokenBalance[msg.sender] += vlTokenAmount;
        
        // Update locked supply
        uint256 supplyBefore = lockedSupply;
        lockedSupply = supplyBefore + _value;
        
        // Mint vlTokens
        _mint(msg.sender, vlTokenAmount);
        
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
    function withdraw(uint256 _lockId) 
        external 
        nonReentrant
        validLockId(msg.sender, _lockId) 
    {
        Lock storage lock = userLocks[msg.sender][_lockId];
        
        if (lock.amount == 0) revert NoExistingLock();
        if (block.timestamp < lock.end) revert LockNotExpired();
        
        uint256 value = lock.amount;
        uint256 vlTokenValue = lock.vlTokenAmount;
        
        // Reset the lock (prevent reentrancy)
        lock.amount = 0;
        lock.end = 0;
        lock.vlTokenAmount = 0;
        
        // Update user's vlToken balance
        userVlTokenBalance[msg.sender] -= vlTokenValue;
        
        // Update locked supply
        uint256 supplyBefore = lockedSupply;
        lockedSupply = supplyBefore - value;
        
        // Burn vlTokens
        _burn(msg.sender, vlTokenValue);
        
        // Transfer PUFFER tokens back to user
        bool ok = PUFFER.transfer(msg.sender, value);
        if (!ok) revert TransferFailed();
        
        emit Withdraw(msg.sender, _lockId, value, block.timestamp);
        emit Supply(supplyBefore, lockedSupply);
    }

    /**
     * @notice Get a user's lock details by lock ID
     */
    function getLock(address _user, uint256 _lockId) external view validLockId(_user, _lockId) returns (Lock memory) {
        return userLocks[_user][_lockId];
    }

    /**
     * @notice Get the total number of locks for a user
     */
    function getLockCount(address _user) external view returns (uint256) {
        return userLockCount[_user];
    }

    /**
     * @notice Get all locks for a user
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
     * @notice Get current total locked supply
     */
    function totalLockedSupply() external view returns (uint256) {
        return lockedSupply;
    }

    /**
     * @notice Get all expired locks for a user
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
     * @notice Returns the non-decaying voting power of an account
     */
    function balanceOf(address account) public view override returns (uint256) {
        return userVlTokenBalance[account];
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