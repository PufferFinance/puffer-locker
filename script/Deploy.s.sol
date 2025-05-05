// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { PufferLocker } from "../src/PufferLocker.sol";
import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

/**
 * @title DeployPufferLocker
 * @notice Deployment script for the PufferLocker contract
 * @dev Handles both testnet (Holesky) and mainnet deployments with proper configuration
 *
 * Usage:
 * - Testnet (Holesky):
 *   forge script script/Deploy.s.sol:DeployPufferLocker --rpc-url $HOLESKY_RPC_URL --private-key $PRIVATE_KEY --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY -vvvv
 *
 * - Mainnet:
 *   forge script script/Deploy.s.sol:DeployPufferLocker --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY -vvvv
 */
contract DeployPufferLocker is Script {
    // Chain IDs
    uint256 private constant MAINNET = 1;
    uint256 private constant HOLESKY = 17000;

    // Puffer team addresses
    address private constant PUFFER_TEAM_MAINNET = 0x46Ab97e7a5D7516B2aed95c34Ce810f1B45bf73A; // Example - replace with actual address
    address private constant PUFFER_TEAM_HOLESKY = 0x46Ab97e7a5D7516B2aed95c34Ce810f1B45bf73A; // Usually same as mainnet for testing

    /**
     * @notice Deploy PufferLocker to the current network
     * @dev Detects the network and uses appropriate parameters
     * @return pufferLocker The deployed PufferLocker contract
     */
    function run() public returns (PufferLocker pufferLocker) {
        uint256 chainId = block.chainid;

        address pufferTeam;

        // Determine correct addresses based on chain
        if (chainId == MAINNET) {
            console2.log("Deploying to Ethereum Mainnet");
            pufferTeam = PUFFER_TEAM_MAINNET;
        } else if (chainId == HOLESKY) {
            console2.log("Deploying to Holesky Testnet");
            pufferTeam = PUFFER_TEAM_HOLESKY;
        } else {
            revert("Unsupported network");
        }

        console2.log("Deploying PufferLocker with:");
        console2.log("- Puffer Token: 0x4d1C297d39C5c1277964D0E3f8Aa901493664530 (hardcoded)");
        console2.log("- Puffer Team:", pufferTeam);

        // Start the deployment
        vm.startBroadcast();

        // Deploy the PufferLocker contract
        pufferLocker = new PufferLocker(pufferTeam);

        vm.stopBroadcast();

        console2.log("PufferLocker deployed at:", address(pufferLocker));

        return pufferLocker;
    }
}

/**
 * @title DeployPufferLockerWithCustomParams
 * @notice Deployment script for PufferLocker with custom team address
 * @dev Use this when you need to specify a custom team address
 *
 * Usage:
 *   forge script script/Deploy.s.sol:DeployPufferLockerWithCustomParams --sig "run(address)" [PUFFER_TEAM] --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY -vvvv
 */
contract DeployPufferLockerWithCustomParams is Script {
    /**
     * @notice Deploy PufferLocker with custom team address
     * @param pufferTeam Address of the Puffer team
     * @return pufferLocker The deployed PufferLocker contract
     */
    function run(address pufferTeam) public returns (PufferLocker pufferLocker) {
        require(pufferTeam != address(0), "Puffer team address cannot be zero");

        console2.log("Deploying PufferLocker with custom parameters:");
        console2.log("- Puffer Token: 0x4d1C297d39C5c1277964D0E3f8Aa901493664530 (hardcoded)");
        console2.log("- Puffer Team:", pufferTeam);

        vm.startBroadcast();

        // Deploy the PufferLocker contract
        pufferLocker = new PufferLocker(pufferTeam);

        vm.stopBroadcast();

        console2.log("PufferLocker deployed at:", address(pufferLocker));

        return pufferLocker;
    }
}
