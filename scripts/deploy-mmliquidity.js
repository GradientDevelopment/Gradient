const { ethers } = require("hardhat");

async function main() {
    console.log("Deploying MMLiquidityManager...");

    // Get the contract factory
    const MMLiquidityManager = await ethers.getContractFactory("MMLiquidityManager");

    // Deploy the contract
    const mmLiquidityManager = await MMLiquidityManager.deploy();

    // Wait for deployment to finish
    await mmLiquidityManager.waitForDeployment();

    const address = await mmLiquidityManager.getAddress();
    console.log("MMLiquidityManager deployed to:", address);

    // Get the owner
    const owner = await mmLiquidityManager.owner();
    console.log("Contract owner:", owner);

    // Log initial parameters
    console.log("\nInitial Parameters:");
    console.log("Min ETH Liquidity:", ethers.formatEther(await mmLiquidityManager.MIN_LIQUIDITY()), "ETH");
    console.log("Max ETH Liquidity:", ethers.formatEther(await mmLiquidityManager.MAX_LIQUIDITY()), "ETH");
    console.log("Min Token Amount:", ethers.formatEther(await mmLiquidityManager.minTokenAmount()), "tokens");
    console.log("Max Token Amount:", ethers.formatEther(await mmLiquidityManager.maxTokenAmount()), "tokens");
    console.log("Reward Rate:", await mmLiquidityManager.rewardRate(), "basis points");
    console.log("Fee Rate:", await mmLiquidityManager.feeRate(), "basis points");

    console.log("\nDeployment completed successfully!");

    return address;
}

// Execute the deployment
main()
    .then((address) => {
        console.log("Contract deployed at:", address);
        process.exit(0);
    })
    .catch((error) => {
        console.error("Deployment failed:", error);
        process.exit(1);
    }); 