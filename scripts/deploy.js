const hre = require("hardhat");

async function main() {
  console.log("Deploying Gradient OTC Orderbook contract...");

  const Orderbook = await hre.ethers.getContractFactory("Orderbook");
  const orderbook = await Orderbook.deploy();

  await orderbook.waitForDeployment();

  const address = await orderbook.getAddress();
  console.log("Orderbook deployed to:", address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  }); 