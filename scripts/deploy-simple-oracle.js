const { ethers } = require("hardhat");

async function main() {
    console.log("Deploying Simple MM Oracle System...");

    // Deploy MMLiquidityManager
    console.log("\n1. Deploying MMLiquidityManager...");
    const MMLiquidityManager = await ethers.getContractFactory("MMLiquidityManager");
    const mmLiquidityManager = await MMLiquidityManager.deploy();
    await mmLiquidityManager.waitForDeployment();
    const mmAddress = await mmLiquidityManager.getAddress();
    console.log("MMLiquidityManager deployed to:", mmAddress);

    // Deploy SimpleMMOracle
    console.log("\n2. Deploying SimpleMMOracle...");
    const SimpleMMOracle = await ethers.getContractFactory("SimpleMMOracle");
    const simpleOracle = await SimpleMMOracle.deploy(mmAddress);
    await simpleOracle.waitForDeployment();
    const oracleAddress = await simpleOracle.getAddress();
    console.log("SimpleMMOracle deployed to:", oracleAddress);

    // Get deployment info
    const [deployer] = await ethers.getSigners();
    console.log("\nDeployer address:", deployer.address);

    // Log oracle configuration
    console.log("\nOracle Configuration:");
    console.log("- Reward Rate:", (await simpleOracle.rewardRate()).toString(), "basis points (1% = 100)");
    console.log("- Min Reward Amount:", ethers.formatEther(await simpleOracle.minRewardAmount()), "ETH");
    console.log("- Max Reward Amount:", ethers.formatEther(await simpleOracle.maxRewardAmount()), "ETH");

    console.log("\n=== Deployment Summary ===");
    console.log("MMLiquidityManager:", mmAddress);
    console.log("SimpleMMOracle:", oracleAddress);
    console.log("\nDeployment completed successfully!");

    // Return deployment addresses
    return {
        mmLiquidityManager: mmAddress,
        simpleOracle: oracleAddress
    };
}

// Execute the deployment
main()
    .then((addresses) => {
        console.log("\n=== Contract Addresses ===");
        console.log("MMLiquidityManager:", addresses.mmLiquidityManager);
        console.log("SimpleMMOracle:", addresses.simpleOracle);
        process.exit(0);
    })
    .catch((error) => {
        console.error("Deployment failed:", error);
        process.exit(1);
    }); 