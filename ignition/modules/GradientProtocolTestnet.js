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

    // 7. Deploy UniswapV3PriceHelper (needed for V3 price support)
    const uniswapV3PriceHelper = m.contract(
        "UniswapV3PriceHelper",
        [ROUTER_ADDRESSES.bsctest.uniswapV3Factory], // Uniswap V3 Factory address (testnet)
        {}
    );

    // 8. Deploy GradientOrderbook (depends on registry)
    const gradientOrderbook = m.contract("GradientOrderbook", [
        gradientRegistry
    ], {});

    // 9. Configure the registry with all contract addresses
    m.call(gradientRegistry, "setMainContracts", [
        gradientMarketMakerFactory, // marketMakerPool (now factory)
        GREY_TOKEN_ADDRESS, // gradientToken (placeholder)
        gradientOrderbook, // orderbook
        fallbackExecutor, // fallbackExecutor
        ROUTER_ADDRESSES.bsctest.uniswapV2Router, // Uniswap V2 Router (testnet)
        gradientFeeManager // feeManager
    ]);

    // 9.5. Update orderbook to get feeManager from registry (after registry is configured)
    m.call(gradientOrderbook, "setGradientRegistry", [gradientRegistry]);

    // 9.6. Explicitly set fee manager in orderbook
    m.call(gradientOrderbook, "setFeeManager", [gradientFeeManager]);

    // 10. Configure orderbook settings for testnet
    // Note: Most settings are already set in constructor:
    // - ethFeePercentage = 50 (0.5%)
    // - tokenFeePercentage = 50 (0.5%)
    // - minOrderSize = 1e6 (0.000001 ETH)
    // - maxOrderSize = 1000 ether
    // - maxOrderTtl = 30 days
    // - mmFeeDistributionPercentage = 7000 (70%)

    // Override maxOrderTtl to 7 days for testnet (shorter than default 30 days)
    m.call(gradientOrderbook, "setMaxOrderTtl", [604800]);

    // 10.5. Set Uniswap V3 Factory address in orderbook
    m.call(gradientOrderbook, "setUniswapV3Factory", [
        ROUTER_ADDRESSES.bsctest.uniswapV3Factory
    ]);

    // 10.6. Set Uniswap V3 Price Helper in orderbook
    m.call(gradientOrderbook, "setUniswapV3PriceHelper", [
        uniswapV3PriceHelper
    ]);

    // 11. Authorize deployer as fulfiller in registry
    m.call(gradientRegistry, "authorizeFulfiller", [
        deployer, // deployer address
        true // authorized
    ]);

    // 12. Set fee manager as reward distributor (so it can distribute fees to MM pools)
    m.call(gradientRegistry, "setRewardDistributor", [
        gradientFeeManager // fee manager address
    ]);

    // 13. Configure fallback executor for testnet
    // Add PancakeSwap V2 as a DEX (BSC testnet addresses)
    m.call(fallbackExecutor, "addDEX", [
        ROUTER_ADDRESSES.bsctest.uniswapV2Router, // DEX identifier (using router address)
        ROUTER_ADDRESSES.bsctest.uniswapV2Router, // Router address
        1 // Priority (1 = highest)
    ]);

    // 13.5. Add PancakeSwap V3 as a DEX (BSC testnet addresses)
    // Note: Verify the V3 SwapRouter address for BSC testnet before deploying
    m.call(fallbackExecutor, "addV3DEX", [
        ROUTER_ADDRESSES.bsctest.uniswapV3Router, // DEX identifier (using router address)
        ROUTER_ADDRESSES.bsctest.uniswapV3Router, // SwapRouter address
        ROUTER_ADDRESSES.bsctest.uniswapV3Factory, // V3 Factory address
        2 // Priority (2 = second priority, after V2)
    ]);

    // 14. Create initial pool for GREY token (optional - can be done later)
    // Note: After creating a pool, you'll need to set the priceHelper on that pool:
    // m.call(poolAddress, "setPriceHelper", [uniswapV3PriceHelper]);
    // m.call(gradientMarketMakerFactory, "createPool", [GREY_TOKEN_ADDRESS]);

    return {
        gradientRegistry,
        gradientMarketMakerFactory,
        eventAggregator,
        fallbackExecutor,
        gradientFeeManager,
        gradientOrderbook,
        uniswapV3PriceHelper
    };
}); 