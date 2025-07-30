const { ethers } = require("hardhat");

async function main() {
    console.log("�� Deploying GradientVesting...");

    // Get the deployer account
    const [deployer] = await ethers.getSigners();
    console.log("Deploying contracts with account:", deployer.address);
    console.log("Account balance:", (await ethers.provider.getBalance(deployer.address)).toString());

    // Deploy the vesting contract
    const GradientVesting = await ethers.getContractFactory("GradientVesting");
    
    // You'll need to provide the GRAY token address here
    const grayTokenAddress = "0x..."; // Replace with actual GRAY token address
    
    console.log("GRAY Token Address:", grayTokenAddress);
    
    const vesting = await GradientVesting.deploy(grayTokenAddress);
    await vesting.waitForDeployment();

    console.log("✅ GradientVesting deployed to:", await vesting.getAddress());
    console.log("Owner:", await vesting.owner());
    console.log("GRAY Token:", await vesting.grayToken());

    // Verify the deployment
    console.log("\n📋 Deployment Summary:");
    console.log("Contract: GradientVesting");
    console.log("Address:", await vesting.getAddress());
    console.log("Owner:", await vesting.owner());
    console.log("GRAY Token:", await vesting.grayToken());
    console.log("Total ETH Deposited:", (await vesting.totalEthDeposited()).toString());
    console.log("Total Tokens Deposited:", (await vesting.totalTokensDeposited()).toString());

    console.log("\n🔗 Next Steps:");
    console.log("1. Verify the contract on Etherscan");
    console.log("2. Set up monitoring for events");
    console.log("3. Test deposit and withdrawal functions");
    console.log("4. Configure frontend integration");

    // Optional: Verify on Etherscan (if on a supported network)
    if (network.name !== "hardhat" && network.name !== "localhost") {
        console.log("\n🔍 Verifying contract on Etherscan...");
        try {
            await hre.run("verify:verify", {
                address: await vesting.getAddress(),
                constructorArguments: [grayTokenAddress],
            });
            console.log("✅ Contract verified on Etherscan!");
        } catch (error) {
            console.log("❌ Verification failed:", error.message);
        }
    }
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("❌ Deployment failed:", error);
        process.exit(1);
    }); 