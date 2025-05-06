// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ERC20Votes } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import { Nonces } from "@openzeppelin/contracts/utils/Nonces.sol";

/**
 * @title VoteTest
 * @notice An ERC20 token with voting capabilities
 * @dev Implements ERC20Votes from OpenZeppelin to enable on-chain voting
 */
contract VoteTest is ERC20, ERC20Permit, ERC20Votes {
    /**
     * @notice Constructor that initializes the token with a name and symbol
     */
    constructor() ERC20("Vote Test Token", "VOTE") ERC20Permit("Vote Test Token") {
        // Mint initial supply to the deployer
        _mint(msg.sender, 1000000 * 10 ** decimals());
    }

    /**
     * @notice Hook that is called before any transfer of tokens
     * @dev Required override to update voting power when tokens are transferred
     */
    function _update(address from, address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._update(from, to, amount);
    }

    /**
     * @notice Mint new tokens to a specified address
     * @param to The address that will receive the minted tokens
     * @param amount The amount of tokens to mint
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
