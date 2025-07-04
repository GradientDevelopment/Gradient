// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title GradientOrderbook
/// @notice A decentralized orderbook for trading ERC20 tokens against ETH
/// @dev Implements a limit order system with order matching and fulfillment
contract GradientOrderbook is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Types of orders that can be placed
    enum OrderType {
        Buy,
        Sell
    }

    /// @notice Types of order execution
    enum OrderExecutionType {
        Limit,
        Market
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
        OrderExecutionType executionType; // Whether this is a limit or market order
        address token; // Token being traded
        uint256 amount; // Total amount of tokens to trade
        uint256 price; // For limit orders: exact price, For market orders: max price (buy) or min price (sell)
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

    /// @notice Mapping from token pair + order type + execution type hash to array of order IDs
    /// @dev Key is keccak256(abi.encodePacked(token, orderType, executionType))
    // mapping(bytes32 => uint256[]) private orderQueues;
    mapping(bytes32 => uint256) public totalOrderCount;
    mapping(bytes32 => mapping(uint256 => uint256)) private orderQueues;

    /// @notice Mapping from order ID to its position in the queue
    /// @dev Used for efficient removal of orders from queues
    mapping(uint256 => uint256) private orderQueuePositions;

    /// @notice Mapping of addresses allowed to fulfill orders
    mapping(address => bool) public whitelistedFulfillers;

    uint256 public constant DIVISOR = 10000;

    uint256 public minOrderSize;
    uint256 public maxOrderSize;
    uint256 public maxOrderTtl;

    /// @notice Emitted when a new order is created
    event OrderCreated(
        uint256 indexed orderId,
        address indexed owner,
        OrderType orderType,
        OrderExecutionType executionType,
        address token,
        uint256 amount,
        uint256 price,
        uint256 expirationTime,
        uint256 totalCost // Add total cost for better tracking
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

    event OrderSizeLimitsUpdated(uint256 minSize, uint256 maxSize);
    event MaxTTLUpdated(uint256 newMaxTTL);
    event RateLimitUpdated(uint256 newInterval);

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

    modifier validToken(address token) {
        require(token != address(0), "Invalid token");
        require(token.code.length > 0, "Not a contract");
        _;
    }

    constructor() Ownable(msg.sender) {
        whitelistedFulfillers[msg.sender] = true;
        feePercentage = 50; // Default 0.5%

        minOrderSize = 1e6; // Example: 0.000001 ETH
        maxOrderSize = 1000 ether; // Example: 1000 ETH
        maxOrderTtl = 30 days; // Example: 30 days
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

    /// @notice Generates a unique key for order queues based on token, order type, and execution type
    /// @param token The token address
    /// @param orderType The type of order (Buy/Sell)
    /// @param executionType The type of execution (Limit/Market)
    /// @return bytes32 A unique key for the order queue
    function _getQueueKey(
        address token,
        OrderType orderType,
        OrderExecutionType executionType
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(token, orderType, executionType));
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

    function setOrderSizeLimits(
        uint256 _minOrderSize,
        uint256 _maxOrderSize
    ) external onlyOwner {
        minOrderSize = _minOrderSize;
        maxOrderSize = _maxOrderSize;
        emit OrderSizeLimitsUpdated(_minOrderSize, _maxOrderSize);
    }

    function setMaxOrderTtl(uint256 _maxOrderTtl) external onlyOwner {
        maxOrderTtl = _maxOrderTtl;
        emit MaxTTLUpdated(_maxOrderTtl);
    }

    /// @notice Creates a new order in the orderbook
    /// @param orderType Type of order (Buy/Sell)
    /// @param executionType Type of execution (Limit/Market)
    /// @param token Address of the token to trade
    /// @param amount Amount of tokens to trade
    /// @param price For limit orders: exact price, For market orders: max price (buy) or min price (sell)
    /// @param ttl Time-to-live in seconds for the order
    /// @dev For buy orders, requires ETH to be sent with the transaction
    /// @dev For sell orders, requires token approval
    /// @return uint256 ID of the created order
    function createOrder(
        OrderType orderType,
        OrderExecutionType executionType,
        address token,
        uint256 amount,
        uint256 price,
        uint256 ttl
    ) external payable validToken(token) nonReentrant returns (uint256) {
        require(amount > 0, "Amount must be greater than 0");
        require(price > 0, "Invalid price range");
        require(ttl > 0, "TTL must be greater than 0");
        require(ttl <= maxOrderTtl, "TTL too long");

        uint256 totalCost = (amount * price) / 1e18;
        uint256 buyerFee = (totalCost * feePercentage) / DIVISOR;
        require(totalCost >= minOrderSize, "Order too small");
        require(totalCost <= maxOrderSize, "Order too large");

        // For buy orders, require ETH payment including potential fee
        if (orderType == OrderType.Buy) {
            require(msg.value >= totalCost + buyerFee, "Insufficient ETH sent");
            totalFeesCollected += buyerFee;
        }
        // For sell orders, transfer tokens to contract
        else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }

        uint256 orderId = _orderIdCounter;
        _orderIdCounter++;

        Order memory newOrder = Order({
            orderId: orderId,
            owner: msg.sender,
            orderType: orderType,
            executionType: executionType,
            token: token,
            amount: amount,
            price: price,
            filledAmount: 0,
            expirationTime: block.timestamp + ttl,
            status: OrderStatus.Active
        });

        orders[orderId] = newOrder;

        // Add to the appropriate queue based on execution type
        _addOrderToQueue(orderId, token, orderType, executionType);

        emit OrderCreated(
            orderId,
            msg.sender,
            orderType,
            executionType,
            token,
            amount,
            price,
            newOrder.expirationTime,
            totalCost
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
                uint256 totalRefund = refundAmount + feeRefund;

                uint256 actualFeeRefund = feeRefund > totalFeesCollected
                    ? totalFeesCollected
                    : feeRefund;
                totalFeesCollected -= actualFeeRefund;

                // Adjust totalRefund if we couldn't refund full fee
                if (actualFeeRefund < feeRefund) {
                    totalRefund = refundAmount + actualFeeRefund;
                }

                require(
                    address(this).balance >= totalRefund,
                    "Insufficient ETH in contract"
                );
                (bool success, ) = order.owner.call{value: totalRefund}("");
                require(success, "ETH refund failed");
            }
        }
        // If it was a sell order, return the tokens
        else {
            uint256 remainingAmount = order.amount - order.filledAmount;
            if (remainingAmount > 0) {
                IERC20(order.token).safeTransfer(order.owner, remainingAmount);
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
    /// @dev Refunds tokens for unfilled sell orders and ETH for unfilled buy orders
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
                IERC20(order.token).safeTransfer(order.owner, remainingAmount);
            }
        }

        // If it was a buy order, return the ETH including potential fee
        if (order.orderType == OrderType.Buy) {
            uint256 remainingAmount = order.amount - order.filledAmount;
            if (remainingAmount > 0) {
                uint256 totalCost = (remainingAmount * order.price) / 1e18;
                uint256 buyerFee = (totalCost * feePercentage) / DIVISOR;
                uint256 refundAmount = totalCost + buyerFee;

                uint256 actualFeeRefund = buyerFee > totalFeesCollected
                    ? totalFeesCollected
                    : buyerFee;
                totalFeesCollected -= actualFeeRefund;

                // Adjust totalRefund if we couldn't refund full fee
                if (actualFeeRefund < buyerFee) {
                    refundAmount = totalCost + actualFeeRefund;
                }

                require(
                    address(this).balance >= refundAmount,
                    "Insufficient ETH in contract"
                );
                // Refund the ETH
                (bool success, ) = payable(order.owner).call{
                    value: refundAmount
                }("");
                require(success, "ETH refund failed");
            }
        }

        emit OrderExpired(orderId);
    }

    function getActiveOrdersCount(
        bytes32 queueKey
    ) public view returns (uint256) {
        // Count active orders
        uint256 activeCount = 0;
        for (uint256 i = 0; i < totalOrderCount[queueKey]; i++) {
            uint256 orderId = orderQueues[queueKey][i];
            if (
                orders[orderId].status == OrderStatus.Active &&
                !isOrderExpired(orderId)
            ) {
                activeCount++;
            }
        }
        return activeCount;
    }

    /// @notice Retrieves all active orders for a given token, order type, and execution type
    /// @param token Address of the token
    /// @param orderType Type of orders to retrieve (Buy/Sell)
    /// @param executionType Type of execution (Limit/Market)
    /// @return uint256[] Array of order IDs that are active and not expired
    function getActiveOrders(
        address token,
        OrderType orderType,
        OrderExecutionType executionType
    ) external view returns (uint256[] memory) {
        bytes32 queueKey = _getQueueKey(token, orderType, executionType);

        uint256 activeCount = getActiveOrdersCount(queueKey);
        // Create array of active orders
        uint256 currentIndex = 0;
        uint256[] memory activeOrders = new uint256[](activeCount);
        for (
            uint256 i = 0;
            i < totalOrderCount[queueKey] && currentIndex < activeCount;
            i++
        ) {
            uint256 orderId = orderQueues[queueKey][i];
            if (
                orders[orderId].status == OrderStatus.Active &&
                !isOrderExpired(orderId)
            ) {
                activeOrders[currentIndex] = orderId;
                currentIndex++;
            }
        }
        return activeOrders;
    }

    function getActiveOrdersPaged(
        address token,
        OrderType orderType,
        OrderExecutionType executionType,
        uint256 startIndex,
        uint256 count
    ) external view returns (uint256[] memory) {
        bytes32 queueKey = _getQueueKey(token, orderType, executionType);
        uint256 total = totalOrderCount[queueKey];
        uint256[] memory temp = new uint256[](count);
        uint256 found = 0;

        for (uint256 i = startIndex; i < total && found < count; i++) {
            uint256 orderId = orderQueues[queueKey][i];
            if (
                orders[orderId].status == OrderStatus.Active &&
                !isOrderExpired(orderId)
            ) {
                temp[found] = orderId;
                found++;
            }
        }

        // Resize array to `found`
        uint256[] memory result = new uint256[](found);
        for (uint256 i = 0; i < found; i++) {
            result[i] = temp[i];
        }

        return result;
    }

    /// @notice Fulfills multiple matched limit orders
    /// @param matches Array of OrderMatch structs containing match details
    /// @dev Only whitelisted fulfillers can call this function
    /// @dev All orders in matches must be limit orders
    function fulfillLimitOrders(
        OrderMatch[] calldata matches
    ) external nonReentrant onlyWhitelistedFulfiller {
        require(matches.length > 0, "No order matches to fulfill");

        for (uint256 i = 0; i < matches.length; i++) {
            _fulfillLimitOrders(matches[i]);
        }
    }

    /// @notice Fulfills multiple matched market orders
    /// @param matches Array of OrderMatch structs containing match details
    /// @param executionPrices Array of execution prices for each match
    /// @dev Only whitelisted fulfillers can call this function
    /// @dev All orders in matches must be market orders
    function fulfillMarketOrders(
        OrderMatch[] calldata matches,
        uint256[] calldata executionPrices
    ) external nonReentrant onlyWhitelistedFulfiller {
        require(matches.length > 0, "No order matches to fulfill");
        require(
            matches.length == executionPrices.length,
            "Mismatched arrays length"
        );

        for (uint256 i = 0; i < matches.length; i++) {
            _fulfillMarketOrders(matches[i], executionPrices[i]);
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

    /// @notice Internal function to fulfill a matched pair of limit orders
    /// @param _match OrderMatch struct containing the match details
    /// @dev Handles the transfer of ETH and tokens between parties
    /// @dev Allows partial fills of either order
    function _fulfillLimitOrders(OrderMatch memory _match) internal {
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
        require(
            buyOrder.executionType == OrderExecutionType.Limit &&
                sellOrder.executionType == OrderExecutionType.Limit,
            "Not limit orders"
        );
        require(
            buyOrder.price >= sellOrder.price,
            "Price mismatch for limit orders"
        );

        // Calculate actual fill amount based on remaining amounts
        uint256 buyRemaining = buyOrder.amount - buyOrder.filledAmount;
        uint256 sellRemaining = sellOrder.amount - sellOrder.filledAmount;
        uint256 actualFillAmount = _match.fillAmount;

        // Adjust fill amount if it exceeds either order's remaining amount
        if (actualFillAmount > buyRemaining) {
            actualFillAmount = buyRemaining;
        }
        if (actualFillAmount > sellRemaining) {
            actualFillAmount = sellRemaining;
        }

        require(actualFillAmount > 0, "No amount to fill");

        // Calculate token amounts and fees
        uint256 tokenAmount = actualFillAmount;
        uint256 paymentAmount = (actualFillAmount * sellOrder.price) / 1e18; // Use sell price for limit orders

        // Calculate and collect fees from seller party
        uint256 sellerFee = _collectFee(paymentAmount);

        // Calculate final amounts after fees
        uint256 sellerPayment = paymentAmount - sellerFee;

        // Execute transfers
        // 1. Transfer ETH from contract to seller (minus fee)
        (bool success, ) = sellOrder.owner.call{value: sellerPayment}("");
        require(success, "ETH transfer to seller failed");

        // 2. Transfer traded tokens from contract to buyer
        IERC20(sellOrder.token).safeTransfer(buyOrder.owner, tokenAmount);

        // Update order states
        buyOrder.filledAmount += actualFillAmount;
        sellOrder.filledAmount += actualFillAmount;

        // Return excess ETH to buyer if using a lower sell price
        if (buyOrder.price > sellOrder.price) {
            uint256 savedAmount = (actualFillAmount *
                (buyOrder.price - sellOrder.price)) / 1e18;
            (success, ) = buyOrder.owner.call{value: savedAmount}("");
            require(success, "ETH savings return failed");
        }

        // Update order statuses and remove from queues if fully filled
        if (buyOrder.filledAmount == buyOrder.amount) {
            buyOrder.status = OrderStatus.Filled;

            emit OrderFulfilled(_match.buyOrderId, actualFillAmount);
        } else {
            emit OrderPartiallyFulfilled(
                _match.buyOrderId,
                actualFillAmount,
                buyOrder.amount - buyOrder.filledAmount
            );
        }

        if (sellOrder.filledAmount == sellOrder.amount) {
            sellOrder.status = OrderStatus.Filled;

            emit OrderFulfilled(_match.sellOrderId, actualFillAmount);
        } else {
            emit OrderPartiallyFulfilled(
                _match.sellOrderId,
                actualFillAmount,
                sellOrder.amount - sellOrder.filledAmount
            );
        }
    }

    /// @notice Internal function to fulfill a matched pair of market orders
    /// @param _match OrderMatch struct containing the match details
    /// @param executionPrice The price at which the orders will be executed
    /// @dev Handles the transfer of ETH and tokens between parties
    /// @dev Allows partial fills of either order
    function _fulfillMarketOrders(
        OrderMatch memory _match,
        uint256 executionPrice
    ) internal {
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
        require(
            (buyOrder.executionType == OrderExecutionType.Market ||
                sellOrder.executionType == OrderExecutionType.Market),
            "Not market orders"
        );

        // Validate execution price
        if (buyOrder.executionType == OrderExecutionType.Market) {
            require(
                executionPrice <= buyOrder.price,
                "Execution price exceeds buyer's max price"
            );
        }
        if (sellOrder.executionType == OrderExecutionType.Market) {
            require(
                executionPrice >= sellOrder.price,
                "Execution price below seller's min price"
            );
        }

        // Calculate actual fill amount based on remaining amounts
        uint256 buyRemaining = buyOrder.amount - buyOrder.filledAmount;
        uint256 sellRemaining = sellOrder.amount - sellOrder.filledAmount;
        uint256 actualFillAmount = _match.fillAmount;

        // Adjust fill amount if it exceeds either order's remaining amount
        if (actualFillAmount > buyRemaining) {
            actualFillAmount = buyRemaining;
        }
        if (actualFillAmount > sellRemaining) {
            actualFillAmount = sellRemaining;
        }

        require(actualFillAmount > 0, "No amount to fill");

        // Calculate token amounts and fees
        uint256 tokenAmount = actualFillAmount;
        uint256 paymentAmount = (actualFillAmount * executionPrice) / 1e18;

        // Calculate and collect fees from seller party
        uint256 sellerFee = _collectFee(paymentAmount);

        // Calculate final amounts after fees
        uint256 sellerPayment = paymentAmount - sellerFee;

        // Execute transfers
        // 1. Transfer ETH from contract to seller (minus fee)
        (bool success, ) = sellOrder.owner.call{value: sellerPayment}("");
        require(success, "ETH transfer to seller failed");

        // 2. Transfer traded tokens from contract to buyer
        IERC20(sellOrder.token).safeTransfer(buyOrder.owner, tokenAmount);

        // Update order states
        buyOrder.filledAmount += actualFillAmount;
        sellOrder.filledAmount += actualFillAmount;

        // Update order statuses and remove from queues if fully filled
        if (buyOrder.filledAmount == buyOrder.amount) {
            buyOrder.status = OrderStatus.Filled;
            emit OrderFulfilled(_match.buyOrderId, actualFillAmount);
        } else {
            emit OrderPartiallyFulfilled(
                _match.buyOrderId,
                actualFillAmount,
                buyOrder.amount - buyOrder.filledAmount
            );
        }

        if (sellOrder.filledAmount == sellOrder.amount) {
            sellOrder.status = OrderStatus.Filled;

            emit OrderFulfilled(_match.sellOrderId, actualFillAmount);
        } else {
            emit OrderPartiallyFulfilled(
                _match.sellOrderId,
                actualFillAmount,
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

    // /// @notice Removes an order from its queue
    // /// @param orderId The ID of the order to remove
    // /// @param queueKey The queue key where the order is stored
    // /// @dev Uses swap and pop pattern for efficient removal
    // function _removeOrderFromQueue(uint256 orderId, bytes32 queueKey) internal {
    //     uint256 position = orderQueuePositions[orderId];

    //     // If order is not in queue, do nothing
    //     if (
    //         position >= totalOrderCount[queueKey] ||
    //         orderQueues[queueKey][position] != orderId
    //     ) {
    //         return;
    //     }

    //     // If order is not the last one, swap with last and update position
    //     if (position != totalOrderCount[queueKey] - 1) {
    //         uint256 lastOrderId = orderQueues[queueKey][
    //             totalOrderCount[queueKey] - 1
    //         ];
    //         orderQueues[queueKey][position] = lastOrderId;
    //         orderQueuePositions[lastOrderId] = position;
    //     }

    //     // Remove the last element
    //     queue.pop();
    //     delete orderQueuePositions[orderId];
    // }

    /// @notice Adds an order to its appropriate queue
    /// @param orderId The ID of the order to add
    /// @param token The token address
    /// @param orderType The type of order (Buy/Sell)
    /// @param executionType The type of execution (Limit/Market)
    function _addOrderToQueue(
        uint256 orderId,
        address token,
        OrderType orderType,
        OrderExecutionType executionType
    ) internal {
        bytes32 queueKey = _getQueueKey(token, orderType, executionType);

        // Store the position of the order in the queue
        orderQueuePositions[orderId] = totalOrderCount[queueKey];
        orderQueues[queueKey][totalOrderCount[queueKey]] = orderId;
        totalOrderCount[queueKey] += 1;
    }

    /// @notice Emergency function to withdraw stuck tokens
    function emergencyWithdraw(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        if (token == address(0)) {
            require(
                amount <= address(this).balance,
                "Insufficient ETH balance"
            );
            (bool success, ) = to.call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}
