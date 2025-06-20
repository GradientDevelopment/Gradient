const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MM Oracle System", function () {
    let mmLiquidityManager;
    let rewardOracle;
    let rewardKeeper;
    let mockToken;
    let owner;
    let user1;
    let user2;
    let updater;

    beforeEach(async function () {
        [owner, user1, user2, updater] = await ethers.getSigners();

        // Deploy mock ERC20 token
        const MockToken = await ethers.getContractFactory("MockERC20");
        mockToken = await MockToken.deploy("Mock Token", "MTK");

        // Deploy MMLiquidityManager
        const MMLiquidityManager = await ethers.getContractFactory("MMLiquidityManager");
        mmLiquidityManager = await MMLiquidityManager.deploy();

        // Deploy Reward Oracle
        const MMRewardOracle = await ethers.getContractFactory("MMRewardOracle");
        rewardOracle = await MMRewardOracle.deploy(mmLiquidityManager.target);

        // Deploy Reward Keeper
        const MMRewardKeeper = await ethers.getContractFactory("MMRewardKeeper");
        rewardKeeper = await MMRewardKeeper.deploy(rewardOracle.target);

        // Setup token support
        await mmLiquidityManager.setTokenSupport(mockToken.target, true);
        await rewardOracle.setTokenSupport(mockToken.target, true);

        // Mint tokens to users
        await mockToken.mint(user1.address, ethers.parseEther("1000"));
        await mockToken.mint(user2.address, ethers.parseEther("1000"));
    });

    describe("Oracle Configuration", function () {
        it("Should have correct initial configuration", async function () {
            const config = await rewardOracle.config();

            expect(config.baseRewardRate).to.equal(100); // 1% per day
            expect(config.volumeMultiplier).to.equal(200); // 2%
            expect(config.timeMultiplier).to.equal(150); // 1.5%
            expect(config.performanceMultiplier).to.equal(300); // 3%
            expect(config.minRewardInterval).to.equal(3600); // 1 hour
            expect(config.maxRewardPerUpdate).to.equal(ethers.parseEther("1")); // 1 ETH
            expect(config.isActive).to.be.true;
        });

        it("Should allow owner to update configuration", async function () {
            await rewardOracle.updateOracleConfig(
                200, // baseRewardRate
                300, // volumeMultiplier
                250, // timeMultiplier
                400, // performanceMultiplier
                1800, // minRewardInterval
                ethers.parseEther("2") // maxRewardPerUpdate
            );

            const config = await rewardOracle.config();
            expect(config.baseRewardRate).to.equal(200);
            expect(config.volumeMultiplier).to.equal(300);
            expect(config.timeMultiplier).to.equal(250);
            expect(config.performanceMultiplier).to.equal(400);
            expect(config.minRewardInterval).to.equal(1800);
            expect(config.maxRewardPerUpdate).to.equal(ethers.parseEther("2"));
        });

        it("Should reject invalid configuration values", async function () {
            await expect(
                rewardOracle.updateOracleConfig(2000, 200, 150, 300, 3600, ethers.parseEther("1"))
            ).to.be.revertedWith("Base rate too high");

            await expect(
                rewardOracle.updateOracleConfig(100, 200, 150, 300, 100, ethers.parseEther("1"))
            ).to.be.revertedWith("Interval too short");
        });
    });

    describe("Pool Metrics Updates", function () {
        it("Should allow updating pool metrics", async function () {
            const volume = ethers.parseEther("1000");
            const performanceScore = 7500; // 75%

            await rewardOracle.updatePoolMetrics(mockToken.target, volume, performanceScore);

            const metrics = await rewardOracle.getPoolMetrics(mockToken.target);
            expect(metrics.totalVolume).to.equal(volume);
            expect(metrics.performanceScore).to.equal(performanceScore);
            expect(metrics.lastUpdateTime).to.be.gt(0);
        });

        it("Should accumulate rewards when metrics are updated", async function () {
            // Add some liquidity first
            const ethAmount = ethers.parseEther("1");
            const tokenAmount = ethers.parseEther("100");
            await mockToken.connect(user1).approve(mmLiquidityManager.target, tokenAmount);
            await mmLiquidityManager.connect(user1).addLiquidity(mockToken.target, tokenAmount, { value: ethAmount });

            // Update metrics multiple times
            await rewardOracle.updatePoolMetrics(mockToken.target, ethers.parseEther("100"), 5000);
            await rewardOracle.updatePoolMetrics(mockToken.target, ethers.parseEther("200"), 6000);
            await rewardOracle.updatePoolMetrics(mockToken.target, ethers.parseEther("300"), 7000);

            const metrics = await rewardOracle.getPoolMetrics(mockToken.target);
            expect(metrics.totalVolume).to.equal(ethers.parseEther("600"));
            expect(metrics.performanceScore).to.equal(7000);
        });

        it("Should reject updates for unsupported tokens", async function () {
            const unsupportedToken = await (await ethers.getContractFactory("MockERC20")).deploy("Unsupported", "UNS");

            await expect(
                rewardOracle.updatePoolMetrics(unsupportedToken.target, 1000, 5000)
            ).to.be.revertedWith("Token not supported");
        });
    });

    describe("Reward Distribution", function () {
        beforeEach(async function () {
            // Setup liquidity
            const ethAmount = ethers.parseEther("1");
            const tokenAmount = ethers.parseEther("100");

            await mockToken.connect(user1).approve(mmLiquidityManager.target, tokenAmount);
            await mockToken.connect(user2).approve(mmLiquidityManager.target, tokenAmount);

            await mmLiquidityManager.connect(user1).addLiquidity(mockToken.target, tokenAmount, { value: ethAmount });
            await mmLiquidityManager.connect(user2).addLiquidity(mockToken.target, tokenAmount, { value: ethAmount });
        });

        it("Should calculate rewards correctly", async function () {
            // Update metrics to accumulate rewards
            await rewardOracle.updatePoolMetrics(mockToken.target, ethers.parseEther("1000"), 8000);

            // Get reward calculation
            const calculation = await rewardOracle.getCurrentRewardCalculation(mockToken.target);

            console.log("Base Reward:", ethers.formatEther(calculation.baseReward), "ETH");
            console.log("Volume Multiplier:", calculation.volumeMultiplier.toString());
            console.log("Time Multiplier:", calculation.timeMultiplier.toString());
            console.log("Performance Multiplier:", calculation.performanceMultiplier.toString());
            console.log("Total Reward:", ethers.formatEther(calculation.totalReward), "ETH");

            expect(calculation.baseReward).to.be.gt(0);
            expect(calculation.totalReward).to.be.gt(0);
        });

        it("Should distribute rewards when triggered", async function () {
            // Fund the oracle with ETH
            await owner.sendTransaction({ to: rewardOracle.target, value: ethers.parseEther("10") });

            // Update metrics to accumulate rewards
            await rewardOracle.updatePoolMetrics(mockToken.target, ethers.parseEther("1000"), 8000);

            // Trigger reward distribution
            await rewardOracle.distributeRewards(mockToken.target);

            // Check that rewards were distributed
            const metrics = await rewardOracle.getPoolMetrics(mockToken.target);
            expect(metrics.accumulatedRewards).to.equal(0);
            expect(metrics.lastRewardDistribution).to.be.gt(0);
        });
    });

    describe("Keeper System", function () {
        beforeEach(async function () {
            // Setup liquidity
            const ethAmount = ethers.parseEther("1");
            const tokenAmount = ethers.parseEther("100");

            await mockToken.connect(user1).approve(mmLiquidityManager.target, tokenAmount);
            await mmLiquidityManager.connect(user1).addLiquidity(mockToken.target, tokenAmount, { value: ethAmount });
        });

        it("Should have correct initial keeper configuration", async function () {
            const config = await rewardKeeper.config();

            expect(config.minInterval).to.equal(3600); // 1 hour
            expect(config.gasPriceLimit).to.equal(ethers.parseUnits("50", "gwei"));
            expect(config.minRewardThreshold).to.equal(ethers.parseEther("0.01"));
            expect(config.isActive).to.be.true;
        });

        it("Should check upkeep conditions", async function () {
            const [upkeepNeeded, performData] = await rewardKeeper.checkUpkeep(mockToken.target);

            // Should be true initially since no execution has happened
            expect(upkeepNeeded).to.be.true;
            expect(performData).to.not.equal("0x");
        });

        it("Should execute upkeep when conditions are met", async function () {
            // Fund oracle
            await owner.sendTransaction({ to: rewardOracle.target, value: ethers.parseEther("5") });

            // Update metrics
            await rewardOracle.updatePoolMetrics(mockToken.target, ethers.parseEther("500"), 6000);

            // Execute upkeep
            const [upkeepNeeded, performData] = await rewardKeeper.checkUpkeep(mockToken.target);
            if (upkeepNeeded) {
                await rewardKeeper.performUpkeep(performData);
            }

            // Check execution stats
            const stats = await rewardKeeper.getKeeperStats(mockToken.target);
            expect(stats.totalExecs).to.be.gt(0);
            expect(stats.lastExec).to.be.gt(0);
        });

        it("Should reject execution when conditions not met", async function () {
            // Execute once
            const [upkeepNeeded1, performData1] = await rewardKeeper.checkUpkeep(mockToken.target);
            if (upkeepNeeded1) {
                await rewardKeeper.performUpkeep(performData1);
            }

            // Try to execute again immediately
            const [upkeepNeeded2, performData2] = await rewardKeeper.checkUpkeep(mockToken.target);
            expect(upkeepNeeded2).to.be.false;
        });

        it("Should allow updating metrics through keeper", async function () {
            const volume = ethers.parseEther("750");
            const performanceScore = 6500;

            await rewardKeeper.updateMetrics(mockToken.target, volume, performanceScore);

            const metrics = await rewardOracle.getPoolMetrics(mockToken.target);
            expect(metrics.totalVolume).to.equal(volume);
            expect(metrics.performanceScore).to.equal(performanceScore);
        });
    });

    describe("Integration Test", function () {
        it("Should handle complete reward flow", async function () {
            // 1. Setup liquidity
            const ethAmount = ethers.parseEther("1");
            const tokenAmount = ethers.parseEther("100");

            await mockToken.connect(user1).approve(mmLiquidityManager.target, tokenAmount);
            await mmLiquidityManager.connect(user1).addLiquidity(mockToken.target, tokenAmount, { value: ethAmount });

            // 2. Fund oracle
            await owner.sendTransaction({ to: rewardOracle.target, value: ethers.parseEther("10") });

            // 3. Update metrics multiple times
            await rewardOracle.updatePoolMetrics(mockToken.target, ethers.parseEther("100"), 5000);
            await rewardOracle.updatePoolMetrics(mockToken.target, ethers.parseEther("200"), 6000);
            await rewardOracle.updatePoolMetrics(mockToken.target, ethers.parseEther("300"), 7000);

            // 4. Check accumulated rewards
            const metrics = await rewardOracle.getPoolMetrics(mockToken.target);
            expect(metrics.accumulatedRewards).to.be.gt(0);

            // 5. Trigger distribution
            await rewardOracle.distributeRewards(mockToken.target);

            // 6. Check that rewards were distributed to users
            const pendingRewards = await mmLiquidityManager.calculatePendingRewards(user1.address, mockToken.target);
            expect(pendingRewards).to.be.gt(0);

            // 7. User claims rewards
            const initialBalance = await ethers.provider.getBalance(user1.address);
            await mmLiquidityManager.connect(user1).claimRewards(mockToken.target);
            const finalBalance = await ethers.provider.getBalance(user1.address);

            expect(finalBalance).to.be.gt(initialBalance);
        });
    });
}); 