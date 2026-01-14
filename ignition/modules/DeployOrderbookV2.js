const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");
const {
    ROUTER_ADDRESSES,
} = require("../../config/addresses");

/**
 * @title DeployOrderbook
 * @notice Ignition module to deploy updated GradientOrderbook with v3 pair bypass support
 * @dev This script deploys:
 *  1. GradientOrderbook (with updated validateExecutionPrice that bypasses v3 pairs)
 *  2. UniswapV3PriceHelper (if not already deployed)
 *  3. Configures all necessary settings
 * 
 * @usage
 * To deploy with existing registry:
 *   EXISTING_REGISTRY_ADDRESS=0x... npx hardhat ignition deploy ignition/modules/DeployOrderbook.js --network mainnet
 * 
 * To deploy with existing registry and price helper:
 *   EXISTING_REGISTRY_ADDRESS=0x... EXISTING_PRICE_HELPER_ADDRESS=0x... npx hardhat ignition deploy ignition/modules/DeployOrderbook.js --network mainnet
 */
module.exports = buildModule("DeployOrderbookV2", (m) => {
    // Get deployer account
    const deployer = m.getAccount(0);

    // 2. Deploy GradientOrderbook
    const gradientOrderbook = m.contract(
        "GradientOrderbook",
        ["0xdB7E3b94bd55FB9D93112830b23BAE82E33527c9"],
        {
            id: "GradientOrderbook",
        }
    );

    // 5. Set fee manager in orderbook (if provided via environment variable)
    m.call(
        gradientOrderbook,
        "setFeeManager",
        ["0x6A3D8c4d5Cb61cC6764Fa54378467bfAe225fC7F"],
        {
            id: "SetFeeManager",
        }
    );

    // 6. Set Uniswap V3 Factory address in orderbook
    m.call(
        gradientOrderbook,
        "setUniswapV3Factory",
        [ROUTER_ADDRESSES.mainnet.uniswapV3Factory
        ],
        {
            id: "SetUniswapV3Factory",
        }
    );

    // 7. Set Uniswap V3 Price Helper in orderbook
    m.call(
        gradientOrderbook,
        "setUniswapV3PriceHelper",
        ["0x790521294b8F9058a3C69763c99333D309d7FF90"],
        {
            id: "SetUniswapV3PriceHelper",
        }
    );

    // 9. Set max order TTL (optional - 7 days in seconds)
    m.call(
        gradientOrderbook,
        "setMaxOrderTtl",
        [604800], // 7 days
        {
            id: "SetMaxOrderTtl",
        }
    );

    // Note: After timelock period, execute the change with:
    // executeContractAddressChange("Orderbook")

    return {
        gradientOrderbook,
    };
});

