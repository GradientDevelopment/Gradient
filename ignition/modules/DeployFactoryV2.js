const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");

/**
 * @title DeployFactory
 * @notice Ignition module to deploy GradientMarketMakerFactory with updated GradientMarketMakerPoolV3
 * @dev This script deploys:
 *  1. GradientRegistry (if EXISTING_REGISTRY_ADDRESS is not set)
 *  2. GradientMarketMakerFactory (uses updated GradientMarketMakerPoolV3)
 *  3. EventAggregator
 *  4. Links them together
 * 
 * @usage
 * To deploy with new registry:
 *   npx hardhat ignition deploy ignition/modules/DeployFactory.js --network mainnet
 * 
 * To use existing registry (set EXISTING_REGISTRY_ADDRESS in .env):
 *   EXISTING_REGISTRY_ADDRESS=0x... npx hardhat ignition deploy ignition/modules/DeployFactory.js --network mainnet
 */
module.exports = buildModule("DeployFactoryV2", (m) => {
    // Get deployer account
    const deployer = m.getAccount(0);
    // 2. Deploy GradientMarketMakerFactory (depends on registry)
    // Factory uses GradientMarketMakerPoolV3 (updated pool contract with emitLiquidityEvent fixes)
    const gradientMarketMakerFactory = m.contract(
        "GradientMarketMakerFactory",
        [
            "0xdB7E3b94bd55FB9D93112830b23BAE82E33527c9",
            "0xE189c082F9A0239f728fe4351558E1ffDE0DD1da", // Placeholder for EventAggregator
        ],
        {
            id: "GradientMarketMakerFactory",
        }
    );

    m.call(
        gradientMarketMakerFactory,
        "setUniv3Helper",
        ["0x790521294b8F9058a3C69763c99333D309d7FF90"],
        {
            id: "SetUniv3Helper",
        }
    );

    // 3. Deploy EventAggregator (depends on factory)
    // const eventAggregator = m.contract(
    //     "EventAggregator",
    //     [gradientMarketMakerFactory],
    //     {
    //         id: "EventAggregator",
    //     }
    // );

    // // 4. Update factory to use the actual EventAggregator address
    // m.call(
    //     gradientMarketMakerFactory,
    //     "setEventAggregator",
    //     [eventAggregator],
    //     {
    //         id: "SetEventAggregator",
    //     }
    // );

    return {
        // gradientRegistry,
        gradientMarketMakerFactory,
        // eventAggregator,
    };
});

