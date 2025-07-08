const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");

module.exports = buildModule("GradientOrderbookStandalone", (m) => {
  // Deploy updated GradientOrderbook with registry address as parameter
  // Note: This assumes the registry is already deployed and its address is known
  const gradientOrderbook = m.contract("GradientOrderbook", [
    "0x73eA50305AcE013C7B779294dcc210E27608dC1B" // Replace with actual registry address
  ], {});

  // Configure orderbook settings after deployment
  // Set initial fee percentage (0.5% = 50 basis points)
  m.call(gradientOrderbook, "setFeePercentage", [50]);

  // Set order size limits
  m.call(gradientOrderbook, "setOrderSizeLimits", [
    "1000000000", // minOrderSize: 0.001 ETH
    "1000000000000000000000", // maxOrderSize: 1000 ETH
  ]);

  // Set maximum order TTL (30 days)
  m.call(gradientOrderbook, "setMaxOrderTtl", [
    "2592000", // 30 days in seconds
  ]);

  // Set MM fee distribution percentage (70%)
  m.call(gradientOrderbook, "updateMMFeeDistributionPercentage", [7000]);

  // Set maximum price deviation (5% = 500 basis points)
  m.call(gradientOrderbook, "updateMaxPriceDeviation", [500]);

  return {
    gradientOrderbook,
  };
}); 