const hre = require("hardhat");
const { ROUTER_ADDRESSES } = require("../config/addresses");

async function main() {
    console.log("Configuring FallbackExecutor...");

    // Get the deployed contracts
    const registryAddress = "0x..."; // Replace with actual deployed address
    const fallbackExecutorAddress = "0x..."; // Replace with actual deployed address

    const registry = await hre.ethers.getContractAt("GradientRegistry", registryAddress);
    const fallbackExecutor = await hre.ethers.getContractAt("FallbackExecutor", fallbackExecutorAddress);

    // Get the current network
    const network = hre.network.name;
    console.log(`Configuring for network: ${network}`);

    let routerAddress, factoryAddress;

    if (network === "mainnet") {
        routerAddress = ROUTER_ADDRESSES.mainnet.uniswapV2Router;
        factoryAddress = ROUTER_ADDRESSES.mainnet.uniswapV2Factory;
    } else if (network === "bsctest") {
        routerAddress = ROUTER_ADDRESSES.bsctest.uniswapV2Router;
        factoryAddress = ROUTER_ADDRESSES.bsctest.uniswapV2Factory;
    } else {
        console.log("Network not configured, using default addresses");
        routerAddress = ROUTER_ADDRESSES.hardhat.uniswapV2Router;
        factoryAddress = ROUTER_ADDRESSES.hardhat.uniswapV2Factory;
    }

    console.log(`Using router: ${routerAddress}`);
    console.log(`Using factory: ${factoryAddress}`);

    // Add DEX
    console.log("Adding DEX to FallbackExecutor...");
    const addDEXTx = await fallbackExecutor.addDEX(
        routerAddress,
        routerAddress,
        factoryAddress,
        1 // Priority
    );
    await addDEXTx.wait();
    console.log("DEX added successfully");

    console.log("FallbackExecutor configuration completed!");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    }); 