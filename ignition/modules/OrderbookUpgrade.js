const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");

module.exports = buildModule("OrderbookUpgrade", (m) => {
  // Deploy the updated GradientOrderbook contract
  // This version includes fixes for tokens with decimals lower than 18
  const gradientRegistry = "0x604D5cBe788CBA5115Ffd3E2407BD4C4B7F81a1e";
  
  const orderbook = m.contract("GradientOrderbook", [gradientRegistry], {});
  
  // Set dust tolerance (0.1% = 10 basis points)
  m.call(orderbook, "updateDustTolerance", [10]);
  
  // IMPORTANT: After deployment, you'll need to manually update the registry
  // to point to the new orderbook address using:
  // gradientRegistry.setMainContracts() with the new orderbook address
  
  return { orderbook };
});
