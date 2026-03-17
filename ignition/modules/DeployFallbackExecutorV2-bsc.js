const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");
const { ROUTER_ADDRESSES } = require("../../config/addresses");

/**
 * Deploys FallbackExecutorV2 (Uniswap V3 SwapRouter02 compatible) and configures DEXes.
 *
 * Usage:
 *   EXISTING_REGISTRY_ADDRESS=0x... npx hardhat ignition deploy ignition/modules/DeployFallbackExecutorV2.js --network base
 *   EXISTING_REGISTRY_ADDRESS=0x... CHAIN=bsc npx hardhat ignition deploy ignition/modules/DeployFallbackExecutorV2.js --network bsc
 *
 * Env:
 *   EXISTING_REGISTRY_ADDRESS - GradientRegistry address (required)
 *   CHAIN - 'base' | 'bsc' (optional, defaults to 'base'; must match --network for correct router addresses)
 */
module.exports = buildModule("DeployFallbackExecutorV2", (m) => {
  const registryAddress = "0x6369bE8bBE2A6Fd1ADcb81512722d6D5bD9dc0D0";
  const routerAddresses = ROUTER_ADDRESSES.bsc;

  const fallbackExecutorV2 = m.contract(
    "FallbackExecutorV2",
    [registryAddress],
    { id: "FallbackExecutorV2" }
  );

  // Add V2 DEX (PancakeSwap/BaseSwap router)
  m.call(
    fallbackExecutorV2,
    "addDEX",
    [
      routerAddresses.uniswapV2Router,
      routerAddresses.uniswapV2Router,
      1,
    ],
    { id: "AddV2DEX" }
  );

  // Add V3 DEX (SwapRouter02 - same interface on Base/BSC)
  m.call(
    fallbackExecutorV2,
    "addV3DEX",
    [
      routerAddresses.uniswapV3Router,
      routerAddresses.uniswapV3Router,
      routerAddresses.uniswapV3Factory,
      2,
    ],
    { id: "AddV3DEX" }
  );

  return {
    fallbackExecutorV2,
  };
});
