// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IGradientMarketMakerPoolV3
 * @notice Interface for individual token market maker pool contracts with price range functionality
 * @dev Each pool is dedicated to one token with concentrated liquidity price ranges
 * @dev Users can specify min/max price ranges when adding liquidity
 */
interface IGradientMarketMakerPoolV3 {
    // Price range struct for concentrated liquidity
    struct PriceRange {
        uint256 minPrice; // Minimum price (in wei per token)
        uint256 maxPrice; // Maximum price (in wei per token)
        bool isActive; // Whether this range is active
    }

    // Enhanced provider position with price range
    struct ProviderPosition {
        uint256 position; // ETH or token position
        uint256 rewardDebt; // Reward debt for accurate calculations
        uint256 pendingRewards; // Pending rewards to claim
        uint256 lastUpdateVersion; // Last version when position was updated
        uint256 lpShares; // LP shares for this provider
        PriceRange priceRange; // Price range for this position
    }

    // Pool metrics with price range support
    struct PoolMetrics {
        uint256 totalPosition; // Total ETH or tokens
        uint256 totalLPShares; // Total LP shares
        uint256 accRewardPerShare; // Accumulated rewards per share
        uint256 rewardBalance; // Available reward balance
        uint256 accountedPosition; // Accounted position for calculations
        uint256 currentPrice; // Current market price
    }

    // Events
    event LiquidityDeposited(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 lpSharesMinted,
        bool isETH,
        uint256 minPrice,
        uint256 maxPrice
    );

    event LiquidityWithdrawn(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 lpSharesBurned,
        bool isETH,
        uint256 minPrice,
        uint256 maxPrice
    );

    event PoolFeeDistributed(
        address indexed from,
        uint256 amount,
        address indexed token,
        bool isETH
    );

    event FeeClaimed(
        address indexed user,
        uint256 amount,
        address indexed token,
        bool isETH
    );

    event PoolBalanceUpdated(
        address indexed token,
        uint256 newTotalETH,
        uint256 newTotalTokens,
        uint256 newETHLPShares,
        uint256 newTokenLPShares
    );

    event PriceRangeUpdated(
        address indexed user,
        uint256 oldMinPrice,
        uint256 oldMaxPrice,
        uint256 newMinPrice,
        uint256 newMaxPrice,
        bool isETH
    );

    event MerkleRootUpdated(uint256 indexed version, bytes32 merkleRoot);
    event UserPositionUpdated(
        address indexed user,
        uint256 indexed version,
        uint256 newETHPosition,
        uint256 newTokenPosition
    );

    event MinLiquidityUpdated(uint256 newMinLiquidity, bool isETH);
    event EmergencyWithdraw(
        address indexed token,
        address indexed recipient,
        uint256 amount,
        bool isETH
    );

    // Enhanced liquidity management functions with price ranges
    /**
     * @notice Add ETH liquidity with price range and optional position update
     * @param minPrice Minimum price for this liquidity position
     * @param maxPrice Maximum price for this liquidity position
     * @param proof Merkle proof for position update (required if user has pending updates)
     * @param newETHPosition New ETH position (required if proof provided)
     * @param newTokenPosition New token position (required if proof provided)
     * @param ethRewardsToAdd Off-chain calculated ETH rewards to add
     * @param tokenRewardsToAdd Off-chain calculated token rewards to add
     */
    function addETHLiquidityWithPriceRange(
        uint256 minPrice,
        uint256 maxPrice,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external payable;

    /**
     * @notice Add token liquidity with price range and optional position update
     * @param tokenAmount Amount of tokens to deposit
     * @param minPrice Minimum price for this liquidity position
     * @param maxPrice Maximum price for this liquidity position
     * @param proof Merkle proof for position update (required if user has pending updates)
     * @param newETHPosition New ETH position (required if proof provided)
     * @param newTokenPosition New token position (required if proof provided)
     * @param ethRewardsToAdd Off-chain calculated ETH rewards to add
     * @param tokenRewardsToAdd Off-chain calculated token rewards to add
     */
    function addTokenLiquidityWithPriceRange(
        uint256 tokenAmount,
        uint256 minPrice,
        uint256 maxPrice,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external;

    /**
     * @notice Add both ETH and token liquidity with price ranges and optional position update
     * @param tokenAmount Amount of tokens to deposit
     * @param ethMinPrice Minimum price for ETH liquidity position
     * @param ethMaxPrice Maximum price for ETH liquidity position
     * @param tokenMinPrice Minimum price for token liquidity position
     * @param tokenMaxPrice Maximum price for token liquidity position
     * @param proof Merkle proof for position update (required if user has pending updates)
     * @param newETHPosition New ETH position (required if proof provided)
     * @param newTokenPosition New token position (required if proof provided)
     * @param ethRewardsToAdd Off-chain calculated ETH rewards to add
     * @param tokenRewardsToAdd Off-chain calculated token rewards to add
     */
    function addLiquidityWithPriceRanges(
        uint256 tokenAmount,
        uint256 ethMinPrice,
        uint256 ethMaxPrice,
        uint256 tokenMinPrice,
        uint256 tokenMaxPrice,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external payable;

    /**
     * @notice Update price range for existing ETH liquidity position
     * @param newMinPrice New minimum price
     * @param newMaxPrice New maximum price
     * @param proof Merkle proof for position update (required if user has pending updates)
     * @param newETHPosition New ETH position (required if proof provided)
     * @param newTokenPosition New token position (required if proof provided)
     * @param ethRewardsToAdd Off-chain calculated ETH rewards to add
     * @param tokenRewardsToAdd Off-chain calculated token rewards to add
     */
    function updateETHPositionPriceRange(
        uint256 newMinPrice,
        uint256 newMaxPrice,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external;

    /**
     * @notice Update price range for existing token liquidity position
     * @param newMinPrice New minimum price
     * @param newMaxPrice New maximum price
     * @param proof Merkle proof for position update (required if user has pending updates)
     * @param newETHPosition New ETH position (required if proof provided)
     * @param newTokenPosition New token position (required if proof provided)
     * @param ethRewardsToAdd Off-chain calculated ETH rewards to add
     * @param tokenRewardsToAdd Off-chain calculated token rewards to add
     */
    function updateTokenPositionPriceRange(
        uint256 newMinPrice,
        uint256 newMaxPrice,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external;

    // Standard liquidity functions (without price ranges for backward compatibility)
    /**
     * @notice Add ETH liquidity with optional position update (no price range)
     * @param proof Merkle proof for position update (required if user has pending updates)
     * @param newETHPosition New ETH position (required if proof provided)
     * @param newTokenPosition New token position (required if proof provided)
     * @param ethRewardsToAdd Off-chain calculated ETH rewards to add
     * @param tokenRewardsToAdd Off-chain calculated token rewards to add
     */
    function addETHLiquidityWithProof(
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external payable;

    /**
     * @notice Add token liquidity with optional position update (no price range)
     * @param tokenAmount Amount of tokens to deposit
     * @param proof Merkle proof for position update (required if user has pending updates)
     * @param newETHPosition New ETH position (required if proof provided)
     * @param newTokenPosition New token position (required if proof provided)
     * @param ethRewardsToAdd Off-chain calculated ETH rewards to add
     * @param tokenRewardsToAdd Off-chain calculated token rewards to add
     */
    function addTokenLiquidityWithProof(
        uint256 tokenAmount,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external;

    // Removal functions with price range support
    /**
     * @notice Remove ETH liquidity with optional position update
     * @param shares Percentage of pool to withdraw (in basis points, 10000 = 100%)
     * @param minEthAmount Minimum amount of ETH to receive
     * @param proof Merkle proof for position update (required if user has pending updates)
     * @param newETHPosition New ETH position (required if proof provided)
     * @param newTokenPosition New token position (required if proof provided)
     * @param ethRewardsToAdd Off-chain calculated ETH rewards to add
     * @param tokenRewardsToAdd Off-chain calculated token rewards to add
     */
    function removeETHLiquidityWithProof(
        uint256 shares,
        uint256 minEthAmount,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external;

    /**
     * @notice Remove token liquidity with optional position update
     * @param shares Percentage of pool to withdraw (in basis points, 10000 = 100%)
     * @param minTokenAmount Minimum amount of tokens to receive
     * @param proof Merkle proof for position update (required if user has pending updates)
     * @param newETHPosition New ETH position (required if proof provided)
     * @param newTokenPosition New token position (required if proof provided)
     * @param ethRewardsToAdd Off-chain calculated ETH rewards to add
     * @param tokenRewardsToAdd Off-chain calculated token rewards to add
     */
    function removeTokenLiquidityWithProof(
        uint256 shares,
        uint256 minTokenAmount,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external;

    /**
     * @notice Remove both ETH and token liquidity with merkle proof
     * @param ethShares Percentage of ETH liquidity to remove (0-10000)
     * @param tokenShares Percentage of token liquidity to remove (0-10000)
     * @param minEthAmount Minimum ETH amount to receive
     * @param minTokenAmount Minimum token amount to receive
     * @param proof Merkle proof for position update
     * @param newETHPosition New ETH position after update
     * @param newTokenPosition New token position after update
     * @param ethRewardsToAdd Total ETH rewards (accumulated)
     * @param tokenRewardsToAdd Total token rewards (accumulated)
     */
    function removeLiquidityWithProof(
        uint256 ethShares,
        uint256 tokenShares,
        uint256 minEthAmount,
        uint256 minTokenAmount,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external;

    // Order execution functions (same as V2)
    /**
     * @notice Execute buy order - Orderbook sends ETH, receives tokens
     * @param ethAmount Amount of ETH sent by orderbook
     * @param tokenAmount Amount of tokens to send to orderbook
     * @param newMerkleRoot New merkle root to update after trade
     */
    function executeBuyOrder(
        uint256 ethAmount,
        uint256 tokenAmount,
        bytes32 newMerkleRoot
    ) external payable;

    /**
     * @notice Execute sell order - Orderbook sends tokens, receives ETH
     * @param ethAmount Amount of ETH to send to orderbook
     * @param tokenAmount Amount of tokens sent by orderbook
     * @param newMerkleRoot New merkle root to update after trade
     */
    function executeSellOrder(
        uint256 ethAmount,
        uint256 tokenAmount,
        bytes32 newMerkleRoot
    ) external;

    // Reward distribution functions (same as V2)
    /**
     * @notice Distributes ETH fees to ETH providers
     */
    function distributePoolFee() external payable;

    /**
     * @notice Distributes token fees to token providers
     * @param tokenAmount Amount of tokens to distribute as fees
     */
    function distributeTokenFee(uint256 tokenAmount) external;

    // Reward claiming functions (same as V2)
    /**
     * @notice Claim all rewards with optional position update
     * @param proof Merkle proof for position update (required if user has pending updates)
     * @param newETHPosition New ETH position (required if proof provided)
     * @param newTokenPosition New token position (required if proof provided)
     * @param ethRewardsToAdd Off-chain calculated ETH rewards to add
     * @param tokenRewardsToAdd Off-chain calculated token rewards to add
     */
    function claimRewardsWithProof(
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external;

    /**
     * @notice Claim only ETH rewards with optional position update
     * @param proof Merkle proof for position update (required if user has pending updates)
     * @param newETHPosition New ETH position (required if proof provided)
     * @param newTokenPosition New token position (required if proof provided)
     * @param ethRewardsToAdd Off-chain calculated ETH rewards to add
     * @param tokenRewardsToAdd Off-chain calculated token rewards to add
     */
    function claimETHRewardsWithProof(
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external;

    /**
     * @notice Claim only token rewards with optional position update
     * @param proof Merkle proof for position update (required if user has pending updates)
     * @param newETHPosition New ETH position (required if proof provided)
     * @param newTokenPosition New token position (required if proof provided)
     * @param ethRewardsToAdd Off-chain calculated ETH rewards to add
     * @param tokenRewardsToAdd Off-chain calculated token rewards to add
     */
    function claimTokenRewardsWithProof(
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external;

    // Position update functions (same as V2)
    /**
     * @notice Update user position using merkle proof
     * @param version Version of the merkle root
     * @param proof Merkle proof for the user's new position
     * @param newETHPosition New ETH position (actual ETH amount)
     * @param newTokenPosition New token position (actual token amount)
     * @param ethRewardsToAdd Off-chain calculated ETH rewards to add
     * @param tokenRewardsToAdd Off-chain calculated token rewards to add
     */
    function updateUserPosition(
        uint256 version,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external;

    // Factory-only functions (same as V2)
    /**
     * @notice Add ETH liquidity for a specific user (factory only)
     * @param user User address to add liquidity for
     */
    function addETHLiquidityForUser(
        address user,
        uint256 minPrice,
        uint256 maxPrice
    ) external payable;

    /**
     * @notice Add token liquidity for a specific user (factory only)
     * @param user User address to add liquidity for
     * @param tokenAmount Amount of tokens to deposit
     */
    function addTokenLiquidityForUser(
        address user,
        uint256 tokenAmount,
        uint256 minPrice,
        uint256 maxPrice
    ) external;

    // View functions with price range support
    /**
     * @notice Get comprehensive user position information including price ranges
     * @param user Address of the user
     * @return ethPosition User's ETH position
     * @return tokenPosition User's token position
     * @return ethLPShares User's ETH LP shares
     * @return tokenLPShares User's token LP shares
     * @return ethPendingRewards User's pending ETH rewards
     * @return tokenPendingRewards User's pending token rewards
     * @return lastUpdateVersion User's last update version
     * @return ethPriceRange User's ETH price range
     * @return tokenPriceRange User's token price range
     */
    function getUserPositionWithPriceRanges(
        address user
    )
        external
        view
        returns (
            uint256 ethPosition,
            uint256 tokenPosition,
            uint256 ethLPShares,
            uint256 tokenLPShares,
            uint256 ethPendingRewards,
            uint256 tokenPendingRewards,
            uint256 lastUpdateVersion,
            PriceRange memory ethPriceRange,
            PriceRange memory tokenPriceRange
        );

    /**
     * @notice Get user position information (backward compatibility)
     * @param user Address of the user
     * @return ethPosition User's ETH position
     * @return tokenPosition User's token position
     * @return ethLPShares User's ETH LP shares
     * @return tokenLPShares User's token LP shares
     * @return ethPendingRewards User's pending ETH rewards
     * @return tokenPendingRewards User's pending token rewards
     * @return lastUpdateVersion User's last update version
     */
    function getUserPosition(
        address user
    )
        external
        view
        returns (
            uint256 ethPosition,
            uint256 tokenPosition,
            uint256 ethLPShares,
            uint256 tokenLPShares,
            uint256 ethPendingRewards,
            uint256 tokenPendingRewards,
            uint256 lastUpdateVersion
        );

    /**
     * @notice Get pool metrics for ETH pool
     * @return metrics ETH pool metrics
     */
    function getETHPoolMetrics()
        external
        view
        returns (PoolMetrics memory metrics);

    /**
     * @notice Get pool metrics for token pool
     * @return metrics Token pool metrics
     */
    function getTokenPoolMetrics()
        external
        view
        returns (PoolMetrics memory metrics);

    /**
     * @notice Get current market price (ETH per token)
     * @return price Current market price in wei per token
     */
    function getCurrentPrice() external view returns (uint256 price);

    /**
     * @notice Check if a price is within a given range
     * @param price Price to check
     * @param minPrice Minimum price
     * @param maxPrice Maximum price
     * @return isWithinRange True if price is within range
     */
    function isPriceWithinRange(
        uint256 price,
        uint256 minPrice,
        uint256 maxPrice
    ) external view returns (bool isWithinRange);

    /**
     * @notice Get the Uniswap V2 pair address for this token
     * @return pairAddress Address of the Uniswap V2 pair
     */
    function getPairAddress() external view returns (address pairAddress);

    /**
     * @notice Get the reserves for this token pair
     * @return reserveETH ETH reserve amount
     * @return reserveToken Token reserve amount
     */
    function getReserves()
        external
        view
        returns (uint256 reserveETH, uint256 reserveToken);

    // Owner functions (same as V2)
    /**
     * @notice Set minimum ETH liquidity requirement
     * @param _minLiquidity New minimum ETH liquidity amount
     */
    function setMinLiquidity(uint256 _minLiquidity) external;

    /**
     * @notice Set minimum token liquidity requirement
     * @param _minTokenLiquidity New minimum token liquidity amount
     */
    function setMinTokenLiquidity(uint256 _minTokenLiquidity) external;

    // Emergency functions (same as V2)
    /**
     * @notice Emergency function to withdraw ETH from the contract
     * @param recipient Address to receive the ETH
     * @param amount Amount of ETH to withdraw (0 = withdraw all)
     */
    function emergencyWithdrawETH(
        address payable recipient,
        uint256 amount
    ) external;

    /**
     * @notice Emergency function to withdraw any ERC20 token from the contract
     * @param tokenAddress Address of the token to withdraw
     * @param recipient Address to receive the tokens
     * @param amount Amount of tokens to withdraw (0 = withdraw all)
     */
    function emergencyWithdrawToken(
        address tokenAddress,
        address recipient,
        uint256 amount
    ) external;

    // Basic view functions (same as V2)
    function token() external view returns (address);

    function factory() external view returns (address);

    function totalETH() external view returns (uint256);

    function totalTokens() external view returns (uint256);

    function merkleRoot() external view returns (bytes32);

    function currentVersion() external view returns (uint256);

    function minLiquidity() external view returns (uint256);

    function minTokenLiquidity() external view returns (uint256);
}
