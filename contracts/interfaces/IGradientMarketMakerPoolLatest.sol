// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IGradientMarketMakerPool
 * @notice Interface for the GradientMarketMakerPool contract
 */
interface IGradientMarketMakerPoolLatest {
    // Structs for ETH Pool
    struct ETHPoolInfo {
        uint256 accountedEth;
        uint256 totalETH;
        uint256 totalLPShares;
        uint256 accRewardPerShare;
        uint256 rewardBalance;
        uint256 accTokenRewardPerShare; // For token rewards to ETH providers
        uint256 tokenRewardBalance; // Token rewards for ETH providers
        address uniswapPair;
    }

    struct ETHProvider {
        uint256 ethAmount;
        uint256 lpShares;
        uint256 rewardDebt;
        uint256 pendingReward;
        uint256 tokenRewardDebt; // For token rewards
        uint256 pendingTokenReward; // Pending token rewards
    }

    // Structs for Token Pool
    struct TokenPoolInfo {
        uint256 accountedToken;
        uint256 totalTokens;
        uint256 totalLPShares;
        uint256 accRewardPerShare;
        uint256 rewardBalance;
        uint256 accETHRewardPerShare; // For ETH rewards to token providers
        uint256 ethRewardBalance; // ETH rewards for token providers
        address uniswapPair;
    }

    struct TokenProvider {
        uint256 tokenAmount;
        uint256 lpShares;
        uint256 rewardDebt;
        uint256 pendingReward;
        uint256 ethRewardDebt; // For ETH rewards
        uint256 pendingETHReward; // Pending ETH rewards
    }

    // Legacy compatibility struct
    struct PoolInfo {
        uint256 totalEth;
        uint256 totalToken;
        uint256 totalLiquidity;
        uint256 totalLPShares;
        uint256 accountedEth;
        uint256 accountedToken;
        uint256 accRewardPerShare;
        uint256 rewardBalance;
        address uniswapPair;
    }

    // Events
    event ETHLiquidityDeposited(
        address indexed user,
        address token,
        uint256 ethAmount,
        uint256 lpSharesMinted
    );

    event TokenLiquidityDeposited(
        address indexed user,
        address token,
        uint256 tokenAmount,
        uint256 lpSharesMinted
    );

    event ETHLiquidityWithdrawn(
        address indexed user,
        address token,
        uint256 ethAmount,
        uint256 lpSharesBurned
    );

    event TokenLiquidityWithdrawn(
        address indexed user,
        address token,
        uint256 tokenAmount,
        uint256 lpSharesBurned
    );

    event BuyOrderFulfilled(
        address indexed buyer,
        address token,
        uint256 ethAmount,
        uint256 tokenAmount
    );

    event SellOrderFulfilled(
        address indexed seller,
        address token,
        uint256 tokenAmount,
        uint256 ethAmount
    );

    event PoolFeeDistributed(
        address indexed from,
        uint256 amount,
        address token,
        bool isETH
    );
    event PoolFeeClaimed(
        address indexed user,
        uint256 amount,
        address token,
        bool isETH
    );

    event PoolSharesClaimed(
        address indexed user,
        uint256 amount,
        address token,
        bool isETH
    );
    event PoolBalanceUpdated(
        address indexed token,
        uint256 newTotalEth,
        uint256 newTotalTokens,
        uint256 newTotalETHLPShares,
        uint256 newTotalTokenLPShares
    );

    event ETHTransferredToOrderbook(
        address indexed orderbook,
        uint256 amount,
        address indexed token
    );

    event TokenTransferredToOrderbook(
        address indexed orderbook,
        address indexed token,
        uint256 amount
    );

    event ETHReceivedFromOrderbook(
        address indexed orderbook,
        uint256 amount,
        address indexed token
    );

    event TokenReceivedFromOrderbook(
        address indexed orderbook,
        address indexed token,
        uint256 amount
    );

    event MinLiquidityUpdated(uint256 newMinLiquidity);
    event MinTokenLiquidityUpdated(uint256 newMinTokenLiquidity);
    event ExcessiveFundsWithdrawn(
        address indexed owner,
        address indexed token,
        uint256 amount,
        string reason
    );

    /**
     * @notice Add ETH liquidity to the pool
     * @param token Address of the token to provide ETH liquidity for
     */
    function addETHLiquidity(address token) external payable;

    /**
     * @notice Add token liquidity to the pool
     * @param token Address of the token to provide liquidity for
     * @param tokenAmount Amount of tokens to deposit
     */
    function addTokenLiquidity(address token, uint256 tokenAmount) external;

    /**
     * @notice Remove ETH liquidity from the pool
     * @param token Address of the token to withdraw from
     * @param shares Percentage of pool to withdraw (in basis points, 10000 = 100%)
     * @param minTokenAmount Minimum amount of tokens to receive
     */
    function removeETHLiquidity(
        address token,
        uint256 shares,
        uint256 minTokenAmount
    ) external;

    /**
     * @notice Remove token liquidity from the pool
     * @param token Address of the token to withdraw from
     * @param shares Percentage of pool to withdraw (in basis points, 10000 = 100%)
     * @param minTokenAmount Minimum amount of tokens to receive
     */
    function removeTokenLiquidity(
        address token,
        uint256 shares,
        uint256 minTokenAmount
    ) external;

    /**
     * @notice Execute buy order - Orderbook sends ETH, receives tokens
     * @param token The token being bought
     * @param ethAmount Amount of ETH sent by orderbook
     * @param tokenAmount Amount of tokens to send to orderbook
     */
    function executeBuyOrder(
        address token,
        uint256 ethAmount,
        uint256 tokenAmount
    ) external payable;

    /**
     * @notice Execute sell order - Token pool provides tokens, receives ETH rewards
     * @param token The token being sold
     * @param ethAmount Amount of ETH to pay for the sell order
     * @param tokenAmount Amount of tokens being sold
     */
    function executeSellOrder(
        address token,
        uint256 ethAmount,
        uint256 tokenAmount
    ) external;

    /**
     * @notice Distributes fee distribution from orderbook to be distributed to market makers
     * @param token Address of the token pool to distribute fees for
     * @param isETHPool Whether to distribute to ETH pool (true) or token pool (false)
     */
    function distributePoolFee(address token, bool isETHPool) external payable;

    /**
     * @notice Claim ETH rewards for ETH providers
     * @param token Address of the token pool to claim rewards from
     */
    function claimEthPoolFee(address token) external;

    /**
     * @notice Claim token rewards for token providers
     * @param token Address of the token pool to claim rewards from
     */
    function claimTokenPoolFee(address token) external;

    /**
     * @notice Gets ETH pool information for a specific token
     * @param token Address of the token to get ETH pool info for
     * @return ETHPoolInfo struct containing ETH pool details
     */
    function getETHPoolInfo(
        address token
    ) external view returns (ETHPoolInfo memory);

    /**
     * @notice Gets token pool information for a specific token
     * @param token Address of the token to get token pool info for
     * @return TokenPoolInfo struct containing token pool details
     */
    function getTokenPoolInfo(
        address token
    ) external view returns (TokenPoolInfo memory);

    /**
     * @notice Gets a user's LP shares for ETH pool
     * @param token Address of the token
     * @param user Address of the user
     * @return lpShares User's LP shares in ETH pool
     */
    function getETHProviderLPShares(
        address token,
        address user
    ) external view returns (uint256 lpShares);

    /**
     * @notice Gets a user's LP shares for token pool
     * @param token Address of the token
     * @param user Address of the user
     * @return lpShares User's LP shares in token pool
     */
    function getTokenProviderLPShares(
        address token,
        address user
    ) external view returns (uint256 lpShares);

    /**
     * @notice Get the Uniswap V2 pair address for a given token
     * @param token Address of the token
     * @return pairAddress Address of the Uniswap V2 pair
     */
    function getPairAddress(
        address token
    ) external view returns (address pairAddress);

    /**
     * @notice Get the reserves for a token pair
     * @param token Address of the token
     * @return reserveETH ETH reserve amount
     * @return reserveToken Token reserve amount
     */
    function getReserves(
        address token
    ) external view returns (uint256 reserveETH, uint256 reserveToken);

    // Legacy compatibility functions
    function getPoolInfo(address token) external view returns (PoolInfo memory);

    function getUserSharePercentage(
        address token,
        address user
    ) external view returns (uint256 sharePercentage);

    function getUserLPShares(
        address token,
        address user
    ) external view returns (uint256 lpShares);
}
