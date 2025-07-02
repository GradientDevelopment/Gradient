// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library OrderStructs {
    enum OrderType {
        BUY,
        SELL
    }
    enum OrderStatus {
        PENDING,
        PARTIALLY_FILLED,
        FILLED,
        CANCELLED,
        EXPIRED
    }
    enum FallbackOption {
        NONE, // No fallback, cancel if not matched
        MARKET_MAKER, // Try market maker pool if not matched
        AMM_DEX, // Try AMM DEX if not matched
        ANY // Try both market maker and AMM DEX
    }

    struct Order {
        uint256 id;
        address user;
        address token;
        uint256 amount; // Total order amount
        uint256 filledAmount; // Amount filled so far
        uint256 price; // Price per unit in wei
        uint256 expiration; // Block timestamp when order expires
        uint256 minFillAmount; // Minimum amount that must be filled
        uint256 maxSlippage; // Maximum allowed slippage in basis points
        OrderType orderType;
        OrderStatus status;
        uint256 timestamp; // Order creation timestamp for time priority
        FallbackOption fallbackOption; // What to do if order can't be matched
    }

    // Price-time priority queue node
    struct OrderNode {
        uint256 orderId;
        uint256 next; // Next order ID in the queue
        uint256 prev; // Previous order ID in the queue
    }

    // Price level containing orders at the same price
    struct PriceLevel {
        uint256 head; // First order ID at this price
        uint256 tail; // Last order ID at this price
        uint256 totalAmount; // Total amount of orders at this price
    }

    // Constants
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_SLIPPAGE = 1000; // 10%
    uint256 public constant MIN_FILL_AMOUNT = 1e15; // 0.001 ETH
}
