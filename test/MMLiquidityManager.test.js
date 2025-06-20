const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MMLiquidityManager", function () {
    let mmLiquidityManager;
    let mockToken;
    let owner;
    let user1;
    let user2;
    let user3;

    beforeEach(async function () {
        [owner, user1, user2, user3] = await ethers.getSigners();

        // Deploy mock ERC20 token
        const MockToken = await ethers.getContractFactory("MockERC20");
        mockToken = await MockToken.deploy("Mock Token", "MTK");

        // Deploy MMLiquidityManager
        const MMLiquidityManager = await ethers.getContractFactory("MMLiquidityManager");
        mmLiquidityManager = await MMLiquidityManager.deploy();

        // Add mock token as supported
        await mmLiquidityManager.setTokenSupport(mockToken.target, true);

        // Mint some tokens to users
        await mockToken.mint(user1.address, ethers.parseEther("1000"));
        await mockToken.mint(user2.address, ethers.parseEther("1000"));
        await mockToken.mint(user3.address, ethers.parseEther("1000"));
    });

    describe("Deployment", function () {
        it("Should set the right owner", async function () {
            expect(await mmLiquidityManager.owner()).to.equal(owner.address);
        });

        it("Should have correct initial parameters", async function () {
            expect(await mmLiquidityManager.MIN_LIQUIDITY()).to.equal(ethers.parseEther("0.01"));
            expect(await mmLiquidityManager.MAX_LIQUIDITY()).to.equal(ethers.parseEther("1000"));
            expect(await mmLiquidityManager.minTokenAmount()).to.equal(ethers.parseEther("100"));
            expect(await mmLiquidityManager.maxTokenAmount()).to.equal(ethers.parseEther("1000000"));
            expect(await mmLiquidityManager.rewardRate()).to.equal(100);
            expect(await mmLiquidityManager.feeRate()).to.equal(30);
        });
    });

    describe("Token Support", function () {
        it("Should allow owner to add token support", async function () {
            const newToken = await (await ethers.getContractFactory("MockERC20")).deploy("New Token", "NTK");

            await expect(mmLiquidityManager.setTokenSupport(newToken.target, true))
                .to.emit(mmLiquidityManager, "TokenSupported")
                .withArgs(newToken.target, true);

            expect(await mmLiquidityManager.isTokenSupported(newToken.target)).to.be.true;
        });

        it("Should allow owner to remove token support", async function () {
            await expect(mmLiquidityManager.setTokenSupport(mockToken.target, false))
                .to.emit(mmLiquidityManager, "TokenSupported")
                .withArgs(mockToken.target, false);

            expect(await mmLiquidityManager.isTokenSupported(mockToken.target)).to.be.false;
        });

        it("Should not allow non-owner to modify token support", async function () {
            await expect(
                mmLiquidityManager.connect(user1).setTokenSupport(mockToken.target, false)
            ).to.be.revertedWithCustomError(mmLiquidityManager, "OwnableUnauthorizedAccount");
        });
    });

    describe("Adding Liquidity", function () {
        it("Should allow users to add liquidity", async function () {
            const ethAmount = ethers.parseEther("1");
            const tokenAmount = ethers.parseEther("100");

            await mockToken.connect(user1).approve(mmLiquidityManager.target, tokenAmount);

            await expect(mmLiquidityManager.connect(user1).addLiquidity(mockToken.target, tokenAmount, { value: ethAmount }))
                .to.emit(mmLiquidityManager, "LiquidityAdded")
                .withArgs(user1.address, mockToken.target, ethAmount, tokenAmount, 10000); // 100% for first provider

            const position = await mmLiquidityManager.getPosition(user1.address, mockToken.target);
            expect(position.ethAmount).to.equal(ethAmount);
            expect(position.tokenAmount).to.equal(tokenAmount);
            expect(position.sharePercentage).to.equal(10000); // 100%
            expect(position.isActive).to.be.true;

            const pool = await mmLiquidityManager.getPool(mockToken.target);
            expect(pool.totalEthLiquidity).to.equal(ethAmount);
            expect(pool.totalTokenLiquidity).to.equal(tokenAmount);
            expect(pool.totalShares).to.equal(10000);
            expect(pool.activePositions).to.equal(1);
        });

        it("Should reject adding liquidity for unsupported tokens", async function () {
            const unsupportedToken = await (await ethers.getContractFactory("MockERC20")).deploy("Unsupported", "UNS");
            const ethAmount = ethers.parseEther("1");
            const tokenAmount = ethers.parseEther("100");

            await unsupportedToken.mint(user1.address, tokenAmount);
            await unsupportedToken.connect(user1).approve(mmLiquidityManager.target, tokenAmount);

            await expect(
                mmLiquidityManager.connect(user1).addLiquidity(unsupportedToken.target, tokenAmount, { value: ethAmount })
            ).to.be.revertedWith("Token not supported");
        });

        it("Should reject adding liquidity below minimum amounts", async function () {
            const lowEthAmount = ethers.parseEther("0.005"); // Below 0.01 ETH minimum
            const lowTokenAmount = ethers.parseEther("50"); // Below 100 token minimum
            const tokenAmount = ethers.parseEther("100");

            await mockToken.connect(user1).approve(mmLiquidityManager.target, tokenAmount);

            await expect(
                mmLiquidityManager.connect(user1).addLiquidity(mockToken.target, tokenAmount, { value: lowEthAmount })
            ).to.be.revertedWith("ETH amount below minimum");

            const ethAmount = ethers.parseEther("1");
            await expect(
                mmLiquidityManager.connect(user1).addLiquidity(mockToken.target, lowTokenAmount, { value: ethAmount })
            ).to.be.revertedWith("Token amount below minimum");
        });

        it("Should reject adding liquidity above maximum amounts", async function () {
            const highEthAmount = ethers.parseEther("1500"); // Above 1000 ETH maximum
            const highTokenAmount = ethers.parseEther("2000000"); // Above 1M token maximum
            const tokenAmount = ethers.parseEther("100");

            await mockToken.connect(user1).approve(mmLiquidityManager.target, highTokenAmount);

            await expect(
                mmLiquidityManager.connect(user1).addLiquidity(mockToken.target, tokenAmount, { value: highEthAmount })
            ).to.be.revertedWith("ETH amount above maximum");

            const ethAmount = ethers.parseEther("1");
            await expect(
                mmLiquidityManager.connect(user1).addLiquidity(mockToken.target, highTokenAmount, { value: ethAmount })
            ).to.be.revertedWith("Token amount above maximum");
        });
    });

    describe("Removing Liquidity", function () {
        beforeEach(async function () {
            const ethAmount = ethers.parseEther("1");
            const tokenAmount = ethers.parseEther("100");

            await mockToken.connect(user1).approve(mmLiquidityManager.target, tokenAmount);
            await mmLiquidityManager.connect(user1).addLiquidity(mockToken.target, tokenAmount, { value: ethAmount });
        });

        it("Should allow users to remove liquidity", async function () {
            const removeEthAmount = ethers.parseEther("0.5");
            const removeTokenAmount = ethers.parseEther("50");

            const initialBalance = await ethers.provider.getBalance(user1.address);

            await expect(mmLiquidityManager.connect(user1).removeLiquidity(mockToken.target, removeEthAmount, removeTokenAmount))
                .to.emit(mmLiquidityManager, "LiquidityRemoved")
                .withArgs(user1.address, mockToken.target, removeEthAmount, removeTokenAmount, 5000); // 50% of shares

            const position = await mmLiquidityManager.getPosition(user1.address, mockToken.target);
            expect(position.ethAmount).to.equal(ethers.parseEther("0.5"));
            expect(position.tokenAmount).to.equal(ethers.parseEther("50"));
            expect(position.sharePercentage).to.equal(5000); // 50%

            const pool = await mmLiquidityManager.getPool(mockToken.target);
            expect(pool.totalEthLiquidity).to.equal(ethers.parseEther("0.5"));
            expect(pool.totalTokenLiquidity).to.equal(ethers.parseEther("50"));
            expect(pool.totalShares).to.equal(5000);
        });

        it("Should remove position when all liquidity is withdrawn", async function () {
            const ethAmount = ethers.parseEther("1");
            const tokenAmount = ethers.parseEther("100");

            await mmLiquidityManager.connect(user1).removeLiquidity(mockToken.target, ethAmount, tokenAmount);

            const position = await mmLiquidityManager.getPosition(user1.address, mockToken.target);
            expect(position.isActive).to.be.false;

            const pool = await mmLiquidityManager.getPool(mockToken.target);
            expect(pool.activePositions).to.equal(0);
        });

        it("Should reject removing more liquidity than available", async function () {
            const tooMuchEth = ethers.parseEther("2");
            const tooMuchToken = ethers.parseEther("200");

            await expect(
                mmLiquidityManager.connect(user1).removeLiquidity(mockToken.target, tooMuchEth, 0)
            ).to.be.revertedWith("Insufficient ETH liquidity");

            await expect(
                mmLiquidityManager.connect(user1).removeLiquidity(mockToken.target, 0, tooMuchToken)
            ).to.be.revertedWith("Insufficient token liquidity");
        });
    });

    describe("Rewards", function () {
        beforeEach(async function () {
            const ethAmount = ethers.parseEther("1");
            const tokenAmount = ethers.parseEther("100");

            await mockToken.connect(user1).approve(mmLiquidityManager.target, tokenAmount);
            await mockToken.connect(user2).approve(mmLiquidityManager.target, tokenAmount);

            await mmLiquidityManager.connect(user1).addLiquidity(mockToken.target, tokenAmount, { value: ethAmount });
            await mmLiquidityManager.connect(user2).addLiquidity(mockToken.target, tokenAmount, { value: ethAmount });
        });

        it("Should allow owner to deposit rewards", async function () {
            const rewardAmount = ethers.parseEther("10");

            await expect(mmLiquidityManager.connect(owner).depositRewards(mockToken.target, { value: rewardAmount }))
                .to.emit(mmLiquidityManager, "RewardsDeposited")
                .withArgs(mockToken.target, rewardAmount);

            const pool = await mmLiquidityManager.getPool(mockToken.target);
            expect(pool.totalRewards).to.equal(rewardAmount);
        });

        it("Should not allow non-owner to deposit rewards", async function () {
            const rewardAmount = ethers.parseEther("10");

            await expect(
                mmLiquidityManager.connect(user1).depositRewards(mockToken.target, { value: rewardAmount })
            ).to.be.revertedWithCustomError(mmLiquidityManager, "OwnableUnauthorizedAccount");
        });

        it("Should calculate share percentages correctly", async function () {
            const share1 = await mmLiquidityManager.calculateSharePercentage(user1.address, mockToken.target);
            const share2 = await mmLiquidityManager.calculateSharePercentage(user2.address, mockToken.target);

            expect(share1).to.equal(5000); // 50%
            expect(share2).to.equal(5000); // 50%
        });
    });

    describe("Multiple Users", function () {
        it("Should handle multiple users adding liquidity", async function () {
            const ethAmount1 = ethers.parseEther("1");
            const tokenAmount1 = ethers.parseEther("100");
            const ethAmount2 = ethers.parseEther("2");
            const tokenAmount2 = ethers.parseEther("200");

            await mockToken.connect(user1).approve(mmLiquidityManager.target, tokenAmount1);
            await mockToken.connect(user2).approve(mmLiquidityManager.target, tokenAmount2);

            await mmLiquidityManager.connect(user1).addLiquidity(mockToken.target, tokenAmount1, { value: ethAmount1 });
            await mmLiquidityManager.connect(user2).addLiquidity(mockToken.target, tokenAmount2, { value: ethAmount2 });

            const pool = await mmLiquidityManager.getPool(mockToken.target);
            expect(pool.totalEthLiquidity).to.equal(ethers.parseEther("3"));
            expect(pool.totalTokenLiquidity).to.equal(ethers.parseEther("300"));
            expect(pool.activePositions).to.equal(2);

            const share1 = await mmLiquidityManager.calculateSharePercentage(user1.address, mockToken.target);
            const share2 = await mmLiquidityManager.calculateSharePercentage(user2.address, mockToken.target);

            // User1: 1 ETH + 100 tokens = 200 value units (assuming 1:1 price)
            // User2: 2 ETH + 200 tokens = 400 value units
            // Total: 600 value units
            // User1 share: 200/600 = 33.33%
            // User2 share: 400/600 = 66.67%
            expect(share1).to.be.closeTo(3333, 100); // ~33.33%
            expect(share2).to.be.closeTo(6667, 100); // ~66.67%
        });
    });

    describe("Parameters", function () {
        it("Should allow owner to update parameters", async function () {
            const newMinToken = ethers.parseEther("200");
            const newMaxToken = ethers.parseEther("2000000");
            const newRewardRate = 200;
            const newFeeRate = 50;

            await expect(mmLiquidityManager.updateParameters(newMinToken, newMaxToken, newRewardRate, newFeeRate))
                .to.emit(mmLiquidityManager, "ParametersUpdated")
                .withArgs(newMinToken, newMaxToken, newRewardRate, newFeeRate);

            expect(await mmLiquidityManager.minTokenAmount()).to.equal(newMinToken);
            expect(await mmLiquidityManager.maxTokenAmount()).to.equal(newMaxToken);
            expect(await mmLiquidityManager.rewardRate()).to.equal(newRewardRate);
            expect(await mmLiquidityManager.feeRate()).to.equal(newFeeRate);
        });

        it("Should not allow non-owner to update parameters", async function () {
            await expect(
                mmLiquidityManager.connect(user1).updateParameters(0, 0, 0, 0)
            ).to.be.revertedWithCustomError(mmLiquidityManager, "OwnableUnauthorizedAccount");
        });
    });

    describe("Emergency Functions", function () {
        it("Should allow owner to emergency withdraw", async function () {
            const ethAmount = ethers.parseEther("1");
            const tokenAmount = ethers.parseEther("100");

            await mockToken.connect(user1).approve(mmLiquidityManager.target, tokenAmount);
            await mmLiquidityManager.connect(user1).addLiquidity(mockToken.target, tokenAmount, { value: ethAmount });

            await mmLiquidityManager.emergencyWithdraw(mockToken.target);

            const ethBalance = await ethers.provider.getBalance(mmLiquidityManager.target);
            const tokenBalance = await mockToken.balanceOf(mmLiquidityManager.target);

            expect(ethBalance).to.equal(0);
            expect(tokenBalance).to.equal(0);
        });
    });
});

// Mock ERC20 Token for testing
const MockERC20 = `
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MockERC20 is ERC20, Ownable {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) Ownable(msg.sender) {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
`; 