// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../libs/OrderStructs.sol";

interface IOrderManager {
    // Events
    event OrderPlaced(
        uint256 indexed orderId,
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 price,
        bool isBuy
    );
    event OrderCancelled(uint256 indexed orderId);
    event OrderFilled(
        uint256 indexed orderId,
        uint256 indexed matchedOrderId,
        address indexed filler,
        uint256 amount,
        uint256 price
    );
    event OrderPartiallyFilled(
        uint256 indexed orderId,
        uint256 indexed matchedOrderId,
        address indexed filler,
        uint256 amount,
        uint256 remainingAmount
    );
    event OrderExpired(uint256 indexed orderId);
    event MinOrderAmountUpdated(uint256 newAmount);
    event MaxOrderAmountUpdated(uint256 newAmount);

    // View functions
    function orders(
        uint256 orderId
    )
        external
        view
        returns (
            uint256 id,
            address user,
            address token,
            uint256 amount,
            uint256 filledAmount,
            uint256 price,
            uint256 expiration,
            uint256 minFillAmount,
            uint256 maxSlippage,
            OrderStructs.OrderType orderType,
            OrderStructs.OrderStatus status,
            uint256 timestamp
        );

    function getBestPrice(
        address token,
        bool isBuy
    ) external view returns (uint256);

    function getOrderBookDepth(
        address token,
        bool isBuy,
        uint256 maxLevels
    ) external view returns (uint256[] memory prices, uint256[] memory amounts);

    // State changing functions
    function placeOrder(
        address token,
        uint256 amount,
        uint256 price,
        uint256 expiration,
        uint256 minFillAmount,
        uint256 maxSlippage,
        bool isBuy
    ) external returns (uint256);

    function cancelOrder(uint256 orderId) external;

    function fillOrder(uint256 orderId, uint256 amount) external;

    function updateOrderLimits(
        uint256 _minOrderAmount,
        uint256 _maxOrderAmount
    ) external;
}
