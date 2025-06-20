# Gradient Orderbook V2

A decentralized orderbook smart contract for trading ERC20 tokens against ETH. This contract implements a hybrid liquidity model, combining a traditional peer-to-peer (P2P) order matching system with the ability to source liquidity from a dedicated Market Maker (MM) pool.

## Features

- **Hybrid Liquidity**: Fulfills orders via P2P matching or a dedicated Market Maker pool.
- Trade any ERC20 token against ETH
- Limit and market order support
- Whitelisted fulfiller system for executing trades
- Non-custodial trading
- Order expiration mechanism and partial fill support
- **Self-Fulfillment**: Allows users to unlock their order's assets to trade on an external AMM.
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
- `createOrder`: Create a new buy or sell order (limit or market).
- `cancelOrder`: Cancel an active order.
- `fulfillOwnOrderWithAMM`: Unlocks assets from an order, allowing the user to execute the trade on an external AMM.
- `getOrder`: Get detailed information about an order.
- `getActiveOrdersPaged`: Get a paginated list of active orders.
- `cleanupExpiredOrder`: Clean up expired orders and get refunds.

#### For Fulfillers (Whitelisted)
- `fulfillLimitOrders`: Execute matched limit orders between two users (P2P).
- `fulfillMarketOrders`: Execute matched market orders between two users (P2P).
- `fulfillOrdersWithMarketMaker`: Fulfill one or more orders using liquidity from the `GradientMarketMakerPool`.

#### For Admin
- `setFulfillerStatus`: Whitelist or unwhitelist order fulfillers.
- `setFeePercentage`: Update the trading fee percentage.
- `updateMMFeeDistributionPercentage`: Set the percentage of fees distributed to the MM pool.
- `withdrawFees`: Withdraw the platform's share of collected fees.
- `setOrderSizeLimits`: Update minimum and maximum order sizes.
- `setMaxOrderTtl`: Update maximum order time-to-live.
- `emergencyWithdraw`: Emergency withdrawal of stuck tokens or ETH.

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

### Fulfilling Orders with Market Maker (Whitelisted Fulfillers Only)

```solidity
uint256[] memory orderIds = new uint256[](1);
orderIds[0] = orderIdToFill;

uint256[] memory fillAmounts = new uint256[](1);
fillAmounts[0] = amountToFill;

orderbook.fulfillOrdersWithMarketMaker(orderIds, fillAmounts);
```

## Security Features

- Reentrancy protection using OpenZeppelin's ReentrancyGuard
- Ownable pattern for admin functions
- Whitelisted fulfiller system
- Safe ETH transfer handling
- Expiration mechanism for stale orders
- Checks-Effects-Interactions pattern
- Order size limits to prevent market manipulation

## Events

The contract emits the following events:

- `OrderCreated`: When a new order is created
- `OrderCancelled`: When an order is cancelled
- `OrderExpired`: When an order expires
- `OrderFulfilled`: When an order is completely filled
- `OrderPartiallyFulfilled`: When an order is partially filled
- `OrderFulfilledByMatching`: When an order is filled via P2P matching.
- `OrderFulfilledByMarketMaker`: When an order is filled via the MM pool.
- `FeeDistributedToPool`: When fees are sent to the MM pool.
- `FulfillerWhitelisted`: When a fulfiller's status changes
- `FeePercentageUpdated`: When the fee percentage is updated
- `FeesWithdrawn`: When fees are withdrawn
- `OrderSizeLimitsUpdated`: When order size limits are updated
- `MaxTTLUpdated`: When maximum TTL is updated
- `MMFeeDistributionPercentageUpdated`: When the MM fee share is updated.

## Dependencies

- OpenZeppelin Contracts
- Gradient Protocol Interfaces (`IGradientRegistry`, `IGradientMarketMakerPool`)

## Development

### Prerequisites

- Node.js v14+
- Yarn or Npm
- Hardhat

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
