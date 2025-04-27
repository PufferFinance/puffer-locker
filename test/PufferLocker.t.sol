// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {PufferLocker} from "../src/PufferLocker.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract PufferLockerTest is Test {
    // Constants
    uint256 constant WEEK = 1 weeks;
    uint256 constant MAX_LOCK_TIME = 2 * 365 days; // 2 years

    // Actors
    address alice;
    address bob;
    address charlie;

    // Contracts
    ERC20Mock public token;
    PufferLocker public pufferLocker;

    // Amounts
    uint256 amount;

    function setUp() public {
        // Setup accounts
        alice = address(0x1);
        bob = address(0x2);
        charlie = address(0x3);
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(charlie, "Charlie");
        
        // Mint tokens to users
        amount = 1000 * 10**18;
        token = new ERC20Mock();
        token.mint(alice, amount * 10);
        token.mint(bob, amount * 10);
        token.mint(charlie, amount * 10);
        
        // Setup PufferLocker
        pufferLocker = new PufferLocker(token);
        
        // Approve pufferLocker to spend tokens
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
        
        // Check vlPuffer balance
        assertEq(pufferLocker.balanceOf(alice), amount * 4);
        
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
        
        // Check total vlPuffer balance
        uint256 expectedBalance = amount * 4 + (amount / 2) * 8 + (amount / 4) * 12;
        assertEq(pufferLocker.balanceOf(alice), expectedBalance);
        
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
        
        // Withdraw
        vm.startPrank(alice);
        pufferLocker.withdraw(lockId);
        vm.stopPrank();
        
        // Check balances after withdrawal
        assertEq(pufferLocker.balanceOf(alice), 0);
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
        
        // Get expired locks
        uint256[] memory expiredLocks = pufferLocker.getExpiredLocks(alice);
        assertEq(expiredLocks.length, 1);
        assertEq(expiredLocks[0], lockId1);
        
        // Withdraw the first expired lock
        vm.startPrank(alice);
        pufferLocker.withdraw(lockId1);
        vm.stopPrank();
        
        // Check balances after first withdrawal
        uint256 expectedBalance = (amount / 2) * 8 + (amount / 4) * 12;
        assertEq(pufferLocker.balanceOf(alice), expectedBalance);
        assertEq(token.balanceOf(alice), amount * 10 - amount / 2 - amount / 4);
        
        // Move time forward past the second lock expiry
        vm.warp(block.timestamp + 3 weeks);
        
        // Get expired locks
        expiredLocks = pufferLocker.getExpiredLocks(alice);
        assertEq(expiredLocks.length, 1);
        assertEq(expiredLocks[0], lockId2);
        
        // Withdraw the second expired lock
        vm.startPrank(alice);
        pufferLocker.withdraw(lockId2);
        vm.stopPrank();
        
        // Check balances after second withdrawal
        expectedBalance = (amount / 4) * 12;
        assertEq(pufferLocker.balanceOf(alice), expectedBalance);
        assertEq(token.balanceOf(alice), amount * 10 - amount / 4);
        
        // Move time forward past the third lock expiry
        vm.warp(block.timestamp + 4 weeks);
        
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
        assertEq(token.balanceOf(alice), amount * 10);
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
        
        // Alice withdraws
        vm.startPrank(alice);
        pufferLocker.withdraw(aliceLockId);
        vm.stopPrank();
        
        // Check balances after Alice's withdrawal
        assertEq(pufferLocker.balanceOf(alice), 0);
        assertEq(pufferLocker.balanceOf(bob), amount * 8);
        assertEq(pufferLocker.balanceOf(charlie), amount * 12);
        
        // Move time forward past Bob's lock expiry
        vm.warp(block.timestamp + 4 weeks);
        
        // Bob withdraws
        vm.startPrank(bob);
        pufferLocker.withdraw(bobLockId);
        vm.stopPrank();
        
        // Check balances after Bob's withdrawal
        assertEq(pufferLocker.balanceOf(alice), 0);
        assertEq(pufferLocker.balanceOf(bob), 0);
        assertEq(pufferLocker.balanceOf(charlie), amount * 12);
    }

    function test_TransfersDisabled() public {
        moveToWeekStart();
        
        // Alice creates a lock
        vm.startPrank(alice);
        pufferLocker.createLock(amount, block.timestamp + 4 weeks);
        vm.stopPrank();
        
        // Try to transfer vlPuffer tokens
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
}
