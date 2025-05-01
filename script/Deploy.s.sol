// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {PufferLocker} from "../src/PufferLocker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

    // Known token addresses on each network
    address private constant PUFFER_MAINNET = 0x4d1C297d39C5c1277964D0E3f8Aa901493664530; // Actual Puffer token on mainnet
    address private constant PUFFER_HOLESKY = 0x4d1C297d39C5c1277964D0E3f8Aa901493664530; // Example - replace with actual testnet address

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

        IERC20 pufferToken;
        address pufferTeam;

        // Determine correct addresses based on chain
        if (chainId == MAINNET) {
            console2.log("Deploying to Ethereum Mainnet");
            pufferToken = IERC20(PUFFER_MAINNET);
            pufferTeam = PUFFER_TEAM_MAINNET;
        } else if (chainId == HOLESKY) {
            console2.log("Deploying to Holesky Testnet");
            pufferToken = IERC20(PUFFER_HOLESKY);
            pufferTeam = PUFFER_TEAM_HOLESKY;
        } else {
            revert("Unsupported network");
        }

        console2.log("Deploying PufferLocker with:");
        console2.log("- Puffer Token:", address(pufferToken));
        console2.log("- Puffer Team:", pufferTeam);

        // Start the deployment
        vm.startBroadcast();

        // Deploy the PufferLocker contract
        pufferLocker = new PufferLocker(pufferToken, pufferTeam);

        vm.stopBroadcast();

        console2.log("PufferLocker deployed at:", address(pufferLocker));

        return pufferLocker;
    }
}

/**
 * @title DeployPufferLockerWithCustomParams
 * @notice Deployment script for PufferLocker with custom parameters
 * @dev Use this when you need to specify custom token or team addresses
 *
 * Usage:
 *   forge script script/Deploy.s.sol:DeployPufferLockerWithCustomParams --sig "run(address,address)" [PUFFER_TOKEN] [PUFFER_TEAM] --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY -vvvv
 */
contract DeployPufferLockerWithCustomParams is Script {
    /**
     * @notice Deploy PufferLocker with custom parameters
     * @param pufferToken Address of the Puffer token
     * @param pufferTeam Address of the Puffer team
     * @return pufferLocker The deployed PufferLocker contract
     */
    function run(address pufferToken, address pufferTeam) public returns (PufferLocker pufferLocker) {
        require(pufferToken != address(0), "Puffer token address cannot be zero");
        require(pufferTeam != address(0), "Puffer team address cannot be zero");

        console2.log("Deploying PufferLocker with custom parameters:");
        console2.log("- Puffer Token:", pufferToken);
        console2.log("- Puffer Team:", pufferTeam);

        vm.startBroadcast();

        // Deploy the PufferLocker contract
        pufferLocker = new PufferLocker(IERC20(pufferToken), pufferTeam);

        vm.stopBroadcast();

        console2.log("PufferLocker deployed at:", address(pufferLocker));

        return pufferLocker;
    }
}
