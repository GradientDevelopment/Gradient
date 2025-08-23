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

    // 6. Deploy GradientOrderbook (depends on registry)
    const gradientOrderbook = m.contract("GradientOrderbook", [
        gradientRegistry
    ], {});

    // 7. Configure the registry with all contract addresses
    m.call(gradientRegistry, "setMainContracts", [
        gradientMarketMakerFactory, // marketMakerPool (now factory)
        GREY_TOKEN_ADDRESS, // gradientToken (placeholder)
        gradientOrderbook, // orderbook
        fallbackExecutor, // fallbackExecutor
        ROUTER_ADDRESSES.bsctest.uniswapV2Router // Uniswap V2 Router (testnet)
    ]);

    // 8. Configure orderbook settings for testnet
    // Set initial fee percentage (0.5% = 50 basis points)
    m.call(gradientOrderbook, "setFeePercentage", [50]);

    // Set order size limits (lower for testnet)
    m.call(gradientOrderbook, "setOrderSizeLimits", [
        "1000000000000", // minOrderSize: 0.0001 ETH
        "100000000000000000000" // maxOrderSize: 100 ETH
    ]);

    // Set max order TTL (7 days for testnet)
    m.call(gradientOrderbook, "setMaxOrderTtl", [604800]);

    // Set MM fee distribution percentage (70%)
    m.call(gradientOrderbook, "updateMMFeeDistributionPercentage", [7000]);

    // 9. Authorize deployer as fulfiller in registry
    m.call(gradientRegistry, "authorizeFulfiller", [
        deployer, // deployer address
        true // authorized
    ]);

    // 10. Set orderbook as reward distributor (so it can distribute fees to MM pools)
    m.call(gradientRegistry, "setRewardDistributor", [
        gradientOrderbook // orderbook address
    ]);

    // 11. Configure fallback executor for testnet
    // Add PancakeSwap as a DEX (BSC testnet addresses)
    m.call(fallbackExecutor, "addDEX", [
        ROUTER_ADDRESSES.bsctest.uniswapV2Router, // PancakeSwap Router
        ROUTER_ADDRESSES.bsctest.uniswapV2Router, // Router address
        1 // Priority (1 = highest)
    ]);

    // 12. Create initial pool for GREY token (optional - can be done later)
    // m.call(gradientMarketMakerFactory, "createPool", [GREY_TOKEN_ADDRESS]);

    return {
        gradientRegistry,
        gradientMarketMakerFactory,
        eventAggregator,
        fallbackExecutor,
        gradientOrderbook
    };
}); 