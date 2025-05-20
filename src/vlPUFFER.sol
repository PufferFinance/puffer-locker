// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { EIP712 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ERC20Votes } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title vlPUFFER
 * @author Puffer Finance
 * @notice vlPUFFER is a lock-based ERC20 token that grants voting power according to lock duration,
 *         compatible with OpenZeppelin ERC20Votes with time-based voting power expiry.
 *
 * This contract allows users to lock PUFFER tokens for a specified duration.
 * In return, they receive vlPUFFER tokens that represent their voting power.
 * The amount of vlPUFFER tokens received is calculated as follows:
 *
 * The multiplier is 30 days. This means if a user locks for 1 year (365 days) they will get x12 multiplier on their PUFFER tokens
 * but the actual unlock time will be slightly lower than 1 year (~360 days).
 *
 * vlPUFFERAmount = pufferAmount * ((unlockTime - block.timestamp) / _LOCK_TIME_MULTIPLIER);
 *
 * vlPUFFER Multiplier examples:
 * 3 months: x3
 * 6 months: x6
 * 9 months: x9
 * 12 months: x12
 * 15 months: x15
 * 18 months: x18
 * 21 months: x21
 * 24 months: x24
 *
 * Because of the rounding, if a user wants to achieve x3 multiplier, they should do a transaction where unlockTime is 3 months + 1 day.
 * In the smart contract, we will round down the unlockTime to the nearest 30 day multiplier, so the user will get x3 multiplier.
 *
 * The user has a grace period to withdraw their tokens after the lock expires, if they don't, they are kicked, and 1% of the PUFFER tokens are sent as a reward to the kicker
 *
 * @custom:security-contact security@puffer.fi
 */
contract vlPUFFER is ERC20, ERC20Votes, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    error TransfersDisabled();
    error InvalidAmount();
    error InvalidMultiplier();
    error TokensMustBeUnlocked();
    error TokensLocked();
    error InvalidPufferToken();
    error LockAlreadyExists();
    error LockDoesNotExist();
    error ReLockingWillReduceVLBalance();
    error NewUnlockTimeMustBeGreaterThanCurrentLock();

    event Deposit(address indexed user, uint256 pufferAmount, uint256 unlockTime, uint256 vlPUFFERAmount);
    event Withdraw(address indexed user, uint256 pufferAmount);
    event Supply(uint256 previousSupply, uint256 currentSupply);
    event ReLockedTokens(address indexed user, uint256 pufferAmount, uint256 unlockTime, uint256 vlPUFFERAmount);
    event UserKicked(address indexed kicker, address indexed user, uint256 vlPUFFERAmount, uint256 kickerFee);

    // If a user locks 100 PUFFER tokens for 2 years, they will get 24000 vlPUFFER
    uint256 internal constant _MAX_MULTIPLIER = 24;
    // The user has 1 week to withdraw their tokens after the lock expires, if they don't, they are kicked, and 1% of the PUFFER tokens are sent as a reward to the kicker
    uint256 internal constant _GRACE_PERIOD = 1 weeks;
    // 1% in basis points
    uint256 internal constant _KICKER_FEE_BPS = 100;
    // 100% in basis points
    // forgefmt: disable-next-line
    uint256 internal constant _KICKER_FEE_DENOMINATOR = 100_00;
    // Multiplier for vlPUFFER amount calculation
    uint256 internal constant _LOCK_TIME_MULTIPLIER = 30 days;
    // The minimum amount of PUFFER (PUFFER has 18 decimals, so this is 10 PUFFER) tokens that can be locked to receive vlPUFFER
    uint256 internal constant _MIN_LOCK_AMOUNT = 10 ether;

    /**
     * @notice The PUFFER token address
     */
    IERC20 public immutable PUFFER;

    struct LockInfo {
        uint256 pufferAmount;
        uint256 unlockTime;
    }

    /**
     * @dev notice Permit struct
     */
    struct Permit {
        uint256 deadline;
        uint256 amount;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /**
     * @notice Mapping of user addresses to their lock information
     * @dev The key is the user address, and the value is a LockInfo struct containing:
     * - pufferAmount: The amount of PUFFER tokens locked
     * - unlockTime: The timestamp when the lock will expire
     */
    mapping(address user => LockInfo lockInfo) public lockInfos;

    modifier onlyValidMultiplier(uint256 multiplier) {
        // Multiplier must be between 1 and 24 (1 month to 2 years)
        require(multiplier >= 1 && multiplier <= _MAX_MULTIPLIER, InvalidMultiplier());
        _;
    }

    constructor(address contractOwner, address pufferToken)
        ERC20("vlPUFFER", "vlPUFFER")
        EIP712("vlPUFFER", "1")
        Ownable(contractOwner)
    {
        require(pufferToken != address(0), InvalidPufferToken());
        PUFFER = IERC20(pufferToken);
    }

    /**
     * @notice Create a new lock by depositing `amount` tokens with `multiplier`x voting power.
     * @dev The multiplier determines both the lock duration and voting power:
     * - 1x = 1 month lock = 1x voting power
     * - 12x = 12 months lock = 12x voting power
     * - 24x = 24 months lock = 24x voting power
     *
     * Example: If a user locks 100 PUFFER tokens with a 12x multiplier:
     * - Lock duration: 12 months
     * - Voting power: 1200 vlPUFFER (100 * 12)
     *
     * @param amount Amount of PUFFER tokens to lock
     * @param multiplier Voting power multiplier (1-24)
     */
    function createLock(uint256 amount, uint256 multiplier) external {
        _createLock(amount, multiplier);
    }

    /**
     * @notice Create a new lock with permit, allowing approval and locking in a single transaction
     * @param value Amount of PUFFER tokens to lock
     * @param multiplier Voting power multiplier (1-24)
     * @param permitData Permit struct containing the signature
     */
    function createLockWithPermit(uint256 value, uint256 multiplier, Permit calldata permitData) external {
        IERC20Permit(address(PUFFER)).permit({
            owner: msg.sender,
            spender: address(this),
            value: permitData.amount,
            deadline: permitData.deadline,
            v: permitData.v,
            s: permitData.s,
            r: permitData.r
        });

        _createLock(value, multiplier);
    }

    function _calculateUnlockTime(uint256 multiplier) internal view returns (uint256) {
        // Calculate unlock time based on multiplier (each multiplier unit = 30 days)
        return uint256(block.timestamp) + (multiplier * _LOCK_TIME_MULTIPLIER);
    }

    function _createLock(uint256 amount, uint256 multiplier) internal onlyValidMultiplier(multiplier) whenNotPaused {
        require(amount >= _MIN_LOCK_AMOUNT, InvalidAmount());
        require(lockInfos[msg.sender].pufferAmount == 0, LockAlreadyExists());

        // Transfer PUFFER tokens to this contract using SafeERC20
        PUFFER.safeTransferFrom(msg.sender, address(this), amount);

        uint256 unlockTime = _calculateUnlockTime(multiplier);
        uint256 vlPUFFERAmount = amount * multiplier;

        uint256 supplyBefore = totalSupply();

        // Mint the vlPUFFER (non transferable)
        _mint(msg.sender, vlPUFFERAmount);

        // Update the lock information
        lockInfos[msg.sender] = LockInfo({ pufferAmount: amount, unlockTime: unlockTime });

        // delegate the voting power to themselves
        _delegate(msg.sender, msg.sender);

        emit Deposit({ user: msg.sender, pufferAmount: amount, unlockTime: unlockTime, vlPUFFERAmount: vlPUFFERAmount });
        emit Supply({ previousSupply: supplyBefore, currentSupply: totalSupply() });
    }

    /**
     * @notice Re-lock the tokens
     *
     * The user has 3 options:
     * 1. Deposit more tokens to old lock to receive more vlPUFFER tokens
     * 2. Extend the lock with a higher multiplier without depositing more tokens
     * 3. Deposit more tokens and extend the lock with a higher multiplier
     *
     * @param amount Amount of PUFFER tokens to lock
     * @param multiplier New voting power multiplier (1-24)
     */
    function reLock(uint256 amount, uint256 multiplier) external onlyValidMultiplier(multiplier) whenNotPaused {
        // Take the tokens only if the amount is greater than 0, that means user is depositing more tokens
        if (amount > 0) {
            PUFFER.safeTransferFrom(msg.sender, address(this), amount);
        }

        LockInfo memory lockInfo = lockInfos[msg.sender];
        require(lockInfo.pufferAmount > 0, LockDoesNotExist());

        // Calculate new unlock time and ensure it's greater than current lock
        uint256 newUnlockTime = _calculateUnlockTime(multiplier);
        require(newUnlockTime >= lockInfo.unlockTime, NewUnlockTimeMustBeGreaterThanCurrentLock());

        uint256 pufferAmount = lockInfo.pufferAmount + amount;
        uint256 newVlPUFFERAmount = pufferAmount * multiplier;

        uint256 currentBalance = balanceOf(msg.sender);
        uint256 supplyBefore = totalSupply();

        // In reLock, the user's new vlPUFFER is calculated based on the
        // new total PUFFER amount and the time remaining from block.timestamp to the new unlockTime.
        //
        // Previously, if this new vlPUFFER was less than the user's current vlPUFFER balance
        // (e.g., they extended the lock for a shorter duration than their previous remaining duration,
        // or didn't add enough PUFFER to compensate for time passed), the logic would attempt
        // to mint a "negative" amount, causing a revert.
        //
        // This has been fixed by checking if the new target vlPUFFER amount is greater or
        // less than the current balance. If it's greater, the difference is minted.
        // If it's less, the transaction reverts to prevent reduction in the user's voting power
        // correctly reflects the new lock conditions.
        if (newVlPUFFERAmount > currentBalance) {
            _mint(msg.sender, newVlPUFFERAmount - currentBalance);
        } else if (newVlPUFFERAmount < currentBalance) {
            revert ReLockingWillReduceVLBalance();
        }

        // Update the lock information
        lockInfos[msg.sender] = LockInfo({ pufferAmount: pufferAmount, unlockTime: newUnlockTime });

        emit ReLockedTokens({
            user: msg.sender,
            pufferAmount: pufferAmount,
            unlockTime: newUnlockTime,
            vlPUFFERAmount: newVlPUFFERAmount
        });
        emit Supply({ previousSupply: supplyBefore, currentSupply: totalSupply() });
    }

    /**
     * @notice Withdraw the tokens
     * @param recipient Address to receive the PUFFER tokens
     */
    function withdraw(address recipient) external {
        uint256 supplyBefore = totalSupply();

        LockInfo memory lockInfo = lockInfos[msg.sender];

        require(lockInfo.pufferAmount > 0, LockDoesNotExist());
        require(lockInfo.unlockTime <= block.timestamp, TokensLocked());

        uint256 pufferAmount = lockInfo.pufferAmount;

        delete lockInfos[msg.sender];

        // Reverts if the user has insufficient balance
        _burn(msg.sender, balanceOf(msg.sender));

        // Transfer PUFFER tokens to the recipient
        PUFFER.safeTransfer(recipient, pufferAmount);

        emit Withdraw({ user: msg.sender, pufferAmount: pufferAmount });
        emit Supply({ previousSupply: supplyBefore, currentSupply: totalSupply() });
    }

    /**
     * @notice Kick multiple users and receive 1% of their PUFFER tokens as a reward
     * @param users Array of user addresses to kick
     */
    function kickUsers(address[] calldata users) external {
        uint256 totalKickerFee;

        for (uint256 i = 0; i < users.length; ++i) {
            address user = users[i];
            LockInfo memory lockInfo = lockInfos[user];

            if (lockInfo.pufferAmount == 0) {
                continue;
            }

            // The user has a grace period to withdraw their tokens
            require(lockInfo.unlockTime + _GRACE_PERIOD < block.timestamp, TokensMustBeUnlocked());

            uint256 vlPUFFERAmount = balanceOf(user);

            // 1% of the PUFFER tokens are sent to the kicker
            uint256 kickerFee = (lockInfo.pufferAmount * _KICKER_FEE_BPS) / _KICKER_FEE_DENOMINATOR;
            totalKickerFee += kickerFee;

            // The rest of the PUFFER tokens are sent to the user
            uint256 pufferAmount = lockInfo.pufferAmount;

            delete lockInfos[user];

            _burn(user, vlPUFFERAmount);

            // Send the rest of the PUFFER tokens to the user
            PUFFER.safeTransfer(user, pufferAmount - kickerFee);

            emit UserKicked({ kicker: msg.sender, user: user, vlPUFFERAmount: vlPUFFERAmount, kickerFee: kickerFee });
        }

        // Send all kicker fees in a single transfer
        if (totalKickerFee > 0) {
            PUFFER.safeTransfer(msg.sender, totalKickerFee);
        }
    }

    /**
     * @notice Get the current timestamp
     * @return The current timestamp
     */
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    /**
     * @notice Get the CLOCK_MODE
     * @return The CLOCK_MODE
     */
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

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
}
