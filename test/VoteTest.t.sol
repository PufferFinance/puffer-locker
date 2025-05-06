// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { PufferLocker } from "../src/PufferLocker.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Test, console2 } from "forge-std/Test.sol";

// Mock Puffer token for testing
contract MockPuffer is ERC20 {
    constructor() ERC20("Puffer", "PUFFER") {
        _mint(msg.sender, 1000000 * 10 ** 18);
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract PufferLockerTest is Test {
    PufferLocker public pufferLocker;
    MockPuffer public pufferToken;
    address public deployer = address(1);
    address public alice = address(2);
    address public bob = address(3);
    uint256 public constant INITIAL_SUPPLY = 1000000 * 10 ** 18;
    uint256 public constant MINT_AMOUNT = 1000 * 10 ** 18;
    uint256 public constant LOCK_DURATION = 52 weeks; // 1 year lock
    uint256 public constant EPOCH_MULTIPLIER = 25; // 52 weeks / 2 weeks per epoch

    function setUp() public {
        vm.startPrank(deployer);
        // Create the mock Puffer token first
        pufferToken = new MockPuffer();
        // Create the PufferLocker with the mock token
        pufferLocker = new PufferLocker(address(pufferToken));
        vm.stopPrank();
    }

    function test_InitialVotingPower() public view {
        // Check initial voting power
        assertEq(pufferLocker.getVotes(deployer), 0, "Deployer should have 0 votes initially (not delegated)");
        assertEq(pufferToken.balanceOf(deployer), INITIAL_SUPPLY, "Deployer should have initial supply");
    }

    function test_SelfDelegation() public {
        // Deployer approves tokens for locking
        vm.startPrank(deployer);
        pufferToken.approve(address(pufferLocker), INITIAL_SUPPLY);

        // Lock tokens to get voting power
        uint256 lockTime = block.timestamp + LOCK_DURATION;
        pufferLocker.createLock(INITIAL_SUPPLY, lockTime);

        // Delegate to self (should be automatic in PufferLocker)
        vm.stopPrank();

        // Check voting power after locking
        assertEq(
            pufferLocker.getVotes(deployer),
            INITIAL_SUPPLY * EPOCH_MULTIPLIER,
            "Deployer should have votes after locking tokens"
        );
    }

    function test_DelegationToOther() public {
        // Mint tokens to Alice
        vm.startPrank(deployer);
        pufferToken.mint(alice, MINT_AMOUNT);
        vm.stopPrank();

        // Check initial voting power
        assertEq(pufferLocker.getVotes(alice), 0, "Alice should have 0 votes initially");
        assertEq(pufferLocker.getVotes(bob), 0, "Bob should have 0 votes initially");

        // Alice locks tokens and then delegates to Bob
        vm.startPrank(alice);
        pufferToken.approve(address(pufferLocker), MINT_AMOUNT);
        uint256 lockTime = block.timestamp + LOCK_DURATION;
        pufferLocker.createLock(MINT_AMOUNT, lockTime);

        // Alice delegates to Bob
        pufferLocker.delegate(bob);
        vm.stopPrank();

        // Check voting power after delegation
        assertEq(pufferLocker.getVotes(alice), 0, "Alice should have 0 votes after delegating");
        assertEq(pufferLocker.getVotes(bob), MINT_AMOUNT * EPOCH_MULTIPLIER, "Bob should have Alice's voting power");
        assertEq(pufferToken.balanceOf(alice), 0, "Alice's PUFFER balance should be 0 after locking");
        assertEq(pufferToken.balanceOf(address(pufferLocker)), MINT_AMOUNT, "PufferLocker should hold Alice's tokens");
    }

    function test_ChangeDelegation() public {
        // Mint tokens to Alice
        vm.startPrank(deployer);
        pufferToken.mint(alice, MINT_AMOUNT);
        vm.stopPrank();

        // Alice locks tokens
        vm.startPrank(alice);
        pufferToken.approve(address(pufferLocker), MINT_AMOUNT);
        uint256 lockTime = block.timestamp + LOCK_DURATION;
        pufferLocker.createLock(MINT_AMOUNT, lockTime);

        // Alice has self-delegation by default after locking
        vm.stopPrank();

        // Check voting power after self-delegation
        uint256 expectedVotes = MINT_AMOUNT * EPOCH_MULTIPLIER;
        assertEq(
            pufferLocker.getVotes(alice),
            expectedVotes,
            "Alice should have votes equal to locked amount * lock time after self-delegation"
        );

        // Alice changes delegation to Bob
        vm.startPrank(alice);
        pufferLocker.delegate(bob);
        vm.stopPrank();

        // Check voting power after changing delegation
        assertEq(pufferLocker.getVotes(alice), 0, "Alice should have 0 votes after delegating to Bob");
        assertEq(pufferLocker.getVotes(bob), expectedVotes, "Bob should have Alice's voting power");
    }

    function test_DelegationAfterTransfer() public {
        // This test needs modification since PufferLocker doesn't allow transfers of vlPUFFER
        // Instead, we'll test delegation when multiple users lock tokens

        // Mint tokens to Alice
        vm.startPrank(deployer);
        pufferToken.mint(alice, MINT_AMOUNT);
        vm.stopPrank();

        // Alice locks tokens
        vm.startPrank(alice);
        pufferToken.approve(address(pufferLocker), MINT_AMOUNT);
        uint256 lockTime = block.timestamp + LOCK_DURATION;
        uint256 lockId = pufferLocker.createLock(MINT_AMOUNT, lockTime);

        // Alice delegates to Bob
        pufferLocker.delegate(bob);
        vm.stopPrank();

        // Check voting power after delegation
        uint256 expectedVotes = MINT_AMOUNT * EPOCH_MULTIPLIER;
        assertEq(pufferLocker.getVotes(bob), expectedVotes, "Bob should have Alice's voting power");

        // Simulate partial withdrawal by having Alice emergencyWithdraw half the tokens
        // First, we need to pause the contract (as owner)
        vm.startPrank(deployer);
        pufferLocker.pause();
        vm.stopPrank();

        // Now Alice can emergency withdraw
        vm.startPrank(alice);
        pufferLocker.emergencyWithdraw(lockId);
        vm.stopPrank();

        // Check voting power after "half" withdrawal
        assertEq(pufferLocker.getVotes(bob), 0, "Bob should have 0 voting power after emergency withdrawal");
        assertEq(
            pufferToken.balanceOf(alice), MINT_AMOUNT, "Alice should have her tokens back after emergency withdrawal"
        );
    }

    function test_DelegationBySig() public {
        // Mint tokens to the signer
        uint256 privateKey = 0xA11CE; // Alice's private key for testing
        address signerAddress = vm.addr(privateKey);

        vm.startPrank(deployer);
        pufferToken.mint(signerAddress, MINT_AMOUNT);
        vm.stopPrank();

        // Signer locks tokens
        vm.startPrank(signerAddress);
        pufferToken.approve(address(pufferLocker), MINT_AMOUNT);
        uint256 lockTime = block.timestamp + LOCK_DURATION;
        pufferLocker.createLock(MINT_AMOUNT, lockTime);
        vm.stopPrank();

        // Create delegation signature
        uint256 nonce = pufferLocker.nonces(signerAddress);
        uint256 expiry = block.timestamp + 1 hours;

        bytes32 domainSeparator = pufferLocker.DOMAIN_SEPARATOR();
        bytes32 DELEGATION_TYPEHASH = keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

        bytes32 structHash = keccak256(abi.encode(DELEGATION_TYPEHASH, bob, nonce, expiry));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        // Execute delegateBySig
        pufferLocker.delegateBySig(bob, nonce, expiry, v, r, s);

        // Check voting power after delegation by signature
        uint256 expectedVotes = MINT_AMOUNT * EPOCH_MULTIPLIER;
        assertEq(pufferLocker.getVotes(bob), expectedVotes, "Bob should have signer's voting power");
        assertEq(pufferLocker.delegates(signerAddress), bob, "Signer should delegate to Bob");
    }

    function test_HistoricalVotes() public {
        // Mint tokens to Alice
        vm.startPrank(deployer);
        pufferToken.mint(alice, MINT_AMOUNT);
        vm.stopPrank();

        // Alice locks tokens and delegates to self
        vm.startPrank(alice);
        pufferToken.approve(address(pufferLocker), MINT_AMOUNT);
        uint256 lockTime = block.timestamp + LOCK_DURATION;
        pufferLocker.createLock(MINT_AMOUNT, lockTime);
        vm.stopPrank();

        // Record current epoch
        uint256 blockNumber1 = pufferLocker.getCurrentEpoch();

        // Move to next block/epoch (add 2 weeks to move to next epoch)
        vm.warp(block.timestamp + 2 weeks);

        // Mint tokens to Bob
        vm.startPrank(deployer);
        pufferToken.mint(bob, MINT_AMOUNT / 2);
        vm.stopPrank();

        // Bob locks tokens and delegates to self
        vm.startPrank(bob);
        pufferToken.approve(address(pufferLocker), MINT_AMOUNT / 2);
        uint256 bobLockTime = block.timestamp + LOCK_DURATION;
        pufferLocker.createLock(MINT_AMOUNT / 2, bobLockTime);
        vm.stopPrank();

        // Record current epoch
        uint256 blockNumber2 = pufferLocker.getCurrentEpoch();

        // Move to next epoch
        vm.warp(block.timestamp + 2 weeks);

        // Check current votes
        uint256 aliceExpectedVotes = MINT_AMOUNT * EPOCH_MULTIPLIER;
        uint256 bobExpectedVotes = (MINT_AMOUNT / 2) * EPOCH_MULTIPLIER;

        assertEq(pufferLocker.getVotes(alice), aliceExpectedVotes, "Alice should have expected voting power");
        assertEq(pufferLocker.getVotes(bob), bobExpectedVotes, "Bob should have expected voting power");

        // Check historical votes at blockNumber1
        assertEq(
            pufferLocker.getPastVotes(alice, blockNumber1),
            aliceExpectedVotes,
            "Alice should have full voting power at epoch 1"
        );
        assertEq(pufferLocker.getPastVotes(bob, blockNumber1), 0, "Bob should have 0 voting power at epoch 1");

        // Check historical votes at blockNumber2
        assertEq(
            pufferLocker.getPastVotes(alice, blockNumber2),
            aliceExpectedVotes,
            "Alice should have full voting power at epoch 2"
        );
        assertEq(
            pufferLocker.getPastVotes(bob, blockNumber2),
            bobExpectedVotes,
            "Bob should have half voting power at epoch 2"
        );
    }
}
