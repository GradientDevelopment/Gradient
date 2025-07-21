const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");

module.exports = buildModule("GradientOrderbook", (m) => {
  const gradientRegistry = "0x15a495C1b95B6843633DD3eC851F16B259c5E325";
  const orderbook = m.contract("GradientOrderbook", [gradientRegistry], {});
  m.call(orderbook, "setOrderSizeLimits", [
    "10000000000000", // minOrderSize: 0.001 ETH
    "1000000000000000000000", // maxOrderSize: 1000 ETH
  ]);
  return { orderbook };
});
