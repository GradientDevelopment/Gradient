# Gradient Orderbook V2

A decentralized orderbook smart contract for trading ERC20 tokens against ETH. This contract implements both limit and market order systems with order matching and fulfillment capabilities.

## Features

- Trade any ERC20 token against ETH
- Limit and market order support
- Order matching system
- Whitelisted fulfiller system
- Non-custodial trading
- Gas-efficient order management
- Order expiration mechanism
- Partial fill support
- Order size limits
- Maximum TTL enforcement
- Emergency withdrawal mechanism
- Paged order retrieval

## Contract Overview

The Orderbook contract provides the following key functionalities:

### Order Types
- **Buy Orders**: Place orders to buy tokens with ETH
- **Sell Orders**: Place orders to sell tokens for ETH

### Execution Types
- **Limit Orders**: Execute at a specific price or better
- **Market Orders**: Execute at the best available price (with price limits)

### Order States
- **Active**: Order is available for fulfillment
- **Filled**: Order has been completely fulfilled
- **Cancelled**: Order was cancelled by the owner
- **Expired**: Order has passed its expiration time

### Key Functions

#### For Traders
- `createOrder`: Create a new buy or sell order (limit or market)
  - For buy orders: Send ETH with the transaction
  - For sell orders: Approve token transfer before calling
- `cancelOrder`: Cancel an active order
- `getOrder`: Get detailed information about an order
- `getRemainingAmount`: Check unfilled amount of an order
- `getActiveOrders`: Get list of active orders for a token
- `getActiveOrdersPaged`: Get paginated list of active orders
- `cleanupExpiredOrder`: Clean up expired orders and get refunds

#### For Fulfillers
- `fulfillLimitOrders`: Execute matched limit orders (whitelisted fulfillers only)
- `fulfillMarketOrders`: Execute matched market orders (whitelisted fulfillers only)

#### For Admin
- `setFulfillerStatus`: Whitelist or unwhitelist order fulfillers
- `setFeePercentage`: Update the trading fee percentage
- `withdrawFees`: Withdraw collected fees
- `setOrderSizeLimits`: Update minimum and maximum order sizes
- `setMaxOrderTtl`: Update maximum order time-to-live
- `emergencyWithdraw`: Emergency withdrawal of stuck tokens or ETH

### Order Limits
- Minimum order size: 0.000001 ETH (1e6 wei)
- Maximum order size: 1000 ETH
- Maximum order TTL: 30 days

## Usage

### Creating a Limit Buy Order

```solidity
// Amount of tokens to buy
uint256 amount = 1000 * 1e18; // Assuming 18 decimals
// Price per token in ETH (18 decimals)
uint256 price = 0.1 * 1e18;   // 0.1 ETH per token
// Time-to-live in seconds (max 30 days)
uint256 ttl = 3600;           // 1 hour

// Calculate total ETH needed (including fee)
uint256 totalEth = (amount * price) / 1e18;
uint256 fee = (totalEth * feePercentage) / 10000; // Using DIVISOR (10000)

// Create buy order
orderbook.createOrder{value: totalEth + fee}(
    OrderType.Buy,
    OrderExecutionType.Limit,
    tokenAddress,
    amount,
    price,
    ttl
);
```

### Creating a Market Sell Order

```solidity
// First approve token transfer
IERC20(tokenAddress).approve(orderbookAddress, amount);

// Create market sell order with minimum price
orderbook.createOrder(
    OrderType.Sell,
    OrderExecutionType.Market,
    tokenAddress,
    amount,
    minPrice,  // Minimum acceptable price
    ttl
);
```

### Fulfilling Limit Orders (Whitelisted Fulfillers Only)

```solidity
OrderMatch[] memory matches = new OrderMatch[](1);
matches[0] = OrderMatch({
    buyOrderId: buyOrderId,
    sellOrderId: sellOrderId,
    fillAmount: fillAmount
});

orderbook.fulfillLimitOrders(matches);
```

### Fulfilling Market Orders (Whitelisted Fulfillers Only)

```solidity
OrderMatch[] memory matches = new OrderMatch[](1);
uint256[] memory executionPrices = new uint256[](1);

matches[0] = OrderMatch({
    buyOrderId: buyOrderId,
    sellOrderId: sellOrderId,
    fillAmount: fillAmount
});
executionPrices[0] = currentMarketPrice;

orderbook.fulfillMarketOrders(matches, executionPrices);
```

## Security Features

- Reentrancy protection using OpenZeppelin's ReentrancyGuard
- Ownable pattern for admin functions
- Whitelisted fulfiller system
- Safe ETH transfer handling
- Expiration mechanism for stale orders
- Checks-Effects-Interactions pattern
- No direct token pair trading to prevent price manipulation
- Order size limits to prevent market manipulation
- Maximum TTL enforcement
- Emergency withdrawal mechanism
- Fee percentage limits

## Events

The contract emits the following events:

- `OrderCreated`: When a new order is created
- `OrderCancelled`: When an order is cancelled
- `OrderExpired`: When an order expires
- `OrderFulfilled`: When an order is completely filled
- `OrderPartiallyFulfilled`: When an order is partially filled
- `FulfillerWhitelisted`: When a fulfiller's status changes
- `FeePercentageUpdated`: When the fee percentage is updated
- `FeesWithdrawn`: When fees are withdrawn
- `OrderSizeLimitsUpdated`: When order size limits are updated
- `MaxTTLUpdated`: When maximum TTL is updated

## Dependencies

- OpenZeppelin Contracts v4.x
  - `@openzeppelin/contracts/token/ERC20/IERC20.sol`
  - `@openzeppelin/contracts/access/Ownable.sol`
  - `@openzeppelin/contracts/utils/ReentrancyGuard.sol`
  - `@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol`

## Development

### Prerequisites

- Node.js v14+
- Hardhat or Foundry
- OpenZeppelin Contracts

### Installation

1. Clone the repository
```bash
git clone https://github.com/GradientDevelopment/Gradient.git
cd Gradient
```

2. Install dependencies
```bash
yarn install
```

### Testing

```bash
yarn test
```

## License

MIT License
