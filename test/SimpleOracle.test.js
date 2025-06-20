const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Simple MM Oracle", function () {
    let mmLiquidityManager;
    let simpleOracle;
    let mockToken;
    let owner;
    let user1;
    let user2;
    let server;

    beforeEach(async function () {
        [owner, user1, user2, server] = await ethers.getSigners();

        // Deploy mock ERC20 token
        const MockToken = await ethers.getContractFactory("MockERC20");
        mockToken = await MockToken.deploy("Mock Token", "MTK");

        // Deploy MMLiquidityManager
        const MMLiquidityManager = await ethers.getContractFactory("MMLiquidityManager");
        mmLiquidityManager = await MMLiquidityManager.deploy();

        // Deploy Simple Oracle
        const SimpleMMOracle = await ethers.getContractFactory("SimpleMMOracle");
        simpleOracle = await SimpleMMOracle.deploy(mmLiquidityManager.target);

        // Setup token support
        await mmLiquidityManager.setTokenSupport(mockToken.target, true);
        await simpleOracle.setTokenSupport(mockToken.target, true);

        // Mint tokens to users
        await mockToken.mint(user1.address, ethers.parseEther("1000"));
        await mockToken.mint(user2.address, ethers.parseEther("1000"));
    });

    describe("Reward Distribution", function () {
        beforeEach(async function () {
            // Add liquidity first
            const ethAmount = ethers.parseEther("1");
            const tokenAmount = ethers.parseEther("100");

            await mockToken.connect(user1).approve(mmLiquidityManager.target, tokenAmount);
            await mockToken.connect(user2).approve(mmLiquidityManager.target, tokenAmount);

            await mmLiquidityManager.connect(user1).addLiquidity(mockToken.target, tokenAmount, { value: ethAmount });
            await mmLiquidityManager.connect(user2).addLiquidity(mockToken.target, tokenAmount, { value: ethAmount });
        });

        it("Should distribute rewards based on trade amount", async function () {
            const tradeAmount = ethers.parseEther("10"); // 10 ETH trade

            // Calculate expected reward (1% of trade amount)
            const expectedReward = (tradeAmount * 100) / 10000; // 1% = 0.1 ETH

            // Server distributes rewards with ETH
            await expect(simpleOracle.connect(server).distributeRewards(
                mockToken.target,
                tradeAmount,
                { value: ethers.parseEther("1") } // Send 1 ETH for rewards
            ))
                .to.emit(simpleOracle, "RewardsDistributed")
                .withArgs(mockToken.target, tradeAmount, expectedReward);

            // Check that rewards were distributed to users
            const pendingRewards1 = await mmLiquidityManager.calculatePendingRewards(user1.address, mockToken.target);
            const pendingRewards2 = await mmLiquidityManager.calculatePendingRewards(user2.address, mockToken.target);

            expect(pendingRewards1).to.be.gt(0);
            expect(pendingRewards2).to.be.gt(0);

            // Users should have equal rewards (50/50 split)
            expect(pendingRewards1).to.be.closeTo(pendingRewards2, ethers.parseEther("0.001"));
        });

        it("Should handle multiple reward distributions", async function () {
            // First distribution
            await simpleOracle.connect(server).distributeRewards(
                mockToken.target,
                ethers.parseEther("5"),
                { value: ethers.parseEther("1") }
            );

            // Second distribution
            await simpleOracle.connect(server).distributeRewards(
                mockToken.target,
                ethers.parseEther("15"),
                { value: ethers.parseEther("1") }
            );

            // Check accumulated rewards
            const pendingRewards1 = await mmLiquidityManager.calculatePendingRewards(user1.address, mockToken.target);
            const pendingRewards2 = await mmLiquidityManager.calculatePendingRewards(user2.address, mockToken.target);

            expect(pendingRewards1).to.be.gt(0);
            expect(pendingRewards2).to.be.gt(0);

            // Total rewards should be from both distributions
            const totalRewards = pendingRewards1 + pendingRewards2;
            const expectedTotal = (ethers.parseEther("5") * 100 / 10000) + (ethers.parseEther("15") * 100 / 10000);
            expect(totalRewards).to.be.closeTo(expectedTotal, ethers.parseEther("0.001"));
        });

        it("Should respect min/max reward limits", async function () {
            // Small trade - should hit minimum reward
            const smallTrade = ethers.parseEther("0.01"); // 0.01 ETH trade
            const expectedMinReward = ethers.parseEther("0.001"); // 0.001 ETH minimum

            await simpleOracle.connect(server).distributeRewards(
                mockToken.target,
                smallTrade,
                { value: ethers.parseEther("1") }
            );

            // Large trade - should hit maximum reward
            const largeTrade = ethers.parseEther("1000"); // 1000 ETH trade
            const expectedMaxReward = ethers.parseEther("1"); // 1 ETH maximum

            await simpleOracle.connect(server).distributeRewards(
                mockToken.target,
                largeTrade,
                { value: ethers.parseEther("2") }
            );

            // Check that limits were applied
            const calculation1 = await simpleOracle.calculateReward(smallTrade);
            const calculation2 = await simpleOracle.calculateReward(largeTrade);

            expect(calculation1).to.equal(expectedMinReward);
            expect(calculation2).to.equal(expectedMaxReward);
        });

        it("Should refund excess ETH", async function () {
            const tradeAmount = ethers.parseEther("10");
            const expectedReward = (tradeAmount * 100) / 10000; // 0.1 ETH
            const sentAmount = ethers.parseEther("1"); // Send 1 ETH
            const expectedRefund = sentAmount - expectedReward; // 0.9 ETH refund

            const initialBalance = await ethers.provider.getBalance(server.address);

            await simpleOracle.connect(server).distributeRewards(
                mockToken.target,
                tradeAmount,
                { value: sentAmount }
            );

            const finalBalance = await ethers.provider.getBalance(server.address);
            const actualRefund = finalBalance - initialBalance + sentAmount - expectedReward;

            // Should refund excess ETH (accounting for gas)
            expect(actualRefund).to.be.closeTo(expectedRefund, ethers.parseEther("0.01"));
        });
    });

    describe("Configuration", function () {
        it("Should allow owner to update reward rate", async function () {
            await simpleOracle.updateRewardRate(200); // 2%
            expect(await simpleOracle.rewardRate()).to.equal(200);

            // Test calculation with new rate
            const tradeAmount = ethers.parseEther("10");
            const expectedReward = (tradeAmount * 200) / 10000; // 2% = 0.2 ETH
            const calculatedReward = await simpleOracle.calculateReward(tradeAmount);
            expect(calculatedReward).to.equal(expectedReward);
        });

        it("Should allow owner to update reward limits", async function () {
            await simpleOracle.updateRewardLimits(
                ethers.parseEther("0.01"), // new min
                ethers.parseEther("2")     // new max
            );

            expect(await simpleOracle.minRewardAmount()).to.equal(ethers.parseEther("0.01"));
            expect(await simpleOracle.maxRewardAmount()).to.equal(ethers.parseEther("2"));
        });

        it("Should reject invalid configurations", async function () {
            await expect(
                simpleOracle.updateRewardRate(2000) // 20% - too high
            ).to.be.revertedWith("Rate too high");

            await expect(
                simpleOracle.updateRewardLimits(
                    ethers.parseEther("2"), // min higher than max
                    ethers.parseEther("1")
                )
            ).to.be.revertedWith("Invalid limits");
        });
    });

    describe("Integration Test", function () {
        it("Should handle complete flow: liquidity -> rewards -> claims", async function () {
            // 1. Users add liquidity
            const ethAmount = ethers.parseEther("1");
            const tokenAmount = ethers.parseEther("100");

            await mockToken.connect(user1).approve(mmLiquidityManager.target, tokenAmount);
            await mmLiquidityManager.connect(user1).addLiquidity(mockToken.target, tokenAmount, { value: ethAmount });

            // 2. Server distributes rewards (after trade happens elsewhere)
            const tradeAmount = ethers.parseEther("20");
            await simpleOracle.connect(server).distributeRewards(
                mockToken.target,
                tradeAmount,
                { value: ethers.parseEther("1") }
            );

            // 3. User claims rewards
            const pendingRewards = await mmLiquidityManager.calculatePendingRewards(user1.address, mockToken.target);
            expect(pendingRewards).to.be.gt(0);

            const initialBalance = await ethers.provider.getBalance(user1.address);
            await mmLiquidityManager.connect(user1).claimRewards(mockToken.target);
            const finalBalance = await ethers.provider.getBalance(user1.address);

            expect(finalBalance).to.be.gt(initialBalance);
        });
    });
}); 