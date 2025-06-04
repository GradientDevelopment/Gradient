const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("Orderbook", function () {
  let Orderbook;
  let orderbook;
  let owner;
  let fulfiller;
  let buyer;
  let seller;
  let tokenA;
  let tokenB;
  let nonWhitelisted;

  beforeEach(async function () {
    // Get signers
    [owner, fulfiller, buyer, seller, nonWhitelisted] = await ethers.getSigners();

    // Deploy mock ERC20 tokens
    const MockToken = await ethers.getContractFactory("MockERC20");
    tokenA = await MockToken.deploy("Token A", "TKA");
    tokenB = await MockToken.deploy("Token B", "TKB");

    // Deploy Orderbook contract
    Orderbook = await ethers.getContractFactory("Orderbook");
    orderbook = await Orderbook.deploy();

    // Get the deployed contract address
    const orderbookAddress = await orderbook.getAddress();

    // Whitelist fulfiller
    await orderbook.setFulfillerStatus(fulfiller.address, true);

    // Mint tokens to all relevant parties
    await tokenA.mint(buyer.address, ethers.parseEther("1000"));
    await tokenA.mint(seller.address, ethers.parseEther("1000"));
    await tokenB.mint(seller.address, ethers.parseEther("1000"));
    await tokenA.mint(fulfiller.address, ethers.parseEther("1000"));
    await tokenB.mint(fulfiller.address, ethers.parseEther("1000"));

    // Approve orderbook contract for all parties with maximum amount
    const maxAmount = ethers.MaxUint256;
    await tokenA.connect(buyer).approve(orderbookAddress, maxAmount);
    await tokenA.connect(seller).approve(orderbookAddress, maxAmount);
    await tokenB.connect(buyer).approve(orderbookAddress, maxAmount);
    await tokenB.connect(seller).approve(orderbookAddress, maxAmount);
    await tokenA.connect(fulfiller).approve(orderbookAddress, maxAmount);
    await tokenB.connect(fulfiller).approve(orderbookAddress, maxAmount);
  });

  describe("Contract Deployment", function () {
    it("Should set the right owner", async function () {
      expect(await orderbook.owner()).to.equal(owner.address);
    });

    it("Should whitelist the owner by default", async function () {
      expect(await orderbook.whitelistedFulfillers(owner.address)).to.be.true;
    });
  });

  describe("Fulfiller Management", function () {
    it("Should allow owner to whitelist fulfillers", async function () {
      await expect(orderbook.setFulfillerStatus(nonWhitelisted.address, true))
        .to.emit(orderbook, "FulfillerWhitelisted")
        .withArgs(nonWhitelisted.address, true);
    });

    it("Should allow owner to remove fulfillers", async function () {
      await orderbook.setFulfillerStatus(fulfiller.address, false);
      expect(await orderbook.whitelistedFulfillers(fulfiller.address)).to.be.false;
    });

    it("Should prevent non-owners from managing fulfillers", async function () {
      await expect(
        orderbook.connect(nonWhitelisted).setFulfillerStatus(nonWhitelisted.address, true)
      ).to.be.revertedWithCustomError(orderbook, "OwnableUnauthorizedAccount");
    });
  });

  describe("Order Creation", function () {
    it("Should create a buy order with fee included", async function () {
      const amount = ethers.parseEther("100");
      const price = ethers.parseEther("1.5");
      const ttl = 3600;
      
      const totalCost = amount * price / ethers.parseEther("1.0");
      const fee = totalCost * BigInt(50) / BigInt(10000); // 0.5% fee
      const totalRequired = totalCost + fee;

      const tx = await orderbook.connect(buyer).createOrder(
        0, // Buy
        await tokenA.getAddress(),
        amount,
        price,
        ttl,
        { value: totalRequired } // Send ETH for buy order + fee
      );

      const orderId = 0;
      const order = await orderbook.getOrder(orderId);

      expect(order.owner).to.equal(buyer.address);
      expect(order.orderType).to.equal(0);
      expect(order.token).to.equal(await tokenA.getAddress());
      expect(order.amount).to.equal(amount);
      expect(order.price).to.equal(price);
      expect(order.status).to.equal(0); // Active
    });

    it("Should fail to create buy order with insufficient ETH (not covering fee)", async function () {
      const amount = ethers.parseEther("100");
      const price = ethers.parseEther("1.5");
      const ttl = 3600;
      
      const totalCost = amount * price / ethers.parseEther("1.0");
      // Send exactly the cost without fee
      await expect(
        orderbook.connect(buyer).createOrder(
          0,
          await tokenA.getAddress(),
          amount,
          price,
          ttl,
          { value: totalCost } // Insufficient ETH - missing fee
        )
      ).to.be.revertedWith("Insufficient ETH sent");
    });

    it("Should return excess ETH including excess fee when sending too much", async function () {
      const amount = ethers.parseEther("100");
      const price = ethers.parseEther("1.5");
      const ttl = 3600;
      
      const totalCost = amount * price / ethers.parseEther("1.0");
      const fee = totalCost * BigInt(50) / BigInt(10000); // 0.5% fee
      const totalRequired = totalCost + fee;
      
      const excess = ethers.parseEther("1.0"); // 1 ETH excess
      const buyerBalanceBefore = await ethers.provider.getBalance(buyer.address);
      
      const tx = await orderbook.connect(buyer).createOrder(
        0,
        await tokenA.getAddress(),
        amount,
        price,
        ttl,
        { value: totalRequired + excess }
      );
      
      const receipt = await tx.wait();
      const gasSpent = receipt.gasUsed * receipt.gasPrice;
      
      const buyerBalanceAfter = await ethers.provider.getBalance(buyer.address);
      const expectedBalance = buyerBalanceBefore - totalRequired - gasSpent;
      
      expect(buyerBalanceAfter).to.be.closeTo(
        expectedBalance,
        ethers.parseEther("0.0001") // Allow for small gas variations
      );
    });

    it("Should create a sell order and lock tokens", async function () {
      const amount = ethers.parseEther("100");
      const price = ethers.parseEther("1.5");
      const ttl = 3600;

      const sellerBalanceBefore = await tokenB.balanceOf(seller.address);

      await expect(
        orderbook.connect(seller).createOrder(
          1, // Sell
          tokenB.getAddress(),
          amount,
          price,
          ttl
        )
      ).to.emit(orderbook, "OrderCreated");

      const sellerBalanceAfter = await tokenB.balanceOf(seller.address);
      expect(sellerBalanceBefore - sellerBalanceAfter).to.equal(amount);
    });

    it("Should fail to create order with zero amount", async function () {
      const price = ethers.parseEther("1.5");
      const ttl = 3600;

      await expect(
        orderbook.connect(seller).createOrder(
          1,
          tokenB.getAddress(),
          0, // Zero amount
          price,
          ttl
        )
      ).to.be.revertedWith("Amount must be greater than 0");
    });

    it("Should fail to create order with zero price", async function () {
      const amount = ethers.parseEther("100");
      const ttl = 3600;

      await expect(
        orderbook.connect(seller).createOrder(
          1,
          tokenB.getAddress(),
          amount,
          0, // Zero price
          ttl
        )
      ).to.be.revertedWith("Invalid price range");
    });
  });

  describe("Order Cancellation", function () {
    let buyOrderId;
    let sellOrderId;

    beforeEach(async function () {
      const amount = ethers.parseEther("100");
      const price = ethers.parseEther("1.5");
      const ttl = 3600;
      
      const totalCost = amount * price / ethers.parseEther("1.0");
      const fee = totalCost * BigInt(50) / BigInt(10000); // 0.5% fee

      // Create a buy order
      await orderbook.connect(buyer).createOrder(
        0,
        await tokenA.getAddress(),
        amount,
        price,
        ttl,
        { value: totalCost + fee }
      );
      buyOrderId = 0;

      // Create a sell order
      await orderbook.connect(seller).createOrder(
        1,
        await tokenB.getAddress(),
        amount,
        price,
        ttl
      );
      sellOrderId = 1;
    });

    it("Should refund ETH including fee when cancelling buy order", async function () {
      const buyerBalanceBefore = await ethers.provider.getBalance(buyer.address);
      
      const tx = await orderbook.connect(buyer).cancelOrder(buyOrderId);
      const receipt = await tx.wait();
      const gasSpent = receipt.gasUsed * receipt.gasPrice;
      
      const order = await orderbook.getOrder(buyOrderId);
      expect(order.status).to.equal(2); // Cancelled
      
      const buyerBalanceAfter = await ethers.provider.getBalance(buyer.address);
      
      // Calculate expected refund (original amount + fee)
      const totalCost = order.amount * order.price / ethers.parseEther("1.0");
      const fee = totalCost * BigInt(50) / BigInt(10000);
      const expectedRefund = totalCost + fee;
      
      expect(buyerBalanceAfter).to.be.closeTo(
        buyerBalanceBefore + expectedRefund - gasSpent,
        ethers.parseEther("0.0001")
      );
    });

    it("Should allow owner to cancel order", async function () {
      const tokenBalanceBefore = await tokenB.balanceOf(seller.address);

      await expect(orderbook.connect(seller).cancelOrder(sellOrderId))
        .to.emit(orderbook, "OrderCancelled")
        .withArgs(sellOrderId);

      const order = await orderbook.getOrder(sellOrderId);
      expect(order.status).to.equal(2); // Cancelled

      const tokenBalanceAfter = await tokenB.balanceOf(seller.address);
      expect(tokenBalanceAfter - tokenBalanceBefore).to.equal(ethers.parseEther("100"));
    });

    it("Should prevent non-owner from cancelling order", async function () {
      await expect(
        orderbook.connect(buyer).cancelOrder(buyOrderId)
      ).to.be.revertedWith("Not order owner");
    });

    it("Should prevent cancelling already cancelled order", async function () {
      await orderbook.connect(seller).cancelOrder(sellOrderId);
      await expect(
        orderbook.connect(seller).cancelOrder(sellOrderId)
      ).to.be.revertedWith("Order not active");
    });
  });

  describe("Order Expiration", function () {
    it("Should correctly identify expired orders", async function () {
      const amount = ethers.parseEther("100");
      const price = ethers.parseEther("1.5");
      const ttl = 3600;

      await orderbook.connect(seller).createOrder(
        1,
        tokenB.getAddress(),
        amount,
        price,
        ttl
      );

      // Fast forward time
      await time.increase(ttl + 1);

      expect(await orderbook.isOrderExpired(0)).to.be.true;
    });

    it("Should allow cleanup of expired orders", async function () {
      const amount = ethers.parseEther("100");
      const price = ethers.parseEther("1.5");
      const ttl = 3600;

      await orderbook.connect(seller).createOrder(
        1,
        tokenB.getAddress(),
        amount,
        price,
        ttl
      );

      // Fast forward time
      await time.increase(ttl + 1);

      await expect(orderbook.cleanupExpiredOrder(0))
        .to.emit(orderbook, "OrderExpired")
        .withArgs(0);

      const order = await orderbook.getOrder(0);
      expect(order.status).to.equal(3); // Expired
    });
  });

  describe("Order Matching and Fulfillment", function () {
    beforeEach(async function () {
      // Create buy and sell orders
      const amount = ethers.parseEther("100");
      const price = ethers.parseEther("1.5");
      const ttl = 3600;

      const totalCost = amount * price / ethers.parseEther("1.0");
      const fee = totalCost * BigInt(50) / BigInt(10000); // 0.5% fee

      // Create buy order
      await orderbook.connect(buyer).createOrder(
        0,
        await tokenA.getAddress(),
        amount,
        price,
        ttl,
        { value: totalCost + fee }
      );
      
      // Create sell order
      await orderbook.connect(seller).createOrder(
        1,
        await tokenA.getAddress(),
        amount,
        price,
        ttl
      );
    });

    it("Should match and fulfill orders with correct fee handling", async function () {
      const fillAmount = ethers.parseEther("50");
      const match = {
        buyOrderId: 0,
        sellOrderId: 1,
        fillAmount: fillAmount
      };

      const sellerBalanceBefore = await ethers.provider.getBalance(seller.address);

      const tx = await orderbook.connect(fulfiller).fulfillMatchedOrders([match]);

      const receipt = await tx.wait();

      const buyOrder = await orderbook.getOrder(0);
      const sellOrder = await orderbook.getOrder(1);

      expect(buyOrder.filledAmount).to.equal(fillAmount);
      expect(sellOrder.filledAmount).to.equal(fillAmount);

      // Calculate expected payments and fees
      const paymentAmount = (fillAmount * sellOrder.price) / ethers.parseEther("1.0");
      const fee = paymentAmount * BigInt(50) / BigInt(10000); // 0.5% fee
      const expectedSellerPayment = paymentAmount - fee;

      // Verify seller received correct amount (minus fee)
      const sellerBalanceAfter = await ethers.provider.getBalance(seller.address);
      expect(sellerBalanceAfter - sellerBalanceBefore).to.equal(expectedSellerPayment);

      // Verify fees were collected
      const expectedTotalFees = fee * BigInt(2); // Fee from both buyer and seller
      expect(await orderbook.totalFeesCollected()).to.equal(expectedTotalFees);
    });

    it("Should refund buyer when matched at better price", async function () {
      // Create a new sell order at a lower price
      const amount = ethers.parseEther("50");
      const lowerPrice = ethers.parseEther("1.0"); // Lower than original 1.5
      const ttl = 3600;

      await orderbook.connect(seller).createOrder(
        1,
        await tokenA.getAddress(),
        amount,
        lowerPrice,
        ttl
      );

      const match = {
        buyOrderId: 0,
        sellOrderId: 2, // The new sell order
        fillAmount: amount
      };

      const buyerBalanceBefore = await ethers.provider.getBalance(buyer.address);

      await orderbook.connect(fulfiller).fulfillMatchedOrders([match]);

      // Calculate savings
      const priceDiff = ethers.parseEther("1.5") - lowerPrice;
      const savedAmount = (amount * priceDiff) / ethers.parseEther("1.0");
      const savedFee = savedAmount * BigInt(50) / BigInt(10000);
      const totalSaved = savedAmount + savedFee;

      const buyerBalanceAfter = await ethers.provider.getBalance(buyer.address);
      expect(buyerBalanceAfter - buyerBalanceBefore).to.equal(totalSaved);
    });

    it("Should handle multiple matches with correct fee calculations", async function () {
      const matches = [
        {
          buyOrderId: 0,
          sellOrderId: 1,
          fillAmount: ethers.parseEther("30")
        },
        {
          buyOrderId: 0,
          sellOrderId: 1,
          fillAmount: ethers.parseEther("20")
        }
      ];

      const sellerBalanceBefore = await ethers.provider.getBalance(seller.address);

      await orderbook.connect(fulfiller).fulfillMatchedOrders(matches);

      const buyOrder = await orderbook.getOrder(0);
      const sellOrder = await orderbook.getOrder(1);

      expect(buyOrder.filledAmount).to.equal(ethers.parseEther("50"));
      expect(sellOrder.filledAmount).to.equal(ethers.parseEther("50"));

      // Calculate expected payments and fees for total filled amount
      const totalFillAmount = ethers.parseEther("50");
      const paymentAmount = (totalFillAmount * sellOrder.price) / ethers.parseEther("1.0");
      const fee = paymentAmount * BigInt(50) / BigInt(10000);
      const expectedSellerPayment = paymentAmount - fee;

      // Verify seller received correct amount (minus fee)
      const sellerBalanceAfter = await ethers.provider.getBalance(seller.address);
      expect(sellerBalanceAfter - sellerBalanceBefore).to.equal(expectedSellerPayment);

      // Verify total fees collected
      const expectedTotalFees = fee * BigInt(2); // Fee from both buyer and seller
      expect(await orderbook.totalFeesCollected()).to.equal(expectedTotalFees);
    });

    it("Should prevent non-whitelisted address from fulfilling orders", async function () {
      const match = {
        buyOrderId: 0,
        sellOrderId: 1,
        fillAmount: ethers.parseEther("50")
      };

      await expect(
        orderbook.connect(nonWhitelisted).fulfillMatchedOrders([match])
      ).to.be.revertedWith("Caller is not whitelisted");
    });
  });

  describe("Order Queries", function () {
    beforeEach(async function () {
      // Create multiple orders
      const amount = ethers.parseEther("100");
      const price = ethers.parseEther("1.5");
      const ttl = 3600;

      // Create orders
      await orderbook.connect(buyer).createOrder(
        0,
        tokenA.getAddress(),
        amount,
        price,
        ttl,
        { value: ethers.parseEther("150") }
      );

      await orderbook.connect(seller).createOrder(
        1,
        tokenA.getAddress(),
        amount,
        price,
        ttl
      );
    });

    it("Should return active orders", async function () {
      const activeOrders = await orderbook.getActiveOrders(
        tokenA.getAddress(),
        0 // Buy orders
      );

      expect(activeOrders.length).to.be.gt(0);
    });

    it("Should return correct remaining amount", async function () {
      const remaining = await orderbook.getRemainingAmount(0);
      expect(remaining).to.equal(ethers.parseEther("100"));
    });

    it("Should return order details", async function () {
      const order = await orderbook.getOrder(0);
      expect(order.owner).to.equal(buyer.address);
      expect(order.status).to.equal(0); // Active
    });
  });

  describe("Fee Management", function () {
    it("Should set the correct initial fee percentage", async function () {
      expect(await orderbook.feePercentage()).to.equal(50); // 0.5%
    });

    it("Should allow owner to update fee percentage", async function () {
      const newFeePercentage = 100; // 1%
      await expect(orderbook.setFeePercentage(newFeePercentage))
        .to.emit(orderbook, "FeePercentageUpdated")
        .withArgs(50, newFeePercentage);

      expect(await orderbook.feePercentage()).to.equal(newFeePercentage);
    });

    it("Should prevent setting fee percentage above maximum", async function () {
      const maxFee = await orderbook.MAX_FEE_PERCENTAGE();
      await expect(
        orderbook.setFeePercentage(maxFee + 1)
      ).to.be.revertedWith("Fee percentage too high");
    });

    it("Should prevent non-owner from setting fee percentage", async function () {
      await expect(
        orderbook.connect(nonWhitelisted).setFeePercentage(100)
      ).to.be.revertedWithCustomError(orderbook, "OwnableUnauthorizedAccount");
    });

    it("Should collect fees from both parties during order fulfillment", async function () {
      // Create buy and sell orders
      const amount = ethers.parseEther("100");
      const price = ethers.parseEther("1.5");
      const ttl = 3600;

      // Create buy order
      await orderbook.connect(buyer).createOrder(
        0, // Buy
        tokenA.getAddress(),
        amount,
        price,
        ttl,
        { value: ethers.parseEther("160") } // Extra ETH to cover fees
      );

      // Create sell order
      await orderbook.connect(seller).createOrder(
        1, // Sell
        tokenA.getAddress(),
        amount,
        price,
        ttl
      );

      // Record balances before fulfillment
      const sellerBalanceBefore = await ethers.provider.getBalance(seller.address);
      
      // Fulfill orders
      const match = {
        buyOrderId: 0,
        sellOrderId: 1,
        fillAmount: ethers.parseEther("100")
      };

      await orderbook.connect(fulfiller).fulfillMatchedOrders([match]);

      // Check collected fees
      const expectedFeePerOrder = ethers.parseEther("150").mul(50).div(10000); // 0.5% of 150 ETH
      const totalExpectedFees = expectedFeePerOrder.mul(2); // Fees from both parties
      expect(await orderbook.totalFeesCollected()).to.equal(totalExpectedFees);

      // Verify seller received amount minus fees
      const sellerBalanceAfter = await ethers.provider.getBalance(seller.address);
      const expectedSellerPayment = ethers.parseEther("150").sub(expectedFeePerOrder);
      expect(sellerBalanceAfter.sub(sellerBalanceBefore)).to.be.closeTo(
        expectedSellerPayment,
        ethers.parseEther("0.0001") // Allow for small gas cost variations
      );
    });

    it("Should allow owner to withdraw collected fees", async function () {
      // First generate some fees
      const amount = ethers.parseEther("100");
      const price = ethers.parseEther("1.5");
      const ttl = 3600;

      // Create and fulfill orders to generate fees
      await orderbook.connect(buyer).createOrder(
        0,
        tokenA.getAddress(),
        amount,
        price,
        ttl,
        { value: ethers.parseEther("160") }
      );

      await orderbook.connect(seller).createOrder(
        1,
        tokenA.getAddress(),
        amount,
        price,
        ttl
      );

      const match = {
        buyOrderId: 0,
        sellOrderId: 1,
        fillAmount: amount
      };

      await orderbook.connect(fulfiller).fulfillMatchedOrders([match]);

      // Record balance before withdrawal
      const recipientBalanceBefore = await ethers.provider.getBalance(owner.address);
      const contractBalance = await ethers.provider.getBalance(orderbook.getAddress());
      const totalFees = await orderbook.totalFeesCollected();
      console.log("contractBalance", contractBalance);
      console.log("totalFees", totalFees);
      console.log("recipientBalanceBefore", recipientBalanceBefore);
      // Withdraw fees
      await expect(orderbook.withdrawFees(owner.address))
        .to.emit(orderbook, "FeesWithdrawn")
        .withArgs(owner.address, totalFees);

      // Verify fees were transferred
      const recipientBalanceAfter = await ethers.provider.getBalance(owner.address);
      expect(recipientBalanceAfter.sub(recipientBalanceBefore)).to.be.closeTo(
        totalFees,
        ethers.parseEther("0.0001") // Allow for small gas cost variations
      );

      // Verify fees were reset
      expect(await orderbook.totalFeesCollected()).to.equal(0);
    });

    it("Should prevent non-owner from withdrawing fees", async function () {
      await expect(
        orderbook.connect(nonWhitelisted).withdrawFees(nonWhitelisted.address)
      ).to.be.revertedWithCustomError(orderbook, "OwnableUnauthorizedAccount");
    });

    it("Should prevent withdrawing fees when none are collected", async function () {
      await expect(
        orderbook.withdrawFees(owner.address)
      ).to.be.revertedWith("No fees to withdraw");
    });

    it("Should prevent withdrawing fees to zero address", async function () {
      await expect(
        orderbook.withdrawFees(ethers.ZeroAddress)
      ).to.be.revertedWith("Invalid recipient");
    });
  });
}); 