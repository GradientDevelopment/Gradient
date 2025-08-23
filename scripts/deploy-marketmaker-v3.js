const { ethers } = require("hardhat");

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deploying contracts with the account:", deployer.address);

    // Configuration - Update these addresses for your network
    const ORDERBOOK_ADDRESS = "0x0000000000000000000000000000000000000000"; // Replace with actual orderbook address
    const ROUTER_ADDRESS = "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D"; // UniswapV2 Router on mainnet

    console.log("Configuration:");
    console.log("- Orderbook Address:", ORDERBOOK_ADDRESS);
    console.log("- Router Address:", ROUTER_ADDRESS);
    console.log("");

    // Deploy MarketMakerFactory
    console.log("Deploying MarketMakerFactory...");
    const MarketMakerFactory = await ethers.getContractFactory("MarketMakerFactory");
    const marketMakerFactory = await MarketMakerFactory.deploy(ORDERBOOK_ADDRESS, ROUTER_ADDRESS);
    await marketMakerFactory.waitForDeployment();
    
    const factoryAddress = await marketMakerFactory.getAddress();
    console.log("MarketMakerFactory deployed to:", factoryAddress);
    console.log("");

    // Verify factory state
    console.log("Verifying factory state...");
    const orderbook = await marketMakerFactory.orderbook();
    const router = await marketMakerFactory.router();
    const factory = await marketMakerFactory.factory();
    
    console.log("- Orderbook:", orderbook);
    console.log("- Router:", router);
    console.log("- Factory:", factory);
    console.log("");

    // Example: Create a pool for a token (if you have a token address)
    const TOKEN_ADDRESS = "0x0000000000000000000000000000000000000000"; // Replace with actual token address
    
    if (TOKEN_ADDRESS !== "0x0000000000000000000000000000000000000000") {
        console.log("Creating pool for token:", TOKEN_ADDRESS);
        
        // Check if pool already exists
        const poolExists = await marketMakerFactory.poolExists(TOKEN_ADDRESS);
        if (poolExists) {
            console.log("Pool already exists for this token");
        } else {
            const tx = await marketMakerFactory.createPool(TOKEN_ADDRESS);
            await tx.wait();
            
            const poolAddress = await marketMakerFactory.getPoolAddress(TOKEN_ADDRESS);
            console.log("Pool created at:", poolAddress);
            
            // Get pool info
            const MarketMakerPool = await ethers.getContractFactory("MarketMakerPool");
            const pool = MarketMakerPool.attach(poolAddress);
            
            console.log("Pool state:");
            console.log("- Token:", await pool.token());
            console.log("- Factory:", await pool.factory());
            console.log("- Orderbook:", await pool.orderbook());
            console.log("- Total LP Shares:", await pool.totalLPShares());
            console.log("- Total ETH:", await pool.totalEth());
            console.log("- Total Tokens:", await pool.totalTokens());
        }
    }

    console.log("");
    console.log("Deployment Summary:");
    console.log("===================");
    console.log("MarketMakerFactory:", factoryAddress);
    console.log("");
    console.log("Next steps:");
    console.log("1. Update the orderbook address if needed");
    console.log("2. Create pools for your tokens");
    console.log("3. Configure your orderbook to use the pool addresses");
    console.log("4. Test the contracts with small amounts first");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    }); 