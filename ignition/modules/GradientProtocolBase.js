const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");
const {
  ROUTER_ADDRESSES,
  GREY_TOKEN_ADDRESS,
} = require("../../config/addresses");

module.exports = buildModule("GradientProtocolBase", (m) => {
  // 1. Deploy GradientRegistry first (central registry)
  const deployer = m.getAccount(0);
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

  // 6. Deploy GradientFeeManager (depends on registry)
  const gradientFeeManager = m.contract(
    "GradientFeeManager",
    [gradientRegistry],
    {}
  );

  // 7. Deploy UniswapV3PriceHelper (Base chain V3 factory)
  const uniswapV3PriceHelper = m.contract(
    "UniswapV3PriceHelper",
    [ROUTER_ADDRESSES.base.uniswapV3Factory],
    {}
  );

  const dexQuoteHelper = m.contract("GradientDexQuoteHelper", [], {});
  m.call(dexQuoteHelper, "addVenue", [
    ROUTER_ADDRESSES.base.uniswapV2Router,
    uniswapV3PriceHelper,
  ]);
  m.call(gradientMarketMakerFactory, "setDexQuoteHelper", [dexQuoteHelper]);

  // 8. Deploy GradientOrderbook (depends on registry)
  const gradientOrderbook = m.contract(
    "GradientOrderbook",
    [gradientRegistry],
    {}
  );

  // 9. Configure the registry with all contract addresses
  m.call(gradientRegistry, "setMainContracts", [
    gradientMarketMakerFactory,
    GREY_TOKEN_ADDRESS,
    gradientOrderbook,
    fallbackExecutor,
    ROUTER_ADDRESSES.base.uniswapV2Router,
    gradientFeeManager,
  ]);

  m.call(gradientOrderbook, "setGradientRegistry", [gradientRegistry]);
  m.call(gradientOrderbook, "setFeeManager", [gradientFeeManager]);

  // 10. Override maxOrderTtl to 7 days for Base
  m.call(gradientOrderbook, "setMaxOrderTtl", [604800]);

  m.call(gradientOrderbook, "setDexQuoteHelper", [dexQuoteHelper]);

  // 11. Authorize deployer as fulfiller in registry
  m.call(gradientRegistry, "authorizeFulfiller", [deployer, true]);

  // 12. Set fee manager as reward distributor
  m.call(gradientRegistry, "setRewardDistributor", [gradientFeeManager]);

  // 13. Configure fallback executor for Base (BaseSwap V2)
  m.call(fallbackExecutor, "addDEX", [
    ROUTER_ADDRESSES.base.uniswapV2Router,
    ROUTER_ADDRESSES.base.uniswapV2Router,
    1
  ]);

  // 13.5. Add BaseSwap V3 as a DEX
  m.call(fallbackExecutor, "addV3DEX", [
    ROUTER_ADDRESSES.base.uniswapV3Router,
    ROUTER_ADDRESSES.base.uniswapV3Router,
    ROUTER_ADDRESSES.base.uniswapV3Factory,
    2
  ]);

  return {
    gradientRegistry,
    gradientMarketMakerFactory,
    eventAggregator,
    fallbackExecutor,
    gradientFeeManager,
    gradientOrderbook,
    uniswapV3PriceHelper,
    dexQuoteHelper,
  };
});
