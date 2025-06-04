# Gradient Orderbook

A decentralized orderbook smart contract for trading ERC20 tokens against ETH. This contract implements a limit order system with order matching and fulfillment capabilities.

## Features

- Trade any ERC20 token against ETH
- Limit order support
- Order matching system
- Whitelisted fulfiller system
- Non-custodial trading
- Gas-efficient order management
- Order expiration mechanism
- Partial fill support

## Contract Overview

The Orderbook contract provides the following key functionalities:

### Order Types
- **Buy Orders**: Place orders to buy tokens with ETH
- **Sell Orders**: Place orders to sell tokens for ETH

### Order States
- **Active**: Order is available for fulfillment
- **Filled**: Order has been completely fulfilled
- **Cancelled**: Order was cancelled by the owner
- **Expired**: Order has passed its expiration time

### Key Functions

#### For Traders
- `createOrder`: Create a new buy or sell order
  - For buy orders: Send ETH with the transaction
  - For sell orders: Approve token transfer before calling
- `cancelOrder`: Cancel an active order
- `getOrder`: Get detailed information about an order
- `getRemainingAmount`: Check unfilled amount of an order
- `getActiveOrders`: Get list of active orders for a token

#### For Fulfillers
- `fulfillMatchedOrders`: Execute matched orders (whitelisted fulfillers only)

#### For Admin
- `setFulfillerStatus`: Whitelist or unwhitelist order fulfillers

## Usage

### Creating a Buy Order

```solidity
// Amount of tokens to buy
uint256 amount = 1000 * 1e18; // Assuming 18 decimals
// Price per token in ETH (18 decimals)
uint256 price = 0.1 * 1e18;   // 0.1 ETH per token
// Time-to-live in seconds
uint256 ttl = 3600;           // 1 hour

// Calculate total ETH needed
uint256 totalEth = (amount * price) / 1e18;

// Create buy order
orderbook.createOrder{value: totalEth}(
    OrderType.Buy,
    tokenAddress,
    amount,
    price,
    ttl
);
```

### Creating a Sell Order

```solidity
// First approve token transfer
IERC20(tokenAddress).approve(orderbookAddress, amount);

// Create sell order
orderbook.createOrder(
    OrderType.Sell,
    tokenAddress,
    amount,
    price,
    ttl
);
```

### Cancelling an Order

```solidity
orderbook.cancelOrder(orderId);
```

### Fulfilling Orders (Whitelisted Fulfillers Only)

```solidity
OrderMatch[] memory matches = new OrderMatch[](1);
matches[0] = OrderMatch({
    buyOrderId: buyOrderId,
    sellOrderId: sellOrderId,
    fillAmount: fillAmount
});

orderbook.fulfillMatchedOrders(matches);
```

## Security Features

- Reentrancy protection using OpenZeppelin's ReentrancyGuard
- Ownable pattern for admin functions
- Whitelisted fulfiller system
- Safe ETH transfer handling
- Expiration mechanism for stale orders
- Checks-Effects-Interactions pattern
- No direct token pair trading to prevent price manipulation

## Events

The contract emits the following events:

- `OrderCreated`: When a new order is created
- `OrderCancelled`: When an order is cancelled
- `OrderExpired`: When an order expires
- `OrderFulfilled`: When an order is completely filled
- `OrderPartiallyFulfilled`: When an order is partially filled
- `FulfillerWhitelisted`: When a fulfiller's status changes

## Dependencies

- OpenZeppelin Contracts v4.x
  - `@openzeppelin/contracts/token/ERC20/IERC20.sol`
  - `@openzeppelin/contracts/access/Ownable.sol`
  - `@openzeppelin/contracts/utils/ReentrancyGuard.sol`

## Development

### Prerequisites

- Node.js v14+
- Hardhat or Foundry
- OpenZeppelin Contracts

### Installation

1. Clone the repository
```bash
git clone https://github.com/yourusername/gradient_orderbook.git
cd gradient_orderbook
```

2. Install dependencies
```bash
npm install
```

### Testing

```bash
npm test
```

## License

MIT License

## Security

For security concerns, please email security@gradientorderbook.com
