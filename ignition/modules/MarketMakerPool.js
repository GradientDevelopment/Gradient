const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");

module.exports = buildModule("MarketMakerPool", (m) => {
  // Deploy GradientRegistry first (required dependency)
  // const gradientRegistry = m.contract("GradientRegistry", [], {});

  // Deploy GradientMarketMakerPool with registry dependency
  const gradientMarketMakerPool = m.contract(
    "GradientMarketMakerPool",
    ["0x54047176c4031A7Dce6289Bca64801ced83AB9C4"],
    {}
  );

  // Configure the registry with the market maker pool address
  // m.call(gradientRegistry, "setMainContracts", [
  //     gradientMarketMakerPool, // marketMakerPool
  //     "0x0000000000000000000000000000000000000000", // gradientToken (placeholder)
  //     "0x0000000000000000000000000000000000000000", // feeCollector (placeholder)
  //     "0x0000000000000000000000000000000000000000", // orderbook (placeholder)
  //     "0x0000000000000000000000000000000000000000", // fallbackExecutor (placeholder)
  //     "0x0000000000000000000000000000000000000000"  // uniswapRouter (placeholder)
  // ]);

  // Authorize deployer as fulfiller in registry
  // const deployer = m.getAccount(0); // Automatically gets the first signer
  // m.call(gradientRegistry, "authorizeFulfiller", [
  //     deployer, // deployer address
  //     true // authorized
  // ]);

  return { gradientMarketMakerPool };
});
