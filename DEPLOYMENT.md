# Gradient Protocol Deployment Guide

This guide explains how to deploy the Gradient Protocol contracts using Hardhat Ignition.

## Prerequisites

- Node.js v16+
- Hardhat installed
- Network configuration in `hardhat.config.js`
- Private key with sufficient funds for deployment

## Deployment Scripts

### 1. Mainnet Deployment (`GradientProtocol.js`)

For production deployment on Ethereum mainnet:

```bash
npx hardhat ignition deploy ignition/modules/GradientProtocol.js --network mainnet
```

**Configuration:**
- Fee percentage: 0.5% (50 basis points)
- Min order size: 0.001 ETH
- Max order size: 1000 ETH
- Max order TTL: 30 days
- MM fee distribution: 70%

### 2. Testnet Deployment (`GradientProtocolTestnet.js`)

For testing on networks like Sepolia, Goerli, or BSC Testnet:

```bash
npx hardhat ignition deploy ignition/modules/GradientProtocolTestnet.js --network sepolia
```

**Configuration:**
- Fee percentage: 0.5% (50 basis points)
- Min order size: 0.0001 ETH
- Max order size: 100 ETH
- Max order TTL: 7 days
- MM fee distribution: 70%

## Deployment Order

The deployment follows this sequence:

1. **GradientRegistry** - Central registry contract
2. **GradientMarketMakerPool** - Liquidity pool contract
3. **FallbackExecutor** - External DEX integration
4. **GradientOrderbook** - Main trading contract
5. **Configuration** - Set up contract relationships and parameters

## Post-Deployment Configuration

### Required Manual Updates

After deployment, you need to update these placeholder addresses:

1. **Deployer Address**: Update the deployer address as an authorized fulfiller
2. **Gradient Token Address**: Set the address of your project's token (if applicable)
3. **Fee Collector Address**: Set the address that will receive platform fees
4. **Orderbook Address**: Set the address of the orderbook contract
5. **Whitelisted Fulfiller Address**: Set the address of the fulfiller contract

### Example Configuration Commands

```javascript
// Update deployer as authorized fulfiller (IMPORTANT: Do this first!)
await gradientRegistry.authorizeFulfiller(deployerAddress, true);

// Update Uniswap pair for a specific token
await gradientRegistry.setContractAddress("UniswapPair", "0x...");

// Update Gradient token address
await gradientRegistry.setContractAddress("GradientToken", "0x...");

// Update fee collector
await gradientRegistry.setContractAddress("FeeCollector", "0x...");
```

### Network-Specific DEX Addresses

Update the FallbackExecutor with the correct DEX addresses for your target network:

#### Ethereum Mainnet
- Uniswap V2 Router: `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D`
- Uniswap V2 Factory: `0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f`

#### Sepolia Testnet
- Uniswap V2 Router: `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D`
- Uniswap V2 Factory: `0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f`

## Verification

After deployment, verify your contracts on Etherscan:

```bash
npx hardhat verify --network mainnet <CONTRACT_ADDRESS> <CONSTRUCTOR_ARGS>
```

## Security Considerations

1. **Private Key Security**: Never commit private keys to version control
2. **Multi-sig Setup**: Consider using a multi-signature wallet for admin functions
3. **Access Control**: Review and test all access control mechanisms
4. **Emergency Pause**: Ensure emergency pause functionality works correctly

## Monitoring

Monitor the deployment using:

```bash
# Check deployment status
npx hardhat ignition list

# View deployment details
npx hardhat ignition show <DEPLOYMENT_ID>
```

## Troubleshooting

### Common Issues

1. **Insufficient Gas**: Ensure your account has enough ETH for deployment
2. **Network Issues**: Verify network configuration in `hardhat.config.js`
3. **Contract Dependencies**: Ensure all dependencies are properly linked

### Recovery

If deployment fails:

1. Check the deployment logs for specific errors
2. Verify all constructor parameters are correct
3. Ensure sufficient gas limit for complex deployments
4. Retry the deployment with `--reset` flag if needed

## Support

For deployment issues, check:
- Hardhat Ignition documentation
- Network-specific documentation
- Contract verification guides 