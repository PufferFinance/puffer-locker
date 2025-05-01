# PufferLocker

PufferLocker is a production-grade Solidity contract implementing a token voting system for Puffer tokens, compatible with OpenZeppelin's ERC20Votes. The system enables users to lock Puffer tokens for a specified duration to receive proportional voting power.

## Core Features

- **Epoch-Based Voting Power**: Voting power is allocated based on locked token amount × lock duration in weeks
- **Multiple Locks**: Users can have multiple independent locks with different expiration times
- **Automatic Expiry**: Voting power automatically expires when locks end without requiring transactions
- **Delegation**: Users can delegate their voting power to other addresses, including a specific Puffer team address
- **Non-transferable**: vlPuffer tokens represent staked positions and cannot be transferred
- **History Tracking**: Epoch-based system allows querying historical voting power
- **Security**: Implements OpenZeppelin's ReentrancyGuard to prevent reentrancy attacks
- **Emergency Shutdown**: Includes admin-controlled emergency shutdown with withdrawal capabilities

## Technical Implementation

- **Lock Mechanism**: Tokens are locked for a user-specified duration (up to 2 years maximum)
- **Voting Power Calculation**: `votingPower = lockedAmount × lockDurationInWeeks`
- **vlPuffer Tokens**: Non-transferable ERC20 tokens representing voting power
- **Time-Based Decay**: Voting power automatically expires at lock end through view function logic
- **Collateral Integrity**: Original tokens always remain withdrawable after lock expiry
- **Pagination**: Efficient pagination support for users with many locks
- **Gas Optimization**: Optimized user tracking and epoch transitions for better gas efficiency

## Contract Architecture

### State Management
- User locks are tracked in mapping `userLocks` with unique identifiers per user
- Active users are tracked to enable accurate `totalSupply` calculations
- Weekly epochs allow point-in-time queries through `balanceOfAtEpoch` and `totalSupplyAtEpoch`
- Two balance views: active (unexpired) and raw (total including expired)

### Key Functions

```solidity
// Create a new lock
function createLock(uint256 _value, uint256 _unlockTime) external returns (uint256 lockId);

// Withdraw tokens from an expired lock
function withdraw(uint256 _lockId) external;

// Delegate voting power to the Puffer team
function delegateToPufferTeam() external;

// Get active (unexpired) voting power
function balanceOf(address account) public view returns (uint256);

// Get raw vlToken balance (including expired tokens)
function getRawBalance(address account) external view returns (uint256);

// View voting power at a specific epoch
function balanceOfAtEpoch(address account, uint256 _epoch) public view returns (uint256);
```

## Deployment

The contract can be deployed to both testnet and mainnet environments using Foundry scripts.

### Prerequisites

- Foundry installed (https://getfoundry.sh/)
- Ethereum RPC endpoints for Holesky testnet and/or Mainnet
- Private key for deployment
- Etherscan API key for verification

### Deployment Commands

#### Holesky Testnet Deployment

```bash
forge script script/Deploy.s.sol:DeployPufferLocker \
  --rpc-url $HOLESKY_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

#### Mainnet Deployment

```bash
forge script script/Deploy.s.sol:DeployPufferLocker \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

#### Custom Parameter Deployment

For deploying with custom token and team addresses:

```bash
forge script script/Deploy.s.sol:DeployPufferLockerWithCustomParams \
  --sig "run(address,address)" $PUFFER_TOKEN_ADDRESS $PUFFER_TEAM_ADDRESS \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

## Development and Testing

Contract is built using Foundry. To use:

```bash
# Install dependencies
forge install

# Run tests
forge test

# Run attack vector tests
forge test --match-test "test_Lock|test_Epoch|test_Mass"

# Build
forge build
```

## Security Considerations

The contract has been tested against several potential attack vectors:

1. **Lock Spam Attack**: Creating numerous small locks to bloat contract storage
2. **Epoch Processing Attack**: Exploiting epoch transitions after periods of inactivity
3. **Mass Withdrawal Attack**: Gas limitations with multiple withdrawals

All tests confirm the contract's resilience to these attack vectors.

## License

Licensed under MIT

