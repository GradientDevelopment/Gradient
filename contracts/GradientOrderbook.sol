// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGradientRegistry} from "./interfaces/IGradientRegistry.sol";
import {IGradientMarketMakerPool} from "./interfaces/IGradientMarketMakerPool.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router.sol";
import {IFallbackExecutor} from "./interfaces/IFallbackExecutor.sol";

/**
 * @title GradientOrderbook
 * @author Gradient Protocol
 * @notice A decentralized orderbook for trading ERC20 tokens against ETH
 * @dev This contract implements a traditional orderbook with limit and market orders.
 */
contract GradientOrderbook is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Registry contract for accessing other protocol contracts
    IGradientRegistry public gradientRegistry;

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

    /// @notice Divisor used for fee calculations (10000 = 100%)
    uint256 public constant DIVISOR = 10000;

    uint256 public minOrderSize;
    uint256 public maxOrderSize;
    uint256 public maxOrderTtl;

    /// @notice Percentage of fees distributed to market maker pool (in basis points)
    uint256 public mmFeeDistributionPercentage = 7000; // 70% default

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

    /// @notice Emitted when an order is fulfilled through matching
    event OrderFulfilledByMatching(
        uint256 indexed orderId,
        uint256 indexed matchedOrderId,
        uint256 amount,
        uint256 price
    );

    /// @notice Emitted when an order is fulfilled through market maker
    event OrderFulfilledByMarketMaker(
        uint256 indexed orderId,
        address indexed marketMakerPool,
        uint256 amount,
        uint256 price
    );

    /// @notice Emitted when fees are distributed to market maker pool
    event FeeDistributedToPool(
        address indexed marketMakerPool,
        address indexed token,
        uint256 epoch,
        uint256 amount,
        uint256 totalFee
    );

    /// @notice Emitted when MM fee distribution percentage is updated
    event MMFeeDistributionPercentageUpdated(
        uint256 oldPercentage,
        uint256 newPercentage
    );

    // Modifiers
    modifier onlyAuthorizedFulfiller() {
        require(
            gradientRegistry.isAuthorizedFulfiller(msg.sender),
            "Caller is not authorized"
        );
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
        // Check if token is blocked
        require(!gradientRegistry.blockedTokens(token), "Token is blocked");
        _;
    }

    constructor(IGradientRegistry _gradientRegistry) Ownable(msg.sender) {
        gradientRegistry = _gradientRegistry;
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

    /**
     * @notice Sets the gradient registry address
     * @param _gradientRegistry New gradient registry address
     * @dev Only callable by the contract owner
     */
    function setGradientRegistry(
        IGradientRegistry _gradientRegistry
    ) external onlyOwner {
        require(
            address(_gradientRegistry) != address(0),
            "Invalid gradient registry"
        );
        gradientRegistry = _gradientRegistry;
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

    /// @notice Sets the minimum and maximum order size limits
    /// @param _minOrderSize New minimum order size in ETH (wei)
    /// @param _maxOrderSize New maximum order size in ETH (wei)
    /// @dev Only callable by contract owner
    function setOrderSizeLimits(
        uint256 _minOrderSize,
        uint256 _maxOrderSize
    ) external onlyOwner {
        require(
            _minOrderSize < _maxOrderSize,
            "Min size must be less than max size"
        );
        minOrderSize = _minOrderSize;
        maxOrderSize = _maxOrderSize;
        emit OrderSizeLimitsUpdated(_minOrderSize, _maxOrderSize);
    }

    /// @notice Sets the maximum time-to-live for orders
    /// @param _maxOrderTtl New maximum TTL in seconds
    /// @dev Only callable by contract owner
    function setMaxOrderTtl(uint256 _maxOrderTtl) external onlyOwner {
        require(_maxOrderTtl > 0, "TTL must be greater than 0");
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

    /// @notice Gets the count of active orders for a given queue
    /// @param queueKey The queue key to count active orders for
    /// @return uint256 Number of active orders in the queue
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

    /// @notice Retrieves a paginated list of active orders for a given token, order type, and execution type
    /// @param token Address of the token
    /// @param orderType Type of orders to retrieve (Buy/Sell)
    /// @param executionType Type of execution (Limit/Market)
    /// @param startIndex Starting index for pagination
    /// @param count Number of orders to retrieve
    /// @return uint256[] Array of order IDs that are active and not expired
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
    /// @dev This function matches buy and sell orders against each other
    function fulfillLimitOrders(
        OrderMatch[] calldata matches
    ) external nonReentrant onlyAuthorizedFulfiller {
        require(matches.length > 0, "No order matches to fulfill");

        for (uint256 i = 0; i < matches.length; i++) {
            _fulfillLimitOrders(matches[i]);
        }
    }

    /// @notice Fulfills multiple matched market orders through order matching
    /// @param matches Array of OrderMatch structs containing match details
    /// @param executionPrices Array of execution prices for each match
    /// @dev Only whitelisted fulfillers can call this function
    /// @dev All orders in matches must be market orders
    /// @dev This function matches buy and sell orders against each other
    function fulfillMarketOrders(
        OrderMatch[] calldata matches,
        uint256[] calldata executionPrices
    ) external nonReentrant onlyAuthorizedFulfiller {
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
            "1 of the orders expired"
        );
        require(
            buyOrder.orderType == OrderType.Buy &&
                sellOrder.orderType == OrderType.Sell,
            "Invalid order types"
        );
        require(buyOrder.token == sellOrder.token, "Token mismatch");
        require(
            buyOrder.owner != sellOrder.owner,
            "Seller and buyer cannot be the same"
        );
        require(
            buyOrder.executionType == OrderExecutionType.Limit &&
                sellOrder.executionType == OrderExecutionType.Limit,
            "Not limit orders"
        );

        // Handle different fulfillment types
        _fulfillLimitOrdersMatching(_match);
    }

    /// @notice Internal function to fulfill limit orders through matching
    /// @param _match OrderMatch struct containing the match details
    function _fulfillLimitOrdersMatching(OrderMatch memory _match) internal {
        Order storage buyOrder = orders[_match.buyOrderId];
        Order storage sellOrder = orders[_match.sellOrderId];

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

        // Handle different fulfillment types
        _fulfillMarketOrdersMatching(_match, executionPrice);
    }

    /// @notice Internal function to fulfill market orders through matching
    /// @param _match OrderMatch struct containing the match details
    /// @param executionPrice The price at which the orders will be executed
    function _fulfillMarketOrdersMatching(
        OrderMatch memory _match,
        uint256 executionPrice
    ) internal {
        Order storage buyOrder = orders[_match.buyOrderId];
        Order storage sellOrder = orders[_match.sellOrderId];

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

    /// @notice Updates the MM fee distribution percentage
    /// @param newPercentage New MM fee distribution percentage in basis points
    /// @dev Only callable by contract owner
    function updateMMFeeDistributionPercentage(
        uint256 newPercentage
    ) external onlyOwner {
        require(newPercentage <= 10000, "Percentage too high");
        uint256 oldPercentage = mmFeeDistributionPercentage;
        mmFeeDistributionPercentage = newPercentage;
        emit MMFeeDistributionPercentageUpdated(oldPercentage, newPercentage);
    }

    /// @notice Fulfills multiple orders through the market maker pool
    /// @param orderIds Array of order IDs to fulfill
    /// @param fillAmounts Array of fill amounts for each order
    /// @dev Only whitelisted fulfillers can call this function
    function fulfillOrdersWithMarketMaker(
        uint256[] calldata orderIds,
        uint256[] calldata fillAmounts
    ) external nonReentrant onlyAuthorizedFulfiller {
        require(orderIds.length > 0, "No orders to fulfill");
        require(
            orderIds.length == fillAmounts.length,
            "Mismatched arrays length"
        );

        for (uint256 i = 0; i < orderIds.length; i++) {
            require(fillAmounts[i] > 0, "Fill amount must be greater than 0");
            _fulfillOrderWithMarketMaker(orderIds[i], fillAmounts[i]);
        }
    }

    /// @notice Internal function to fulfill a single order through the market maker pool
    /// @param orderId ID of the order to fulfill
    /// @param fillAmount Amount of tokens to fill
    function _fulfillOrderWithMarketMaker(
        uint256 orderId,
        uint256 fillAmount
    ) internal {
        Order storage order = orders[orderId];

        // Validate order
        require(order.status == OrderStatus.Active, "Order not active");
        require(!isOrderExpired(orderId), "Order expired");

        // Get market maker pool address from registry
        address marketMakerPool = gradientRegistry.marketMakerPool();
        require(marketMakerPool != address(0), "Market maker pool not set");

        // Calculate actual fill amount based on remaining amount
        uint256 remainingAmount = order.amount - order.filledAmount;
        uint256 actualFillAmount = fillAmount > remainingAmount
            ? remainingAmount
            : fillAmount;

        require(actualFillAmount > 0, "No amount to fill");

        // Calculate payment amount and fees
        uint256 paymentAmount = (actualFillAmount * order.price) / 1e18;

        if (order.orderType == OrderType.Buy) {
            // Buy order from order to get tokens from market maker pool
            uint256 epoch = IGradientMarketMakerPool(marketMakerPool)
                .getCurrentTokenEpoch(order.token);
            // For buy orders: orderbook sends ETH to market maker, receives tokens
            // Execute buy order - Orderbook sends ETH, receives tokens
            IGradientMarketMakerPool(marketMakerPool).executeBuyOrder{
                value: paymentAmount
            }(order.token, paymentAmount, actualFillAmount);

            // Distribute market maker fee from already collected fees
            uint256 fee = (paymentAmount * feePercentage) / DIVISOR;
            uint256 feeForPool = (fee * mmFeeDistributionPercentage) / DIVISOR;
            totalFeesCollected -= feeForPool;
            if (feeForPool > 0) {
                IGradientMarketMakerPool(marketMakerPool).distributePoolFee{
                    value: feeForPool
                }(order.token, epoch, false);
                emit FeeDistributedToPool(
                    marketMakerPool,
                    order.token,
                    epoch,
                    feeForPool,
                    fee
                );
            }
            IERC20(order.token).safeTransfer(order.owner, actualFillAmount);
        } else {
            // Sell order from order to get ETH from market maker pool
            uint256 epoch = IGradientMarketMakerPool(marketMakerPool)
                .getCurrentETHEpoch(order.token);
            // Approve tokens to market maker pool
            IERC20(order.token).approve(marketMakerPool, actualFillAmount);

            // Execute sell order - Orderbook sends tokens, receives ETH
            IGradientMarketMakerPool(marketMakerPool).executeSellOrder(
                order.token,
                paymentAmount,
                actualFillAmount
            );

            // Collect fee from ETH received
            uint256 fee = _collectFee(paymentAmount);
            uint256 finalPayment = paymentAmount - fee;

            // Distribute fees to market maker pool
            uint256 feeForPool = (fee * mmFeeDistributionPercentage) / DIVISOR;
            totalFeesCollected -= feeForPool;
            if (feeForPool > 0) {
                IGradientMarketMakerPool(marketMakerPool).distributePoolFee{
                    value: feeForPool
                }(order.token, epoch, true); // Distribute to ETH pool for sell orders
                emit FeeDistributedToPool(
                    marketMakerPool,
                    order.token,
                    epoch,
                    feeForPool,
                    fee
                );
            }

            // Transfer ETH to seller (minus fee)
            (bool success, ) = order.owner.call{value: finalPayment}("");
            require(success, "ETH transfer to seller failed");
        }

        // Update order state
        order.filledAmount += actualFillAmount;

        // Update order status
        if (order.filledAmount == order.amount) {
            order.status = OrderStatus.Filled;
            emit OrderFulfilled(orderId, actualFillAmount);
        } else {
            emit OrderPartiallyFulfilled(
                orderId,
                actualFillAmount,
                order.amount - order.filledAmount
            );
        }

        emit OrderFulfilledByMarketMaker(
            orderId,
            marketMakerPool,
            actualFillAmount,
            order.price
        );
    }

    /// @notice Allows users to fulfill their own order via AMM
    /// @param orderId ID of the order to fulfill
    /// @param fillAmount Amount of tokens to fill
    /// @param minAmountOut Minimum amount to receive (slippage protection)
    /// @dev Only the order owner can call this function
    /// @dev Uses FallbackExecutor to find the best DEX and execute the trade
    function fulfillOwnOrderWithAMM(
        uint256 orderId,
        uint256 fillAmount,
        uint256 minAmountOut
    ) external nonReentrant orderExists(orderId) onlyOrderOwner(orderId) {
        require(fillAmount > 0, "Fill amount must be greater than 0");

        Order storage order = orders[orderId];
        require(order.status == OrderStatus.Active, "Order not active");

        // Calculate actual fill amount based on remaining amount
        uint256 remainingAmount = order.amount - order.filledAmount;
        uint256 actualFillAmount = fillAmount > remainingAmount
            ? remainingAmount
            : fillAmount;
        require(actualFillAmount > 0, "No amount to fill");

        // Calculate payment amount and fees
        uint256 paymentAmount = (actualFillAmount * order.price) / 1e18;

        // Get FallbackExecutor from registry
        address fallbackExecutor = gradientRegistry.fallbackExecutor();
        require(fallbackExecutor != address(0), "FallbackExecutor not set");

        // Execute trade through FallbackExecutor
        if (order.orderType == OrderType.Buy) {
            // Execute the buy trade directly through FallbackExecutor
            uint256 tokensReceived = IFallbackExecutor(fallbackExecutor)
                .executeTrade{value: paymentAmount}(
                order.token,
                paymentAmount,
                minAmountOut,
                true // isBuy = true
            );

            // Transfer all received tokens to order owner
            IERC20(order.token).safeTransfer(order.owner, tokensReceived);
        } else {
            // Approve tokens to FallbackExecutor
            IERC20(order.token).approve(fallbackExecutor, actualFillAmount);

            // Execute the sell trade
            uint256 ethReceived = IFallbackExecutor(fallbackExecutor)
                .executeTrade(
                    order.token,
                    actualFillAmount,
                    minAmountOut,
                    false // isBuy = false
                );

            uint256 ammFee = _collectFee(ethReceived);

            // Transfer received ETH to order owner (minus fee)
            uint256 ethForUser = ethReceived - ammFee;
            (bool success, ) = order.owner.call{value: ethForUser}("");
            require(success, "ETH transfer to seller failed");
        }
        order.filledAmount += actualFillAmount;

        // Update order status
        if (order.filledAmount == order.amount) {
            order.status = OrderStatus.Filled;
            emit OrderFulfilled(orderId, actualFillAmount);
        } else {
            emit OrderPartiallyFulfilled(
                orderId,
                actualFillAmount,
                order.amount - order.filledAmount
            );
        }
    }
}
