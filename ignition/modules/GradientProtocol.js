const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");
const {
  ROUTER_ADDRESSES,
  GREY_TOKEN_ADDRESS,
} = require("../../config/addresses");

module.exports = buildModule("GradientProtocol", (m) => {
  // 1. Deploy GradientRegistry first (central registry)
  const deployer = m.getAccount(0); // Automatically gets the first signer
  const gradientRegistry = m.contract("GradientRegistry", [], {});

  // 2. Deploy GradientMarketMakerPool (depends on registry)
  const gradientMarketMakerPool = m.contract(
    "GradientMarketMakerPool",
    [gradientRegistry],
    {}
  );

  // 3. Deploy FallbackExecutor (depends on registry)
  const fallbackExecutor = m.contract(
    "FallbackExecutor",
    [gradientRegistry],
    {}
  );

  // 4. Deploy GradientOrderbook (depends on registry)
  const gradientOrderbook = m.contract(
    "GradientOrderbook",
    [gradientRegistry],
    {}
  );

  // 5. Configure the registry with all contract addresses
  m.call(gradientRegistry, "setMainContracts", [
    gradientMarketMakerPool, // marketMakerPool
    GREY_TOKEN_ADDRESS, // gradientToken (placeholder)
    deployer, // feeCollector (placeholder)
    gradientOrderbook, // orderbook
    fallbackExecutor, // fallbackExecutor
    ROUTER_ADDRESSES.mainnet.uniswapV2Router, // Uniswap V2 Router (mainnet)
  ]);

  // 6. Set up initial configurations
  // Set orderbook as authorized contract in registry
  m.call(gradientRegistry, "setContractAuthorization", [
    gradientOrderbook,
    true,
  ]);

  // 7. Configure orderbook settings
  // Set initial fee percentage (0.5% = 50 basis points)
  m.call(gradientOrderbook, "setFeePercentage", [50]);

  // Set order size limits
  m.call(gradientOrderbook, "setOrderSizeLimits", [
    "1000000000000", // minOrderSize: 0.001 ETH
    "1000000000000000000000", // maxOrderSize: 1000 ETH
  ]);

  // Set MM fee distribution percentage (70%)
  m.call(gradientOrderbook, "updateMMFeeDistributionPercentage", [7000]);

  // 8. Configure market maker pool
  // Set up initial pool configuration (if needed)
  // Note: Pools are created dynamically when liquidity is provided

  // 9. Authorize deployer as fulfiller in registry
  m.call(gradientRegistry, "authorizeFulfiller", [
    deployer, // deployer address
    true, // authorized
  ]);

  // 10. Set orderbook as reward distributor (so it can distribute fees to MM pool)
  m.call(gradientRegistry, "setRewardDistributor", [
    gradientOrderbook, // orderbook address
  ]);

  // 11. Configure fallback executor
  // Add Uniswap V2 as a DEX (example addresses for mainnet)
  m.call(fallbackExecutor, "addDEX", [
    ROUTER_ADDRESSES.mainnet.uniswapV2Router, // Uniswap V2 Router
    ROUTER_ADDRESSES.mainnet.uniswapV2Router, // Router address
    ROUTER_ADDRESSES.mainnet.uniswapV2Factory, // Factory address
    1, // Priority (1 = highest)
  ]);

  return {
    gradientRegistry,
    gradientMarketMakerPool,
    fallbackExecutor,
    gradientOrderbook,
  };
});