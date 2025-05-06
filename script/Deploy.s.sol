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

    // Puffer token address
    address private constant PUFFER_TOKEN = 0x4d1C297d39C5c1277964D0E3f8Aa901493664530;

    /**
     * @notice Deploy PufferLocker to the current network
     * @dev Detects the network and uses appropriate parameters
     * @return pufferLocker The deployed PufferLocker contract
     */
    function run() public returns (PufferLocker pufferLocker) {
        uint256 chainId = block.chainid;

        if (chainId == MAINNET) {
            console2.log("Deploying to Ethereum Mainnet");
        } else if (chainId == HOLESKY) {
            console2.log("Deploying to Holesky Testnet");
        } else {
            revert("Unsupported network");
        }

        console2.log("Deploying PufferLocker with:");
        console2.log("- Puffer Token:", PUFFER_TOKEN);

        // Start the deployment
        vm.startBroadcast();

        // Deploy the PufferLocker contract
        pufferLocker = new PufferLocker(PUFFER_TOKEN);

        vm.stopBroadcast();

        console2.log("PufferLocker deployed at:", address(pufferLocker));

        return pufferLocker;
    }
}

/**
 * @title DeployPufferLockerWithCustomParams
 * @notice Deployment script for PufferLocker with custom token address
 * @dev Use this when you need to specify a custom token address
 *
 * Usage:
 *   forge script script/Deploy.s.sol:DeployPufferLockerWithCustomParams --sig "run(address)" [PUFFER_TOKEN] --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY -vvvv
 */
contract DeployPufferLockerWithCustomParams is Script {
    /**
     * @notice Deploy PufferLocker with custom token address
     * @param pufferToken Address of the Puffer token
     * @return pufferLocker The deployed PufferLocker contract
     */
    function run(address pufferToken) public returns (PufferLocker pufferLocker) {
        require(pufferToken != address(0), "Puffer token address cannot be zero");

        console2.log("Deploying PufferLocker with custom parameters:");
        console2.log("- Puffer Token:", pufferToken);

        vm.startBroadcast();

        // Deploy the PufferLocker contract
        pufferLocker = new PufferLocker(pufferToken);

        vm.stopBroadcast();

        console2.log("PufferLocker deployed at:", address(pufferLocker));

        return pufferLocker;
    }
}
