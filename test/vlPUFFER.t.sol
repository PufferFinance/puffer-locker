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

        // 100 * 365 / 30 = 1200
        assertEq(vlPuffer.balanceOf(alice), amount * 12, "Bad vlPUFFER balance it should be ~ x12");
        assertEq(puffer.balanceOf(address(vlPuffer)), amount, "Bad PUFFER balance");

        (uint256 pufferAmount, uint256 time) = vlPuffer.lockInfos(alice);
        assertEq(pufferAmount, amount, "Bad puffer amount");

        // There is a small difference because of the rounding
        assertApproxEqRel(time, 360 days, 0.0001 ether, "Bad unlock time"); // 360 days because of the rounding
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

        // 100 * 365 / 30 = 1200
        assertEq(vlPuffer.balanceOf(owner), amount * 12, "Bad vlPUFFER balance");
    }

    function test_createLockWithPermit_expired() public {
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

    function test_createLock_withDelegation() public {
        uint256 amount = 100 ether;
        uint256 lockDuration = 365 days;
        uint256 unlockTime = block.timestamp + lockDuration;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, unlockTime);
        vm.stopPrank();

        // Check that alice is delegated to herself by default
        assertEq(vlPuffer.delegates(alice), alice, "Default delegation should be to self");
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

        // (100 + 50) * 24 = 3600 vlPUFFER
        // that is x24 multiplier
        assertEq(vlPuffer.balanceOf(alice), 3600 ether, "Bad vlPUFFER balance after reLock");
    }

    function test_reLock_withZeroAmountAndSameUnlockTime() public {
        uint256 initialAmount = 100 ether;
        uint256 initialLockDuration = 365 days;
        uint256 initialUnlockTime = block.timestamp + initialLockDuration;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), type(uint256).max);
        vlPuffer.createLock(initialAmount, initialUnlockTime);

        // Relock with same unlock time and zero amount should succeed
        vlPuffer.reLock(0, initialUnlockTime);
        vm.stopPrank();

        // Balance should remain the same
        assertEq(vlPuffer.balanceOf(alice), 1200 ether, "Bad vlPUFFER balance after reLock");
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

        address[] memory users = new address[](1);
        users[0] = alice;

        vm.prank(kicker);
        vlPuffer.kickUsers(users);
        uint256 kickerBalanceAfter = puffer.balanceOf(kicker);

        uint256 expectedKickerFee = amount * 100 / 10_000; // 1% fee
        assertEq(kickerBalanceAfter, expectedKickerFee, "Bad kicker fee");
        assertEq(vlPuffer.balanceOf(alice), 0, "vlPUFFER balance should be 0 after kick");
    }

    function test_kickUsers() public {
        uint256 amount = 100 ether;
        uint256 lockDuration = 365 days;
        uint256 unlockTime = block.timestamp + lockDuration;

        // Create locks for multiple users
        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, unlockTime);
        vm.stopPrank();

        vm.startPrank(bob);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, unlockTime);
        vm.stopPrank();

        // Fast forward past lock time and grace period
        vm.warp(unlockTime + 1 weeks + 1);

        address kicker = makeAddr("Kicker");
        uint256 kickerBalanceBefore = puffer.balanceOf(kicker);
        assertEq(kickerBalanceBefore, 0, "Bad kicker balance before kick");

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        vm.prank(kicker);
        vlPuffer.kickUsers(users);
        uint256 kickerBalanceAfter = puffer.balanceOf(kicker);

        uint256 expectedKickerFee = (amount * 2) * 100 / 10_000; // 1% fee for both users
        assertEq(kickerBalanceAfter, expectedKickerFee, "Bad kicker fee");
        assertEq(vlPuffer.balanceOf(alice), 0, "vlPUFFER balance should be 0 after kick for alice");
        assertEq(vlPuffer.balanceOf(bob), 0, "vlPUFFER balance should be 0 after kick for bob");
    }

    function test_RevertWhen_kickUser_twice() public {
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
        address[] memory users = new address[](1);
        users[0] = alice;

        // First kick should succeed
        vm.prank(kicker);
        vlPuffer.kickUsers(users);

        // The same user can be kicked again but this time there are no token transfers
        vm.prank(kicker);
        vm.expectEmit(true, true, true, true);
        emit vlPUFFER.UserKicked(kicker, alice, 0, 0);
        vlPuffer.kickUsers(users);
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

        address[] memory users = new address[](1);
        users[0] = alice;

        vm.expectRevert(vlPUFFER.TokensMustBeUnlocked.selector);
        vlPuffer.kickUsers(users);
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

        assertEq(vlPuffer.balanceOf(alice), 1200 ether, "Bad vlPUFFER balance after createLock");

        // Try to relock with earlier unlock time
        vm.expectRevert(vlPUFFER.UnlockTimeMustBeGreaterOrEqualThanLock.selector);
        vlPuffer.reLock(0, (unlockTime - 15 days));
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
        address[] memory users = new address[](1);
        users[0] = alice;

        vm.prank(bob);
        vm.expectRevert(vlPUFFER.TokensMustBeUnlocked.selector);
        vlPuffer.kickUsers(users);
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
        // Add 1 second because of the rounding in the voting power calculation
        uint256 twoYears = 2 * 365 days + 1;
        uint256 amount = 100 ether;

        uint256 originalTime = block.timestamp;
        uint256 unlockTime = originalTime + twoYears;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, unlockTime);
        vm.stopPrank();

        uint256 twoYearVotingPower = amount * 24;
        assertEq(vlPuffer.getVotes(alice), twoYearVotingPower, "Alice has the same voting power in vlPUFFER");

        vm.startPrank(bob);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, unlockTime);
        vlPuffer.delegate(alice);
        vm.stopPrank();

        puffer.mint(charlie, 1000 ether);

        vlPuffer.getVotes(alice);

        // Alice got her own votes + delegated votes from Bob
        assertEq(vlPuffer.getVotes(alice), 2 * twoYearVotingPower, "Bad votes");
        assertEq(vlPuffer.totalSupply(), 2 * twoYearVotingPower, "Bad total supply");
        assertEq(vlPuffer.getVotes(bob), 0, "Bad votes");
        assertEq(vlPuffer.getVotes(charlie), 0, "Bad votes");

        uint256 presentTimestamp = block.timestamp + 10 days;
        // Fast forward 10 days, assume that the last voting snapshot is 8 days ago
        vm.warp(presentTimestamp);

        assertEq(
            vlPuffer.getPastVotes(alice, presentTimestamp - 8 days),
            2 * twoYearVotingPower,
            "Bad votes in the last voting period Alice"
        );
        assertEq(vlPuffer.totalSupply(), 2 * twoYearVotingPower, "Bad total supply in the last voting period");

        // David creates a new lock, but delegates to self
        address david = makeAddr("David");
        puffer.mint(david, 1000 ether);

        vm.startPrank(david);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, block.timestamp + twoYears);
        vm.stopPrank();

        assertEq(vlPuffer.getVotes(david), twoYearVotingPower, "David has 2 year voting power in vlPUFFER present");

        uint256 alicePastVotes = vlPuffer.getPastVotes(alice, presentTimestamp - 8 days);
        assertEq(alicePastVotes, 2 * twoYearVotingPower, "Alice has 2 year voting power in vlPUFFER past");
        assertEq(vlPuffer.getVotes(alice), 2 * twoYearVotingPower, "Alice has 2 year voting power in vlPUFFER present");
        // 3 * twoYearVotingPower
        uint256 totalSupplyAfter3Locks = 3 * twoYearVotingPower;
        assertEq(vlPuffer.totalSupply(), totalSupplyAfter3Locks, "Total supply is increased for David's vlPUFFER");

        // Charlie delegates to Alice
        vm.startPrank(charlie);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, twoYears);
        assertEq(vlPuffer.getVotes(charlie), twoYearVotingPower, "David has 2 year voting power in vlPUFFER present");
        vlPuffer.delegate(alice);
        vm.stopPrank();

        // The present values increased, Alice has 3 delegated votes (1 alice, 1 bob, 1 charlie)
        assertEq(vlPuffer.getVotes(alice), 3 * twoYearVotingPower, "Alice voting power in present increased");
        assertEq(vlPuffer.totalSupply(), 4 * twoYearVotingPower, "Total supply in present is increased");

        // Go in to the future
        vm.warp(block.timestamp + 100 days);

        // Query the old voting power
        assertEq(
            vlPuffer.getPastVotes(alice, presentTimestamp - 8 days),
            alicePastVotes,
            "Alice has the same voting power in vlPUFFER in the past"
        );

        // At this time, we only had two locks, so the totalSupply is 2 * 2433333333333333333333
        assertEq(
            vlPuffer.getPastTotalSupply(presentTimestamp - 8 days),
            2 * twoYearVotingPower,
            "Total supply in the past remained"
        );

        // Here, we had 4 locks (alice, bob, charlie, david)
        assertEq(
            vlPuffer.getPastTotalSupply(presentTimestamp),
            4 * twoYearVotingPower,
            "Total supply in the past after 4 locks"
        );
    }

    function test_reLock_withAdditionalTokens() public {
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

        assertEq(vlPuffer.balanceOf(alice), 3600 ether, "Bad vlPUFFER balance after reLock");
    }

    function test_reLock_withZeroAmount() public {
        uint256 initialAmount = 100 ether;
        uint256 initialLockDuration = 365 days;
        uint256 initialUnlockTime = block.timestamp + initialLockDuration;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), type(uint256).max);
        vlPuffer.createLock(initialAmount, initialUnlockTime);

        // Extend lock without adding more tokens
        uint256 newLockDuration = 2 * 365 days;
        uint256 newUnlockTime = block.timestamp + newLockDuration;

        vlPuffer.reLock(0, newUnlockTime);
        vm.stopPrank();

        assertEq(vlPuffer.balanceOf(alice), 2400 ether, "Bad vlPUFFER balance after reLock");
    }

    function test_kickUsers_withMultipleUsers() public {
        uint256 amount = 100 ether;
        uint256 lockDuration = 365 days;
        uint256 unlockTime = block.timestamp + lockDuration;

        // Create locks for multiple users
        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, unlockTime);
        vm.stopPrank();

        vm.startPrank(bob);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, unlockTime);
        vm.stopPrank();

        // Fast forward past lock time and grace period
        vm.warp(unlockTime + 1 weeks + 1);

        address kicker = makeAddr("Kicker");
        uint256 kickerBalanceBefore = puffer.balanceOf(kicker);
        assertEq(kickerBalanceBefore, 0, "Bad kicker balance before kick");

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        vm.prank(kicker);
        vlPuffer.kickUsers(users);
        uint256 kickerBalanceAfter = puffer.balanceOf(kicker);

        uint256 expectedKickerFee = (amount * 2) * 100 / 10_000; // 1% fee for both users
        assertEq(kickerBalanceAfter, expectedKickerFee, "Bad kicker fee");
        assertEq(vlPuffer.balanceOf(alice), 0, "vlPUFFER balance should be 0 after kick for alice");
        assertEq(vlPuffer.balanceOf(bob), 0, "vlPUFFER balance should be 0 after kick for bob");
    }

    function test_kickUsers_withNoFee() public {
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
        address[] memory users = new address[](1);
        users[0] = alice;

        // First kick should succeed
        vm.prank(kicker);
        vlPuffer.kickUsers(users);

        // The same user can be kicked again but this time there are no token transfers
        vm.prank(kicker);
        vm.expectEmit(true, true, true, true);
        emit vlPUFFER.UserKicked(kicker, alice, 0, 0);
        vlPuffer.kickUsers(users);
    }
}
