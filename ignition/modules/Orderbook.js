const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");

module.exports = buildModule("GradientOrderbook", (m) => {
  const orderbook = m.contract("GradientOrderbook", [], {});

  return { orderbook };
});
