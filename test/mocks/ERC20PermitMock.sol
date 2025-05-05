// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * @title ERC20PermitMock
 * @dev Mock implementation of ERC20 token with ERC2612 permit functionality for testing
 * Provides additional functions to help with generating permits for tests
 */
contract ERC20PermitMock is ERC20, ERC20Permit {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) ERC20Permit(name) {
        _decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /**
     * @dev Helper function for tests to get the permit message digest
     * @param owner The owner of the tokens
     * @param spender The address which will spend the tokens
     * @param value The amount of tokens that will be spent
     * @param nonce The current nonce of the owner
     * @param deadline The time at which the signature expires
     * @return The hash digest that should be signed by the owner
     */
    function getPermitDigest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        external
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                    owner,
                    spender,
                    value,
                    nonce,
                    deadline
                )
            )
        );
    }
}
