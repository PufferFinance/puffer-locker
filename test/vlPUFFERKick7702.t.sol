// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import { vlPUFFER } from "../src/vlPUFFER.sol";
import { ERC20PermitMock } from "./mocks/ERC20PermitMock.sol";
import { Test } from "forge-std/Test.sol";

contract AliceMaliciousRevert {
    fallback() external {
        revert("Alice is malicious");
    }
}

contract vlPUFFERTest is Test {
    // Constants
    uint256 constant MAX_MULTIPLIER = 24;
    uint256 constant MIN_LOCK_AMOUNT = 10 ether;
    uint256 constant LOCK_TIME_MULTIPLIER = 30 days;

    // Actors
    uint256 aliceSK = uint256(1337);
    address alice = vm.addr(aliceSK);

    address pufferMultisig = makeAddr("Puffer Multisig");

    // Contracts
    ERC20PermitMock public puffer;
    vlPUFFER public vlPuffer;

    function setUp() public {
        puffer = new ERC20PermitMock("PUFFER", "PUFFER", 18);
        vlPuffer = new vlPUFFER(pufferMultisig, address(puffer));

        // Mint tokens to test users
        puffer.mint(alice, 1000 ether);
    }

    function test_aliceLocksTokens_andSetsMaliciousContract() public {
        // Alice Locks 1000 tokens for 1 year
        vm.startPrank(alice);
        puffer.approve(address(vlPuffer), 1000 ether);
        vlPuffer.createLock(1000 ether, 12); // 1 year

        assertEq(address(alice).code.length, 0, "Alice should not have a code");

        vm.deal(address(this), 2 ether);

        vm.startPrank(address(this));
        // This time it should work. because the malicious contract is not attached
        payable(address(alice)).transfer(1 ether);

        vm.startPrank(alice);

        // Alice signs and attaches malicious contract delegation
        vm.signAndAttachDelegation(address(new AliceMaliciousRevert()), aliceSK);

        assertGt(address(alice).code.length, 0, "Alice should have a code");

        vm.stopPrank();

        // Make sure the malicious contract is actually called
        vm.expectRevert();
        payable(address(alice)).transfer(1 ether);

        assertEq(vlPuffer.balanceOf(alice), 12_000 ether, "Alice should get x12 vlTokens");

        // 1 year and 10 days in the future
        vm.warp((block.timestamp + (30 days * 12)) + 10 days);

        assertEq(vlPuffer.balanceOf(alice), 12_000 ether, "Alice still has original amount of vlPUFFER");

        address kicker = makeAddr("Kicker");

        address[] memory users = new address[](1);
        users[0] = alice;

        vm.startPrank(kicker);
        vlPuffer.kickUsers(users);
        vm.stopPrank();

        assertEq(vlPuffer.balanceOf(alice), 0 ether, "Alice should have 0 vlPUFFER");

        assertEq(puffer.balanceOf(alice), 990 ether, "Alice should get 990 PUFFER");
        assertEq(puffer.balanceOf(kicker), 10 ether, "Kicker should get 10 PUFFER");
    }
}
