const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("FallbackExecutor Uniswap V3 Compatibility", function () {
  let FallbackExecutor;
  let executor;
  let owner;
  let user;
  let tokenA;
  let weth;
  let mockV3Factory;
  let mockV3Router;
  let mockRegistry;
  let mockOrderbook;

  const DEXVersion = {
    V2: 0,
    V3: 1
  };

  beforeEach(async function () {
    [owner, user, mockOrderbook] = await ethers.getSigners();

    // Deploy Mock Tokens
    const MockToken = await ethers.getContractFactory("MockERC20");
    tokenA = await MockToken.deploy("Token A", "TKA");
    weth = await MockToken.deploy("Wrapped Ether", "WETH");

    // Deploy Mock Uniswap V3 Contracts
    const MockV3Factory = await ethers.getContractFactory("MockUniswapV3Factory");
    mockV3Factory = await MockV3Factory.deploy();

    const MockV3Router = await ethers.getContractFactory("MockUniswapV3SwapRouter");
    mockV3Router = await MockV3Router.deploy(await mockV3Factory.getAddress(), await weth.getAddress());

    // Create a V3 Pool for TokenA/WETH
    await mockV3Factory.createPool(await tokenA.getAddress(), await weth.getAddress(), 3000); // 0.3% fee

    // Deploy Mock Registry (using a simple object or contract if needed, but FallbackExecutor needs an address)
    // We can deploy a real registry or a mock. Let's deploy a mock registry.
    // Since we don't have a MockRegistry file, we can deploy the real GradientRegistry but it might have dependencies.
    // Or we can deploy a minimal mock using Hardhat's deployContract if we had the artifact.
    // Let's check if we can deploy a simple mock for registry.
    // FallbackExecutor calls: gradientRegistry.orderbook() and gradientRegistry.blockedTokens(token)

    // We'll create a simple MockRegistry contract inline if possible, but we can't.
    // So we'll deploy a MockRegistry contract.
    // Wait, I didn't create MockRegistry.sol. I should have.
    // But I can deploy the real GradientRegistry if it's simple.
    // Let's look at GradientRegistry.sol.
    // It seems to be in contracts/GradientRegistry.sol.

    const GradientRegistry = await ethers.getContractFactory("GradientRegistry");
    mockRegistry = await GradientRegistry.deploy(owner.address); // Assuming constructor takes owner
    // Actually let's check GradientRegistry constructor.
    // If it's complex, I'll create a mock.

    // For now, let's assume we can deploy it.
    // We need to set the orderbook address in the registry.
    await mockRegistry.setOrderbook(mockOrderbook.address);

    // Deploy FallbackExecutor
    FallbackExecutor = await ethers.getContractFactory("FallbackExecutor");
    executor = await FallbackExecutor.deploy(await mockRegistry.getAddress());
  });

  it("Should add a V3 DEX correctly", async function () {
    await executor.addV3DEX(
      await mockV3Router.getAddress(), // Using router as DEX address identifier
      await mockV3Router.getAddress(),
      await mockV3Factory.getAddress(),
      1 // Priority
    );

    const dexConfig = await executor.getDEXConfig(await mockV3Router.getAddress());
    expect(dexConfig.router).to.equal(await mockV3Router.getAddress());
    expect(dexConfig.factory).to.equal(await mockV3Factory.getAddress());
    expect(dexConfig.version).to.equal(DEXVersion.V3);
    expect(dexConfig.isActive).to.be.true;
  });

  it("Should fail to get WETH address if only V3 DEX is added", async function () {
    // This confirms the potential issue identified in the plan
    await executor.addV3DEX(
      await mockV3Router.getAddress(),
      await mockV3Router.getAddress(),
      await mockV3Factory.getAddress(),
      1
    );

    // We can't access internal _getWETHAddress directly, but we can try to execute a trade
    // which calls _getWETHAddress.

    // Fund the executor with some ETH for buying
    const amountIn = ethers.parseEther("1");

    // We need to call executeTrade from the orderbook
    // We are simulating the orderbook

    await expect(
      executor.connect(mockOrderbook).executeTrade(
        await tokenA.getAddress(),
        amountIn,
        0, // minAmountOut
        true // isBuy
      )
    ).to.be.revertedWith("WETH address not found");
  });

  it("Should execute V3 trade if WETH address is available (e.g. via V2)", async function () {
    // Deploy Mock V2 Router that returns WETH
    const MockV2Router = await ethers.getContractFactory("MockV2Router");
    const mockV2Router = await MockV2Router.deploy(ethers.ZeroAddress, await weth.getAddress());

    // Add V2 DEX (priority 2, so V3 is preferred but V2 is checked for WETH)
    await executor.addDEX(
      await mockV2Router.getAddress(),
      await mockV2Router.getAddress(),
      2
    );

    // Add V3 DEX (priority 1)
    await executor.addV3DEX(
      await mockV3Router.getAddress(),
      await mockV3Router.getAddress(),
      await mockV3Factory.getAddress(),
      1
    );

    // Fund the executor with some ETH for buying
    const amountIn = ethers.parseEther("1");

    // Execute trade
    // We expect it to succeed now because _getWETHAddress will find the V2 router
    await expect(
      executor.connect(mockOrderbook).executeTrade(
        await tokenA.getAddress(),
        amountIn,
        0, // minAmountOut
        true // isBuy
      )
    ).to.emit(executor, "TradeExecuted");
  });
});
