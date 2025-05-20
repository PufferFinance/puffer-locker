// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import { vlPUFFER } from "../src/vlPUFFER.sol";
import { ERC20PermitMock } from "./mocks/ERC20PermitMock.sol";
import { Test } from "forge-std/Test.sol";

contract vlPUFFERTest is Test {
    // Constants
    uint256 constant MAX_MULTIPLIER = 24;
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
        uint256 multiplier = 12; // 12 months = x12 multiplier

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, multiplier);
        vm.stopPrank();

        assertEq(vlPuffer.balanceOf(alice), amount * multiplier, "Bad vlPUFFER balance");
        assertEq(puffer.balanceOf(address(vlPuffer)), amount, "Bad PUFFER balance");

        (uint256 pufferAmount, uint256 time) = vlPuffer.lockInfos(alice);
        assertEq(pufferAmount, amount, "Bad puffer amount");
        assertEq(time, block.timestamp + (multiplier * LOCK_TIME_MULTIPLIER), "Bad unlock time");
    }

    function test_createLockWithPermit() public {
        uint256 amount = 100 ether;
        uint256 multiplier = 12; // 12 months = x12 multiplier
        uint256 deadline = block.timestamp + 1 hours;
        uint256 privateKey = 0xA11CE; // Owner's private key
        address owner = vm.addr(privateKey);

        // Mint tokens to the owner
        puffer.mint(owner, amount);

        vm.startPrank(owner);
        bytes32 digest = puffer.getPermitDigest(owner, address(vlPuffer), amount, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        vlPUFFER.Permit memory permit = vlPUFFER.Permit({ deadline: deadline, amount: amount, v: v, r: r, s: s });

        vlPuffer.createLockWithPermit(amount, multiplier, permit);
        vm.stopPrank();

        assertEq(vlPuffer.balanceOf(owner), amount * multiplier, "Bad vlPUFFER balance");
        assertEq(puffer.balanceOf(address(vlPuffer)), amount, "Bad PUFFER balance in vlPUFFER");
    }

    function test_createLockWithPermit_expired() public {
        uint256 amount = 100 ether;
        uint256 multiplier = 12;
        uint256 deadline = block.timestamp - 1; // Past deadline
        uint256 privateKey = 0xA11CE;
        address owner = vm.addr(privateKey);

        puffer.mint(owner, amount);

        vm.startPrank(owner);
        bytes32 digest = puffer.getPermitDigest(owner, address(vlPuffer), amount, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        vlPUFFER.Permit memory permit = vlPUFFER.Permit({ deadline: deadline, amount: amount, v: v, r: r, s: s });

        vm.expectRevert(abi.encodeWithSignature("ERC2612ExpiredSignature(uint256)", 0));
        vlPuffer.createLockWithPermit(amount, multiplier, permit);
        vm.stopPrank();
    }

    function test_createLock_withDelegation() public {
        uint256 amount = 100 ether;
        uint256 multiplier = 12;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, multiplier);
        vm.stopPrank();

        // Check that alice is delegated to herself by default
        assertEq(vlPuffer.delegates(alice), alice, "Default delegation should be to self");
        assertEq(puffer.balanceOf(address(vlPuffer)), amount, "Bad PUFFER balance in vlPUFFER");
    }

    function test_reLock() public {
        uint256 initialAmount = 100 ether;
        uint256 initialMultiplier = 12;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), type(uint256).max);
        vlPuffer.createLock(initialAmount, initialMultiplier);

        // Add more tokens and extend lock
        uint256 additionalAmount = 50 ether;
        uint256 newMultiplier = 24;

        vlPuffer.reLock(additionalAmount, newMultiplier);
        vm.stopPrank();

        // (100 + 50) * 24 = 3600 vlPUFFER
        assertEq(vlPuffer.balanceOf(alice), 3600 ether, "Bad vlPUFFER balance after reLock");
        assertEq(
            puffer.balanceOf(address(vlPuffer)), initialAmount + additionalAmount, "Bad PUFFER balance in vlPUFFER"
        );
    }

    function test_reLock_withZeroAmountAndSameMultiplier() public {
        uint256 initialAmount = 100 ether;
        uint256 initialMultiplier = 12;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), type(uint256).max);
        vlPuffer.createLock(initialAmount, initialMultiplier);

        uint256 initialLockingTime = block.timestamp;

        uint256 unlockTime = initialLockingTime + 12 * 30 days;

        (, uint256 time) = vlPuffer.lockInfos(alice);

        assertEq(time, unlockTime, "Bad unlock time");

        // 10 months go by
        uint256 newBlockTime = initialLockingTime + 10 * 30 days;
        vm.warp(newBlockTime);

        // This should work, but extend the lock period
        vlPuffer.reLock(0, initialMultiplier);

        (, uint256 time2) = vlPuffer.lockInfos(alice);

        // The unlock time should be 1 year on top of current block time
        assertEq(time2, newBlockTime + 12 * 30 days, "Bad unlock time 2");

        vm.stopPrank();
    }

    function test_withdraw(uint256 amount) public {
        amount = bound(amount, MIN_LOCK_AMOUNT, type(uint128).max);
        uint256 multiplier = 12;

        puffer.mint(charlie, amount);

        vm.startPrank(charlie);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, multiplier);

        // Fast forward past lock time
        vm.warp(block.timestamp + (multiplier * LOCK_TIME_MULTIPLIER) + 1);

        uint256 balanceBefore = puffer.balanceOf(charlie);
        vlPuffer.withdraw(charlie);
        uint256 balanceAfter = puffer.balanceOf(charlie);

        assertEq(balanceAfter - balanceBefore, amount, "Bad withdrawal amount");
        assertEq(vlPuffer.balanceOf(charlie), 0, "vlPUFFER balance should be 0 after withdrawal");
        vm.stopPrank();
    }

    function test_kickUser() public {
        uint256 amount = 100 ether;
        uint256 multiplier = 12;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, multiplier);
        vm.stopPrank();

        // Fast forward past lock time and grace period
        vm.warp(block.timestamp + (multiplier * LOCK_TIME_MULTIPLIER) + 1 weeks + 1);

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
        uint256 multiplier = 12;

        // Create locks for multiple users
        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, multiplier);
        vm.stopPrank();

        vm.startPrank(bob);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, multiplier);
        vm.stopPrank();

        // Fast forward past lock time and grace period
        vm.warp(block.timestamp + (multiplier * LOCK_TIME_MULTIPLIER) + 1 weeks + 1);

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
        uint256 multiplier = 12;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, multiplier);
        vm.stopPrank();

        // Fast forward past lock time and grace period
        vm.warp(block.timestamp + (multiplier * LOCK_TIME_MULTIPLIER) + 1 weeks + 1);

        address kicker = makeAddr("Kicker");
        address[] memory users = new address[](1);
        users[0] = alice;

        // First kick should succeed
        vm.prank(kicker);
        vlPuffer.kickUsers(users);

        // The same user can be 'kicked' again but this time there are no token transfers
        vm.prank(kicker);
        vlPuffer.kickUsers(users);
    }

    function test_RevertWhen_createLock_insufficientAmount(uint256 amount) public {
        amount = bound(amount, 0, MIN_LOCK_AMOUNT - 1);
        uint256 multiplier = 12;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vm.expectRevert(vlPUFFER.InvalidAmount.selector);
        vlPuffer.createLock(amount, multiplier);
        vm.stopPrank();
    }

    function test_RevertWhen_createLock_invalidMultiplier(uint256 multiplier) public {
        uint256 amount = 100 ether;
        multiplier = bound(multiplier, 0, 0); // Test with 0 multiplier

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vm.expectRevert(vlPUFFER.InvalidMultiplier.selector);
        vlPuffer.createLock(amount, multiplier);
        vm.stopPrank();
    }

    function test_RevertWhen_withdraw_beforeUnlock() public {
        uint256 amount = 100 ether;
        uint256 multiplier = 12;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, multiplier);
        vm.expectRevert(vlPUFFER.TokensLocked.selector);
        vlPuffer.withdraw(alice);
        vm.stopPrank();
    }

    function test_RevertWhen_kickUser_beforeGracePeriod() public {
        uint256 amount = 100 ether;
        uint256 multiplier = 12;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, multiplier);
        vm.stopPrank();

        vm.warp(block.timestamp + (multiplier * LOCK_TIME_MULTIPLIER) + 1); // Just after unlock, before grace period
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
        vlPuffer.createLock(100 ether, 12);
        vm.stopPrank();

        // Test unpause
        vm.prank(pufferMultisig);
        vlPuffer.unpause();
        assertFalse(vlPuffer.paused(), "Contract should be unpaused");

        // Test that operations work again after unpause
        vm.startPrank(alice);
        vlPuffer.createLock(100 ether, 12);
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

    function test_RevertWhen_createLock_exceedsMaxMultiplier() public {
        uint256 amount = 100 ether;
        uint256 multiplier = MAX_MULTIPLIER + 1;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vm.expectRevert(vlPUFFER.InvalidMultiplier.selector);
        vlPuffer.createLock(amount, multiplier);
        vm.stopPrank();
    }

    function test_RevertWhen_createLock_lockAlreadyExists() public {
        uint256 amount = 100 ether;
        uint256 multiplier = 12;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), type(uint256).max);
        vlPuffer.createLock(amount, multiplier);

        // Try to create another lock
        vm.expectRevert(vlPUFFER.LockAlreadyExists.selector);
        vlPuffer.createLock(amount, multiplier);
        vm.stopPrank();
    }

    function test_reLock_decreaseVlPufferBalance() public {
        uint256 initialAmount = 100 ether;
        uint256 initialMultiplier = 12;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), type(uint256).max);
        vlPuffer.createLock(initialAmount, initialMultiplier);

        // Fast forward 6 months
        vm.warp(block.timestamp + 180 days);

        // Try to relock with a lower multiplier
        vm.expectRevert(vlPUFFER.ReLockingWillReduceVLBalance.selector);
        vlPuffer.reLock(0, 6);
        vm.stopPrank();
    }

    function test_RevertWhen_withdraw_noLock() public {
        vm.startPrank(alice);
        vm.expectRevert(vlPUFFER.LockDoesNotExist.selector);
        vlPuffer.withdraw(alice);
        vm.stopPrank();
    }

    function test_kickUser_noLock() public {
        address[] memory users = new address[](1);
        users[0] = alice;

        vm.prank(bob);
        // Nothing happens, the tx is successful, but it's a no-op
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
        uint256 multiplier = 12;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, multiplier);

        vm.expectRevert(vlPUFFER.TransfersDisabled.selector);
        vlPuffer.transfer(bob, 1 ether);
        vm.stopPrank();
    }

    function test_RevertWhen_transferFrom() public {
        uint256 amount = 100 ether;
        uint256 multiplier = 12;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, multiplier);
        vlPuffer.approve(bob, amount);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(vlPUFFER.TransfersDisabled.selector);
        vlPuffer.transferFrom(alice, bob, 1 ether);
        vm.stopPrank();
    }

    function test_delegation() public {
        uint256 amount = 100 ether;
        uint256 multiplier = 24; // 2 years = x24 multiplier

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, multiplier);
        vm.stopPrank();

        uint256 twoYearVotingPower = amount * multiplier;
        assertEq(vlPuffer.getVotes(alice), twoYearVotingPower, "Alice has the same voting power in vlPUFFER");

        vm.startPrank(bob);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, multiplier);
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
        vlPuffer.createLock(amount, multiplier);
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
        vlPuffer.createLock(amount, multiplier);
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
        uint256 initialMultiplier = 12;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), type(uint256).max);
        vlPuffer.createLock(initialAmount, initialMultiplier);

        // Add more tokens and extend lock
        uint256 additionalAmount = 50 ether;
        uint256 newMultiplier = 24;

        vlPuffer.reLock(additionalAmount, newMultiplier);
        vm.stopPrank();

        assertEq(vlPuffer.balanceOf(alice), 3600 ether, "Bad vlPUFFER balance after reLock");
    }

    function test_reLock_withZeroAmount() public {
        uint256 initialAmount = 100 ether;
        uint256 initialMultiplier = 12;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), type(uint256).max);
        vlPuffer.createLock(initialAmount, initialMultiplier);

        // ReLock with zero amount but higher multiplier
        uint256 newMultiplier = 24;
        vlPuffer.reLock(0, newMultiplier);

        // Should have 100 * 24 = 2400 vlPUFFER
        assertEq(vlPuffer.balanceOf(alice), 2400 ether, "Bad vlPUFFER balance after reLock");
        assertEq(puffer.balanceOf(address(vlPuffer)), initialAmount, "Bad PUFFER balance in vlPUFFER");
        vm.stopPrank();
    }

    function test_kickUsers_withMultipleUsers() public {
        uint256 amount = 100 ether;
        uint256 multiplier = 12;

        // Create locks for multiple users
        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, multiplier);
        vm.stopPrank();

        vm.startPrank(bob);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, multiplier);
        vm.stopPrank();

        // Fast forward past lock time and grace period
        vm.warp(block.timestamp + (multiplier * LOCK_TIME_MULTIPLIER) + 1 weeks + 1);

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

    function test_kickUsers_withZeroFee() public {
        uint256 amount = 10 ether; // Minimum lock amount
        uint256 multiplier = 12;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, multiplier);
        vm.stopPrank();

        // Fast forward past lock time and grace period
        vm.warp(block.timestamp + (multiplier * LOCK_TIME_MULTIPLIER) + 1 weeks + 1);

        address kicker = makeAddr("Kicker");
        address[] memory users = new address[](1);
        users[0] = alice;

        vm.prank(kicker);
        vlPuffer.kickUsers(users);

        // Verify fee was transferred (1% of 10 ether = 0.1 ether)
        assertEq(puffer.balanceOf(kicker), 0.1 ether, "Kicker should receive 0.1 ether fee");
    }

    function test_reLock_withSameUnlockTime() public {
        uint256 initialAmount = 100 ether;
        uint256 initialMultiplier = 12;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), type(uint256).max);
        vlPuffer.createLock(initialAmount, initialMultiplier);

        // Fast forward 30 days
        vm.warp(block.timestamp + 1 days);

        vlPuffer.reLock(0, initialMultiplier);
        vm.stopPrank();
    }

    function test_reLock_withLowerUnlockTime() public {
        uint256 initialAmount = 100 ether;
        uint256 initialMultiplier = 12;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), type(uint256).max);
        vlPuffer.createLock(initialAmount, initialMultiplier);

        // Try to relock with lower multiplier (lower unlock time)
        vm.expectRevert(vlPUFFER.NewUnlockTimeMustBeGreaterThanCurrentLock.selector);
        vlPuffer.reLock(0, initialMultiplier - 1);
        vm.stopPrank();
    }

    function test_kickUsers_withNoLock() public {
        address[] memory users = new address[](1);
        users[0] = alice;

        vm.prank(bob);
        // Should not revert, just skip the user
        vlPuffer.kickUsers(users);
    }

    function test_kickUsers_beforeGracePeriod() public {
        uint256 amount = 100 ether;
        uint256 multiplier = 12;

        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), amount);
        vlPuffer.createLock(amount, multiplier);
        vm.stopPrank();

        // Fast forward to just after unlock but before grace period
        vm.warp(block.timestamp + (multiplier * LOCK_TIME_MULTIPLIER) + 1);

        address[] memory users = new address[](1);
        users[0] = alice;

        vm.prank(bob);
        vm.expectRevert(vlPUFFER.TokensMustBeUnlocked.selector);
        vlPuffer.kickUsers(users);
    }
}
