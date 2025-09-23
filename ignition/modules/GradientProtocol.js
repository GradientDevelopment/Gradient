const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");
const {
  ROUTER_ADDRESSES,
  GREY_TOKEN_ADDRESS,
  FULFILLER_ADDRESS,
} = require("../../config/addresses");

module.exports = buildModule("GradientProtocol", (m) => {
  // 1. Deploy GradientRegistry first (central registry)
  const deployer = m.getAccount(0); // Automatically gets the first signer
  const gradientRegistry = m.contract("GradientRegistry", [], {});

  // 2. Deploy GradientMarketMakerFactory (depends on registry)
  const gradientMarketMakerFactory = m.contract(
    "GradientMarketMakerFactory",
    [
      gradientRegistry,
      "0x0000000000000000000000000000000000000000" // Placeholder for EventAggregator
    ],
    {}
  );

  // 3. Deploy EventAggregator (depends on factory)
  const eventAggregator = m.contract("EventAggregator", [
    gradientMarketMakerFactory
  ], {});

  // 4. Update factory to use the actual EventAggregator address
  m.call(gradientMarketMakerFactory, "setEventAggregator", [eventAggregator]);

  // 5. Deploy FallbackExecutor (depends on registry)
  const fallbackExecutor = m.contract(
    "FallbackExecutor",
    [gradientRegistry],
    {}
  );

  // 6. Deploy GradientOrderbook (depends on registry)
  const gradientOrderbook = m.contract(
    "GradientOrderbook",
    [gradientRegistry],
    {}
  );

  // 7. Configure the registry with all contract addresses
  m.call(gradientRegistry, "setMainContracts", [
    gradientMarketMakerFactory, // marketMakerPool (now factory)
    GREY_TOKEN_ADDRESS, // gradientToken (placeholder)
    gradientOrderbook, // orderbook
    fallbackExecutor, // fallbackExecutor
    ROUTER_ADDRESSES.mainnet.uniswapV2Router, // Uniswap V2 Router (mainnet)
  ]);

  // 8. Configure orderbook settings for mainnet
  // Note: Most settings are already set in constructor:
  // - ethFeePercentage = 50 (0.5%)
  // - tokenFeePercentage = 50 (0.5%)
  // - minOrderSize = 1e6 (0.000001 ETH)
  // - maxOrderSize = 1000 ether
  // - maxOrderTtl = 30 days
  // - mmFeeDistributionPercentage = 7000 (70%)
  
  // Override maxOrderTtl to 7 days for mainnet (shorter than default 30 days)
  m.call(gradientOrderbook, "setMaxOrderTtl", [604800]);

  // 9. Authorize fulfiller in registry
  m.call(gradientRegistry, "authorizeFulfiller", [
    FULFILLER_ADDRESS, // fulfiller address from config
    true // authorized
  ]);

  // 10. Set orderbook as reward distributor (so it can distribute fees to MM pools)
  m.call(gradientRegistry, "setRewardDistributor", [
    gradientOrderbook // orderbook address
  ]);

  // 11. Configure fallback executor for mainnet
  // Add Uniswap V2 as a DEX (mainnet addresses)
  m.call(fallbackExecutor, "addDEX", [
    ROUTER_ADDRESSES.mainnet.uniswapV2Router, // Uniswap V2 Router
    ROUTER_ADDRESSES.mainnet.uniswapV2Router, // Router address
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