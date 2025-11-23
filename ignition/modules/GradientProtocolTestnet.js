const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");
const { ROUTER_ADDRESSES, GREY_TOKEN_ADDRESS } = require("../../config/addresses");

module.exports = buildModule("GradientProtocolTestnet", (m) => {
    // 1. Deploy GradientRegistry first (central registry)
    const deployer = m.getAccount(0); // Automatically gets the first signer
    const gradientRegistry = m.contract("GradientRegistry", [], {});

    // 2. Deploy GradientMarketMakerFactory (depends on registry)
    const gradientMarketMakerFactory = m.contract("GradientMarketMakerFactory", [
        gradientRegistry,
        "0x0000000000000000000000000000000000000000" // Placeholder for EventAggregator
    ], {});

    // 3. Deploy EventAggregator (depends on factory)
    const eventAggregator = m.contract("EventAggregator", [
        gradientMarketMakerFactory
    ], {});

    // 4. Update factory to use the actual EventAggregator address
    m.call(gradientMarketMakerFactory, "setEventAggregator", [eventAggregator]);

    // 5. Deploy FallbackExecutor (depends on registry)
    const fallbackExecutor = m.contract("FallbackExecutor", [
        gradientRegistry
    ], {});

    // 6. Deploy GradientFeeManager (depends on registry)
    const gradientFeeManager = m.contract("GradientFeeManager", [
        gradientRegistry
    ], {});

    // 7. Deploy GradientOrderbook (depends on registry)
    const gradientOrderbook = m.contract("GradientOrderbook", [
        gradientRegistry
    ], {});

    // 8. Configure the registry with all contract addresses
    m.call(gradientRegistry, "setMainContracts", [
        gradientMarketMakerFactory, // marketMakerPool (now factory)
        GREY_TOKEN_ADDRESS, // gradientToken (placeholder)
        gradientOrderbook, // orderbook
        fallbackExecutor, // fallbackExecutor
        ROUTER_ADDRESSES.bsctest.uniswapV2Router, // Uniswap V2 Router (testnet)
        gradientFeeManager // feeManager
    ]);

    // 8.5. Update orderbook to get feeManager from registry (after registry is configured)
    m.call(gradientOrderbook, "setGradientRegistry", [gradientRegistry]);

    // 8.6. Explicitly set fee manager in orderbook
    m.call(gradientOrderbook, "setFeeManager", [gradientFeeManager]);

    // 9. Configure orderbook settings for testnet
    // Note: Most settings are already set in constructor:
    // - ethFeePercentage = 50 (0.5%)
    // - tokenFeePercentage = 50 (0.5%)
    // - minOrderSize = 1e6 (0.000001 ETH)
    // - maxOrderSize = 1000 ether
    // - maxOrderTtl = 30 days
    // - mmFeeDistributionPercentage = 7000 (70%)

    // Override maxOrderTtl to 7 days for testnet (shorter than default 30 days)
    m.call(gradientOrderbook, "setMaxOrderTtl", [604800]);

    // 10. Authorize deployer as fulfiller in registry
    m.call(gradientRegistry, "authorizeFulfiller", [
        deployer, // deployer address
        true // authorized
    ]);

    // 11. Set fee manager as reward distributor (so it can distribute fees to MM pools)
    m.call(gradientRegistry, "setRewardDistributor", [
        gradientFeeManager // fee manager address
    ]);

    // 12. Configure fallback executor for testnet
    // Add PancakeSwap as a DEX (BSC testnet addresses)
    m.call(fallbackExecutor, "addDEX", [
        ROUTER_ADDRESSES.bsctest.uniswapV2Router, // PancakeSwap Router
        ROUTER_ADDRESSES.bsctest.uniswapV2Router, // Router address
        1 // Priority (1 = highest)
    ]);

    // 13. Create initial pool for GREY token (optional - can be done later)
    // m.call(gradientMarketMakerFactory, "createPool", [GREY_TOKEN_ADDRESS]);

    return {
        gradientRegistry,
        gradientMarketMakerFactory,
        eventAggregator,
        fallbackExecutor,
        gradientFeeManager,
        gradientOrderbook
    };
}); 