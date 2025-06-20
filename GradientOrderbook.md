# GradientOrderbook.sol: Contract Use Cases Overview

The `GradientOrderbook.sol` contract implements a decentralized order book exchange for trading ERC20 tokens against ETH, supporting limit and market orders. It uniquely combines peer-to-peer matching with the ability to source liquidity from a dedicated Market Maker (MM) pool, all facilitated by a set of whitelisted "fulfillers".

### 1. For Traders (End-Users)

These are the primary users who want to buy or sell tokens.

*   **Placing Orders:**
    *   **Limit Orders:** A trader can place a limit order to buy or sell a specific amount of an ERC20 token at a precise price.
    *   **Market Orders:** A trader can place a market order, specifying the amount to trade and a slippage tolerance (as a max buy price or min sell price).
    *   **Fund Locking:** When creating an order, the user's assets are locked in the contract. For a buy order, ETH is locked; for a sell order, the ERC20 tokens are locked.

*   **Managing Orders:**
    *   **Cancellation:** Traders can cancel their own active orders at any time before they are completely filled, and their locked assets are returned.
    *   **Querying:** Traders can view the status, filled amount, and other details of any order on the books.

*   **Self-Fulfillment via AMM:**
    *   The `fulfillOwnOrderWithAMM` function offers a unique feature. It allows a user to "unlock" the assets from their own order to personally execute a trade on an external Automated Market Maker (AMM). The contract marks the order as filled and returns the locked ETH or tokens to the user, who is then responsible for performing the swap on an AMM like Uniswap.

### 2. For Fulfillers (Whitelisted Backend Agents)

Fulfillers are trusted, whitelisted addresses (typically off-chain bots or services) that are responsible for executing trades. They are the engine of the exchange.

*   **Peer-to-Peer Matching:**
    *   Fulfillers constantly monitor the order book for compatible buy and sell orders.
    *   When a match is found (e.g., a buyer's price meets or exceeds a seller's price), the fulfiller submits the pair to the `fulfillLimitOrders` or `fulfillMarketOrders` function. The contract then handles the atomic settlement, transferring tokens to the buyer and ETH to the seller.

*   **Market Maker Integration:**
    *   If a direct peer-to-peer match isn't available, a fulfiller can use the `fulfillOrdersWithMarketMaker` function.
    *   This allows an order to be filled against a separate `GradientMarketMakerPool` contract, which acts as a guaranteed liquidity provider. The fulfiller initiates the trade, and the contract coordinates the asset swap between the trader and the MM pool.

### 3. For the Contract Owner (Administrator)

The owner of the contract has administrative privileges to manage the platform and its parameters.

*   **Platform Configuration:**
    *   **Fee Management:** The owner sets the trading `feePercentage`.
    *   **Fulfiller Whitelisting:** The owner has exclusive rights to grant and revoke fulfiller status using `setFulfillerStatus`.
    *   **Order Constraints:** The owner can define global rules like the minimum/maximum order size and the maximum Time-To-Live (TTL) for an order.
    *   **MM Fee Share:** The owner can configure the percentage of collected fees that are distributed to the Market Maker pool for providing liquidity.

*   **Treasury and Safety:**
    *   **Fee Withdrawal:** The owner can withdraw the platform's accumulated trading fees.
    *   **Emergency Withdraw:** In case of an emergency or if assets get stuck, the owner can use the `emergencyWithdraw` function to rescue ETH or any ERC20 token from the contract. 