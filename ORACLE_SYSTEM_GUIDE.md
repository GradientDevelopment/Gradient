# MM Oracle System Guide

## Overview

The MM Oracle System provides automated reward calculation and distribution for the MMLiquidityManager contract. It consists of three main components:

1. **MMLiquidityManager** - Core liquidity management contract
2. **MMRewardOracle** - Oracle for reward calculation and distribution
3. **MMRewardKeeper** - Automated keeper for triggering updates

## System Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   External      │    │   MMReward      │    │   MMLiquidity   │
│   Data Sources  │───▶│   Oracle        │───▶│   Manager       │
│                 │    │                 │    │                 │
└─────────────────┘    └─────────────────┘    └─────────────────┘
                                │
                                ▼
                       ┌─────────────────┐
                       │   MMReward      │
                       │   Keeper        │
                       │                 │
                       └─────────────────┘
```

## Components

### 1. MMRewardOracle

The oracle calculates rewards based on multiple factors:

#### Configuration Parameters
- **Base Reward Rate**: 1% per day (100 basis points)
- **Volume Multiplier**: 2% bonus for high trading volume
- **Time Multiplier**: 1.5% bonus for longer time periods
- **Performance Multiplier**: 3% bonus for high performance scores
- **Min Reward Interval**: 1 hour minimum between distributions
- **Max Reward Per Update**: 1 ETH maximum per distribution

#### Reward Calculation Formula
```
Total Reward = Base Reward × (1 + Volume Multiplier + Time Multiplier + Performance Multiplier)
```

Where:
- **Base Reward** = (baseRewardRate × timeElapsed) / (10000 × 1 day)
- **Volume Multiplier** = (totalVolume × volumeMultiplier) / 1e18
- **Time Multiplier** = (timeElapsed × timeMultiplier) / (365 days)
- **Performance Multiplier** = (performanceScore × performanceMultiplier) / 10000

#### Key Functions

```solidity
// Update pool metrics
function updatePoolMetrics(address token, uint256 volume, uint256 performanceScore)

// Distribute rewards for a specific token
function distributeRewards(address token)

// Distribute rewards for all supported tokens
function distributeAllRewards()

// Get current reward calculation
function getCurrentRewardCalculation(address token)
```

### 2. MMRewardKeeper

The keeper automates reward distribution based on conditions:

#### Configuration Parameters
- **Min Interval**: 1 hour minimum between executions
- **Gas Price Limit**: 50 gwei maximum gas price
- **Min Reward Threshold**: 0.01 ETH minimum to trigger distribution
- **Is Active**: Whether keeper is enabled

#### Key Functions

```solidity
// Check if upkeep is needed
function checkUpkeep(address token) returns (bool upkeepNeeded, bytes memory performData)

// Execute upkeep for a specific token
function performUpkeep(bytes calldata performData)

// Execute upkeep for all tokens
function performUpkeepAll()

// Update metrics through keeper
function updateMetrics(address token, uint256 volume, uint256 performanceScore)
```

## Usage Examples

### 1. Manual Reward Distribution

```javascript
// Fund the oracle
await owner.sendTransaction({ 
    to: rewardOracle.address, 
    value: ethers.parseEther("10") 
});

// Update pool metrics
await rewardOracle.updatePoolMetrics(
    tokenAddress,
    ethers.parseEther("1000"), // volume
    7500 // performance score (75%)
);

// Distribute rewards
await rewardOracle.distributeRewards(tokenAddress);
```

### 2. Automated Keeper Execution

```javascript
// Check if upkeep is needed
const [upkeepNeeded, performData] = await rewardKeeper.checkUpkeep(tokenAddress);

if (upkeepNeeded) {
    // Execute upkeep
    await rewardKeeper.performUpkeep(performData);
}
```

### 3. Batch Operations

```javascript
// Update metrics for multiple tokens
await rewardOracle.updatePoolMetrics(token1, volume1, score1);
await rewardOracle.updatePoolMetrics(token2, volume2, score2);

// Distribute rewards for all tokens
await rewardOracle.distributeAllRewards();
```

## Integration with External Systems

### 1. Data Sources

The oracle can be integrated with various data sources:

- **DEX APIs**: Uniswap, SushiSwap for trading volume
- **Price Oracles**: Chainlink for token prices
- **Analytics Platforms**: For performance metrics
- **Custom APIs**: For project-specific data

### 2. Automation Services

The keeper can be integrated with:

- **Chainlink Keepers**: For decentralized automation
- **Gelato Network**: For gasless automation
- **Custom Bots**: For specific requirements

### 3. Monitoring and Alerts

```javascript
// Monitor oracle activity
const metrics = await rewardOracle.getPoolMetrics(tokenAddress);
console.log("Total Volume:", ethers.formatEther(metrics.totalVolume));
console.log("Performance Score:", metrics.performanceScore);
console.log("Accumulated Rewards:", ethers.formatEther(metrics.accumulatedRewards));

// Monitor keeper activity
const stats = await rewardKeeper.getKeeperStats(tokenAddress);
console.log("Last Execution:", new Date(stats.lastExec * 1000));
console.log("Total Executions:", stats.totalExecs);
```

## Configuration Management

### Oracle Configuration

```javascript
// Update oracle parameters
await rewardOracle.updateOracleConfig(
    200,  // baseRewardRate (2%)
    300,  // volumeMultiplier (3%)
    250,  // timeMultiplier (2.5%)
    400,  // performanceMultiplier (4%)
    1800, // minRewardInterval (30 minutes)
    ethers.parseEther("2") // maxRewardPerUpdate (2 ETH)
);
```

### Keeper Configuration

```javascript
// Update keeper parameters
await rewardKeeper.updateKeeperConfig(
    1800, // minInterval (30 minutes)
    ethers.parseUnits("30", "gwei"), // gasPriceLimit (30 gwei)
    ethers.parseEther("0.005") // minRewardThreshold (0.005 ETH)
);
```

## Security Features

### 1. Access Control
- Owner-only configuration updates
- Emergency pause functionality
- Emergency withdrawal capability

### 2. Validation
- Input validation for all parameters
- Gas price limits for keeper execution
- Minimum interval enforcement

### 3. Reentrancy Protection
- All external functions use `nonReentrant` modifier
- Safe external calls to MMLiquidityManager

## Gas Optimization

### 1. Efficient Storage
- Packed structs for configuration
- Minimal storage operations
- Batch processing for multiple tokens

### 2. Conditional Execution
- Only execute when conditions are met
- Gas price limits prevent expensive executions
- Minimum threshold checks

### 3. Event-Based Tracking
- Events for off-chain monitoring
- Reduced on-chain storage requirements
- Efficient state management

## Deployment Process

### 1. Deploy Contracts
```bash
npx hardhat run scripts/deploy-oracle-system.js --network <network>
```

### 2. Configure Oracle
```javascript
// Add supported tokens
await rewardOracle.setTokenSupport(tokenAddress, true);

// Update configuration
await rewardOracle.updateOracleConfig(...);
```

### 3. Fund Oracle
```javascript
// Send ETH to oracle for reward distribution
await owner.sendTransaction({
    to: rewardOracle.address,
    value: ethers.parseEther("100")
});
```

### 4. Activate Keeper
```javascript
// Ensure keeper is active
const config = await rewardKeeper.config();
if (!config.isActive) {
    await rewardKeeper.toggleKeeper();
}
```

## Monitoring and Maintenance

### 1. Regular Checks
- Monitor accumulated rewards
- Check keeper execution frequency
- Verify reward distribution accuracy

### 2. Performance Optimization
- Adjust configuration based on usage
- Monitor gas costs
- Optimize update frequency

### 3. Emergency Procedures
- Pause oracle if issues detected
- Emergency withdraw funds if needed
- Update configuration for new requirements

## Future Enhancements

### 1. Advanced Metrics
- Impermanent loss calculation
- Risk-adjusted returns
- Market volatility metrics

### 2. Multi-Token Rewards
- Support for rewards in different tokens
- Dynamic reward token selection
- Cross-token reward distribution

### 3. Governance Integration
- DAO governance for parameters
- Community voting on configurations
- Decentralized decision making

### 4. Advanced Automation
- Machine learning-based predictions
- Dynamic parameter adjustment
- Cross-chain automation

This oracle system provides a robust, automated solution for reward distribution that can scale with your MM liquidity management needs. 