// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import { vlPUFFER } from "../src/vlPUFFER.sol";
import { ERC20PermitMock } from "./mocks/ERC20PermitMock.sol";
import { Test } from "forge-std/Test.sol";

contract vlPUFFERTest is Test {
    // Constants
    uint256 constant MAX_LOCK_TIME = 2 * 365 days;
    uint256 constant MIN_LOCK_AMOUNT = 10 ether;
    uint256 constant LOCK_TIME_MULTIPLIER = 30 days;

    // Actors
    address alice = makeAddr("Alice");
    address bob = makeAddr("Bob");
    address charlie = makeAddr("Charlie");
    address pufferMultisig = makeAddr("Puffer Multisig");

    // Contracts
    ERC20PermitMock public puffer;
    vlPUFFER public vlPuffer;

    function setUp() public {
        puffer = new ERC20PermitMock("PUFFER", "PUFFER", 18);
        vlPuffer = new vlPUFFER(pufferMultisig, address(puffer));

        // Mint tokens to test users
        puffer.mint(alice, 1000 ether);
        puffer.mint(bob, 1000 ether);
    }

    function test_constructor() public view {
        assertEq(vlPuffer.owner(), pufferMultisig, "Bad owner");
        assertEq(vlPuffer.decimals(), 18, "Bad decimals");
        assertEq(vlPuffer.name(), "vlPUFFER", "Bad name");
        assertEq(vlPuffer.symbol(), "vlPUFFER", "Bad symbol");
    }

    function test_contract_deployment() public {
        vm.expectRevert(vlPUFFER.InvalidPufferToken.selector);
        new vlPUFFER(pufferMultisig, address(0));
    }

    function test_createLock() public {
        uint256 amount = 100 ether;
        uint256 lockDuration = 365 days;
        uint256 unlockTime = block.timestamp + lockDuration;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, unlockTime);
        vm.stopPrank();

        // 100 * 365 / 30 = 1216.666666666666666666
        assertEq(vlPuffer.balanceOf(alice), 1216666666666666666666, "Bad vlPUFFER balance it should be ~ x12");
        assertEq(puffer.balanceOf(address(vlPuffer)), amount, "Bad PUFFER balance");
    }

    function test_createLockWithPermit() public {
        uint256 amount = 100 ether;
        uint256 lockDuration = 365 days;
        uint256 unlockTime = block.timestamp + lockDuration;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 privateKey = 0xA11CE; // Owner's private key
        address owner = vm.addr(privateKey);

        // Mint tokens to the owner
        puffer.mint(owner, amount);

        vm.startPrank(owner);
        bytes32 digest = puffer.getPermitDigest(owner, address(vlPuffer), amount, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        vlPuffer.createLockWithPermit(amount, unlockTime, deadline, v, r, s);
        vm.stopPrank();

        // 100 * 365 / 30 = 1216.666666666666666666
        assertEq(vlPuffer.balanceOf(owner), 1216666666666666666666, "Bad vlPUFFER balance it should be ~ x12");
    }

    function test_reLock() public {
        uint256 initialAmount = 100 ether;
        uint256 initialLockDuration = 365 days;
        uint256 initialUnlockTime = block.timestamp + initialLockDuration;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), type(uint256).max);
        vlPuffer.createLock(initialAmount, initialUnlockTime);

        // Add more tokens and extend lock
        uint256 additionalAmount = 50 ether;
        uint256 newLockDuration = 2 * 365 days;
        uint256 newUnlockTime = block.timestamp + newLockDuration;

        vlPuffer.reLock(additionalAmount, newUnlockTime);
        vm.stopPrank();

        // (100 + 50) * 730 / 30 = 3650 vlPUFFER
        // that is x24 multiplier
        assertEq(vlPuffer.balanceOf(alice), 3650 ether, "Bad vlPUFFER balance after reLock");
    }

    function test_withdraw(uint256 amount) public {
        amount = bound(amount, MIN_LOCK_AMOUNT, type(uint128).max);
        uint256 lockDuration = 365 days;
        uint256 unlockTime = block.timestamp + lockDuration;

        puffer.mint(charlie, amount);

        vm.startPrank(charlie);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, unlockTime);

        // Fast forward past lock time
        vm.warp(unlockTime + 1);

        uint256 balanceBefore = puffer.balanceOf(charlie);
        vlPuffer.withdraw(charlie);
        uint256 balanceAfter = puffer.balanceOf(charlie);

        assertEq(balanceAfter - balanceBefore, amount, "Bad withdrawal amount");
        assertEq(vlPuffer.balanceOf(charlie), 0, "vlPUFFER balance should be 0 after withdrawal");
        vm.stopPrank();
    }

    function test_kickUser() public {
        uint256 amount = 100 ether;
        uint256 lockDuration = 365 days;
        uint256 unlockTime = block.timestamp + lockDuration;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, unlockTime);
        vm.stopPrank();

        // Fast forward past lock time and grace period
        vm.warp(unlockTime + 1 weeks + 1);

        address kicker = makeAddr("Kicker");

        uint256 kickerBalanceBefore = puffer.balanceOf(kicker);
        assertEq(kickerBalanceBefore, 0, "Bad kicker balance before kick");

        vm.prank(kicker);
        vlPuffer.kickUser(alice);
        uint256 kickerBalanceAfter = puffer.balanceOf(kicker);

        uint256 expectedKickerFee = amount * 100 / 10000; // 1% fee
        assertEq(kickerBalanceAfter, expectedKickerFee, "Bad kicker fee");
        assertEq(vlPuffer.balanceOf(alice), 0, "vlPUFFER balance should be 0 after kick");
    }

    function test_RevertWhen_createLock_insufficientAmount(uint256 amount) public {
        amount = bound(amount, 0, MIN_LOCK_AMOUNT - 1);
        uint256 unlockTime = block.timestamp + 365 days;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vm.expectRevert(vlPUFFER.InvalidAmount.selector);
        vlPuffer.createLock(amount, unlockTime);
        vm.stopPrank();
    }

    function test_RevertWhen_createLock_invalidDuration(uint256 unlockTime) public {
        uint256 amount = 100 ether;
        unlockTime = bound(unlockTime, block.timestamp + 1, block.timestamp + 29 days);

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vm.expectRevert(vlPUFFER.LockDurationMustBeAtLeast30Days.selector);
        vlPuffer.createLock(amount, unlockTime);
        vm.stopPrank();
    }

    function test_RevertWhen_withdraw_beforeUnlock() public {
        uint256 amount = 100 ether;
        uint256 lockDuration = 365 days;
        uint256 unlockTime = block.timestamp + lockDuration;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, unlockTime);
        vm.expectRevert(vlPUFFER.TokensLocked.selector);
        vlPuffer.withdraw(alice);
        vm.stopPrank();
    }

    function test_RevertWhen_kickUser_beforeGracePeriod() public {
        uint256 amount = 100 ether;
        uint256 lockDuration = 365 days;
        uint256 unlockTime = block.timestamp + lockDuration;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, unlockTime);
        vm.stopPrank();

        vm.warp(unlockTime + 1); // Just after unlock, before grace period
        vm.prank(bob);
        vm.expectRevert(vlPUFFER.TokensMustBeUnlocked.selector);
        vlPuffer.kickUser(alice);
    }

    function test_pauseAndUnpause() public {
        // Test pause
        vm.prank(pufferMultisig);
        vlPuffer.pause();
        assertTrue(vlPuffer.paused(), "Contract should be paused");

        // Test that operations are blocked when paused
        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), 100 ether);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vlPuffer.createLock(100 ether, block.timestamp + 365 days);
        vm.stopPrank();

        // Test unpause
        vm.prank(pufferMultisig);
        vlPuffer.unpause();
        assertFalse(vlPuffer.paused(), "Contract should be unpaused");

        // Test that operations work again after unpause
        vm.startPrank(alice);
        vlPuffer.createLock(100 ether, block.timestamp + 365 days);
        vm.stopPrank();
    }

    function test_nonces() public view {
        // OZ is handling nonces, this is just for the code coverage
        uint256 nonce = vlPuffer.nonces(alice);
        assertEq(nonce, 0, "Initial nonce should be 0");
    }

    function test_clock() public view {
        uint48 currentTime = vlPuffer.clock();
        assertEq(currentTime, uint48(block.timestamp), "Clock should return current timestamp");
    }

    function test_CLOCK_MODE() public view {
        string memory mode = vlPuffer.CLOCK_MODE();
        assertEq(mode, "mode=timestamp", "CLOCK_MODE should return mode=timestamp");
    }

    function test_RevertWhen_reLock_invalidUnlockTime() public {
        uint256 amount = 100 ether;
        uint256 lockDuration = 365 days;
        uint256 unlockTime = block.timestamp + lockDuration;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, unlockTime);

        // Try to relock with earlier unlock time
        vm.expectRevert(vlPUFFER.UnlockTimeMustBeGreaterOrEqualThanLock.selector);
        vlPuffer.reLock(0, unlockTime - 1);
        vm.stopPrank();
    }

    function test_RevertWhen_reLock_noLockExists() public {
        vm.startPrank(alice);
        vm.expectRevert(vlPUFFER.LockDoesNotExist.selector);
        vlPuffer.reLock(0, block.timestamp + 365 days);
        vm.stopPrank();
    }

    function test_RevertWhen_reLock_invalidDuration() public {
        uint256 amount = 100 ether;
        uint256 lockDuration = 365 days;
        uint256 unlockTime = block.timestamp + lockDuration;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, unlockTime);

        // Try to relock with duration less than 30 days
        vm.expectRevert(vlPUFFER.LockDurationMustBeAtLeast30Days.selector);
        vlPuffer.reLock(0, block.timestamp + 29 days);
        vm.stopPrank();
    }

    function test_RevertWhen_createLock_futureLockTimeRequired() public {
        uint256 amount = 100 ether;
        uint256 unlockTime = block.timestamp - 1; // Past time

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vm.expectRevert(vlPUFFER.FutureLockTimeRequired.selector);
        vlPuffer.createLock(amount, unlockTime);
        vm.stopPrank();
    }

    function test_RevertWhen_createLock_exceedsMaxLockTime() public {
        uint256 amount = 100 ether;
        uint256 unlockTime = block.timestamp + MAX_LOCK_TIME + 2 days; // Exceeds max lock time

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vm.expectRevert(vlPUFFER.ExceedsMaxLockTime.selector);
        vlPuffer.createLock(amount, unlockTime);
        vm.stopPrank();
    }

    function test_RevertWhen_createLock_lockAlreadyExists() public {
        uint256 amount = 100 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), type(uint256).max);
        vlPuffer.createLock(amount, unlockTime);

        // Try to create another lock
        vm.expectRevert(vlPUFFER.LockAlreadyExists.selector);
        vlPuffer.createLock(amount, unlockTime);
        vm.stopPrank();
    }

    function test_RevertWhen_createLockWithPermit_invalidDeadline() public {
        uint256 amount = 100 ether;
        uint256 lockDuration = 365 days;
        uint256 unlockTime = block.timestamp + lockDuration;
        uint256 deadline = block.timestamp - 1; // Past deadline
        uint256 privateKey = 0xA11CE;
        address owner = vm.addr(privateKey);

        puffer.mint(owner, amount);

        vm.startPrank(owner);
        bytes32 digest = puffer.getPermitDigest(owner, address(vlPuffer), amount, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        vm.expectRevert(abi.encodeWithSignature("ERC2612ExpiredSignature(uint256)", 0));
        vlPuffer.createLockWithPermit(amount, unlockTime, deadline, v, r, s);
        vm.stopPrank();
    }

    function test_reLock_decreaseVlPuffer() public {
        uint256 initialAmount = 100 ether;
        uint256 initialLockDuration = 365 days;
        uint256 initialUnlockTime = block.timestamp + initialLockDuration;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), type(uint256).max);
        vlPuffer.createLock(initialAmount, initialUnlockTime);

        // Fast forward 6 months
        vm.warp(block.timestamp + 180 days);

        // Relock with same amount but shorter duration
        uint256 newLockDuration = 180 days;
        uint256 newUnlockTime = block.timestamp + newLockDuration;

        // Should fail because new unlock time is before current unlock time
        vm.expectRevert(vlPUFFER.UnlockTimeMustBeGreaterOrEqualThanLock.selector);
        vlPuffer.reLock(0, newUnlockTime);
        vm.stopPrank();
    }

    function test_reLock_decreaseVlPufferBalance() public {
        uint256 initialAmount = 100 ether;
        uint256 initialLockDuration = 365 days;
        uint256 initialUnlockTime = block.timestamp + initialLockDuration;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), type(uint256).max);
        vlPuffer.createLock(initialAmount, initialUnlockTime);

        // Fast forward 6 months
        vm.warp(block.timestamp + 180 days);

        // Extend lock by 3 months from current time
        // This will be less vlPUFFER than initial because:
        // 1. Initial: 100 tokens * 365 days / 30 days = ~1216 vlPUFFER
        // 2. New: 100 tokens * 90 days / 30 days = ~300 vlPUFFER
        uint256 newUnlockTime = block.timestamp + 90 days;

        vm.expectRevert(vlPUFFER.UnlockTimeMustBeGreaterOrEqualThanLock.selector);
        vlPuffer.reLock(0, newUnlockTime);

        // Now try with a valid unlock time that's greater than the current lock
        newUnlockTime = initialUnlockTime + 90 days;

        vm.expectRevert(vlPUFFER.ReLockingWillReduceVLBalance.selector);
        vlPuffer.reLock(0, newUnlockTime);
    }

    function test_RevertWhen_withdraw_noLock() public {
        vm.startPrank(alice);
        vm.expectRevert(vlPUFFER.LockDoesNotExist.selector);
        vlPuffer.withdraw(alice);
        vm.stopPrank();
    }

    function test_RevertWhen_kickUser_noLock() public {
        vm.prank(bob);
        vm.expectRevert(vlPUFFER.TokensMustBeUnlocked.selector);
        vlPuffer.kickUser(alice);
    }

    function test_RevertWhen_pause_notOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        vlPuffer.pause();
    }

    function test_RevertWhen_unpause_notOwner() public {
        vm.prank(pufferMultisig);
        vlPuffer.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        vlPuffer.unpause();
    }

    function test_RevertWhen_transfer() public {
        uint256 amount = 100 ether;
        uint256 lockDuration = 365 days;
        uint256 unlockTime = block.timestamp + lockDuration;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, unlockTime);

        vm.expectRevert(vlPUFFER.TransfersDisabled.selector);
        vlPuffer.transfer(bob, 1 ether);
        vm.stopPrank();
    }

    function test_RevertWhen_transferFrom() public {
        uint256 amount = 100 ether;
        uint256 lockDuration = 365 days;
        uint256 unlockTime = block.timestamp + lockDuration;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, unlockTime);
        vlPuffer.approve(bob, amount);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(vlPUFFER.TransfersDisabled.selector);
        vlPuffer.transferFrom(alice, bob, 1 ether);
        vm.stopPrank();
    }

    function test_delegation() public {
        uint256 amount = 100 ether;

        uint256 originalTime = block.timestamp;
        uint256 unlockTime = originalTime + 2 * 365 days;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, unlockTime);
        vm.stopPrank();

        vm.startPrank(bob);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, unlockTime);
        vlPuffer.delegate(alice);
        vm.stopPrank();

        puffer.mint(charlie, 1000 ether);

        vlPuffer.getVotes(alice);

        assertEq(vlPuffer.getVotes(alice), 4866666666666666666666, "Bad votes");
        assertEq(vlPuffer.getVotes(bob), 0, "Bad votes");
        assertEq(vlPuffer.getVotes(charlie), 0, "Bad votes");

        vm.warp(block.timestamp + 10 days);

        address david = makeAddr("David");
        puffer.mint(david, 1000 ether);

        vm.startPrank(david);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, unlockTime);
        vm.stopPrank();

        vm.startPrank(charlie);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, unlockTime);
        vlPuffer.delegate(alice);
        vm.stopPrank();

        assertEq(vlPuffer.getVotes(alice), 7266666666666666666666, "Bad votes present");
        assertEq(vlPuffer.totalSupply(), 9666666666666666666666, "Bad total supply present");

        uint256 snapshotTime = block.timestamp - (1 weeks + 2 days);

        assertEq(vlPuffer.getPastVotes(alice, snapshotTime), 4866666666666666666666, "Bad past votes");
        assertEq(vlPuffer.getPastTotalSupply(snapshotTime), 4866666666666666666666, "Bad past total supply");
    }

    //@todo test delegation and how it works
}
