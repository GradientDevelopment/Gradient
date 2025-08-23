const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");
const {
  ROUTER_ADDRESSES,
  GREY_TOKEN_ADDRESS,
} = require("../../config/addresses");

module.exports = buildModule("GradientProtocol", (m) => {
  // 1. Deploy GradientRegistry first (central registry)
  const deployer = m.getAccount(0); // Automatically gets the first signer
  const gradientRegistry = m.contract("GradientRegistry", [], {});

  // 2. Deploy GradientMarketMakerFactory (depends on registry)
  const gradientMarketMakerFactory = m.contract(
    "GradientMarketMakerFactory",
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
    gradientMarketMakerFactory, // marketMakerPool (now factory)
    GREY_TOKEN_ADDRESS, // gradientToken (placeholder)
    gradientOrderbook, // orderbook
    fallbackExecutor, // fallbackExecutor
    ROUTER_ADDRESSES.mainnet.uniswapV2Router, // Uniswap V2 Router (mainnet)
  ]);

  // 6. Set up initial configurations
  // Note: setContractAuthorization was removed - roles are now managed through AccessControl

  // 7. Configure orderbook settings
  // Set initial fee percentage (0.5% = 50 basis points)
  m.call(gradientOrderbook, "setFeePercentage", [50]);

  // Set order size limits
  m.call(gradientOrderbook, "setOrderSizeLimits", [
    "10000000000000", // minOrderSize: 0.001 ETH
    "1000000000000000000000", // maxOrderSize: 1000 ETH
  ]);

  // Set MM fee distribution percentage (70%)
  m.call(gradientOrderbook, "updateMMFeeDistributionPercentage", [7000]);

  // 8. Configure market maker factory
  // Note: Individual pools are created dynamically when liquidity is provided
  // Initial pools can be created here if needed

  // 9. Authorize deployer as fulfiller in registry
  m.call(gradientRegistry, "authorizeFulfiller", [
    deployer, // deployer address
    true, // authorized
  ]);

  // 10. Set orderbook as reward distributor (so it can distribute fees to MM pools)
  m.call(gradientRegistry, "setRewardDistributor", [
    gradientOrderbook, // orderbook address
  ]);

  // 11. Configure fallback executor
  // Add Uniswap V2 as a DEX (example addresses for mainnet)
  m.call(fallbackExecutor, "addDEX", [
    ROUTER_ADDRESSES.mainnet.uniswapV2Router, // Uniswap V2 Router
    ROUTER_ADDRESSES.mainnet.uniswapV2Router, // Router address
    1, // Priority (1 = highest)
  ]);

  return {
    gradientRegistry,
    gradientMarketMakerFactory,
    fallbackExecutor,
    gradientOrderbook,
  };
});