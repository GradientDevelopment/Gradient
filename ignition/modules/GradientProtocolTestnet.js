const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");

module.exports = buildModule("GradientProtocolTestnet", (m) => {
    // 1. Deploy GradientRegistry first (central registry)
    const gradientRegistry = m.contract("GradientRegistry", [], {});

    // 2. Deploy GradientMarketMakerPool (depends on registry)
    const gradientMarketMakerPool = m.contract("GradientMarketMakerPool", [
        gradientRegistry
    ], {});

    // 3. Deploy FallbackExecutor (standalone)
    const fallbackExecutor = m.contract("FallbackExecutor", [], {});

    // 4. Deploy GradientOrderbook (depends on registry)
    const gradientOrderbook = m.contract("GradientOrderbook", [
        gradientRegistry
    ], {});

    // 5. Configure the registry with all contract addresses
    m.call(gradientRegistry, "setMainContracts", [
        gradientMarketMakerPool, // marketMakerPool
        "0x0000000000000000000000000000000000000000", // gradientToken (placeholder)
        "0x0000000000000000000000000000000000000000", // feeCollector (placeholder)
        gradientOrderbook, // orderbook
        fallbackExecutor // fallbackExecutor
    ]);

    // 6. Set up initial configurations
    // Set orderbook as authorized contract in registry
    m.call(gradientRegistry, "setContractAuthorization", [
        gradientOrderbook,
        true
    ]);

    // 7. Configure orderbook settings for testnet
    // Set initial fee percentage (0.5% = 50 basis points)
    m.call(gradientOrderbook, "setFeePercentage", [50]);

    // Set order size limits (lower for testnet)
    m.call(gradientOrderbook, "setOrderSizeLimits", [
        "100000000000000", // minOrderSize: 0.0001 ETH
        "100000000000000000000" // maxOrderSize: 100 ETH
    ]);

    // Set max order TTL (7 days for testnet)
    m.call(gradientOrderbook, "setMaxOrderTtl", [604800]);

    // Set MM fee distribution percentage (70%)
    m.call(gradientOrderbook, "updateMMFeeDistributionPercentage", [7000]);

    // 8. Authorize deployer as fulfiller in registry
    const deployer = m.getAccount(0); // Automatically gets the first signer

    m.call(gradientRegistry, "authorizeFulfiller", [
        deployer, // deployer address
        true // authorized
    ]);

    // 9. Set orderbook as reward distributor (so it can distribute fees to MM pool)
    m.call(gradientRegistry, "setRewardDistributor", [
        gradientOrderbook // orderbook address
    ]);

    // 10. Configure fallback executor for testnet
    // Add Uniswap V2 testnet addresses (example for Sepolia)
    // Note: These addresses need to be updated based on the specific testnet
    // m.call(fallbackExecutor, "addDEX", [
    //     "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D", // Uniswap V2 Router (placeholder)
    //     "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D", // Router address (placeholder)
    //     "0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f", // Factory address (placeholder)
    //     1 // Priority (1 = highest)
    // ]);

    return {
        gradientRegistry,
        gradientMarketMakerPool,
        fallbackExecutor,
        gradientOrderbook
    };
}); 