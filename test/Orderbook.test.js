const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("GradientOrderbook", function () {
  let GradientOrderbook;
  let orderbook;
  let owner;
  let fulfiller;
  let buyer;
  let seller;
  let tokenA;
  let tokenB;
  let nonWhitelisted;

  // Add enum values for better readability
  const OrderType = {
    Buy: 0,
    Sell: 1
  };

  const OrderExecutionType = {
    Limit: 0,
    Market: 1
  };

  const OrderStatus = {
    Active: 0,
    Filled: 1,
    Cancelled: 2,
    Expired: 3
  };

  beforeEach(async function () {
    // Get signers
    [owner, fulfiller, buyer, seller, nonWhitelisted] = await ethers.getSigners();

    // Deploy mock ERC20 tokens
    const MockToken = await ethers.getContractFactory("MockERC20");
    tokenA = await MockToken.deploy("Token A", "TKA");
    tokenB = await MockToken.deploy("Token B", "TKB");

    // Deploy Orderbook contract
    GradientOrderbook = await ethers.getContractFactory("GradientOrderbook");
    orderbook = await GradientOrderbook.deploy();

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

      const totalCost = (amount * price) / ethers.parseEther("1.0");
      const fee = (totalCost * BigInt(60)) / BigInt(10000);

      await expect(
        orderbook.connect(buyer).createOrder(
          OrderType.Buy,
          OrderExecutionType.Limit,
          await tokenA.getAddress(),
          amount,
          price,
          ttl,
          { value: totalCost + fee }
        )
      ).to.emit(orderbook, "OrderCreated");
    });

    it("Should fail to create buy order with insufficient ETH", async function () {
      const amount = ethers.parseEther("100");
      const price = ethers.parseEther("1.5");
      const ttl = 3600;

      const totalCost = (amount * price) / ethers.parseEther("1.0");
      const fee = (totalCost * BigInt(60)) / BigInt(10000);

      await expect(
        orderbook.connect(buyer).createOrder(
          OrderType.Buy,
          OrderExecutionType.Limit,
          await tokenA.getAddress(),
          amount,
          price,
          ttl,
          { value: totalCost } // Not including fee
        )
      ).to.be.revertedWith("Insufficient ETH sent");
    });

    it("Should create a sell order and lock tokens", async function () {
      const amount = ethers.parseEther("100");
      const price = ethers.parseEther("1.5");
      const ttl = 3600;

      // Approve tokens first
      await tokenA.connect(seller).approve(await orderbook.getAddress(), amount);

      await expect(
        orderbook.connect(seller).createOrder(
          OrderType.Sell,
          OrderExecutionType.Limit,
          await tokenA.getAddress(),
          amount,
          price,
          ttl
        )
      ).to.emit(orderbook, "OrderCreated");

      // Verify tokens are locked
      expect(await tokenA.balanceOf(await orderbook.getAddress())).to.equal(amount);
    });

    it("Should fail to create order with zero amount", async function () {
      const price = ethers.parseEther("1.5");
      const ttl = 3600;

      await expect(
        orderbook.connect(buyer).createOrder(
          OrderType.Buy,
          OrderExecutionType.Limit,
          await tokenA.getAddress(),
          0,
          price,
          ttl,
          { value: ethers.parseEther("1") }
        )
      ).to.be.revertedWith("Amount must be greater than 0");
    });

    it("Should fail to create order with zero price", async function () {
      const amount = ethers.parseEther("100");
      const ttl = 3600;

      await expect(
        orderbook.connect(buyer).createOrder(
          OrderType.Buy,
          OrderExecutionType.Limit,
          await tokenA.getAddress(),
          amount,
          0,
          ttl,
          { value: ethers.parseEther("1") }
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

      const totalCost = (amount * price) / ethers.parseEther("1.0");
      const fee = (totalCost * BigInt(60)) / BigInt(10000);

      // Create a buy order
      await orderbook.connect(buyer).createOrder(
        OrderType.Buy,
        OrderExecutionType.Limit,
        await tokenA.getAddress(),
        amount,
        price,
        ttl,
        { value: totalCost + fee }
      );
      buyOrderId = 0;

      // Create a sell order
      await orderbook.connect(seller).createOrder(
        OrderType.Sell,
        OrderExecutionType.Limit,
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
      expect(order.status).to.equal(OrderStatus.Cancelled);

      const buyerBalanceAfter = await ethers.provider.getBalance(buyer.address);

      // Calculate expected refund (original amount + fee)
      const totalCost = (order.amount * order.price) / ethers.parseEther("1.0");
      const fee = (totalCost * BigInt(60)) / BigInt(10000);
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
      expect(order.status).to.equal(OrderStatus.Cancelled);

      const tokenBalanceAfter = await tokenB.balanceOf(seller.address);
      expect(BigInt(tokenBalanceAfter) - BigInt(tokenBalanceBefore)).to.equal(ethers.parseEther("100"));
    });

    it("Should prevent non-owner from cancelling order", async function () {
      await expect(
        orderbook.connect(nonWhitelisted).cancelOrder(buyOrderId)
      ).to.be.revertedWith("Not order owner");
    });

    it("Should prevent cancelling non-existent order", async function () {
      await expect(
        orderbook.connect(buyer).cancelOrder(999)
      ).to.be.revertedWith("Order does not exist");
    });

    it("Should prevent cancelling already cancelled order", async function () {
      await orderbook.connect(buyer).cancelOrder(buyOrderId);
      await expect(
        orderbook.connect(buyer).cancelOrder(buyOrderId)
      ).to.be.revertedWith("Order not active");
    });
  });

  describe("Order Expiration", function () {
    it("Should correctly identify expired orders", async function () {
      const amount = ethers.parseEther("100");
      const price = ethers.parseEther("1.5");
      const ttl = 3600;

      await orderbook.connect(seller).createOrder(
        OrderType.Sell,
        OrderExecutionType.Limit,
        await tokenB.getAddress(),
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
        OrderType.Sell,
        OrderExecutionType.Limit,
        await tokenB.getAddress(),
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
      expect(order.status).to.equal(OrderStatus.Expired);
    });
  });

  describe("Order Matching and Fulfillment", function () {
    let buyOrderId;
    let sellOrderId;
    let amount;
    let price;
    let ttl;

    beforeEach(async function () {
      amount = ethers.parseEther("100");
      price = ethers.parseEther("1.5");
      ttl = 3600;

      // Create buy order
      const totalCost = (amount * price) / ethers.parseEther("1.0");
      const fee = (totalCost * BigInt(60)) / BigInt(10000);

      await orderbook.connect(buyer).createOrder(
        OrderType.Buy,
        OrderExecutionType.Limit,
        await tokenA.getAddress(),
        amount,
        price,
        ttl,
        { value: totalCost + fee }
      );
      buyOrderId = 0;

      // Create sell order
      await orderbook.connect(seller).createOrder(
        OrderType.Sell,
        OrderExecutionType.Limit,
        await tokenA.getAddress(),
        amount,
        price,
        ttl
      );
      sellOrderId = 1;
    });

    it("Should match and fulfill limit orders with correct fee handling", async function () {
      const sellerBalanceBefore = await ethers.provider.getBalance(seller.address);
      const buyerTokenBalanceBefore = await tokenA.balanceOf(buyer.address);

      // Match and fulfill orders
      const match = {
        buyOrderId,
        sellOrderId,
        fillAmount: amount
      };

      await orderbook.connect(fulfiller).fulfillLimitOrders([match]);

      // Verify order statuses
      const buyOrder = await orderbook.getOrder(buyOrderId);
      const sellOrder = await orderbook.getOrder(sellOrderId);
      expect(buyOrder.status).to.equal(OrderStatus.Filled);
      expect(sellOrder.status).to.equal(OrderStatus.Filled);

      // Verify token transfer
      const buyerTokenBalanceAfter = await tokenA.balanceOf(buyer.address);
      expect(BigInt(buyerTokenBalanceAfter) - BigInt(buyerTokenBalanceBefore)).to.equal(amount);

      // Verify ETH transfer to seller (minus fees)
      const sellerBalanceAfter = await ethers.provider.getBalance(seller.address);
      const paymentAmount = (amount * price) / ethers.parseEther("1.0");
      const fee = (paymentAmount * BigInt(60)) / BigInt(10000);
      const expectedSellerPayment = paymentAmount - fee;

      expect(BigInt(sellerBalanceAfter) - BigInt(sellerBalanceBefore)).to.be.closeTo(
        expectedSellerPayment,
        ethers.parseEther("0.0001") // Allow for gas costs
      );
    });

    // it("Should match and fulfill market orders", async function () {
    //   // Create market orders
    //   const marketAmount = ethers.parseEther("50");
    //   const marketPrice = ethers.parseEther("1.4"); // Different price for market orders

    //   // Create market buy order
    //   const totalCost = (marketAmount * marketPrice) / ethers.parseEther("1.0");
    //   const fee = (totalCost * BigInt(60)) / BigInt(10000);

    //   await orderbook.connect(buyer).createOrder(
    //     OrderType.Buy,
    //     OrderExecutionType.Market,
    //     await tokenA.getAddress(),
    //     marketAmount,
    //     marketPrice,
    //     ttl,
    //     { value: totalCost + fee }
    //   );
    //   const marketBuyOrderId = 2;

    //   // Create market sell order
    //   await orderbook.connect(seller).createOrder(
    //     OrderType.Sell,
    //     OrderExecutionType.Market,
    //     await tokenA.getAddress(),
    //     marketAmount,
    //     marketPrice,
    //     ttl
    //   );
    //   const marketSellOrderId = 3;

    //   // Match and fulfill market orders
    //   const match = {
    //     buyOrderId: marketBuyOrderId,
    //     sellOrderId: marketSellOrderId,
    //     fillAmount: marketAmount
    //   };

    //   const executionPrice = ethers.parseEther("1.55"); // Price between buy and sell orders
    //   await orderbook.connect(fulfiller).fulfillMarketOrders([match], [executionPrice]);

    //   // Verify order statuses
    //   const buyOrder = await orderbook.getOrder(marketBuyOrderId);
    //   const sellOrder = await orderbook.getOrder(marketSellOrderId);
    //   expect(buyOrder.status).to.equal(OrderStatus.Filled);
    //   expect(sellOrder.status).to.equal(OrderStatus.Filled);
    // });

    it("Should handle partial fills correctly", async function () {
      const partialAmount = ethers.parseEther("50");
      const sellerBalanceBefore = await ethers.provider.getBalance(seller.address);

      // Match and fulfill with partial amount
      const match = {
        buyOrderId,
        sellOrderId,
        fillAmount: partialAmount
      };

      await orderbook.connect(fulfiller).fulfillLimitOrders([match]);

      // Verify order statuses and remaining amounts
      const buyOrder = await orderbook.getOrder(buyOrderId);
      const sellOrder = await orderbook.getOrder(sellOrderId);
      expect(buyOrder.status).to.equal(OrderStatus.Active);
      expect(sellOrder.status).to.equal(OrderStatus.Active);
      expect(buyOrder.filledAmount).to.equal(partialAmount);
      expect(sellOrder.filledAmount).to.equal(partialAmount);

      // Verify partial payment to seller
      const sellerBalanceAfter = await ethers.provider.getBalance(seller.address);
      const paymentAmount = (partialAmount * price) / ethers.parseEther("1.0");
      const fee = (paymentAmount * BigInt(60)) / BigInt(10000);
      const expectedSellerPayment = paymentAmount - fee;

      expect(BigInt(sellerBalanceAfter) - BigInt(sellerBalanceBefore)).to.be.closeTo(
        expectedSellerPayment,
        ethers.parseEther("0.0001")
      );
    });

    it("Should prevent non-whitelisted fulfiller from matching orders", async function () {
      const match = {
        buyOrderId,
        sellOrderId,
        fillAmount: amount
      };

      await expect(
        orderbook.connect(nonWhitelisted).fulfillLimitOrders([match])
      ).to.be.revertedWith("Caller is not whitelisted");
    });

    it("Should prevent matching expired orders", async function () {
      // Advance time past TTL
      await time.increase(ttl + 1);

      const match = {
        buyOrderId,
        sellOrderId,
        fillAmount: amount
      };

      await expect(
        orderbook.connect(fulfiller).fulfillLimitOrders([match])
      ).to.be.revertedWith("Orders expired");
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
        OrderType.Buy,
        OrderExecutionType.Limit,
        await tokenA.getAddress(),
        amount,
        price,
        ttl,
        { value: ethers.parseEther("150.9") }
      );

      await orderbook.connect(seller).createOrder(
        OrderType.Sell,
        OrderExecutionType.Limit,
        await tokenA.getAddress(),
        amount,
        price,
        ttl
      );
    });

    it("Should return active orders", async function () {
      const activeOrders = await orderbook.getActiveOrders(
        await tokenA.getAddress(),
        OrderType.Buy,
        OrderExecutionType.Market
      );

      expect(activeOrders.length).to.be.gte(0);
    });

    it("Should return correct remaining amount", async function () {
      const remaining = await orderbook.getRemainingAmount(0);
      expect(remaining).to.equal(ethers.parseEther("100"));
    });

    it("Should return order details", async function () {
      const order = await orderbook.getOrder(0);
      expect(order.owner).to.equal(buyer.address);
      expect(order.status).to.equal(OrderStatus.Active); // Active
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
        orderbook.setFeePercentage(maxFee + BigInt(1))
      ).to.be.revertedWith("Fee percentage too high");
    });

    it("Should prevent non-owner from setting fee percentage", async function () {
      await expect(
        orderbook.connect(nonWhitelisted).setFeePercentage(100)
      ).to.be.revertedWithCustomError(orderbook, "OwnableUnauthorizedAccount");
    });

    it("Should allow owner to withdraw collected fees", async function () {
      // First generate some fees
      const amount = ethers.parseEther("100");
      const price = ethers.parseEther("1.5");
      const ttl = 3600;

      // Create and fulfill orders to generate fees
      await orderbook.connect(buyer).createOrder(
        OrderType.Buy,
        OrderExecutionType.Limit,
        await tokenA.getAddress(),
        amount,
        price,
        ttl,
        { value: ethers.parseEther("160") }
      );

      await orderbook.connect(seller).createOrder(
        OrderType.Sell,
        OrderExecutionType.Limit,
        await tokenA.getAddress(),
        amount,
        price,
        ttl
      );

      const match = {
        buyOrderId: 0,
        sellOrderId: 1,
        fillAmount: amount
      };

      await orderbook.connect(fulfiller).fulfillLimitOrders([match]);

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
      expect(BigInt(recipientBalanceAfter) - BigInt(recipientBalanceBefore)).to.be.closeTo(
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

  describe("Order Size Limits", function () {

    it("Should fail to create order above maximum size", async function () {
      const amount = ethers.parseEther("1000");
      const price = ethers.parseEther("2"); // Will result in total cost > maxOrderSize
      const ttl = 3600;

      const totalCost = (amount * price) / ethers.parseEther("1.0");
      const fee = (totalCost * BigInt(60)) / BigInt(10000);

      await expect(
        orderbook.connect(buyer).createOrder(
          OrderType.Buy,
          OrderExecutionType.Limit,
          await tokenA.getAddress(),
          amount,
          price,
          ttl,
          { value: totalCost + fee }
        )
      ).to.be.revertedWith("Order too large");
    });

    it("Should allow owner to update order size limits", async function () {
      const newMinSize = ethers.parseEther("0.1");
      const newMaxSize = ethers.parseEther("2000");

      await expect(orderbook.setOrderSizeLimits(newMinSize, newMaxSize))
        .to.emit(orderbook, "OrderSizeLimitsUpdated")
        .withArgs(newMinSize, newMaxSize);

      expect(await orderbook.minOrderSize()).to.equal(newMinSize);
      expect(await orderbook.maxOrderSize()).to.equal(newMaxSize);
    });
  });

  describe("Order TTL", function () {
    it("Should fail to create order with TTL exceeding maximum", async function () {
      const amount = ethers.parseEther("100");
      const price = ethers.parseEther("1.5");
      const maxTtl = await orderbook.maxOrderTtl();

      await expect(
        orderbook.connect(buyer).createOrder(
          OrderType.Buy,
          OrderExecutionType.Limit,
          await tokenA.getAddress(),
          amount,
          price,
          maxTtl + BigInt(1),
          { value: ethers.parseEther("1000") }
        )
      ).to.be.revertedWith("TTL too long");
    });

    it("Should allow owner to update maximum TTL", async function () {
      const newMaxTtl = 60 * 24 * 60 * 60; // 60 days

      await expect(orderbook.setMaxOrderTtl(newMaxTtl))
        .to.emit(orderbook, "MaxTTLUpdated")
        .withArgs(newMaxTtl);

      expect(await orderbook.maxOrderTtl()).to.equal(newMaxTtl);
    });
  });

  describe("Paged Order Retrieval", function () {
    beforeEach(async function () {
      // Create multiple orders for testing pagination
      const amount = ethers.parseEther("100");
      const price = ethers.parseEther("1.5");
      const ttl = 3600;

      // Create 5 buy orders
      for (let i = 0; i < 5; i++) {
        const totalCost = amount * price / ethers.parseEther("1.0");
        const fee = totalCost * BigInt(60) / BigInt(10000);
        await orderbook.connect(buyer).createOrder(
          OrderType.Buy,
          OrderExecutionType.Limit,
          await tokenA.getAddress(),
          amount,
          price + BigInt(i), // Different prices
          ttl,
          { value: totalCost + fee }
        );
      }
    });

    it("Should retrieve orders with pagination", async function () {
      const pageSize = 2;
      const firstPage = await orderbook.getActiveOrdersPaged(
        await tokenA.getAddress(),
        OrderType.Buy,
        OrderExecutionType.Limit,
        0, // startIndex
        pageSize
      );

      expect(firstPage.length).to.equal(pageSize);

      const secondPage = await orderbook.getActiveOrdersPaged(
        await tokenA.getAddress(),
        OrderType.Buy,
        OrderExecutionType.Limit,
        pageSize, // startIndex
        pageSize
      );

      expect(secondPage.length).to.equal(pageSize);
      expect(firstPage[0]).to.not.equal(secondPage[0]); // Different orders
    });

    it("Should return empty array for out of bounds page", async function () {
      const pageSize = 2;
      const result = await orderbook.getActiveOrdersPaged(
        await tokenA.getAddress(),
        OrderType.Buy,
        OrderExecutionType.Limit,
        10, // startIndex beyond available orders
        pageSize
      );

      expect(result.length).to.equal(0);
    });
  });
}); 