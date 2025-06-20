# Gradient Orderbook V3

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

## System Flow Diagram

This diagram illustrates the primary user flows and contract interactions within the Gradient protocol.

```
                                     +--------------------+
                                     | Liquidity Provider |
                                     +----------+---------+
                                                |
                                   (Adds/Removes Liquidity)
                                                |
                                                v
+----------+      +-----------+      +-------------------------------------------+
|  Trader  |      | Fulfiller |      |         GradientMarketMakerPool         |
+----+-----+      +-----+-----+      +--------------------+--------------------+
     |                  |                                  ^
(Create/Cancel/AMM)     | (Executes Matches)               | (Fulfill from Pool)
     |                  |                                  |
     v                  v                                  |
+--------------------------------------------------------------------+
|                          GradientOrderbook                         |
+--------------------------------------------------------------------+
     |         ^
     |         | (AMM Self-Fulfill)
     |         |
     v         +
+----------+
| External |
|   AMM    |
+----------+
```

Note: All core contracts use the GradientRegistry for service discovery (not shown for clarity).

## Smart Contract Architecture

The protocol is composed of several key smart contracts that work together to create a robust and decentralized trading environment.

### `GradientRegistry.sol`

*   **Purpose:** This contract serves as the central nervous system of the protocol. It is an on-chain registry that holds the addresses of all other core contracts (e.g., `GradientOrderbook`, `GradientMarketMakerPool`).
*   **Key Features:**
    *   **Upgradability:** By allowing the owner to update contract addresses, the registry enables seamless upgrades to different components of the protocol without requiring a full migration.
    *   **Access Control:** It maintains a list of authorized contracts, ensuring that critical functions can only be called by other trusted parts of the system.
    *   **System Configuration:** It stores system-wide settings, such as lists of blocked tokens and authorized reward distributors.

### `GradientOrderbook.sol`

*   **Purpose:** This is the main user-facing contract that implements the decentralized exchange logic. It manages the entire lifecycle of trade orders.
*   **Key Features:**
    *   **Hybrid Order Fulfillment:** It uniquely supports both peer-to-peer (P2P) order matching and integration with a market maker pool for liquidity.
    *   **Order Management:** Handles the creation, cancellation, and status tracking of limit and market orders.
    *   **Asset Handling:** Securely locks and transfers ETH and ERC20 tokens upon trade settlement.
    *   **AMM Fallback:** Includes a `fulfillOwnOrderWithAMM` function, allowing users to unlock their assets to execute a trade on an external AMM.

### `GradientMarketMakerPool.sol`

*   **Purpose:** This contract functions as the protocol's dedicated liquidity provider. It allows liquidity providers (LPs) to deposit assets (ETH and ERC20 tokens) and earn passive income from trading fees.
*   **Key Features:**
    *   **Liquidity Pools:** Maintains individual liquidity pools for different ERC20 tokens.
    *   **LP Rewards:** Collects a share of trading fees from the `GradientOrderbook` and distributes them as rewards to LPs, proportional to their stake in the pool.
    *   **Order Fulfillment:** Interacts directly with the `GradientOrderbook` to provide the necessary assets to fill trades that cannot be matched P2P.
    *   **Ratio Management:** Relies on a Uniswap V2 pair to enforce a fair 50/50 deposit ratio for liquidity provision.

### `FallbackExecutor.sol`

*   **Purpose:** This contract acts as a safety net and a tool for sourcing external liquidity. Its primary role is to execute trades on third-party Automated Market Makers (AMMs) like Uniswap when internal liquidity is insufficient or unavailable. **Note: While this contract is part of the architecture, its automatic integration with the `GradientOrderbook` is not yet implemented.**
*   **Key Features:**
    *   **Multi-DEX Integration:** Designed to be a DEX aggregator, it can be configured to interact with multiple AMMs.
    *   **Best Price Execution:** It can be programmed to query different DEXes and find the best execution price for a given trade.
    *   **Token & DEX Management:** The owner can add or remove supported tokens and DEX configurations, allowing the protocol to adapt to the evolving DeFi landscape.
    -   **Trade Execution:** Provides a generic `executeTrade` function that can handle both buy (ETH-for-token) and sell (token-for-ETH) swaps.

## Interfaces

The protocol uses a set of interfaces to define the contract functions and ensure interoperability between the different components and external services like Uniswap.

### Core Protocol Interfaces
*   **`IGradientRegistry.sol`**: Defines the functions exposed by the `GradientRegistry` contract. It allows other contracts to securely query for the official addresses of core protocol components.
*   **`IGradientMarketMakerPool.sol`**: Defines the external functions for the `GradientMarketMakerPool`. This includes functions for depositing and withdrawing liquidity, claiming rewards, and, crucially, functions called by the `GradientOrderbook` to transfer assets when filling an order (`transferTokenToOrderbook`, `receiveETHFromOrderbook`, etc.).
*   **`IFallbackExecutor.sol`**: Defines the standard functions for the `FallbackExecutor` contract, ensuring that any contract wanting to use it for swaps knows how to call it.

### External Protocol Interfaces
*   **`IUniswapV2Router.sol`**, **`IUniswapV2Factory.sol`**, **`IUniswapV2Pair.sol`**: These are standard, well-known interfaces for interacting with the Uniswap V2 ecosystem. They are used by the `GradientMarketMakerPool` to check token reserves for liquidity deposits and by the `fulfillOwnOrderWithAMM` function in the `GradientOrderbook` to perform swaps.

### General-Purpose & Legacy Interfaces
*   **`IOrderManager.sol`** and **`IMarketMakerPool.sol`**: These appear to be more generic or potentially older versions of interfaces for an order book and a market maker pool. While not directly implemented by the primary contracts, they exist within the project and may be intended for future modules, alternative implementations, or have been part of a previous design iteration.

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
