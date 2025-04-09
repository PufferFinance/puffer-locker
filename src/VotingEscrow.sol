// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/**
 * @title VotingEscrow
 * @notice Lock-based ERC20 token that grants voting power according to lock duration, 
 *         compatible with OpenZeppelin ERC20Votes.
 */
contract VotingEscrow is ERC20, ERC20Permit, ERC20Votes {
    // ------------------------ ERRORS ------------------------
    error NotEOA();
    error ZeroValue();
    error NoExistingLock();
    error LockExpired();
    error LockNotExpired();
    error LockAlreadyExists();
    error FutureLockTimeRequired();
    error ExceedsMaxLockTime();
    error MustExtendBeyondCurrentLock();
    error TransferFailed();
    error BlockOutOfRange();

    // ------------------------ STRUCTS ------------------------
    struct Point {
        int128 bias;
        int128 slope;
        uint256 ts;
        uint256 blk;
    }

    struct LockedBalance {
        int128 amount;
        uint256 end;
    }

    // ------------------------ EVENTS ------------------------
    event Deposit(address indexed provider, uint256 value, uint256 locktime, int128 depositType, uint256 ts);
    event Withdraw(address indexed provider, uint256 value, uint256 ts);
    event Supply(uint256 prevSupply, uint256 supply);

    // ------------------------ STATE VARIABLES ------------------------
    IERC20 public immutable PUFFER;
    uint256 public immutable maxLockTime;
    uint256 public lockedSupply;
    mapping(address => LockedBalance) public lockedBalances;
    mapping(uint256 => int128) public slopeChanges;
    mapping(uint256 => Point) public pointHistory;
    uint256 public epoch;
    mapping(address => mapping(uint256 => Point)) public userPointHistory;
    mapping(address => uint256) public userPointEpoch;
    mapping(address => mapping(uint256 => int128)) internal _userSlopeChanges;

    uint256 internal constant MULTIPLIER = 10**18;

    // ------------------------ CONSTRUCTOR ------------------------
    constructor(IERC20 _puffer, uint256 _maxLockTime)
        ERC20("vePUFFER", "vePUFFER")
        ERC20Permit("vePUFFER")
    {
        PUFFER = _puffer;
        maxLockTime = _maxLockTime;
    }

    // ------------------------ MODIFIERS ------------------------
    modifier onlyEOA() {
        if (msg.sender != tx.origin) revert NotEOA();
        _;
    }

    modifier nonZeroValue(uint256 _value) {
        if (_value == 0) revert ZeroValue();
        _;
    }

    modifier hasActiveLock(address _addr) {
        LockedBalance memory locked = lockedBalances[_addr];
        if (locked.amount <= 0) revert NoExistingLock();
        if (locked.end <= block.timestamp) revert LockExpired();
        _;
    }

    modifier validUnlockTime(uint256 _unlockTime) {
        uint256 unlockTime = (_unlockTime / 1 weeks) * 1 weeks;
        if (unlockTime <= block.timestamp) revert FutureLockTimeRequired();
        if (unlockTime > block.timestamp + maxLockTime) revert ExceedsMaxLockTime();
        _;
    }

    modifier validBlock(uint256 _block) {
        if (_block > block.number) revert BlockOutOfRange();
        _;
    }

    // ------------------------ PUBLIC / EXTERNAL FUNCTIONS ------------------------

    /**
     * @notice Deposit tokens for another address without changing its lock end time. 
     *         Requires an existing lock for that address.
     */
    function depositFor(address _addr, uint256 _value) external onlyEOA nonZeroValue(_value) hasActiveLock(_addr) {
        LockedBalance memory locked = lockedBalances[_addr];
        _depositFor(_addr, _value, 0, locked, 0);
    }

    /**
     * @notice Create a new lock by depositing `_value` tokens until `_unlockTime`.
     */
    function createLock(uint256 _value, uint256 _unlockTime) 
        external 
        onlyEOA 
        nonZeroValue(_value) 
        validUnlockTime(_unlockTime) 
    {
        uint256 unlockTime = (_unlockTime / 1 weeks) * 1 weeks;
        LockedBalance memory locked = lockedBalances[msg.sender];

        if (locked.amount > 0) revert LockAlreadyExists();

        _depositFor(msg.sender, _value, unlockTime, locked, 1);
    }

    /**
     * @notice Increase the locked amount for the caller.
     */
    function increaseAmount(uint256 _value) external onlyEOA nonZeroValue(_value) hasActiveLock(msg.sender) {
        LockedBalance memory locked = lockedBalances[msg.sender];
        _depositFor(msg.sender, _value, 0, locked, 2);
    }

    /**
     * @notice Extend the unlock time for the caller.
     */
    function increaseUnlockTime(uint256 _unlockTime) external onlyEOA validUnlockTime(_unlockTime) {
        LockedBalance memory locked = lockedBalances[msg.sender];
        uint256 unlockTime = (_unlockTime / 1 weeks) * 1 weeks;

        if (locked.amount <= 0) revert NoExistingLock();
        if (locked.end <= block.timestamp) revert LockExpired();
        if (unlockTime <= locked.end) revert MustExtendBeyondCurrentLock();

        _depositFor(msg.sender, 0, unlockTime, locked, 3);
    }

    /**
     * @notice Withdraw all tokens for the caller if the lock is expired.
     */
    function withdraw() external onlyEOA {
        LockedBalance memory locked = lockedBalances[msg.sender];
        if (block.timestamp < locked.end) revert LockNotExpired();

        uint256 value = uint256(int256(locked.amount));
        LockedBalance memory oldLocked = locked;
        locked.amount = 0;
        locked.end = 0;
        lockedBalances[msg.sender] = locked;

        uint256 supplyBefore = lockedSupply;
        lockedSupply = supplyBefore - value;
        _checkpoint(msg.sender, oldLocked, locked);

        bool ok = PUFFER.transfer(msg.sender, value);
        if (!ok) revert TransferFailed();

        emit Withdraw(msg.sender, value, block.timestamp);
        emit Supply(supplyBefore, lockedSupply);
    }

    /**
     * @notice Get current total locked supply (voting power).
     */
    function totalLockedSupply() external view returns (uint256) {
        return lockedSupply;
    }

    /**
     * @notice Returns the current slope-based voting power of an account.
     */
    function balanceOf(address account) public view override returns (uint256) {
        uint256 userEpoch = userPointEpoch[account];
        if (userEpoch == 0) {
            return 0;
        }
        Point memory pt = userPointHistory[account][userEpoch];
        int128 timeDelta = int128(int256(block.timestamp - pt.ts));
        int128 currentBias = pt.bias - pt.slope * timeDelta;
        if (currentBias < 0) currentBias = 0;
        return uint256(int256(currentBias));
    }

    /**
     * @notice Returns slope-based total supply at current time.
     */
    function totalSupply() public view override(ERC20) returns (uint256) {
        uint256 _epoch = epoch;
        Point memory lastPoint = pointHistory[_epoch];
        return _supplyAt(lastPoint, block.timestamp);
    }

    /**
     * @notice Returns the slope-based total supply at a specific block.
     */
    function totalSupplyAtBlock(uint256 _block) external view validBlock(_block) returns (uint256) {
        uint256 _epoch = epoch;
        uint256 targetEpoch = _findBlockEpoch(_block, _epoch);
        Point memory point = pointHistory[targetEpoch];

        uint256 epochNext = targetEpoch < _epoch ? targetEpoch + 1 : targetEpoch;
        uint256 blockTime = 0;

        if (epochNext <= _epoch) {
            Point memory pointNext = pointHistory[epochNext];
            if (point.blk != pointNext.blk) {
                uint256 dBlock = pointNext.blk - point.blk;
                uint256 dTime = pointNext.ts - point.ts;
                blockTime = point.ts + (dTime * (_block - point.blk)) / dBlock;
            } else {
                blockTime = point.ts;
            }
        } else {
            if (point.blk != block.number) {
                uint256 dBlock = block.number - point.blk;
                uint256 dTime = block.timestamp - point.ts;
                blockTime = point.ts + (dTime * (_block - point.blk)) / dBlock;
            } else {
                blockTime = point.ts;
            }
        }

        return _supplyAt(point, blockTime);
    }

    /**
     * @notice Returns the slope-based voting balance of `_addr` at block `_block`.
     */
    function balanceOfAt(address _addr, uint256 _block) external view validBlock(_block) returns (uint256) {
        uint256 min_ = 0;
        uint256 max_ = userPointEpoch[_addr];
        for (uint256 i = 0; i < 128; i++) {
            if (min_ >= max_) {
                break;
            }
            uint256 mid = (min_ + max_ + 1) / 2;
            if (userPointHistory[_addr][mid].blk <= _block) {
                min_ = mid;
            } else {
                max_ = mid - 1;
            }
        }

        Point memory upoint = userPointHistory[_addr][min_];
        uint256 _epoch = epoch;
        uint256 targetEpoch = _findBlockEpoch(_block, _epoch);
        Point memory point0 = pointHistory[targetEpoch];
        uint256 blockTime = 0;

        if (targetEpoch < _epoch) {
            Point memory point1 = pointHistory[targetEpoch + 1];
            if (point0.blk != point1.blk) {
                uint256 dBlock = point1.blk - point0.blk;
                uint256 dTime = point1.ts - point0.ts;
                blockTime = point0.ts + (dTime * (_block - point0.blk)) / dBlock;
            } else {
                blockTime = point0.ts;
            }
        } else {
            if (point0.blk != block.number) {
                uint256 dBlock = block.number - point0.blk;
                uint256 dTime = block.timestamp - point0.ts;
                blockTime = point0.ts + (dTime * (_block - point0.blk)) / dBlock;
            } else {
                blockTime = point0.ts;
            }
        }

        int128 dt = int128(int256(blockTime - upoint.ts));
        int128 newBias = upoint.bias - upoint.slope * dt;
        if (newBias < 0) {
            newBias = 0;
        }
        return uint256(int256(newBias));
    }

    // ------------------------ INTERNAL FUNCTIONS ------------------------

    /**
     * @dev Deposits `_value` tokens for `_addr`, optionally setting a new unlock time, 
     *      and updates checkpoints for slope/bias accounting.
     */
    function _depositFor(
        address _addr,
        uint256 _value,
        uint256 unlockTime,
        LockedBalance memory lockedBalance,
        int128 depositType
    ) internal {
        LockedBalance memory oldLocked = lockedBalance;
        uint256 supplyBefore = lockedSupply;

        lockedSupply = supplyBefore + _value;
        lockedBalance.amount += int128(int256(_value));
        if (unlockTime != 0) {
            lockedBalance.end = unlockTime;
        }
        lockedBalances[_addr] = lockedBalance;

        _checkpoint(_addr, oldLocked, lockedBalance);

        if (_value > 0) {
            bool ok = PUFFER.transferFrom(_addr, address(this), _value);
            if (!ok) revert TransferFailed();
        }

        emit Deposit(_addr, _value, lockedBalance.end, depositType, block.timestamp);
        emit Supply(supplyBefore, lockedSupply);
    }

    /**
     * @dev Updates global and user-specific slope/bias at the current timestamp. 
     */
    function _checkpoint(
        address _addr,
        LockedBalance memory oldLocked,
        LockedBalance memory newLocked
    ) internal {
        Point memory lastPoint = epoch > 0
            ? pointHistory[epoch]
            : Point(0, 0, block.timestamp, block.number);
        uint256 lastCheckpoint = lastPoint.ts;
        uint256 blockSlope = 0;

        if (block.timestamp > lastPoint.ts) {
            blockSlope = (MULTIPLIER * (block.number - lastPoint.blk)) / 
                         (block.timestamp - lastPoint.ts);
        }

        uint256 t_i = (lastCheckpoint / 1 weeks) * 1 weeks;
        for (uint256 i = 0; i < 255; i++) {
            t_i += 1 weeks;
            int128 dSlope = 0;
            if (t_i > block.timestamp) {
                t_i = block.timestamp;
            } else {
                dSlope = slopeChanges[t_i];
            }
            int128 timeDelta = int128(int256(t_i - lastCheckpoint));
            lastPoint.bias -= lastPoint.slope * timeDelta;
            lastPoint.slope += dSlope;
            if (lastPoint.bias < 0) {
                lastPoint.bias = 0;
            }
            if (lastPoint.slope < 0) {
                lastPoint.slope = 0;
            }
            lastCheckpoint = t_i;
            lastPoint.ts = t_i;

            lastPoint.blk = (epoch > 0 ? pointHistory[epoch].blk : lastPoint.blk)
                + (blockSlope * (t_i - pointHistory[epoch].ts)) / MULTIPLIER;

            epoch += 1;
            pointHistory[epoch] = lastPoint;

            if (t_i == block.timestamp) {
                lastPoint.blk = block.number;
                break;
            }
        }

        if (_addr != address(0)) {
            int128 oldSlope = 0;
            int128 newSlope = 0;

            if (oldLocked.end > block.timestamp && oldLocked.amount > 0) {
                oldSlope = oldLocked.amount / int128(int256(maxLockTime));
            }
            if (newLocked.end > block.timestamp && newLocked.amount > 0) {
                newSlope = newLocked.amount / int128(int256(maxLockTime));
            }

            Point memory uNew = Point({
                bias: 0,
                slope: newSlope,
                ts: block.timestamp,
                blk: block.number
            });
            if (newLocked.end > block.timestamp) {
                uNew.bias = newSlope * int128(int256(newLocked.end - block.timestamp));
            }

            int128 oldDSlope = slopeChanges[oldLocked.end];
            int128 newDSlope = slopeChanges[newLocked.end];

            if (oldLocked.end > block.timestamp) {
                oldDSlope += oldSlope;
                if (newLocked.end == oldLocked.end) {
                    oldDSlope -= newSlope;
                }
                slopeChanges[oldLocked.end] = oldDSlope;
            }
            if (newLocked.end > block.timestamp) {
                if (newLocked.end > oldLocked.end) {
                    newDSlope -= newSlope;
                    slopeChanges[newLocked.end] = newDSlope;
                }
            }

            uint256 userEpoch = userPointEpoch[_addr] + 1;
            userPointEpoch[_addr] = userEpoch;
            userPointHistory[_addr][userEpoch] = uNew;
        }
    }

    /**
     * @dev Binary search for the epoch closest to `_block`.
     */
    function _findBlockEpoch(uint256 _block, uint256 maxEpoch) internal view returns (uint256) {
        uint256 min_ = 0;
        uint256 max_ = maxEpoch;
        for (uint256 i = 0; i < 128; i++) {
            if (min_ >= max_) {
                break;
            }
            uint256 mid = (min_ + max_ + 1) / 2;
            if (pointHistory[mid].blk <= _block) {
                min_ = mid;
            } else {
                max_ = mid - 1;
            }
        }
        return min_;
    }

    /**
     * @dev Computes total supply at time `t` from a given point reference.
     */
    function _supplyAt(Point memory point, uint256 t) internal view returns (uint256) {
        Point memory lastPoint = point;
        uint256 t_i = (lastPoint.ts / 1 weeks) * 1 weeks;

        for (uint256 i = 0; i < 255; i++) {
            t_i += 1 weeks;
            int128 dSlope = 0;
            if (t_i > t) {
                t_i = t;
            } else {
                dSlope = slopeChanges[t_i];
            }
            int128 timeDelta = int128(int256(t_i - lastPoint.ts));
            lastPoint.bias -= lastPoint.slope * timeDelta;
            if (t_i == t) {
                break;
            }
            lastPoint.slope += dSlope;
            if (lastPoint.bias < 0) {
                lastPoint.bias = 0;
            }
            if (lastPoint.slope < 0) {
                lastPoint.slope = 0;
            }
            lastPoint.ts = t_i;
        }

        if (lastPoint.bias < 0) {
            lastPoint.bias = 0;
        }
        return uint256(int256(lastPoint.bias));
    }

    // ------------------------ OVERRIDES REQUIRED BY SOLIDITY ------------------------

    function _update(address from, address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._update(from, to, amount);
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