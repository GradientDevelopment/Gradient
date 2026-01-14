// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGradientRegistry} from "./interfaces/IGradientRegistry.sol";
import {IGradientMarketMakerPoolV3} from "./interfaces/IGradientMarketMakerPoolV3.sol";
import {IGradientFeeManager} from "./interfaces/IGradientFeeManager.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router.sol";
import {IFallbackExecutor} from "./interfaces/IFallbackExecutor.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IUniswapV2Factory} from "./interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IUniswapV3Factory} from "./interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {IUniswapV3PriceHelper} from "./interfaces/IUniswapV3PriceHelper.sol";
import {GradientMarketMakerFactory} from "./GradientMarketMakerFactory.sol";

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

    /// @notice Fee manager contract for handling fee distribution
    IGradientFeeManager public feeManager;

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
        uint256 ethAmount; // Amount of ETH committed for buy orders
        uint256 ethSpent; // Actual ETH spent so far (for buy market orders)
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

    /// @notice Default fee percentage charged on all trades (in basis points, 1 = 0.01%)
    uint256 public defaultFeePercentage;

    /// @notice Token-specific fee percentages (in basis points, 1 = 0.01%)
    /// @dev Default is 100 basis points (1%) for all tokens
    mapping(address => uint256) public tokenSpecificFeePercentage;

    /// @notice Maximum fee percentage that can be set (in basis points)
    uint256 public constant MAX_FEE_PERCENTAGE = 500; // 5%

    /// @notice Minimum fee percentage that can be set (in basis points)
    uint256 public constant MIN_FEE_PERCENTAGE = 50; // 0.5%

    /// @notice Maximum token-specific fee percentage (in basis points)
    uint256 public constant MAX_TOKEN_SPECIFIC_FEE_PERCENTAGE = 300; // 3%

    /// @notice Mapping from order ID to Order struct
    mapping(uint256 => Order) public orders;

    /// @notice Mapping from token pair + order type + execution type hash to array of order IDs
    /// @dev Key is keccak256(abi.encodePacked(token, orderType, executionType))
    mapping(bytes32 => uint256) public totalOrderCount;
    mapping(bytes32 => uint256) public headOrder;
    mapping(bytes32 => uint256) public tailOrder;
    struct LinkedOrder {
        uint256 prev;
        uint256 next;
        bool exists;
    }
    mapping(bytes32 => mapping(uint256 => LinkedOrder)) public linkedOrders;

    /// @notice Mapping from order ID to its position in the queue
    /// @dev Used for efficient removal of orders from queues
    mapping(uint256 => uint256) private orderQueuePositions;

    /// @notice Divisor used for fee calculations (10000 = 100%)
    uint256 public constant DIVISOR = 10000;

    uint256 public minOrderSize;
    uint256 public maxOrderSize;
    uint256 public maxOrderTtl;

    /// @notice Maximum allowed price deviation from market price (in basis points, 1 = 0.01%)
    uint256 public maxPriceDeviation = 500; // 5% default

    /// @notice Dust tolerance for automatic order fulfillment (in basis points, 1 = 0.01%)
    uint256 public dustTolerance = 100; // 1% default

    /// @notice Uniswap V3 Factory address for accessing V3 pools
    address public uniswapV3Factory;

    /// @notice Uniswap V3 Price Helper contract for price calculations
    IUniswapV3PriceHelper public uniswapV3PriceHelper;

    /// @notice Common fee tiers for Uniswap V3 (500 = 0.05%, 3000 = 0.3%, 10000 = 1%)
    uint24[] public v3FeeTiers = [500, 3000, 10000];

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
        uint256 totalCost,
        string objectId,
        bool isAutofallback
    );

    /// @notice Emitted when an order is cancelled by its owner
    event OrderCancelled(uint256 indexed orderId);

    /// @notice Emitted when an order expires
    event OrderExpired(uint256 indexed orderId);

    /// @notice Emitted when an order is completely filled
    event OrderFulfilled(
        uint256 indexed orderId,
        uint256 amount,
        uint256 totalFilledAmount,
        uint256 executionPrice
    );

    /// @notice Emitted when an order is partially filled
    event OrderPartiallyFulfilled(
        uint256 indexed orderId,
        uint256 amount,
        uint256 remaining,
        uint256 totalFilledAmount,
        uint256 executionPrice
    );

    /// @notice Emitted when default fee percentage is updated
    event DefaultFeePercentageUpdated(
        uint256 oldFeePercentage,
        uint256 newFeePercentage
    );

    /// @notice Emitted when token-specific fee percentage is updated
    event TokenSpecificFeePercentageUpdated(
        address indexed token,
        uint256 oldFeePercentage,
        uint256 newFeePercentage
    );

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
        uint256 amount,
        uint256 totalFee
    );

    /// @notice Emitted when max price deviation is updated
    event MaxPriceDeviationUpdated(uint256 oldDeviation, uint256 newDeviation);

    /// @notice Emitted when dust tolerance is updated
    event DustToleranceUpdated(uint256 oldTolerance, uint256 newTolerance);

    /// @notice Emitted when Uniswap V3 Factory is updated
    event UniswapV3FactoryUpdated(
        address indexed oldFactory,
        address indexed newFactory
    );

    /// @notice Emitted when Uniswap V3 Price Helper is updated
    event UniswapV3PriceHelperUpdated(address indexed priceHelper);

    /// @notice Emitted when V3 fee tiers are updated
    event V3FeeTiersUpdated(uint24[] feeTiers);

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

    modifier validateMarketOrderPrice(uint256 orderId, uint256 executionPrice) {
        Order memory order = orders[orderId];

        if (order.executionType == OrderExecutionType.Market) {
            if (order.orderType == OrderType.Buy) {
                require(
                    executionPrice <= order.price,
                    "Execution price exceeds buyer's max price"
                );
            } else {
                require(
                    executionPrice >= order.price,
                    "Execution price below seller's min price"
                );
            }
        }

        if (order.executionType == OrderExecutionType.Limit) {
            require(
                executionPrice == order.price,
                "Execution price not matched with order price."
            );
        }
        _;
    }

    constructor(IGradientRegistry _gradientRegistry) Ownable(msg.sender) {
        gradientRegistry = _gradientRegistry;
        // feeManager will be set via setGradientRegistry after deployment
        defaultFeePercentage = 100; // 1% default fee for all trades

        minOrderSize = 1000000000000; // 0.000001 ETH
        maxOrderSize = 1000 ether;
        maxOrderTtl = 30 days;
    }

    receive() external payable {}

    fallback() external payable {}

    /// @notice Internal function to calculate and collect ETH fees
    /// @param amount Amount in ETH to calculate fee from
    /// @param token Token address for potential token-specific fee
    /// @return uint256 Fee amount collected
    function _collectEthFee(
        uint256 amount,
        address token
    ) internal returns (uint256) {
        // Use token-specific fee if set, otherwise use default fee
        uint256 feePercentage = getCurrentFeePercentage(token);

        uint256 feeAmount = (amount * feePercentage) / DIVISOR;
        if (feeAmount > 0) {
            // Transfer ETH to feeManager and track
            feeManager.collectEthFee{value: feeAmount}(feeAmount, token);
        }
        return feeAmount;
    }

    /// @notice Internal function to calculate and collect token fees
    /// @param amount Amount in tokens to calculate fee from
    /// @param token Token address
    /// @return uint256 Fee amount collected
    function _collectTokenFee(
        uint256 amount,
        address token
    ) internal returns (uint256) {
        // Use token-specific fee if set, otherwise use default fee
        uint256 feePercentage = getCurrentFeePercentage(token);

        uint256 feeAmount = (amount * feePercentage) / DIVISOR;
        if (feeAmount > 0) {
            // Transfer tokens to feeManager
            IERC20(token).safeTransfer(address(feeManager), feeAmount);
            // Track the fee in feeManager
            feeManager.collectTokenFee(feeAmount, token);
        }
        return feeAmount;
    }

    /// @notice Internal function to distribute market maker fees according to new split logic
    /// @param totalFee Total fee amount to distribute
    /// @param token Token address for partner token check
    /// @param marketMakerPool Market maker pool address for distribution
    function _distributeMarketMakerTokenFees(
        uint256 totalFee,
        address token,
        address marketMakerPool
    ) internal {
        feeManager.distributeMarketMakerTokenFees(
            totalFee,
            token,
            marketMakerPool
        );
    }

    /// @notice Internal function to distribute market maker ETH fees according to new split logic
    /// @param totalFee Total ETH fee amount to distribute
    /// @param token Token address for partner token check
    /// @param marketMakerPool Market maker pool address for distribution
    function _distributeMarketMakerEthFees(
        uint256 totalFee,
        address token,
        address marketMakerPool
    ) internal {
        feeManager.distributeMarketMakerEthFees{value: totalFee}(
            totalFee,
            token,
            marketMakerPool
        );
    }

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

        linkedOrders[queueKey][orderId] = LinkedOrder({
            prev: tailOrder[queueKey],
            next: 0,
            exists: true
        });

        if (tailOrder[queueKey] != 0) {
            linkedOrders[queueKey][tailOrder[queueKey]].next = orderId;
        } else {
            headOrder[queueKey] = orderId;
        }

        tailOrder[queueKey] = orderId;

        // Store the position of the order in the queue
        orderQueuePositions[orderId] = totalOrderCount[queueKey];
        totalOrderCount[queueKey] += 1;
    }

    function _removeOrderFromLinkedQueue(
        bytes32 queueKey,
        uint256 orderId
    ) internal {
        LinkedOrder storage node = linkedOrders[queueKey][orderId];
        require(node.exists, "Order not in queue");

        if (node.prev != 0) {
            linkedOrders[queueKey][node.prev].next = node.next;
        } else {
            headOrder[queueKey] = node.next;
        }

        if (node.next != 0) {
            linkedOrders[queueKey][node.next].prev = node.prev;
        } else {
            tailOrder[queueKey] = node.prev;
        }

        delete linkedOrders[queueKey][orderId];
    }

    /// @notice Creates a new order in the orderbook
    /// @param orderType Type of order (Buy/Sell)
    /// @param executionType Type of execution (Limit/Market)
    /// @param token Address of the token to trade
    /// @param amount Amount of tokens to trade
    /// @param price For limit orders: exact price, For market orders: max price (buy) or min price (sell)
    /// @param ttl Time-to-live in seconds for the order
    /// @param objectId Optional object ID for tracking
    /// @param isAutofallback Whether this is an autofallback order
    /// @dev For buy orders, requires ETH to be sent with the transaction
    /// @dev For sell orders, requires token approval
    /// @return uint256 ID of the created order
    function createOrder(
        OrderType orderType,
        OrderExecutionType executionType,
        address token,
        uint256 amount,
        uint256 price,
        uint256 ttl,
        string memory objectId,
        bool isAutofallback
    ) external payable validToken(token) nonReentrant returns (uint256) {
        require(amount > 0, "Amount must be greater than 0");
        require(price > 0, "Invalid price range");
        require(ttl > 0, "TTL must be greater than 0");
        require(ttl <= maxOrderTtl, "TTL too long");

        // Normalize token amount to 18 decimals for consistent price calculations
        uint256 normalizedAmount = normalizeTo18Decimals(amount, token);

        require(
            normalizedAmount <= type(uint256).max / price,
            "Price calculation would overflow"
        );
        uint256 totalCost = (normalizedAmount * price) / 1e18;
        require(totalCost >= minOrderSize, "Order too small");
        require(totalCost <= maxOrderSize, "Order too large");

        if (orderType == OrderType.Buy) {
            require(msg.value >= totalCost, "Insufficient ETH sent");
        } else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }

        uint256 orderId = _orderIdCounter++;
        uint256 expirationTime = block.timestamp + ttl;

        orders[orderId] = Order({
            orderId: orderId,
            owner: msg.sender,
            orderType: orderType,
            executionType: executionType,
            token: token,
            amount: normalizedAmount, // Store normalized amount for calculations
            price: price,
            ethAmount: (orderType == OrderType.Buy) ? totalCost : 0,
            ethSpent: 0,
            filledAmount: 0,
            expirationTime: expirationTime,
            status: OrderStatus.Active
        });

        _addOrderToQueue(orderId, token, orderType, executionType);

        emit OrderCreated(
            orderId,
            msg.sender,
            orderType,
            executionType,
            token,
            amount, // Emit original amount for transparency
            price,
            expirationTime,
            totalCost,
            objectId,
            isAutofallback
        );

        if (orderType == OrderType.Buy && msg.value > totalCost) {
            (bool success, ) = msg.sender.call{value: msg.value - totalCost}(
                ""
            );
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
        if (order.orderType == OrderType.Buy) {
            uint256 refundAmount;
            if (order.executionType == OrderExecutionType.Market) {
                refundAmount = order.ethAmount > order.ethSpent
                    ? (order.ethAmount - order.ethSpent)
                    : 0;
            } else {
                uint256 remainingAmount = order.amount > order.filledAmount
                    ? (order.amount - order.filledAmount)
                    : 0;
                refundAmount = (remainingAmount * order.price) / 1e18;
            }
            if (refundAmount > 0) {
                require(
                    address(this).balance >= refundAmount,
                    "Insufficient ETH in contract"
                );
                (bool success, ) = order.owner.call{value: refundAmount}("");
                require(success, "ETH refund failed");
            }
        } else {
            uint256 remainingAmount = order.amount > order.filledAmount
                ? (order.amount - order.filledAmount)
                : 0;
            if (remainingAmount > 0) {
                uint256 actualRemainingAmount = denormalizeFrom18Decimals(
                    remainingAmount,
                    order.token
                );
                IERC20(order.token).safeTransfer(
                    order.owner,
                    actualRemainingAmount
                );
            }
        }

        bytes32 queueKey = _getQueueKey(
            order.token,
            order.orderType,
            order.executionType
        );
        _removeOrderFromLinkedQueue(queueKey, orderId);

        emit OrderCancelled(orderId);
    }

    /// @notice Marks multiple expired orders as expired and handles refunds
    /// @param orderIds Array of IDs of expired orders to clean up
    /// @dev Anyone can call this function for expired orders
    /// @dev Refunds tokens for unfilled sell orders and ETH for unfilled buy orders
    /// @dev More gas efficient than calling cleanupExpiredOrder multiple times
    function cleanupExpiredOrders(
        uint256[] memory orderIds
    ) external nonReentrant {
        require(orderIds.length > 0, "No orders to clean up");
        require(orderIds.length <= 100, "Too many orders to clean up at once");

        for (uint256 i = 0; i < orderIds.length; i++) {
            uint256 orderId = orderIds[i];

            // Check if order exists
            require(
                orders[orderId].owner != address(0),
                "Order does not exist"
            );

            Order storage order = orders[orderId];
            require(order.status == OrderStatus.Active, "Order not active");
            require(isOrderExpired(orderId), "Order not expired");

            order.status = OrderStatus.Expired;

            if (order.orderType == OrderType.Sell) {
                uint256 remainingAmount = order.amount > order.filledAmount
                    ? (order.amount - order.filledAmount)
                    : 0;
                if (remainingAmount > 0) {
                    // Denormalize the remaining amount back to token decimals
                    uint256 actualRemainingAmount = denormalizeFrom18Decimals(
                        remainingAmount,
                        order.token
                    );
                    IERC20(order.token).safeTransfer(
                        order.owner,
                        actualRemainingAmount
                    );
                }
            }

            if (order.orderType == OrderType.Buy) {
                uint256 refundAmount;
                if (order.executionType == OrderExecutionType.Market) {
                    refundAmount = order.ethAmount > order.ethSpent
                        ? (order.ethAmount - order.ethSpent)
                        : 0;
                } else {
                    uint256 remainingAmount = order.amount > order.filledAmount
                        ? (order.amount - order.filledAmount)
                        : 0;
                    refundAmount = (remainingAmount * order.price) / 1e18;
                }
                if (refundAmount > 0) {
                    require(
                        address(this).balance >= refundAmount,
                        "Insufficient ETH in contract"
                    );
                    (bool success, ) = payable(order.owner).call{
                        value: refundAmount
                    }("");
                    require(success, "ETH refund failed");
                }
            }

            bytes32 queueKey = _getQueueKey(
                order.token,
                order.orderType,
                order.executionType
            );
            _removeOrderFromLinkedQueue(queueKey, orderId);

            emit OrderExpired(orderId);
        }
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

        uint256 buyRemaining = buyOrder.amount > buyOrder.filledAmount
            ? (buyOrder.amount - buyOrder.filledAmount)
            : 0;
        uint256 sellRemaining = sellOrder.amount > sellOrder.filledAmount
            ? (sellOrder.amount - sellOrder.filledAmount)
            : 0;
        uint256 actualFillAmount = _match.fillAmount;

        if (actualFillAmount > buyRemaining) {
            actualFillAmount = buyRemaining;
        }
        if (actualFillAmount > sellRemaining) {
            actualFillAmount = sellRemaining;
        }

        require(actualFillAmount > 0, "No amount to fill");

        uint256 tokenAmount = actualFillAmount;
        uint256 paymentAmount = (actualFillAmount * sellOrder.price) / 1e18; // Use sell price for limit orders

        // Calculate fees from receiving amounts
        uint256 buyerFee = _collectEthFee(paymentAmount, sellOrder.token); // ETH fee from buyer's payment
        uint256 sellerFee = _collectTokenFee(tokenAmount, sellOrder.token); // Token fee from seller's tokens

        // Transfer ETH to seller (buyer pays ETH fee)
        uint256 sellerPayment = paymentAmount - buyerFee;
        (bool success, ) = sellOrder.owner.call{value: sellerPayment}("");
        require(success, "ETH transfer to seller failed");

        // Transfer tokens to buyer (seller pays token fee)
        {
            uint256 actualTokenAmount = denormalizeFrom18Decimals(
                tokenAmount,
                sellOrder.token
            );
            uint256 actualTokenFee = denormalizeFrom18Decimals(
                sellerFee,
                sellOrder.token
            );
            IERC20(sellOrder.token).safeTransfer(
                buyOrder.owner,
                actualTokenAmount - actualTokenFee
            );
        }

        buyOrder.filledAmount += actualFillAmount;
        sellOrder.filledAmount += actualFillAmount;

        if (buyOrder.price > sellOrder.price) {
            uint256 savedAmount = (actualFillAmount *
                (buyOrder.price - sellOrder.price)) / 1e18;
            (success, ) = buyOrder.owner.call{value: savedAmount}("");
            require(success, "ETH savings return failed");
        }

        _updateOrderStatus(
            _match.buyOrderId,
            actualFillAmount,
            sellOrder.price
        );
        _updateOrderStatus(
            _match.sellOrderId,
            actualFillAmount,
            buyOrder.price
        );
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

        // Validate execution price against market price
        require(
            validateExecutionPrice(buyOrder.token, executionPrice),
            "Execution price deviates too much from market price"
        );

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

        uint256 buyRemaining = getBuyOrderRemainingAmount(
            buyOrder,
            executionPrice
        );
        uint256 sellRemaining = sellOrder.amount > sellOrder.filledAmount
            ? (sellOrder.amount - sellOrder.filledAmount)
            : 0;

        uint256 actualFillAmount = _match.fillAmount;
        if (actualFillAmount > buyRemaining) {
            actualFillAmount = buyRemaining;
        }
        if (actualFillAmount > sellRemaining) {
            actualFillAmount = sellRemaining;
        }

        require(actualFillAmount > 0, "No amount to fill");

        uint256 tokenAmount = actualFillAmount;
        uint256 paymentAmount = (actualFillAmount * executionPrice) / 1e18;

        // Calculate fees from receiving amounts
        uint256 buyerFee = _collectEthFee(paymentAmount, sellOrder.token); // ETH fee from buyer's payment
        uint256 sellerFee = _collectTokenFee(tokenAmount, sellOrder.token); // Token fee from seller's tokens

        // Transfer ETH to seller (buyer pays ETH fee)
        uint256 sellerPayment = paymentAmount - buyerFee;

        (bool success, ) = sellOrder.owner.call{value: sellerPayment}("");
        require(success, "ETH transfer to seller failed");

        {
            uint256 actualTokenAmount = denormalizeFrom18Decimals(
                tokenAmount,
                sellOrder.token
            );
            uint256 actualTokenFee = denormalizeFrom18Decimals(
                sellerFee,
                sellOrder.token
            );
            IERC20(sellOrder.token).safeTransfer(
                buyOrder.owner,
                actualTokenAmount - actualTokenFee
            );
        }

        buyOrder.filledAmount += actualFillAmount;
        // Track actual ETH spent for buy market orders
        if (
            buyOrder.orderType == OrderType.Buy &&
            buyOrder.executionType == OrderExecutionType.Market
        ) {
            buyOrder.ethSpent += paymentAmount;
        }
        sellOrder.filledAmount += actualFillAmount;

        _updateOrderStatus(_match.buyOrderId, actualFillAmount, executionPrice);
        _updateOrderStatus(
            _match.sellOrderId,
            actualFillAmount,
            executionPrice
        );
    }

    /// @notice Fulfills multiple orders through the market maker pool
    /// @param orderIds Array of order IDs to fulfill
    /// @param fillAmounts Array of fill amounts for each order
    /// @param executionPrices Array of execution prices for each order
    /// @param merkleRoot The merkle root to use for position updates
    /// @dev Only whitelisted fulfillers can call this function
    function fulfillOrdersWithMarketMaker(
        uint256[] calldata orderIds,
        uint256[] calldata fillAmounts,
        uint256[] calldata executionPrices,
        bytes32 merkleRoot
    ) external nonReentrant onlyAuthorizedFulfiller {
        require(orderIds.length > 0, "No orders to fulfill");
        require(
            orderIds.length == fillAmounts.length &&
                orderIds.length == executionPrices.length,
            "Mismatched arrays length"
        );

        for (uint256 i = 0; i < orderIds.length; i++) {
            require(fillAmounts[i] > 0, "Fill amount must be greater than 0");
            require(
                executionPrices[i] > 0,
                "Execution price must be greater than 0"
            );
            _fulfillOrderWithMarketMaker(
                orderIds[i],
                fillAmounts[i],
                executionPrices[i],
                merkleRoot
            );
        }
    }

    /// @notice Internal function to fulfill a single order through the market maker pool
    /// @param orderId ID of the order to fulfill
    /// @param fillAmount Amount of tokens to fill
    /// @param executionPrice The price at which the order will be executed
    /// @param merkleRoot The merkle root to use for position updates
    function _fulfillOrderWithMarketMaker(
        uint256 orderId,
        uint256 fillAmount,
        uint256 executionPrice,
        bytes32 merkleRoot
    ) internal validateMarketOrderPrice(orderId, executionPrice) {
        Order storage order = orders[orderId];

        // Validate order
        require(order.status == OrderStatus.Active, "Order not active");
        require(!isOrderExpired(orderId), "Order expired");

        // Validate execution price against market price
        require(
            validateExecutionPrice(order.token, executionPrice),
            "Execution price deviates too much from market price"
        );

        address marketMakerFactory = gradientRegistry.marketMakerFactory();
        require(
            marketMakerFactory != address(0),
            "Market maker factory not set"
        );

        address marketMakerPool = GradientMarketMakerFactory(marketMakerFactory)
            .getPool(order.token);
        require(
            marketMakerPool != address(0),
            "Market maker pool not found for token"
        );

        // Calculate actual fill amount based on remaining amount
        uint256 remainingAmount;
        if (
            order.orderType == OrderType.Buy &&
            order.executionType == OrderExecutionType.Market
        ) {
            remainingAmount = getBuyOrderRemainingAmount(order, executionPrice);
        } else {
            remainingAmount = order.amount > order.filledAmount
                ? (order.amount - order.filledAmount)
                : 0;
        }
        uint256 actualFillAmount = fillAmount > remainingAmount
            ? remainingAmount
            : fillAmount;

        require(actualFillAmount > 0, "No amount to fill");

        // Calculate payment amount and fees
        uint256 paymentAmount = (actualFillAmount * executionPrice) / 1e18;

        if (order.orderType == OrderType.Buy) {
            // Buy order from order to get tokens from market maker pool
            uint256 actualTokenAmount = denormalizeFrom18Decimals(
                actualFillAmount,
                order.token
            );

            // For buy orders: orderbook sends ETH to market maker, receives tokens
            IGradientMarketMakerPoolV3(marketMakerPool).executeBuyOrder{
                value: paymentAmount
            }(paymentAmount, actualTokenAmount, merkleRoot);

            // Calculate fee from received tokens and deduct from user
            uint256 tokenFee = (actualTokenAmount *
                (getCurrentFeePercentage(order.token))) / DIVISOR;
            uint256 netTokenAmount = actualTokenAmount - tokenFee;

            // Distribute fees using new market maker split logic (50% to market makers, 50% to teams)
            if (tokenFee > 0) {
                // Transfer fee tokens to feeManager
                IERC20(order.token).safeTransfer(address(feeManager), tokenFee);

                // Distribute according to the split
                _distributeMarketMakerTokenFees(
                    tokenFee,
                    order.token,
                    marketMakerPool
                );
            }

            IERC20(order.token).safeTransfer(order.owner, netTokenAmount);
        } else {
            // Denormalize the amount for token approval
            uint256 actualTokenAmount = denormalizeFrom18Decimals(
                actualFillAmount,
                order.token
            );

            // For sell orders: orderbook sends full tokens to market maker, receives ETH
            IERC20(order.token).approve(marketMakerPool, actualTokenAmount);

            // Execute sell order - Orderbook sends tokens, receives ETH
            IGradientMarketMakerPoolV3(marketMakerPool).executeSellOrder(
                paymentAmount,
                actualTokenAmount,
                merkleRoot
            );

            // Calculate fee from received ETH and deduct from user
            uint256 ethFee = (paymentAmount *
                (getCurrentFeePercentage(order.token))) / DIVISOR;
            uint256 netEthAmount = paymentAmount - ethFee;

            // Distribute fees using new market maker split logic (50% to market makers, 50% to teams)
            if (ethFee > 0) {
                // Distribute according to the split
                _distributeMarketMakerEthFees(
                    ethFee,
                    order.token,
                    marketMakerPool
                );
            }

            // Transfer ETH to seller (minus fee)
            (bool success, ) = order.owner.call{value: netEthAmount}("");
            require(success, "ETH transfer to seller failed");
        }

        // Update order state
        order.filledAmount += actualFillAmount;
        // Track actual ETH spent for buy market orders
        if (
            order.orderType == OrderType.Buy &&
            order.executionType == OrderExecutionType.Market
        ) {
            order.ethSpent += paymentAmount;
        }

        // Update order status
        _updateOrderStatus(orderId, actualFillAmount, executionPrice);

        emit OrderFulfilledByMarketMaker(
            orderId,
            marketMakerPool,
            actualFillAmount,
            executionPrice
        );
    }

    /// @notice Internal function to fulfill an order via AMM
    /// @param orderId ID of the order to fulfill
    /// @param fillAmount Amount of tokens to fill
    /// @param minAmountOut Minimum amount to receive (slippage protection)
    /// @dev Uses FallbackExecutor to find the best DEX and execute the trade
    function _fulfillOrderWithAMM(
        uint256 orderId,
        uint256 fillAmount,
        uint256 minAmountOut
    ) internal {
        require(fillAmount > 0, "Fill amount must be greater than 0");

        Order storage order = orders[orderId];
        require(order.status == OrderStatus.Active, "Order not active");

        // Calculate actual fill amount based on remaining amount
        uint256 remainingAmount;
        if (
            order.orderType == OrderType.Buy &&
            order.executionType == OrderExecutionType.Market
        ) {
            remainingAmount = getBuyOrderRemainingAmount(order, order.price);
        } else {
            remainingAmount = order.amount > order.filledAmount
                ? (order.amount - order.filledAmount)
                : 0;
        }
        uint256 actualFillAmount = fillAmount > remainingAmount
            ? remainingAmount
            : fillAmount;
        require(actualFillAmount > 0, "No amount to fill");

        // Get FallbackExecutor from registry
        address fallbackExecutor = gradientRegistry.fallbackExecutor();
        require(fallbackExecutor != address(0), "FallbackExecutor not set");

        // For buy orders, calculate how much ETH to send based on order type
        uint256 ethToSend;
        uint256 effectiveExecutionPrice;

        if (order.orderType == OrderType.Buy) {
            if (order.executionType == OrderExecutionType.Market) {
                // For market orders, send the remaining ETH (up to the fill amount)
                uint256 ethRemaining = order.ethAmount > order.ethSpent
                    ? (order.ethAmount - order.ethSpent)
                    : 0;
                ethToSend = ethRemaining;
            } else {
                // For limit orders, calculate based on order price
                ethToSend = (actualFillAmount * order.price) / 1e18;
            }

            // Execute the buy trade directly through FallbackExecutor with full ETH amount
            uint256 tokensReceived = IFallbackExecutor(fallbackExecutor)
                .executeTrade{value: ethToSend}(
                order.token,
                ethToSend,
                minAmountOut,
                true // isBuy = true
            );

            // Calculate fee from received tokens and deduct from user (buy order receives tokens)
            uint256 tokenFee = _collectTokenFee(tokensReceived, order.token);
            uint256 netTokenAmount = tokensReceived - tokenFee;

            // Transfer tokens to the buyer (minus fee)
            IERC20(order.token).safeTransfer(order.owner, netTokenAmount);

            // Calculate effective execution price for buy orders
            if (tokensReceived > 0) {
                effectiveExecutionPrice = (ethToSend * 1e18) / tokensReceived;
            } else {
                effectiveExecutionPrice = order.price; // Fallback to order price
            }
        } else {
            // Denormalize the amount for token approval and transfer
            uint256 actualTokenAmount = denormalizeFrom18Decimals(
                actualFillAmount,
                order.token
            );

            // Approve tokens to FallbackExecutor (approve the full amount)
            IERC20(order.token).approve(fallbackExecutor, actualTokenAmount);

            // Execute the sell trade with full amount
            uint256 ethReceived = IFallbackExecutor(fallbackExecutor)
                .executeTrade(
                    order.token,
                    actualTokenAmount,
                    minAmountOut,
                    false // isBuy = false
                );

            // Calculate fee from received ETH and deduct from user (sell order receives ETH)
            uint256 ethFee = _collectEthFee(ethReceived, order.token);
            uint256 netEthAmount = ethReceived - ethFee;
            (bool success, ) = order.owner.call{value: netEthAmount}("");
            require(success, "ETH transfer to seller failed");

            // Calculate effective execution price for sell orders
            if (actualFillAmount > 0) {
                effectiveExecutionPrice =
                    (ethReceived * 1e18) /
                    actualFillAmount;
            } else {
                effectiveExecutionPrice = order.price; // Fallback to order price
            }
        }
        order.filledAmount += actualFillAmount;
        // Track actual ETH spent for buy market orders
        if (
            order.orderType == OrderType.Buy &&
            order.executionType == OrderExecutionType.Market
        ) {
            order.ethSpent += ethToSend;
        }

        // Update order status
        _updateOrderStatus(orderId, actualFillAmount, effectiveExecutionPrice);
    }

    /// @notice Allows authorized fulfillers to automatically fulfill orders via AMM
    /// @param orderId ID of the order to fulfill
    /// @param fillAmount Amount of tokens to fill
    /// @param minAmountOut Minimum amount to receive (slippage protection)
    /// @dev Only authorized fulfillers can call this function
    /// @dev Uses FallbackExecutor to find the best DEX and execute the trade
    /// @dev This enables automatic order fulfillment so users don't need to manually fulfill their orders
    function autoFallbackOrderWithAMM(
        uint256 orderId,
        uint256 fillAmount,
        uint256 minAmountOut
    ) external nonReentrant orderExists(orderId) onlyAuthorizedFulfiller {
        _fulfillOrderWithAMM(orderId, fillAmount, minAmountOut);
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
        _fulfillOrderWithAMM(orderId, fillAmount, minAmountOut);
    }

    /// @notice Internal function to update order status
    /// @param orderId ID of the order to update
    /// @param actualFillAmount Amount of tokens/ETH that was filled
    /// @param executionPrice The price at which the order was executed
    function _updateOrderStatus(
        uint256 orderId,
        uint256 actualFillAmount,
        uint256 executionPrice
    ) internal {
        Order storage order = orders[orderId];
        // For buy market orders, check if all ETH is spent
        if (
            order.orderType == OrderType.Buy &&
            order.executionType == OrderExecutionType.Market
        ) {
            uint256 remainingEth = order.ethAmount > order.ethSpent
                ? (order.ethAmount - order.ethSpent)
                : 0;

            // Check if remaining ETH is below dust tolerance
            bool isDustRemaining = remainingEth > 0 &&
                (remainingEth * 10000) / order.ethAmount <= dustTolerance;

            if (order.ethSpent >= order.ethAmount || isDustRemaining) {
                order.status = OrderStatus.Filled;
                // If dust remaining, mark it as spent to prevent refund issues
                if (isDustRemaining) {
                    order.ethSpent = order.ethAmount;
                }
                bytes32 queueKey = _getQueueKey(
                    order.token,
                    order.orderType,
                    order.executionType
                );
                _removeOrderFromLinkedQueue(queueKey, orderId);
                emit OrderFulfilled(
                    orderId,
                    actualFillAmount,
                    order.ethSpent,
                    executionPrice
                );
            } else {
                emit OrderPartiallyFulfilled(
                    orderId,
                    actualFillAmount,
                    remainingEth,
                    order.ethSpent,
                    executionPrice
                );
            }
        } else {
            uint256 remainingAmount = order.amount > order.filledAmount
                ? (order.amount - order.filledAmount)
                : 0;

            // Check if remaining tokens are below dust tolerance
            bool isDustRemaining = remainingAmount > 0 &&
                (remainingAmount * 10000) / order.amount <= dustTolerance;

            if (order.filledAmount == order.amount || isDustRemaining) {
                order.status = OrderStatus.Filled;
                // If dust remaining, mark it as filled to prevent refund issues
                if (isDustRemaining) {
                    order.filledAmount = order.amount;
                }
                bytes32 queueKey = _getQueueKey(
                    order.token,
                    order.orderType,
                    order.executionType
                );
                _removeOrderFromLinkedQueue(queueKey, orderId);
                emit OrderFulfilled(
                    orderId,
                    actualFillAmount,
                    order.filledAmount,
                    executionPrice
                );
            } else {
                emit OrderPartiallyFulfilled(
                    orderId,
                    actualFillAmount,
                    remainingAmount,
                    order.filledAmount,
                    executionPrice
                );
            }
        }
    }

    // ========================== View Functions ==========================

    /// @notice Returns the current fee percentage for a token
    /// @param token Token address
    /// @return uint256 Fee percentage
    function getCurrentFeePercentage(
        address token
    ) public view returns (uint256) {
        return
            tokenSpecificFeePercentage[token] > 0
                ? tokenSpecificFeePercentage[token]
                : defaultFeePercentage;
    }

    /// @notice Helper function to get token decimals
    /// @param token The token address
    /// @return uint8 The number of decimals for the token
    function getTokenDecimals(address token) internal view returns (uint8) {
        return IERC20Metadata(token).decimals();
    }

    /// @notice Helper function to normalize token amount to 18 decimals
    /// @param amount The token amount in its native decimals
    /// @param token The token address
    /// @return uint256 The normalized amount in 18 decimals
    function normalizeTo18Decimals(
        uint256 amount,
        address token
    ) internal view returns (uint256) {
        uint8 decimals = getTokenDecimals(token);
        if (decimals == 18) {
            return amount;
        } else if (decimals < 18) {
            return amount * (10 ** (18 - decimals));
        } else {
            return amount / (10 ** (decimals - 18));
        }
    }

    /// @notice Helper function to denormalize from 18 decimals to token decimals
    /// @param amount The amount in 18 decimals
    /// @param token The token address
    /// @return uint256 The denormalized amount in token decimals
    function denormalizeFrom18Decimals(
        uint256 amount,
        address token
    ) internal view returns (uint256) {
        uint8 decimals = getTokenDecimals(token);
        if (decimals == 18) {
            return amount;
        } else if (decimals < 18) {
            return amount / (10 ** (18 - decimals));
        } else {
            return amount * (10 ** (decimals - 18));
        }
    }

    /// @notice Gets the count of active orders for a given queue
    /// @param queueKey The queue key to count active orders for
    /// @return uint256 Number of active orders in the queue
    function getActiveOrdersCount(
        bytes32 queueKey
    ) public view returns (uint256) {
        uint256 activeCount = 0;
        uint256 currentOrderId = headOrder[queueKey];

        while (currentOrderId != 0) {
            Order storage order = orders[currentOrderId];
            if (
                order.status == OrderStatus.Active &&
                !isOrderExpired(currentOrderId)
            ) {
                activeCount++;
            }

            currentOrderId = linkedOrders[queueKey][currentOrderId].next;
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
        uint256[] memory activeOrders = new uint256[](activeCount);
        uint256 currentOrderId = headOrder[queueKey];
        uint256 currentIndex = 0;

        while (currentOrderId != 0 && currentIndex < activeCount) {
            Order storage order = orders[currentOrderId];
            if (
                order.status == OrderStatus.Active &&
                !isOrderExpired(currentOrderId)
            ) {
                activeOrders[currentIndex] = currentOrderId;
                currentIndex++;
            }

            currentOrderId = linkedOrders[queueKey][currentOrderId].next;
        }

        return activeOrders;
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

    /// @notice Checks if an order has expired
    /// @param orderId ID of the order to check
    /// @return bool True if the order has expired, false otherwise
    function isOrderExpired(
        uint256 orderId
    ) public view orderExists(orderId) returns (bool) {
        return block.timestamp > orders[orderId].expirationTime;
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
        if (
            order.orderType == OrderType.Buy &&
            order.executionType == OrderExecutionType.Market
        ) {
            // For market buy orders, return remaining ETH
            return
                order.ethAmount > order.ethSpent
                    ? (order.ethAmount - order.ethSpent)
                    : 0;
        } else {
            // For other orders, return remaining tokens
            return
                order.amount > order.filledAmount
                    ? (order.amount - order.filledAmount)
                    : 0;
        }
    }

    // ========================== Internal Helper Functions ==========================
    /// @notice Calculates the remaining buyable token amount for a buy order
    /// @param order The order struct (storage pointer)
    /// @param executionPrice The price at which the order is being filled
    /// @return uint256 The remaining amount of tokens that can be bought
    function getBuyOrderRemainingAmount(
        Order storage order,
        uint256 executionPrice
    ) internal view returns (uint256) {
        if (
            order.executionType == OrderExecutionType.Market &&
            order.orderType == OrderType.Buy
        ) {
            uint256 ethRemaining = order.ethAmount > order.ethSpent
                ? (order.ethAmount - order.ethSpent)
                : 0;
            return (ethRemaining * 1e18) / executionPrice;
        } else {
            return
                order.amount > order.filledAmount
                    ? (order.amount - order.filledAmount)
                    : 0;
        }
    }

    // ========================== Admin Functions ==========================

    /// @notice Sets the default fee percentage for all trades
    /// @param newFeePercentage New fee percentage in basis points (1 = 0.01%)
    /// @dev Only callable by contract owner
    function setDefaultFeePercentage(
        uint256 newFeePercentage
    ) external onlyOwner {
        require(
            newFeePercentage <= MAX_FEE_PERCENTAGE,
            "Fee percentage too high"
        );
        uint256 oldFeePercentage = defaultFeePercentage;
        defaultFeePercentage = newFeePercentage;
        emit DefaultFeePercentageUpdated(oldFeePercentage, newFeePercentage);
    }

    /// @notice Sets the token-specific fee percentage for a given token
    /// @param token Token address to set fee for
    /// @param newFeePercentage New fee percentage in basis points (1 = 0.01%)
    /// @dev Only callable by contract owner. Fee must be between 0.5% and 3%
    function setTokenSpecificFeePercentage(
        address token,
        uint256 newFeePercentage
    ) external onlyOwner {
        require(token != address(0), "Invalid token address");
        require(
            newFeePercentage >= MIN_FEE_PERCENTAGE,
            "Fee percentage too low"
        );
        require(
            newFeePercentage <= MAX_TOKEN_SPECIFIC_FEE_PERCENTAGE,
            "Fee percentage too high"
        );
        uint256 oldFeePercentage = tokenSpecificFeePercentage[token];
        tokenSpecificFeePercentage[token] = newFeePercentage;
        emit TokenSpecificFeePercentageUpdated(
            token,
            oldFeePercentage,
            newFeePercentage
        );
    }

    /// @notice Removes token-specific fee percentage for a given token (reverts to default)
    /// @param token Token address to remove specific fee for
    /// @dev Only callable by contract owner. Sets token-specific fee to 0, so it uses default
    function removeTokenSpecificFeePercentage(
        address token
    ) external onlyOwner {
        require(token != address(0), "Invalid token address");
        uint256 oldFeePercentage = tokenSpecificFeePercentage[token];
        require(oldFeePercentage > 0, "No specific fee set for this token");
        tokenSpecificFeePercentage[token] = 0;
        emit TokenSpecificFeePercentageUpdated(token, oldFeePercentage, 0);
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
        feeManager = IGradientFeeManager(_gradientRegistry.feeManager());
    }

    /**
     * @notice Sets the fee manager address
     * @param _feeManager New fee manager address
     * @dev Only callable by the contract owner
     */
    function setFeeManager(IGradientFeeManager _feeManager) external onlyOwner {
        require(address(_feeManager) != address(0), "Invalid fee manager");
        feeManager = _feeManager;
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

    /// @notice Updates the dust tolerance
    /// @param newDustTolerance New dust tolerance in basis points (1 = 0.01%)
    /// @dev Only callable by contract owner
    function updateDustTolerance(uint256 newDustTolerance) external onlyOwner {
        require(newDustTolerance <= 10000, "Dust tolerance too high");
        uint256 oldDustTolerance = dustTolerance;
        dustTolerance = newDustTolerance;
        emit DustToleranceUpdated(oldDustTolerance, newDustTolerance);
    }

    /// @notice Gets the current market price from Uniswap for a token (checks V3 first, then V2)
    /// @param token Address of the token
    /// @return marketPrice Current market price in ETH (18 decimals)
    function getCurrentMarketPrice(
        address token
    ) public view returns (uint256 marketPrice) {
        // Try V3 first if price helper is set
        if (address(uniswapV3PriceHelper) != address(0)) {
            address routerAddress = gradientRegistry.router();
            if (routerAddress != address(0)) {
                uint8 decimals = IERC20Metadata(token).decimals();
                uint256 v3Price = uniswapV3PriceHelper.getPriceFromV3(
                    token,
                    IUniswapV2Router02(routerAddress).WETH(),
                    decimals
                );
                if (v3Price > 0) {
                    return v3Price;
                }
            }
        }

        // Fall back to V2
        uint256 v2Price = getPriceFromV2(token);
        require(v2Price > 0, "No liquidity available in V2 or V3");
        return v2Price;
    }

    /// @notice Validates execution price against current market price
    /// @param token Address of the token
    /// @param executionPrice Execution price to validate
    /// @return bool True if price is within acceptable deviation
    function validateExecutionPrice(
        address token,
        uint256 executionPrice
    ) public view returns (bool) {
        // Skip validation for v3 pairs
        if (address(uniswapV3PriceHelper) != address(0)) {
            address routerAddress = gradientRegistry.router();
            if (routerAddress != address(0)) {
                try
                    uniswapV3PriceHelper.getV3PoolAddress(
                        token,
                        IUniswapV2Router02(routerAddress).WETH()
                    )
                returns (address v3Pool) {
                    if (v3Pool != address(0)) {
                        return true; // v3 pair exists - bypass validation
                    }
                } catch {}
            }
        }

        uint256 marketPrice = getCurrentMarketPrice(token);

        // Handle edge cases
        if (marketPrice == 0) {
            return false; // Cannot validate against zero market price
        }

        if (executionPrice == marketPrice) {
            return true; // Exact match is always valid
        }

        // Calculate price deviation with improved precision
        uint256 deviation;
        if (executionPrice > marketPrice) {
            // Calculate percentage above market price
            // deviation = ((executionPrice - marketPrice) * 10000) / marketPrice
            uint256 priceDifference = executionPrice - marketPrice;

            // Check for overflow in multiplication
            require(
                priceDifference <= type(uint256).max / 10000,
                "Price difference too large"
            );

            deviation = (priceDifference * 10000) / marketPrice;
        } else {
            // Calculate percentage below market price
            // deviation = ((marketPrice - executionPrice) * 10000) / marketPrice
            uint256 priceDifference = marketPrice - executionPrice;

            // Check for overflow in multiplication
            require(
                priceDifference <= type(uint256).max / 10000,
                "Price difference too large"
            );

            deviation = (priceDifference * 10000) / marketPrice;
        }

        return deviation <= maxPriceDeviation;
    }

    /// @notice Gets the reserves for a token pair from Uniswap V2
    /// @param token Address of the token
    /// @return reserveETH ETH reserve amount
    /// @return reserveToken Token reserve amount
    function getReserves(
        address token
    ) public view returns (uint256 reserveETH, uint256 reserveToken) {
        address routerAddress = gradientRegistry.router();
        require(routerAddress != address(0), "Router not set");

        IUniswapV2Router02 router = IUniswapV2Router02(routerAddress);
        address factory = router.factory();
        address weth = router.WETH();

        // Get pair address
        address pairAddress = IUniswapV2Factory(factory).getPair(token, weth);
        require(pairAddress != address(0), "Pair does not exist");

        // Get reserves
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pairAddress)
            .getReserves();
        address token0 = IUniswapV2Pair(pairAddress).token0();

        (reserveETH, reserveToken) = token0 == token
            ? (reserve1, reserve0)
            : (reserve0, reserve1);
    }

    /// @notice Gets price from Uniswap V2 pool
    /// @param token Address of the token
    /// @return price Price in ETH per token (18 decimals), or 0 if pool doesn't exist
    function getPriceFromV2(
        address token
    ) internal view returns (uint256 price) {
        try this.getReserves(token) returns (
            uint256 reserveETH,
            uint256 reserveToken
        ) {
            if (reserveETH == 0 || reserveToken == 0) {
                return 0;
            }

            // Calculate price: ETH per token (18 decimals)
            uint8 decimals = IERC20Metadata(token).decimals();

            if (decimals == 18) {
                price = (reserveETH * 1e18) / reserveToken;
            } else if (decimals < 18) {
                uint256 scalingFactor = 10 ** (18 - decimals);
                uint256 scaledReserveETH = reserveETH / scalingFactor;
                price = (scaledReserveETH * 1e18) / reserveToken;
            } else {
                uint256 scalingFactor = 10 ** (decimals - 18);
                uint256 scaledReserveToken = reserveToken / scalingFactor;
                price = (reserveETH * 1e18) / scaledReserveToken;
            }
        } catch {
            return 0;
        }
    }

    /// @notice Updates the maximum allowed price deviation from market price
    /// @param newDeviation New maximum price deviation in basis points (1 = 0.01%)
    /// @dev Only callable by contract owner
    function updateMaxPriceDeviation(uint256 newDeviation) external onlyOwner {
        require(newDeviation <= 10000, "Deviation too high");
        uint256 oldDeviation = maxPriceDeviation;
        maxPriceDeviation = newDeviation;
        emit MaxPriceDeviationUpdated(oldDeviation, newDeviation);
    }

    /// @notice Sets the Uniswap V3 Factory address
    /// @param _uniswapV3Factory Address of the Uniswap V3 Factory
    /// @dev Only callable by contract owner
    function setUniswapV3Factory(address _uniswapV3Factory) external onlyOwner {
        require(_uniswapV3Factory != address(0), "Invalid factory address");
        address oldFactory = uniswapV3Factory;
        uniswapV3Factory = _uniswapV3Factory;
        emit UniswapV3FactoryUpdated(oldFactory, _uniswapV3Factory);
    }

    /// @notice Sets the Uniswap V3 Price Helper address
    /// @param _uniswapV3PriceHelper Address of the Uniswap V3 Price Helper
    /// @dev Only callable by contract owner
    function setUniswapV3PriceHelper(
        IUniswapV3PriceHelper _uniswapV3PriceHelper
    ) external onlyOwner {
        require(
            address(_uniswapV3PriceHelper) != address(0),
            "Invalid price helper address"
        );
        uniswapV3PriceHelper = _uniswapV3PriceHelper;
        emit UniswapV3PriceHelperUpdated(address(_uniswapV3PriceHelper));
    }

    /// @notice Sets the V3 fee tiers to check
    /// @param _feeTiers Array of fee tiers (e.g., [500, 3000, 10000] for 0.05%, 0.3%, 1%)
    /// @dev Only callable by contract owner
    function setV3FeeTiers(uint24[] calldata _feeTiers) external onlyOwner {
        require(_feeTiers.length > 0, "Fee tiers array cannot be empty");
        require(_feeTiers.length <= 10, "Too many fee tiers");
        v3FeeTiers = _feeTiers;
        emit V3FeeTiersUpdated(_feeTiers);
    }

    // =============================== EMERGENCY FUNCTIONS ===============================

    /**
     * @notice Emergency function to withdraw ETH from the contract
     * @param recipient Address to receive the ETH
     * @param amount Amount of ETH to withdraw (0 = withdraw all)
     * @dev Only callable by contract owner in emergency situations
     */
    function emergencyWithdrawETH(
        address payable recipient,
        uint256 amount
    ) external onlyOwner {
        require(recipient != address(0), "Invalid recipient");
        require(address(this).balance > 0, "No ETH to withdraw");

        uint256 withdrawAmount = amount == 0 ? address(this).balance : amount;
        require(
            withdrawAmount <= address(this).balance,
            "Insufficient ETH balance"
        );

        (bool success, ) = recipient.call{value: withdrawAmount}("");
        require(success, "ETH withdrawal failed");

        emit EmergencyWithdrawETH(recipient, withdrawAmount);
    }

    /**
     * @notice Emergency function to withdraw ERC20 tokens from the contract
     * @param token Address of the token to withdraw
     * @param recipient Address to receive the tokens
     * @param amount Amount of tokens to withdraw (0 = withdraw all)
     * @dev Only callable by contract owner in emergency situations
     */
    function emergencyWithdrawToken(
        address token,
        address recipient,
        uint256 amount
    ) external onlyOwner {
        require(token != address(0), "Invalid token address");
        require(recipient != address(0), "Invalid recipient");

        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "No tokens to withdraw");

        uint256 withdrawAmount = amount == 0 ? balance : amount;
        require(withdrawAmount <= balance, "Insufficient token balance");

        IERC20(token).safeTransfer(recipient, withdrawAmount);

        emit EmergencyWithdrawToken(token, recipient, withdrawAmount);
    }

    /**
     * @notice Emergency function to withdraw multiple tokens at once
     * @param tokens Array of token addresses to withdraw
     * @param recipient Address to receive all tokens
     * @dev Only callable by contract owner in emergency situations
     * @dev More gas efficient than calling emergencyWithdrawToken multiple times
     */
    function emergencyWithdrawMultipleTokens(
        address[] calldata tokens,
        address recipient
    ) external onlyOwner {
        require(recipient != address(0), "Invalid recipient");
        require(tokens.length > 0, "No tokens specified");
        require(tokens.length <= 20, "Too many tokens to withdraw at once");

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            require(token != address(0), "Invalid token address");

            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance > 0) {
                IERC20(token).safeTransfer(recipient, balance);
                emit EmergencyWithdrawToken(token, recipient, balance);
            }
        }
    }

    // Events for emergency withdrawals
    event EmergencyWithdrawETH(address indexed recipient, uint256 amount);
    event EmergencyWithdrawToken(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );
}
