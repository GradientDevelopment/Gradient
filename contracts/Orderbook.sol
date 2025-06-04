// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Orderbook
/// @notice A decentralized orderbook for trading ERC20 tokens against ETH
/// @dev Implements a limit order system with order matching and fulfillment
/// @custom:security-contact security@gradientorderbook.com
contract Orderbook is Ownable, ReentrancyGuard {
    /// @notice Types of orders that can be placed
    enum OrderType {
        Buy,
        Sell
    }

    /// @notice Possible states of an order
    enum OrderStatus {
        Active,
        Filled,
        Cancelled,
        Expired
    }

    /// @notice Structure containing all information about an order
    /// @dev All amounts use the decimal precision of their respective tokens
    struct Order {
        uint256 orderId; // Unique identifier for the order
        address owner; // Address that created the order
        OrderType orderType; // Whether this is a buy or sell order
        address token; // Token being traded
        uint256 amount; // Total amount of tokens to trade
        uint256 price; // Price per token in ETH (18 decimals)
        uint256 filledAmount; // Amount of tokens that have been filled
        uint256 expirationTime; // Timestamp when the order expires
        OrderStatus status; // Current status of the order
    }

    /// @notice Parameters required for order fulfillment
    struct FulfillmentParams {
        uint256 orderId; // ID of the order to fulfill
        uint256 fillAmount; // Amount of tokens to fill
        uint256 price; // Price at which to fill
        address counterparty; // Address of the counterparty
    }

    /// @notice Parameters for matching orders
    struct OrderMatch {
        uint256 buyOrderId; // ID of the buy order
        uint256 sellOrderId; // ID of the sell order
        uint256 fillAmount; // Amount of tokens to exchange
    }

    /// @notice Counter for generating unique order IDs
    uint256 private _orderIdCounter;

    /// @notice Fee percentage charged on trades (in basis points, 1 = 0.01%)
    uint256 public feePercentage;

    /// @notice Maximum fee percentage that can be set (in basis points)
    uint256 public constant MAX_FEE_PERCENTAGE = 500; // 5%

    /// @notice Total fees collected
    uint256 public totalFeesCollected;

    /// @notice Mapping from order ID to Order struct
    mapping(uint256 => Order) public orders;

    /// @notice Mapping from token pair + order type hash to array of order IDs
    /// @dev Key is keccak256(abi.encodePacked(token, orderType))
    mapping(bytes32 => uint256[]) private orderQueues;

    /// @notice Mapping of addresses allowed to fulfill orders
    mapping(address => bool) public whitelistedFulfillers;

    uint256 public constant DIVISOR = 10000;

    /// @notice Emitted when a new order is created
    event OrderCreated(
        uint256 indexed orderId,
        address indexed owner,
        OrderType orderType,
        address token,
        uint256 amount,
        uint256 price,
        uint256 expirationTime
    );

    /// @notice Emitted when an order is cancelled by its owner
    event OrderCancelled(uint256 indexed orderId);

    /// @notice Emitted when an order expires
    event OrderExpired(uint256 indexed orderId);

    /// @notice Emitted when an order is completely filled
    event OrderFulfilled(uint256 indexed orderId, uint256 amount);

    /// @notice Emitted when an order is partially filled
    event OrderPartiallyFulfilled(
        uint256 indexed orderId,
        uint256 amount,
        uint256 remaining
    );

    /// @notice Emitted when a fulfiller's whitelist status changes
    event FulfillerWhitelisted(address indexed fulfiller, bool status);

    /// @notice Emitted when fee percentage is updated
    event FeePercentageUpdated(
        uint256 oldFeePercentage,
        uint256 newFeePercentage
    );

    /// @notice Emitted when fees are withdrawn
    event FeesWithdrawn(address indexed recipient, uint256 amount);

    // Modifiers
    modifier onlyWhitelistedFulfiller() {
        require(whitelistedFulfillers[msg.sender], "Caller is not whitelisted");
        _;
    }

    modifier orderExists(uint256 orderId) {
        require(orders[orderId].owner != address(0), "Order does not exist");
        _;
    }

    modifier onlyOrderOwner(uint256 orderId) {
        require(orders[orderId].owner == msg.sender, "Not order owner");
        _;
    }

    constructor() Ownable(msg.sender) {
        whitelistedFulfillers[msg.sender] = true;
        feePercentage = 50; // Default 0.5%
    }

    /// @notice Sets the fee percentage for trades
    /// @param newFeePercentage New fee percentage in basis points (1 = 0.01%)
    /// @dev Only callable by contract owner
    function setFeePercentage(uint256 newFeePercentage) external onlyOwner {
        require(
            newFeePercentage <= MAX_FEE_PERCENTAGE,
            "Fee percentage too high"
        );
        uint256 oldFeePercentage = feePercentage;
        feePercentage = newFeePercentage;
        emit FeePercentageUpdated(oldFeePercentage, newFeePercentage);
    }

    /// @notice Withdraws collected fees to the specified address
    /// @param recipient Address to receive the fees
    /// @dev Only callable by contract owner
    function withdrawFees(address payable recipient) external onlyOwner {
        require(recipient != address(0), "Invalid recipient");
        uint256 amount = totalFeesCollected;
        require(amount > 0, "No fees to withdraw");

        totalFeesCollected = 0;
        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Fee withdrawal failed");

        emit FeesWithdrawn(recipient, amount);
    }

    /// @notice Generates a unique key for order queues based on token and order type
    /// @param token The token address
    /// @param orderType The type of order (Buy/Sell)
    /// @return bytes32 A unique key for the order queue
    function _getQueueKey(
        address token,
        OrderType orderType
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(token, orderType));
    }

    /// @notice Sets or removes a fulfiller's whitelisted status
    /// @param fulfiller Address of the fulfiller to modify
    /// @param status New status for the fulfiller (true = whitelisted, false = not whitelisted)
    /// @dev Only callable by contract owner
    function setFulfillerStatus(
        address fulfiller,
        bool status
    ) external onlyOwner {
        whitelistedFulfillers[fulfiller] = status;
        emit FulfillerWhitelisted(fulfiller, status);
    }

    /// @notice Creates a new order in the orderbook
    /// @param orderType Type of order (Buy/Sell)
    /// @param token Address of the token to trade
    /// @param amount Amount of tokens to trade
    /// @param price Price per token in ETH (18 decimals)
    /// @param ttl Time-to-live in seconds for the order
    /// @dev For buy orders, requires ETH to be sent with the transaction
    /// @dev For sell orders, requires token approval
    /// @return uint256 ID of the created order
    function createOrder(
        OrderType orderType,
        address token,
        uint256 amount,
        uint256 price,
        uint256 ttl
    ) external payable nonReentrant returns (uint256) {
        require(token != address(0), "Invalid token");
        require(amount > 0, "Amount must be greater than 0");
        require(price > 0, "Invalid price range");
        require(ttl > 0, "TTL must be greater than 0");

        uint256 totalCost = (amount * price) / 1e18;
        uint256 buyerFee = (totalCost * feePercentage) / DIVISOR;

        // For buy orders, require ETH payment including potential fee
        if (orderType == OrderType.Buy) {
            require(msg.value >= totalCost + buyerFee, "Insufficient ETH sent");
            totalFeesCollected += buyerFee;
        }
        // For sell orders, transfer tokens to contract
        else {
            require(
                IERC20(token).transferFrom(msg.sender, address(this), amount),
                "Token transfer failed"
            );
        }

        uint256 orderId = _orderIdCounter;
        _orderIdCounter++;

        Order memory newOrder = Order({
            orderId: orderId,
            owner: msg.sender,
            orderType: orderType,
            token: token,
            amount: amount,
            price: price,
            filledAmount: 0,
            expirationTime: block.timestamp + ttl,
            status: OrderStatus.Active
        });

        orders[orderId] = newOrder;

        // Add to the appropriate queue
        bytes32 queueKey = _getQueueKey(token, orderType);
        orderQueues[queueKey].push(orderId);

        emit OrderCreated(
            orderId,
            msg.sender,
            orderType,
            token,
            amount,
            price,
            newOrder.expirationTime
        );

        // Return excess ETH for buy orders
        if (orderType == OrderType.Buy && msg.value > (totalCost + buyerFee)) {
            uint256 excess = msg.value - (totalCost + buyerFee);
            (bool success, ) = msg.sender.call{value: excess}("");
            require(success, "ETH return failed");
        }

        return orderId;
    }

    /// @notice Cancels an active order
    /// @param orderId ID of the order to cancel
    /// @dev Only the order owner can cancel their order
    /// @dev Refunds ETH for buy orders and tokens for sell orders
    function cancelOrder(
        uint256 orderId
    ) external nonReentrant orderExists(orderId) onlyOrderOwner(orderId) {
        Order storage order = orders[orderId];
        require(order.status == OrderStatus.Active, "Order not active");
        require(!isOrderExpired(orderId), "Order expired");

        order.status = OrderStatus.Cancelled;

        // If it was a buy order, return the ETH including potential fee
        if (order.orderType == OrderType.Buy) {
            uint256 remainingAmount = order.amount - order.filledAmount;
            if (remainingAmount > 0) {
                uint256 refundAmount = (remainingAmount * order.price) / 1e18;
                uint256 feeRefund = (refundAmount * feePercentage) / DIVISOR;
                (bool success, ) = order.owner.call{
                    value: refundAmount + feeRefund
                }("");
                require(success, "ETH refund failed");
            }
        }
        // If it was a sell order, return the tokens
        else {
            uint256 remainingAmount = order.amount - order.filledAmount;
            if (remainingAmount > 0) {
                require(
                    IERC20(order.token).transfer(order.owner, remainingAmount),
                    "Token return failed"
                );
            }
        }

        emit OrderCancelled(orderId);
    }

    /// @notice Checks if an order has expired
    /// @param orderId ID of the order to check
    /// @return bool True if the order has expired, false otherwise
    function isOrderExpired(
        uint256 orderId
    ) public view orderExists(orderId) returns (bool) {
        return block.timestamp > orders[orderId].expirationTime;
    }

    /// @notice Marks an expired order as expired and handles refunds
    /// @param orderId ID of the expired order to clean up
    /// @dev Anyone can call this function for expired orders
    /// @dev Refunds tokens for unfilled sell orders
    function cleanupExpiredOrder(
        uint256 orderId
    ) external nonReentrant orderExists(orderId) {
        Order storage order = orders[orderId];
        require(order.status == OrderStatus.Active, "Order not active");
        require(isOrderExpired(orderId), "Order not expired");

        order.status = OrderStatus.Expired;

        // If it was a sell order, return the tokens
        if (order.orderType == OrderType.Sell) {
            uint256 remainingAmount = order.amount - order.filledAmount;
            if (remainingAmount > 0) {
                require(
                    IERC20(order.token).transfer(order.owner, remainingAmount),
                    "Token return failed"
                );
            }
        }

        emit OrderExpired(orderId);
    }

    /// @notice Retrieves all active orders for a given token and order type
    /// @param token Address of the input token
    /// @param orderType Type of orders to retrieve (Buy/Sell)
    /// @return uint256[] Array of order IDs that are active and not expired
    function getActiveOrders(
        address token,
        OrderType orderType
    ) external view returns (uint256[] memory) {
        bytes32 queueKey = _getQueueKey(token, orderType);
        uint256[] storage queueOrders = orderQueues[queueKey];

        // Count active orders
        uint256 activeCount = 0;
        for (uint256 i = 0; i < queueOrders.length; i++) {
            if (
                orders[queueOrders[i]].status == OrderStatus.Active &&
                !isOrderExpired(queueOrders[i])
            ) {
                activeCount++;
            }
        }

        // Create array of active orders
        uint256[] memory activeOrders = new uint256[](activeCount);
        uint256 currentIndex = 0;
        for (
            uint256 i = 0;
            i < queueOrders.length && currentIndex < activeCount;
            i++
        ) {
            if (
                orders[queueOrders[i]].status == OrderStatus.Active &&
                !isOrderExpired(queueOrders[i])
            ) {
                activeOrders[currentIndex] = queueOrders[i];
                currentIndex++;
            }
        }

        return activeOrders;
    }

    /// @notice Fulfills multiple matched orders
    /// @param matches Array of OrderMatch structs containing match details
    /// @dev Only whitelisted fulfillers can call this function
    function fulfillMatchedOrders(
        OrderMatch[] calldata matches
    ) external nonReentrant onlyWhitelistedFulfiller {
        require(matches.length > 0, "No order matches to fulfill");

        for (uint256 i = 0; i < matches.length; i++) {
            _fulfillMatchedOrders(matches[i]);
        }
    }

    /// @notice Internal function to calculate and collect fees
    /// @param amount Amount in ETH to calculate fee from
    /// @return uint256 Fee amount collected
    function _collectFee(uint256 amount) internal returns (uint256) {
        uint256 feeAmount = (amount * feePercentage) / DIVISOR;
        totalFeesCollected += feeAmount;
        return feeAmount;
    }

    /// @notice Internal function to fulfill a matched pair of orders
    /// @param _match OrderMatch struct containing the match details
    /// @dev Handles the transfer of ETH and tokens between parties
    function _fulfillMatchedOrders(OrderMatch memory _match) internal {
        Order storage buyOrder = orders[_match.buyOrderId];
        Order storage sellOrder = orders[_match.sellOrderId];

        // Validate orders
        require(
            buyOrder.status == OrderStatus.Active &&
                sellOrder.status == OrderStatus.Active,
            "Orders must be active"
        );
        require(
            !isOrderExpired(_match.buyOrderId) &&
                !isOrderExpired(_match.sellOrderId),
            "Orders expired"
        );
        require(
            buyOrder.orderType == OrderType.Buy &&
                sellOrder.orderType == OrderType.Sell,
            "Invalid order types"
        );
        require(buyOrder.token == sellOrder.token, "Token mismatch");
        require(buyOrder.price >= sellOrder.price, "Price mismatch");

        // Validate fill amount
        uint256 buyRemaining = buyOrder.amount - buyOrder.filledAmount;
        uint256 sellRemaining = sellOrder.amount - sellOrder.filledAmount;
        require(_match.fillAmount > 0, "Invalid fill amount");
        require(
            _match.fillAmount <= buyRemaining &&
                _match.fillAmount <= sellRemaining,
            "Fill amount exceeds available"
        );

        // Calculate token amounts and fees
        uint256 tokenAmount = _match.fillAmount;
        uint256 paymentAmount = (_match.fillAmount * sellOrder.price) / 1e18; // Using sell order price

        // Calculate and collect fees from seller party
        uint256 sellerFee = _collectFee(paymentAmount);

        // Calculate final amounts after fees
        uint256 sellerPayment = paymentAmount - sellerFee;

        // Execute transfers
        // 1. Transfer ETH from contract to seller (minus fee)
        (bool success, ) = sellOrder.owner.call{value: sellerPayment}("");
        require(success, "ETH transfer to seller failed");

        // 2. Transfer traded tokens from contract to buyer
        require(
            IERC20(sellOrder.token).transfer(buyOrder.owner, tokenAmount),
            "Token transfer failed"
        );

        // Update order states
        buyOrder.filledAmount += _match.fillAmount;
        sellOrder.filledAmount += _match.fillAmount;

        // Return excess ETH to buyer if using a lower sell price
        if (buyOrder.price > sellOrder.price) {
            uint256 savedAmount = (_match.fillAmount *
                (buyOrder.price - sellOrder.price)) / 1e18;
            uint256 savedFee = (savedAmount * feePercentage) / DIVISOR;
            (success, ) = buyOrder.owner.call{value: savedAmount + savedFee}(
                ""
            );
            require(success, "ETH savings return failed");
        }

        // Update order statuses
        if (buyOrder.filledAmount == buyOrder.amount) {
            buyOrder.status = OrderStatus.Filled;
            emit OrderFulfilled(_match.buyOrderId, _match.fillAmount);
        } else {
            emit OrderPartiallyFulfilled(
                _match.buyOrderId,
                _match.fillAmount,
                buyOrder.amount - buyOrder.filledAmount
            );
        }

        if (sellOrder.filledAmount == sellOrder.amount) {
            sellOrder.status = OrderStatus.Filled;
            emit OrderFulfilled(_match.sellOrderId, _match.fillAmount);
        } else {
            emit OrderPartiallyFulfilled(
                _match.sellOrderId,
                _match.fillAmount,
                sellOrder.amount - sellOrder.filledAmount
            );
        }
    }

    /// @notice Retrieves detailed information about an order
    /// @param orderId ID of the order to query
    /// @return Order struct containing all order details
    function getOrder(
        uint256 orderId
    ) external view orderExists(orderId) returns (Order memory) {
        return orders[orderId];
    }

    /// @notice Gets the unfilled amount for an order
    /// @param orderId ID of the order to query
    /// @return uint256 Amount of tokens/ETH remaining to be filled
    function getRemainingAmount(
        uint256 orderId
    ) external view orderExists(orderId) returns (uint256) {
        Order storage order = orders[orderId];
        return order.amount - order.filledAmount;
    }

    /// @notice Allows the contract to receive ETH
    /// @dev Required for receiving ETH payments
    receive() external payable {}

    /// @notice Fallback function that accepts ETH
    /// @dev Required for receiving ETH payments through alternative methods
    fallback() external payable {}
}
