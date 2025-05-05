// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { PufferLocker } from "../src/PufferLocker.sol";

import { ERC20PermitMock } from "./mocks/ERC20PermitMock.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test, console2 } from "forge-std/Test.sol";

contract PufferLockerTest is Test {
    // Constants
    uint256 constant WEEK = 1 weeks;
    uint256 constant MAX_LOCK_TIME = 2 * 365 days; // 2 years
    // Hardcoded Puffer token address (same as in PufferLocker.sol)
    address constant PUFFER_ADDRESS = 0x4d1C297d39C5c1277964D0E3f8Aa901493664530;

    // Actors
    address alice;
    uint256 alicePrivateKey;
    address bob;
    address charlie;
    address pufferTeam;

    // Contracts
    ERC20PermitMock public token;
    PufferLocker public pufferLocker;

    // Amounts
    uint256 amount;

    function setUp() public {
        // Setup accounts with known private keys for permit signing
        alicePrivateKey = 0xA11CE;
        alice = vm.addr(alicePrivateKey);
        bob = address(0x2);
        charlie = address(0x3);
        pufferTeam = address(0x4);
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(charlie, "Charlie");
        vm.label(pufferTeam, "Puffer Team");

        // Deploy the ERC20PermitMock at the hardcoded Puffer address
        vm.etch(PUFFER_ADDRESS, address(new ERC20PermitMock("Puffer", "PUFFER", 18)).code);

        // Get a reference to the mock token at the hardcoded address
        token = ERC20PermitMock(PUFFER_ADDRESS);

        // Mint tokens to users
        amount = 1000 * 10 ** 18;
        token.mint(alice, amount * 10);
        token.mint(bob, amount * 10);
        token.mint(charlie, amount * 10);

        // Setup PufferLocker
        pufferLocker = new PufferLocker(pufferTeam);

        // Approve pufferLocker to spend tokens for normal tests
        vm.startPrank(alice);
        token.approve(address(pufferLocker), amount * 100);
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(address(pufferLocker), amount * 100);
        vm.stopPrank();

        vm.startPrank(charlie);
        token.approve(address(pufferLocker), amount * 100);
        vm.stopPrank();
    }

    // Helper function to move to beginning of a week
    function moveToWeekStart() internal {
        uint256 currentTime = block.timestamp;
        uint256 weekStart = (currentTime / WEEK + 1) * WEEK;
        vm.warp(weekStart);
        vm.roll(block.number + 1);
    }

    function test_CreateLock() public {
        moveToWeekStart();

        // Alice creates a 4-week lock
        vm.startPrank(alice);
        uint256 lockId = pufferLocker.createLock(amount, block.timestamp + 4 weeks);
        vm.stopPrank();

        // Check lock ID
        assertEq(lockId, 0);

        // Check user's lock count
        assertEq(pufferLocker.getLockCount(alice), 1);

        // Get the lock
        PufferLocker.Lock memory lock = pufferLocker.getLock(alice, lockId);

        // Check lock details
        assertEq(lock.amount, amount);
        assertEq(lock.end, block.timestamp + 4 weeks);
        assertEq(lock.vlTokenAmount, amount * 4); // 4 weeks = 4x multiplier

        // Check vlPUFFER active balance
        assertEq(pufferLocker.balanceOf(alice), amount * 4);

        // Check raw balance
        assertEq(pufferLocker.getRawBalance(alice), amount * 4);

        // Check total supply
        assertEq(pufferLocker.totalSupply(), amount * 4);

        // Check locked supply
        assertEq(pufferLocker.totalLockedSupply(), amount);
    }

    function test_MultipleLocks() public {
        moveToWeekStart();

        // Alice creates multiple locks with different durations
        vm.startPrank(alice);
        uint256 lockId1 = pufferLocker.createLock(amount, block.timestamp + 4 weeks);
        uint256 lockId2 = pufferLocker.createLock(amount / 2, block.timestamp + 8 weeks);
        uint256 lockId3 = pufferLocker.createLock(amount / 4, block.timestamp + 12 weeks);
        vm.stopPrank();

        // Check lock IDs
        assertEq(lockId1, 0);
        assertEq(lockId2, 1);
        assertEq(lockId3, 2);

        // Check user's lock count
        assertEq(pufferLocker.getLockCount(alice), 3);

        // Check lock details
        PufferLocker.Lock memory lock1 = pufferLocker.getLock(alice, lockId1);
        PufferLocker.Lock memory lock2 = pufferLocker.getLock(alice, lockId2);
        PufferLocker.Lock memory lock3 = pufferLocker.getLock(alice, lockId3);

        assertEq(lock1.amount, amount);
        assertEq(lock1.end, block.timestamp + 4 weeks);
        assertEq(lock1.vlTokenAmount, amount * 4);

        assertEq(lock2.amount, amount / 2);
        assertEq(lock2.end, block.timestamp + 8 weeks);
        assertEq(lock2.vlTokenAmount, (amount / 2) * 8);

        assertEq(lock3.amount, amount / 4);
        assertEq(lock3.end, block.timestamp + 12 weeks);
        assertEq(lock3.vlTokenAmount, (amount / 4) * 12);

        // Check total vlPUFFER balance - should be the sum of all active locks
        uint256 expectedBalance = amount * 4 + (amount / 2) * 8 + (amount / 4) * 12;
        assertEq(pufferLocker.balanceOf(alice), expectedBalance);
        assertEq(pufferLocker.getRawBalance(alice), expectedBalance);

        // Check locked token amount
        uint256 expectedLockedAmount = amount + (amount / 2) + (amount / 4);
        assertEq(pufferLocker.totalLockedSupply(), expectedLockedAmount);
    }

    function test_WithdrawExpiredLock() public {
        moveToWeekStart();

        // Alice creates a 4-week lock
        vm.startPrank(alice);
        uint256 lockId = pufferLocker.createLock(amount, block.timestamp + 4 weeks);
        vm.stopPrank();

        // Check initial balance
        assertEq(pufferLocker.balanceOf(alice), amount * 4);
        assertEq(token.balanceOf(alice), amount * 10 - amount);

        // Try to withdraw before expiry
        vm.startPrank(alice);
        vm.expectRevert(PufferLocker.LockNotExpired.selector);
        pufferLocker.withdraw(lockId);
        vm.stopPrank();

        // Move time forward to after lock expiry
        vm.warp(block.timestamp + 4 weeks + 1);

        // Check that active balance is now 0 due to expiry
        assertEq(pufferLocker.balanceOf(alice), 0);
        // But raw balance should still show the tokens
        assertEq(pufferLocker.getRawBalance(alice), amount * 4);

        // Withdraw
        vm.startPrank(alice);
        pufferLocker.withdraw(lockId);
        vm.stopPrank();

        // Check balances after withdrawal
        assertEq(pufferLocker.balanceOf(alice), 0);
        assertEq(pufferLocker.getRawBalance(alice), 0);
        assertEq(token.balanceOf(alice), amount * 10);

        // Check lock was reset
        PufferLocker.Lock memory lock = pufferLocker.getLock(alice, lockId);
        assertEq(lock.amount, 0);
        assertEq(lock.end, 0);
        assertEq(lock.vlTokenAmount, 0);
    }

    function test_WithdrawMultipleExpiredLocks() public {
        moveToWeekStart();

        // Alice creates multiple locks with different durations
        vm.startPrank(alice);
        uint256 lockId1 = pufferLocker.createLock(amount, block.timestamp + 4 weeks);
        uint256 lockId2 = pufferLocker.createLock(amount / 2, block.timestamp + 8 weeks);
        uint256 lockId3 = pufferLocker.createLock(amount / 4, block.timestamp + 12 weeks);
        vm.stopPrank();

        // Move time forward past the first lock expiry
        vm.warp(block.timestamp + 6 weeks);

        // Check active balance - first lock should have expired
        uint256 expectedActiveBalance = (amount / 2) * 8 + (amount / 4) * 12;
        assertEq(pufferLocker.balanceOf(alice), expectedActiveBalance);

        // Get expired locks
        uint256[] memory expiredLocks = pufferLocker.getExpiredLocks(alice);
        assertEq(expiredLocks.length, 1);
        assertEq(expiredLocks[0], lockId1);

        // Withdraw the first expired lock
        vm.startPrank(alice);
        pufferLocker.withdraw(lockId1);
        vm.stopPrank();

        // Check balances after first withdrawal
        assertEq(pufferLocker.balanceOf(alice), expectedActiveBalance);
        uint256 expectedRawBalance = (amount / 2) * 8 + (amount / 4) * 12;
        assertEq(pufferLocker.getRawBalance(alice), expectedRawBalance);
        assertEq(token.balanceOf(alice), amount * 10 - amount / 2 - amount / 4);

        // Move time forward past the second lock expiry
        vm.warp(block.timestamp + 3 weeks);

        // Check active balance - second lock should have expired
        expectedActiveBalance = (amount / 4) * 12;
        assertEq(pufferLocker.balanceOf(alice), expectedActiveBalance);

        // Get expired locks
        expiredLocks = pufferLocker.getExpiredLocks(alice);
        assertEq(expiredLocks.length, 1);
        assertEq(expiredLocks[0], lockId2);

        // Withdraw the second expired lock
        vm.startPrank(alice);
        pufferLocker.withdraw(lockId2);
        vm.stopPrank();

        // Check balances after second withdrawal
        assertEq(pufferLocker.balanceOf(alice), expectedActiveBalance);
        expectedRawBalance = (amount / 4) * 12;
        assertEq(pufferLocker.getRawBalance(alice), expectedRawBalance);
        assertEq(token.balanceOf(alice), amount * 10 - amount / 4);

        // Move time forward past the third lock expiry
        vm.warp(block.timestamp + 4 weeks);

        // Check active balance - all locks should have expired
        assertEq(pufferLocker.balanceOf(alice), 0);

        // Get expired locks
        expiredLocks = pufferLocker.getExpiredLocks(alice);
        assertEq(expiredLocks.length, 1);
        assertEq(expiredLocks[0], lockId3);

        // Withdraw the third expired lock
        vm.startPrank(alice);
        pufferLocker.withdraw(lockId3);
        vm.stopPrank();

        // Check balances after third withdrawal
        assertEq(pufferLocker.balanceOf(alice), 0);
        assertEq(pufferLocker.getRawBalance(alice), 0);
        assertEq(token.balanceOf(alice), amount * 10);
    }

    function test_AutomaticBalanceExpiry() public {
        moveToWeekStart();

        // Alice creates a lock
        vm.startPrank(alice);
        pufferLocker.createLock(amount, block.timestamp + 4 weeks);
        vm.stopPrank();

        // Initial check
        assertEq(pufferLocker.balanceOf(alice), amount * 4);

        // Move time forward just before expiry
        vm.warp(block.timestamp + 4 weeks - 1);

        // Balance should still be active
        assertEq(pufferLocker.balanceOf(alice), amount * 4);

        // Move time forward past expiry
        vm.warp(block.timestamp + 2);

        // Balance should now be 0 even though no transaction occurred
        assertEq(pufferLocker.balanceOf(alice), 0);

        // Raw balance should still show the tokens
        assertEq(pufferLocker.getRawBalance(alice), amount * 4);

        // User should still be able to withdraw
        uint256[] memory expiredLocks = pufferLocker.getExpiredLocks(alice);
        assertEq(expiredLocks.length, 1);
    }

    function test_InvalidLockId() public {
        moveToWeekStart();

        // Try to get a lock with invalid ID
        vm.expectRevert(PufferLocker.InvalidLockId.selector);
        pufferLocker.getLock(alice, 0);

        // Try to withdraw a lock with invalid ID
        vm.startPrank(alice);
        vm.expectRevert(PufferLocker.InvalidLockId.selector);
        pufferLocker.withdraw(0);
        vm.stopPrank();

        // Create a lock
        vm.startPrank(alice);
        uint256 lockId = pufferLocker.createLock(amount, block.timestamp + 4 weeks);
        vm.stopPrank();

        // Try to get a lock with an ID that's too high
        vm.expectRevert(PufferLocker.InvalidLockId.selector);
        pufferLocker.getLock(alice, lockId + 1);
    }

    function test_ZeroValue() public {
        moveToWeekStart();

        // Try to create a lock with zero value
        vm.startPrank(alice);
        vm.expectRevert(PufferLocker.ZeroValue.selector);
        pufferLocker.createLock(0, block.timestamp + 4 weeks);
        vm.stopPrank();
    }

    function test_MaxLockTime() public {
        moveToWeekStart();

        // Try to create a lock with too long lock time
        vm.startPrank(alice);
        vm.expectRevert(PufferLocker.ExceedsMaxLockTime.selector);
        pufferLocker.createLock(amount, block.timestamp + MAX_LOCK_TIME + 1 weeks);
        vm.stopPrank();

        // Create a lock with exactly the max time
        vm.startPrank(alice);
        uint256 lockId = pufferLocker.createLock(amount, block.timestamp + MAX_LOCK_TIME);
        vm.stopPrank();

        // Get the lock
        PufferLocker.Lock memory lock = pufferLocker.getLock(alice, lockId);

        // Calculate expected values
        uint256 endTime = (block.timestamp + MAX_LOCK_TIME) / WEEK * WEEK; // Align to weeks
        uint256 numWeeks = (endTime - block.timestamp) / WEEK;

        // Check lock details
        assertEq(lock.amount, amount);
        assertEq(lock.end, endTime);
        assertEq(lock.vlTokenAmount, amount * numWeeks);
    }

    function test_PastLockTime() public {
        moveToWeekStart();

        // Try to create a lock with past unlock time
        vm.startPrank(alice);
        vm.expectRevert(PufferLocker.FutureLockTimeRequired.selector);
        pufferLocker.createLock(amount, block.timestamp - 1);
        vm.stopPrank();

        // Try to create a lock with current unlock time
        vm.startPrank(alice);
        vm.expectRevert(PufferLocker.FutureLockTimeRequired.selector);
        pufferLocker.createLock(amount, block.timestamp);
        vm.stopPrank();
    }

    function test_MultipleUsers() public {
        moveToWeekStart();

        // Alice creates a 4-week lock
        vm.startPrank(alice);
        uint256 aliceLockId = pufferLocker.createLock(amount, block.timestamp + 4 weeks);
        vm.stopPrank();

        // Bob creates an 8-week lock
        vm.startPrank(bob);
        uint256 bobLockId = pufferLocker.createLock(amount, block.timestamp + 8 weeks);
        vm.stopPrank();

        // Charlie creates a 12-week lock
        vm.startPrank(charlie);
        pufferLocker.createLock(amount, block.timestamp + 12 weeks);
        vm.stopPrank();

        // Check balances
        assertEq(pufferLocker.balanceOf(alice), amount * 4);
        assertEq(pufferLocker.balanceOf(bob), amount * 8);
        assertEq(pufferLocker.balanceOf(charlie), amount * 12);

        // Move time forward past Alice's lock expiry
        vm.warp(block.timestamp + 6 weeks);

        // Check balances - Alice's should be expired
        assertEq(pufferLocker.balanceOf(alice), 0);
        assertEq(pufferLocker.balanceOf(bob), amount * 8);
        assertEq(pufferLocker.balanceOf(charlie), amount * 12);

        // Alice withdraws
        vm.startPrank(alice);
        pufferLocker.withdraw(aliceLockId);
        vm.stopPrank();

        // Check balances after Alice's withdrawal
        assertEq(pufferLocker.balanceOf(alice), 0);
        assertEq(pufferLocker.getRawBalance(alice), 0);
        assertEq(pufferLocker.balanceOf(bob), amount * 8);
        assertEq(pufferLocker.balanceOf(charlie), amount * 12);

        // Move time forward past Bob's lock expiry
        vm.warp(block.timestamp + 4 weeks);

        // Check balances - Bob's should be expired
        assertEq(pufferLocker.balanceOf(alice), 0);
        assertEq(pufferLocker.balanceOf(bob), 0);
        assertEq(pufferLocker.balanceOf(charlie), amount * 12);

        // Bob withdraws
        vm.startPrank(bob);
        pufferLocker.withdraw(bobLockId);
        vm.stopPrank();

        // Check balances after Bob's withdrawal
        assertEq(pufferLocker.balanceOf(alice), 0);
        assertEq(pufferLocker.balanceOf(bob), 0);
        assertEq(pufferLocker.getRawBalance(bob), 0);
        assertEq(pufferLocker.balanceOf(charlie), amount * 12);
    }

    function test_EpochBasedBalance() public {
        moveToWeekStart();

        // Starting at epoch 0
        uint256 initialEpoch = pufferLocker.getCurrentEpoch();

        // Alice creates a lock for 4 weeks
        vm.startPrank(alice);
        pufferLocker.createLock(amount, block.timestamp + 4 weeks);
        vm.stopPrank();

        // Move forward one epoch (1 week)
        vm.warp(block.timestamp + WEEK);

        // Should be in epoch 1
        assertEq(pufferLocker.getCurrentEpoch(), initialEpoch + 1);

        // Check balance at current epoch
        assertEq(pufferLocker.balanceOf(alice), amount * 4);

        // Move forward to epoch 4 (after lock expiry)
        vm.warp(block.timestamp + 3 * WEEK);

        // Should be in epoch 4
        assertEq(pufferLocker.getCurrentEpoch(), initialEpoch + 4);

        // Check balance - should be 0 now that lock expired
        assertEq(pufferLocker.balanceOf(alice), 0);
    }

    function test_TotalSupplyAtEpoch() public {
        moveToWeekStart();

        // Starting at epoch 0
        // No need to track initialEpoch here

        // Alice creates a lock for 4 weeks
        vm.startPrank(alice);
        pufferLocker.createLock(amount, block.timestamp + 4 weeks);
        vm.stopPrank();

        // Bob creates a lock for 8 weeks
        vm.startPrank(bob);
        pufferLocker.createLock(amount, block.timestamp + 8 weeks);
        vm.stopPrank();

        // Check total supply
        uint256 expectedSupply = amount * 4 + amount * 8;
        assertEq(pufferLocker.totalSupply(), expectedSupply);

        // Move forward to epoch 4 (Alice's lock expired)
        vm.warp(block.timestamp + 4 * WEEK);

        // Check total supply - Alice's should be expired
        expectedSupply = amount * 8;
        assertEq(pufferLocker.totalSupply(), expectedSupply);

        // Move forward to epoch 8 (all locks expired)
        vm.warp(block.timestamp + 4 * WEEK);

        // Check total supply - should be 0
        assertEq(pufferLocker.totalSupply(), 0);
    }

    function test_TransfersDisabled() public {
        moveToWeekStart();

        // Alice creates a lock
        vm.startPrank(alice);
        pufferLocker.createLock(amount, block.timestamp + 4 weeks);
        vm.stopPrank();

        // Try to transfer vlPUFFER tokens
        vm.startPrank(alice);
        vm.expectRevert(PufferLocker.TransfersDisabled.selector);
        pufferLocker.transfer(bob, amount);
        vm.stopPrank();

        // Try to approve and transferFrom
        vm.startPrank(alice);
        pufferLocker.approve(bob, amount);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(PufferLocker.TransfersDisabled.selector);
        pufferLocker.transferFrom(alice, bob, amount);
        vm.stopPrank();
    }

    function test_LockAlignment() public {
        // Set time to middle of a week
        uint256 weekStart = (block.timestamp / WEEK) * WEEK;
        vm.warp(weekStart + WEEK / 2);

        // Alice creates a lock
        vm.startPrank(alice);
        uint256 lockId = pufferLocker.createLock(amount, block.timestamp + 4 weeks);
        vm.stopPrank();

        // Check that the end time is aligned to a week boundary
        PufferLocker.Lock memory lock = pufferLocker.getLock(alice, lockId);
        assertEq(lock.end % WEEK, 0);
    }

    function test_GetAllLocks() public {
        moveToWeekStart();

        // Alice creates multiple locks
        vm.startPrank(alice);
        pufferLocker.createLock(amount, block.timestamp + 4 weeks);
        pufferLocker.createLock(amount / 2, block.timestamp + 8 weeks);
        pufferLocker.createLock(amount / 4, block.timestamp + 12 weeks);
        vm.stopPrank();

        // Get all locks
        PufferLocker.Lock[] memory locks = pufferLocker.getAllLocks(alice);

        // Check number of locks
        assertEq(locks.length, 3);

        // Check each lock's details
        assertEq(locks[0].amount, amount);
        assertEq(locks[0].end, block.timestamp + 4 weeks);
        assertEq(locks[0].vlTokenAmount, amount * 4);

        assertEq(locks[1].amount, amount / 2);
        assertEq(locks[1].end, block.timestamp + 8 weeks);
        assertEq(locks[1].vlTokenAmount, (amount / 2) * 8);

        assertEq(locks[2].amount, amount / 4);
        assertEq(locks[2].end, block.timestamp + 12 weeks);
        assertEq(locks[2].vlTokenAmount, (amount / 4) * 12);
    }

    function test_getExpiredLocks() public {
        moveToWeekStart();

        // Alice creates multiple locks with different durations
        vm.startPrank(alice);
        pufferLocker.createLock(amount, block.timestamp + 4 weeks);
        pufferLocker.createLock(amount / 2, block.timestamp + 8 weeks);
        pufferLocker.createLock(amount / 4, block.timestamp + 12 weeks);
        vm.stopPrank();

        // Initially no locks should be expired
        uint256[] memory expiredLocks = pufferLocker.getExpiredLocks(alice);
        assertEq(expiredLocks.length, 0);

        // Move time forward past the first lock expiry
        vm.warp(block.timestamp + 6 weeks);

        // Check expired locks
        expiredLocks = pufferLocker.getExpiredLocks(alice);
        assertEq(expiredLocks.length, 1);
        assertEq(expiredLocks[0], 0);

        // Move time forward past the second lock expiry
        vm.warp(block.timestamp + 4 weeks);

        // Check expired locks
        expiredLocks = pufferLocker.getExpiredLocks(alice);
        assertEq(expiredLocks.length, 2);
        assertEq(expiredLocks[0], 0);
        assertEq(expiredLocks[1], 1);

        // Move time forward past the third lock expiry
        vm.warp(block.timestamp + 4 weeks);

        // Check expired locks
        expiredLocks = pufferLocker.getExpiredLocks(alice);
        assertEq(expiredLocks.length, 3);
        assertEq(expiredLocks[0], 0);
        assertEq(expiredLocks[1], 1);
        assertEq(expiredLocks[2], 2);

        // Withdraw one lock
        vm.startPrank(alice);
        pufferLocker.withdraw(1);
        vm.stopPrank();

        // Check expired locks after withdrawal
        expiredLocks = pufferLocker.getExpiredLocks(alice);
        assertEq(expiredLocks.length, 2);
        assertEq(expiredLocks[0], 0);
        assertEq(expiredLocks[1], 2);
    }

    function test_NoExistingLock() public {
        moveToWeekStart();

        // Alice creates a lock
        vm.startPrank(alice);
        uint256 lockId = pufferLocker.createLock(amount, block.timestamp + 4 weeks);
        vm.stopPrank();

        // Move time forward past lock expiry
        vm.warp(block.timestamp + 6 weeks);

        // Verify balance is 0 due to expiry but user can still withdraw
        assertEq(pufferLocker.balanceOf(alice), 0);
        assertEq(pufferLocker.getRawBalance(alice), amount * 4);

        // Withdraw the lock
        vm.startPrank(alice);
        pufferLocker.withdraw(lockId);
        vm.stopPrank();

        // Try to withdraw again
        vm.startPrank(alice);
        vm.expectRevert(PufferLocker.NoExistingLock.selector);
        pufferLocker.withdraw(lockId);
        vm.stopPrank();
    }

    function test_Delegation() public {
        moveToWeekStart();

        // Alice creates a lock
        vm.startPrank(alice);
        pufferLocker.createLock(amount, block.timestamp + 4 weeks);
        vm.stopPrank();

        // Check initial delegation - self-delegated by default
        address initialDelegatee = pufferLocker.getDelegatee(alice);
        assertEq(initialDelegatee, alice);

        // Alice delegates to Bob
        vm.startPrank(alice);
        pufferLocker.delegate(bob);
        vm.stopPrank();

        // Check delegation updated
        assertEq(pufferLocker.getDelegatee(alice), bob);

        // Move time forward past lock expiry
        vm.warp(block.timestamp + 5 weeks);

        // Active balance should be 0 due to expiry
        assertEq(pufferLocker.balanceOf(alice), 0);

        // Raw balance should still show the tokens
        assertEq(pufferLocker.getRawBalance(alice), amount * 4);
    }

    function test_DelegateToPufferTeam() public {
        moveToWeekStart();

        // Alice creates a lock
        vm.startPrank(alice);
        pufferLocker.createLock(amount, block.timestamp + 4 weeks);

        // Delegate to Puffer team
        pufferLocker.delegateToPufferTeam();
        vm.stopPrank();

        // Check delegation updated
        assertEq(pufferLocker.getDelegatee(alice), pufferTeam);

        // Move time forward past lock expiry
        vm.warp(block.timestamp + 5 weeks);

        // Active balance should be 0 due to expiry
        assertEq(pufferLocker.balanceOf(alice), 0);

        // Raw balance should still show the tokens
        assertEq(pufferLocker.getRawBalance(alice), amount * 4);
    }

    function test_DelegationWithMultipleLocks() public {
        moveToWeekStart();

        // Alice creates multiple locks
        vm.startPrank(alice);
        pufferLocker.createLock(amount, block.timestamp + 4 weeks);
        pufferLocker.createLock(amount / 2, block.timestamp + 8 weeks);

        // Delegate to Bob
        pufferLocker.delegate(bob);
        vm.stopPrank();

        // Check delegation
        assertEq(pufferLocker.getDelegatee(alice), bob);

        // Alice creates another lock - Bob remains delegate
        vm.startPrank(alice);
        pufferLocker.createLock(amount / 4, block.timestamp + 12 weeks);
        vm.stopPrank();

        // Move time forward past first lock expiry
        vm.warp(block.timestamp + 6 weeks);

        // Get active balance - first lock should have expired
        uint256 expectedActiveBalance = (amount / 2) * 8 + (amount / 4) * 12;
        assertEq(pufferLocker.balanceOf(alice), expectedActiveBalance);

        // Raw balance should include all locks
        uint256 expectedRawBalance = amount * 4 + (amount / 2) * 8 + (amount / 4) * 12;
        assertEq(pufferLocker.getRawBalance(alice), expectedRawBalance);
    }

    function test_WithdrawAfterDelegation() public {
        moveToWeekStart();

        // Alice creates a lock
        vm.startPrank(alice);
        uint256 lockId = pufferLocker.createLock(amount, block.timestamp + 4 weeks);

        // Delegate to Bob
        pufferLocker.delegate(bob);
        vm.stopPrank();

        // Move time forward past lock expiry
        vm.warp(block.timestamp + 6 weeks);

        // Active balance should be 0 due to expiry
        assertEq(pufferLocker.balanceOf(alice), 0);

        // Raw balance should still show the tokens
        assertEq(pufferLocker.getRawBalance(alice), amount * 4);

        // Alice withdraws
        vm.startPrank(alice);
        pufferLocker.withdraw(lockId);
        vm.stopPrank();

        // Check balances after withdrawal
        assertEq(pufferLocker.balanceOf(alice), 0);
        assertEq(pufferLocker.getRawBalance(alice), 0);
    }

    function test_LockSpamAttack() public {
        moveToWeekStart();

        // Set a small amount for each lock
        uint256 smallAmount = 1; // 1 wei, the smallest possible amount

        // Number of locks to create (simulating a spam attack)
        uint256 numLocks = 20; // Start with a reasonable number for testing

        // Approve small amounts
        vm.startPrank(alice);
        token.approve(address(pufferLocker), smallAmount * numLocks);

        // Record initial gas
        uint256 initialGas = gasleft();

        // Create many tiny locks
        for (uint256 i = 0; i < numLocks; i++) {
            uint256 unlockTime = block.timestamp + (i % 10 + 1) * WEEK; // Varying lock times
            pufferLocker.createLock(smallAmount, unlockTime);
        }

        // Measure gas used for creating locks
        uint256 gasUsedForCreation = initialGas - gasleft();
        console2.log("Gas used for creating", numLocks, "locks:", gasUsedForCreation);

        // Check lock count
        assertEq(pufferLocker.getLockCount(alice), numLocks);

        // Measure gas for reading all locks
        initialGas = gasleft();
        pufferLocker.getAllLocks(alice);
        uint256 gasUsedForReading = initialGas - gasleft();
        console2.log("Gas used for reading all locks:", gasUsedForReading);

        // Measure gas for getting expired locks after some time passes
        vm.warp(block.timestamp + 6 * WEEK); // Forward 6 weeks to expire some locks

        initialGas = gasleft();
        pufferLocker.getExpiredLocks(alice);
        uint256 gasUsedForExpiredLocks = initialGas - gasleft();
        console2.log("Gas used for getting expired locks:", gasUsedForExpiredLocks);
        vm.stopPrank();

        // Test the impact on other users when one user has many locks
        vm.startPrank(bob);
        initialGas = gasleft();
        pufferLocker.createLock(amount, block.timestamp + 4 * WEEK);
        uint256 gasUsedForOtherUser = initialGas - gasleft();
        console2.log("Gas used for creation by other user:", gasUsedForOtherUser);
        vm.stopPrank();

        // Enable pausing as the contract owner (address(this))
        pufferLocker.pause();

        // Test emergency withdrawal as alice
        vm.startPrank(alice);
        // Try emergency withdraw with one lock
        uint256 firstLockId = 0;
        initialGas = gasleft();
        pufferLocker.emergencyWithdraw(firstLockId);
        uint256 gasUsedForEmergencyWithdraw = initialGas - gasleft();
        console2.log("Gas used for emergency withdraw:", gasUsedForEmergencyWithdraw);
        vm.stopPrank();

        // Calculate maximum possible locks in a single block
        uint256 blockGasLimit = 30000000; // Ethereum's block gas limit (approximate)
        uint256 estimatedMaxLocks = blockGasLimit / (gasUsedForCreation / numLocks);
        console2.log("Estimated max locks per block:", estimatedMaxLocks);

        // Determine if this is a concern that needs mitigation
        bool isAttackConcern = gasUsedForReading > 5000000 // If reading becomes too expensive
            || gasUsedForExpiredLocks > 5000000 // If getting expired locks becomes too expensive
            || estimatedMaxLocks > 1000; // If one can create too many locks in a block

        console2.log("Is attack a concern:", isAttackConcern);
    }

    // Add test for Pausable functionality
    function test_PausableBasics() public {
        // Contract should not be paused initially
        assertFalse(pufferLocker.paused());

        // Alice should be able to create a lock when not paused
        vm.startPrank(alice);
        token.approve(address(pufferLocker), amount);
        uint256 lockId = pufferLocker.createLock(amount, block.timestamp + 4 weeks);
        vm.stopPrank();

        // Owner pauses the contract
        pufferLocker.pause();

        // Contract should now be paused
        assertTrue(pufferLocker.paused());

        // Alice should not be able to create a lock when paused
        vm.startPrank(alice);
        token.approve(address(pufferLocker), amount);
        vm.expectRevert();
        pufferLocker.createLock(amount, block.timestamp + 4 weeks);
        vm.stopPrank();

        // Move time forward past lock expiry
        vm.warp(block.timestamp + 5 weeks);

        // Alice should be able to use emergency withdraw when paused
        vm.startPrank(alice);
        pufferLocker.emergencyWithdraw(lockId);
        vm.stopPrank();

        // Owner unpauses the contract
        pufferLocker.unpause();

        // Contract should now be unpaused
        assertFalse(pufferLocker.paused());

        // Emergency withdraw should not work when not paused
        vm.startPrank(alice);
        token.approve(address(pufferLocker), amount);
        lockId = pufferLocker.createLock(amount, block.timestamp + 4 weeks);
        vm.expectRevert(PufferLocker.EmergencyUnlockNotEnabled.selector);
        pufferLocker.emergencyWithdraw(lockId);
        vm.stopPrank();
    }

    function test_EpochSpamAttack() public {
        moveToWeekStart();

        // Simulate a long period of inactivity
        uint256 inactiveWeeks = 100; // 100 weeks (about 2 years)
        vm.warp(block.timestamp + inactiveWeeks * WEEK);

        // Try to create a lock after the long inactivity
        vm.startPrank(alice);
        uint256 gasBeforeFirstTx = gasleft();
        pufferLocker.createLock(amount, block.timestamp + 4 * WEEK);
        uint256 gasUsedFirstTx = gasBeforeFirstTx - gasleft();
        console2.log("Gas used after", inactiveWeeks, "weeks of inactivity:", gasUsedFirstTx);

        // Check if it processed all epochs or was limited
        uint256 currentEpoch = pufferLocker.currentEpoch();
        console2.log("Current epoch after first tx:", currentEpoch);
        console2.log("Expected epoch if all processed:", inactiveWeeks);

        // Create another lock to see if epoch processing continues
        uint256 gasBeforeSecondTx = gasleft();
        pufferLocker.createLock(amount, block.timestamp + 4 * WEEK);
        uint256 gasUsedSecondTx = gasBeforeSecondTx - gasleft();
        console2.log("Gas used for second tx:", gasUsedSecondTx);

        // Check new epoch
        uint256 newEpoch = pufferLocker.currentEpoch();
        console2.log("Current epoch after second tx:", newEpoch);

        // Manually process remaining epochs
        if (newEpoch < inactiveWeeks) {
            pufferLocker.processEpochTransitions(inactiveWeeks - newEpoch);
            console2.log("Current epoch after manual processing:", pufferLocker.currentEpoch());
        }

        vm.stopPrank();
    }

    function test_LockSpamAttackLarge() public {
        moveToWeekStart();

        // Set a small amount for each lock
        uint256 smallAmount = 1; // 1 wei, the smallest possible amount

        // Number of locks to create (simulating a spam attack)
        uint256 numLocks = 100; // Testing with a larger number of locks

        // Approve small amounts
        vm.startPrank(alice);
        token.approve(address(pufferLocker), smallAmount * numLocks);

        // Record initial gas
        uint256 initialGas = gasleft();

        // Create many tiny locks
        for (uint256 i = 0; i < numLocks; i++) {
            uint256 unlockTime = block.timestamp + (i % 10 + 1) * WEEK; // Varying lock times
            pufferLocker.createLock(smallAmount, unlockTime);
        }

        // Measure gas used for creating locks
        uint256 gasUsedForCreation = initialGas - gasleft();
        console2.log("Gas used for creating", numLocks, "locks:", gasUsedForCreation);

        // Check lock count
        assertEq(pufferLocker.getLockCount(alice), numLocks);

        // Measure gas for paginated lock reading (more realistic for large numbers)
        initialGas = gasleft();
        pufferLocker.getLocks(alice, 0, 20); // Read first 20 locks
        uint256 gasUsedForPaginatedReading = initialGas - gasleft();
        console2.log("Gas used for paginated reading (20 locks):", gasUsedForPaginatedReading);

        // Measure gas for reading all locks (potentially expensive with many locks)
        initialGas = gasleft();
        pufferLocker.getAllLocks(alice);
        uint256 gasUsedForReading = initialGas - gasleft();
        console2.log("Gas used for reading all locks:", gasUsedForReading);

        // Measure gas for getting expired locks after some time passes
        vm.warp(block.timestamp + 6 * WEEK); // Forward 6 weeks to expire some locks

        initialGas = gasleft();
        pufferLocker.getExpiredLocks(alice);
        uint256 gasUsedForExpiredLocks = initialGas - gasleft();
        console2.log("Gas used for getting expired locks:", gasUsedForExpiredLocks);

        // Also test paginated version
        initialGas = gasleft();
        pufferLocker.getExpiredLocks(alice, 0, 20);
        uint256 gasUsedForPaginatedExpiredLocks = initialGas - gasleft();
        console2.log("Gas used for paginated expired locks:", gasUsedForPaginatedExpiredLocks);
        vm.stopPrank();

        // Calculate maximum possible locks in a single block
        uint256 blockGasLimit = 30000000; // Ethereum's block gas limit (approximate)
        uint256 estimatedMaxLocks = blockGasLimit / (gasUsedForCreation / numLocks);
        console2.log("Estimated max locks per block:", estimatedMaxLocks);

        // Estimate gas for various operations at scale
        console2.log("Estimated gas for 1000 locks getAllLocks():", (gasUsedForReading * 1000) / numLocks);
        console2.log("Estimated gas for 1000 locks getExpiredLocks():", (gasUsedForExpiredLocks * 1000) / numLocks);

        // Determine if this is a concern that needs mitigation
        bool isAttackConcern = (gasUsedForReading * 1000) / numLocks > 30000000 // If reading at scale becomes impossible
            || (gasUsedForExpiredLocks * 1000) / numLocks > 30000000 // If getting expired locks at scale becomes impossible
            || estimatedMaxLocks > 1000; // If one can create too many locks in a block

        console2.log("Is attack a concern:", isAttackConcern);
    }

    function test_MassWithdrawalAttack() public {
        moveToWeekStart();

        // Number of locks to create
        uint256 numLocks = 50;
        uint256 lockAmount = amount / 100; // Use a smaller amount per lock

        // Mint more tokens if needed
        token.mint(alice, lockAmount * numLocks);

        // Approve tokens
        vm.startPrank(alice);
        token.approve(address(pufferLocker), lockAmount * numLocks);

        // Create many locks with short durations
        for (uint256 i = 0; i < numLocks; i++) {
            uint256 unlockTime = block.timestamp + 1 weeks; // All expire at the same time
            pufferLocker.createLock(lockAmount, unlockTime);
        }

        // Move forward past expiry
        vm.warp(block.timestamp + 2 weeks);

        // Get expired locks
        uint256[] memory expiredLocks = pufferLocker.getExpiredLocks(alice);
        assertEq(expiredLocks.length, numLocks);

        // Measure gas for withdrawing each lock
        uint256 totalGasUsed = 0;
        for (uint256 i = 0; i < expiredLocks.length; i++) {
            uint256 initialGas = gasleft();
            pufferLocker.withdraw(expiredLocks[i]);
            uint256 gasUsed = initialGas - gasleft();
            totalGasUsed += gasUsed;

            if (i == 0 || i == expiredLocks.length - 1) {
                console2.log("Gas used for withdrawal", i, ":", gasUsed);
            }
        }

        console2.log("Average gas per withdrawal:", totalGasUsed / expiredLocks.length);
        console2.log(
            "Max withdrawals possible in one block (30M gas):", 30000000 / (totalGasUsed / expiredLocks.length)
        );

        vm.stopPrank();
    }

    function test_RelockExpiredLock() public {
        moveToWeekStart();

        // Alice creates a 4-week lock
        vm.startPrank(alice);
        uint256 lockId = pufferLocker.createLock(amount, block.timestamp + 4 weeks);
        vm.stopPrank();

        // Check initial balance
        assertEq(pufferLocker.balanceOf(alice), amount * 4);
        assertEq(token.balanceOf(alice), amount * 10 - amount);

        // Move time forward past lock expiry
        vm.warp(block.timestamp + 4 weeks + 1);

        // Check that active balance is now 0 due to expiry
        assertEq(pufferLocker.balanceOf(alice), 0);
        // But raw balance should still show the tokens
        assertEq(pufferLocker.getRawBalance(alice), amount * 4);

        // Relock expired lock for 8 more weeks
        vm.startPrank(alice);
        pufferLocker.relockExpiredLock(lockId, block.timestamp + 8 weeks);
        vm.stopPrank();

        // Get the updated lock
        PufferLocker.Lock memory lock = pufferLocker.getLock(alice, lockId);

        // Check updated lock details
        assertEq(lock.amount, amount);

        // The end time should be aligned to a week boundary
        uint256 expectedEndTime = (block.timestamp + 8 weeks) / WEEK * WEEK;
        assertEq(lock.end, expectedEndTime);

        // Calculate expected token amount based on actual epochs until end time
        uint256 expectedEpochs = (expectedEndTime - block.timestamp) / WEEK;
        uint256 expectedVlTokenAmount = amount * expectedEpochs;
        assertEq(lock.vlTokenAmount, expectedVlTokenAmount);

        // Check vlPUFFER active balance
        assertEq(pufferLocker.balanceOf(alice), expectedVlTokenAmount);

        // Check raw balance
        assertEq(pufferLocker.getRawBalance(alice), expectedVlTokenAmount);

        // Original amount of PUFFER tokens should still be locked
        assertEq(token.balanceOf(alice), amount * 10 - amount);
        assertEq(pufferLocker.totalLockedSupply(), amount);
    }

    function test_RelockExpiredLockInvalidStates() public {
        moveToWeekStart();

        // Alice creates a 4-week lock
        vm.startPrank(alice);
        uint256 lockId = pufferLocker.createLock(amount, block.timestamp + 4 weeks);
        vm.stopPrank();

        // Try to relock before expiry
        vm.startPrank(alice);
        vm.expectRevert(PufferLocker.LockNotExpired.selector);
        pufferLocker.relockExpiredLock(lockId, block.timestamp + 8 weeks);
        vm.stopPrank();

        // Move time forward past lock expiry
        vm.warp(block.timestamp + 4 weeks + 1);

        // Test NoExistingLock error with a non-existent lock
        vm.startPrank(alice);

        // First withdraw the lock to make it non-existent
        pufferLocker.withdraw(lockId);

        // Now try to relock the withdrawn lock
        vm.expectRevert(PufferLocker.NoExistingLock.selector);
        pufferLocker.relockExpiredLock(lockId, block.timestamp + 8 weeks);
        vm.stopPrank();
    }

    // Add a dedicated test for MAX_LOCK_TIME validation in relockExpiredLock
    function test_RelockExpiredLockMaxLockTime() public {
        moveToWeekStart();

        // Alice creates a short lock
        vm.startPrank(alice);
        uint256 lockId = pufferLocker.createLock(amount, block.timestamp + 4 weeks);
        vm.stopPrank();

        // Move time forward to just past lock expiry
        vm.warp(block.timestamp + 4 weeks + 1);

        // Try to relock with way too long a lock time
        vm.startPrank(alice);
        uint256 tooLongLockTime = block.timestamp + 3 * 365 days; // 3 years, well beyond MAX_LOCK_TIME (2 years)
        vm.expectRevert(PufferLocker.ExceedsMaxLockTime.selector);
        pufferLocker.relockExpiredLock(lockId, tooLongLockTime);
        vm.stopPrank();
    }

    function test_RelockMultipleTimes() public {
        moveToWeekStart();

        // Alice creates a 4-week lock
        vm.startPrank(alice);
        uint256 lockId = pufferLocker.createLock(amount, block.timestamp + 4 weeks);
        vm.stopPrank();

        // Move time forward past lock expiry
        vm.warp(block.timestamp + 4 weeks + 1);

        // Relock for 8 weeks
        vm.startPrank(alice);
        pufferLocker.relockExpiredLock(lockId, block.timestamp + 8 weeks);
        vm.stopPrank();

        // Move time forward past the second lock expiry
        vm.warp(block.timestamp + 8 weeks + 1);

        // Relock for 12 weeks
        vm.startPrank(alice);
        pufferLocker.relockExpiredLock(lockId, block.timestamp + 12 weeks);
        vm.stopPrank();

        // Get the updated lock
        PufferLocker.Lock memory lock = pufferLocker.getLock(alice, lockId);

        // Check updated lock details
        assertEq(lock.amount, amount);

        // The end time should be aligned to a week boundary
        uint256 expectedEndTime = (block.timestamp + 12 weeks) / WEEK * WEEK;
        assertEq(lock.end, expectedEndTime);

        // Calculate expected token amount based on actual epochs until end time
        uint256 expectedEpochs = (expectedEndTime - block.timestamp) / WEEK;
        uint256 expectedVlTokenAmount = amount * expectedEpochs;
        assertEq(lock.vlTokenAmount, expectedVlTokenAmount);

        // Check vlPUFFER active balance
        assertEq(pufferLocker.balanceOf(alice), expectedVlTokenAmount);

        // Original amount of PUFFER tokens should still be locked
        assertEq(token.balanceOf(alice), amount * 10 - amount);
        assertEq(pufferLocker.totalLockedSupply(), amount);
    }

    function test_CreateLockWithPermit() public {
        moveToWeekStart();

        // Set up a new user with no existing approval
        uint256 davidPrivateKey = 0xDAD1D;
        address david = vm.addr(davidPrivateKey);
        token.mint(david, amount * 10);

        // Create permit signature parameters
        uint256 deadline = block.timestamp + 1 days;

        // Generate the permit signature
        bytes32 digest = token.getPermitDigest(
            david, // owner
            address(pufferLocker), // spender
            amount, // value
            token.nonces(david), // nonce
            deadline // deadline
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(davidPrivateKey, digest);

        // David calls createLockWithPermit (no approve needed)
        vm.startPrank(david);
        uint256 lockId = pufferLocker.createLockWithPermit(
            amount, // _value
            block.timestamp + 4 weeks, // _unlockTime
            deadline, // _deadline
            v,
            r,
            s // signature components
        );
        vm.stopPrank();

        // Check lock was created successfully
        assertEq(lockId, 0);
        assertEq(pufferLocker.getLockCount(david), 1);

        // Get the lock
        PufferLocker.Lock memory lock = pufferLocker.getLock(david, lockId);

        // Check lock details
        assertEq(lock.amount, amount);
        assertEq(lock.end, block.timestamp + 4 weeks);
        assertEq(lock.vlTokenAmount, amount * 4); // 4 weeks = 4x multiplier

        // Check vlPUFFER active balance
        assertEq(pufferLocker.balanceOf(david), amount * 4);

        // Check raw balance
        assertEq(pufferLocker.getRawBalance(david), amount * 4);

        // Verify token was transferred (without an explicit approve call)
        assertEq(token.balanceOf(david), amount * 10 - amount);
        assertEq(token.allowance(david, address(pufferLocker)), 0); // No allowance should exist
    }
}
