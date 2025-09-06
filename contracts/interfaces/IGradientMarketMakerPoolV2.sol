// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IGradientMarketMakerPoolV2
 * @notice Interface for individual token market maker pool contracts
 * @dev Each pool is dedicated to one token, so token parameters are not needed
 * @dev Uses merkle tree for efficient bulk position updates after trades
 */
interface IGradientMarketMakerPoolV2 {
    // Events
    event ETHLiquidityDeposited(
        address indexed user,
        address token,
        uint256 ethAmount
    );

    event TokenLiquidityDeposited(
        address indexed user,
        address token,
        uint256 tokenAmount
    );

    event ETHLiquidityWithdrawn(
        address indexed user,
        address token,
        uint256 ethAmount
    );

    event TokenLiquidityWithdrawn(
        address indexed user,
        address token,
        uint256 tokenAmount
    );

    event PoolFeeDistributed(
        address indexed from,
        uint256 amount,
        address token
    );

    event FeeClaimed(address indexed user, uint256 amount, address token);

    event PoolBalanceUpdated(
        address indexed token,
        uint256 newTotalEth,
        uint256 newTotalTokens
    );

    event MinLiquidityUpdated(uint256 newMinLiquidity);
    event MinTokenLiquidityUpdated(uint256 newMinTokenLiquidity);

    event MerkleRootUpdated(uint256 indexed version, bytes32 merkleRoot);
    event UserPositionUpdated(
        address indexed user,
        uint256 indexed version,
        uint256 newETHPosition,
        uint256 newTokenPosition
    );

    /**
     * @notice Add liquidity to the pool with optional position update
     * @param tokenAmount Amount of tokens to deposit
     * @param proof Merkle proof for position update (required if user has pending updates)
     * @param newETHPosition New ETH position (required if proof provided)
     * @param newTokenPosition New token position (required if proof provided)
     */
    function addLiquidityWithProof(
        uint256 tokenAmount,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition
    ) external payable;

    /**
     * @notice Add ETH liquidity to the pool for a specific user
     * @param user User address to add liquidity for
     */
    function addETHLiquidityForUser(address user) external payable;

    /**
     * @notice Add token liquidity to the pool for a specific user
     * @param user User address to add liquidity for
     * @param tokenAmount Amount of tokens to deposit
     */
    function addTokenLiquidityForUser(
        address user,
        uint256 tokenAmount
    ) external;

    /**
     * @notice Add ETH liquidity to the pool with optional position update
     * @param proof Merkle proof for position update (required if user has pending updates)
     * @param newETHPosition New ETH position (required if proof provided)
     * @param newTokenPosition New token position (required if proof provided)
     */
    function addETHLiquidityWithProof(
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition
    ) external payable;

    /**
     * @notice Add token liquidity to the pool with optional position update
     * @param tokenAmount Amount of tokens to deposit
     * @param proof Merkle proof for position update (required if user has pending updates)
     * @param newETHPosition New ETH position (required if proof provided)
     * @param newTokenPosition New token position (required if proof provided)
     */
    function addTokenLiquidityWithProof(
        uint256 tokenAmount,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition
    ) external;

    /**
     * @notice Remove liquidity with position update
     * @param shares Percentage of pool to withdraw (in basis points, 10000 = 100%)
     * @param minEthAmount Minimum amount of ETH to receive
     * @param minTokenAmount Minimum amount of tokens to receive
     * @param proof Merkle proof for position update
     * @param newETHPosition New ETH position (actual ETH amount)
     * @param newTokenPosition New token position (actual token amount)
     */
    function removeLiquidityWithUpdate(
        uint256 shares,
        uint256 minEthAmount,
        uint256 minTokenAmount,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition
    ) external;

    /**
     * @notice Remove liquidity with optional position update
     * @param shares Percentage of pool to withdraw (in basis points, 10000 = 100%)
     * @param minEthAmount Minimum amount of ETH to receive
     * @param minTokenAmount Minimum amount of tokens to receive
     * @param proof Merkle proof for position update (required if user has pending updates)
     * @param newETHPosition New ETH position (required if proof provided)
     * @param newTokenPosition New token position (required if proof provided)
     */
    function removeLiquidityWithProof(
        uint256 shares,
        uint256 minEthAmount,
        uint256 minTokenAmount,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition
    ) external;

    /**
     * @notice Remove ETH liquidity with optional position update
     * @param shares Percentage of pool to withdraw (in basis points, 10000 = 100%)
     * @param minEthAmount Minimum amount of ETH to receive
     * @param proof Merkle proof for position update (required if user has pending updates)
     * @param newETHPosition New ETH position (required if proof provided)
     * @param newTokenPosition New token position (required if proof provided)
     */
    function removeETHLiquidityWithProof(
        uint256 shares,
        uint256 minEthAmount,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition
    ) external;

    /**
     * @notice Remove token liquidity with optional position update
     * @param shares Percentage of pool to withdraw (in basis points, 10000 = 100%)
     * @param minTokenAmount Minimum amount of tokens to receive
     * @param proof Merkle proof for position update (required if user has pending updates)
     * @param newETHPosition New ETH position (required if proof provided)
     * @param newTokenPosition New token position (required if proof provided)
     */
    function removeTokenLiquidityWithProof(
        uint256 shares,
        uint256 minTokenAmount,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition
    ) external;

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

    /**
     * @notice Distributes ETH fees to ETH providers only
     */
    function distributePoolFee() external payable;

    /**
     * @notice Distributes token fees to token providers only
     * @param tokenAmount Amount of tokens to distribute as fees
     */
    function distributeTokenFee(uint256 tokenAmount) external;

    /**
     * @notice Claim rewards with optional position update
     * @param proof Merkle proof for position update (required if user has pending updates)
     * @param newETHPosition New ETH position (required if proof provided)
     * @param newTokenPosition New token position (required if proof provided)
     */
    function claimRewardsWithProof(
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external;

    /**
     * @notice Claim only ETH rewards for ETH liquidity providers with optional position update
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
     * @notice Claim only token rewards for token liquidity providers with optional position update
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

    /**
     * @notice Update Merkle root for LP share updates
     * @param version New version number
     * @param newMerkleRoot New Merkle root
     */
    function updateMerkleRoot(uint256 version, bytes32 newMerkleRoot) external;

    /**
     * @notice Set pending position update for automatic processing
     * @param user User address
     * @param proof Merkle proof
     * @param newETHPosition New ETH position (actual ETH amount)
     * @param newTokenPosition New token position (actual token amount)
     */
    function setPendingPositionUpdate(
        address user,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition
    ) external;

    /**
     * @notice Set pending ETH provider position update for automatic processing
     * @param user User address
     * @param proof Merkle proof
     * @param newETHPosition New ETH position (actual ETH amount)
     */
    function setPendingETHProviderPositionUpdate(
        address user,
        bytes32[] calldata proof,
        uint256 newETHPosition
    ) external;

    /**
     * @notice Set pending token provider position update for automatic processing
     * @param user User address
     * @param proof Merkle proof
     * @param newTokenPosition New token position (actual token amount)
     */
    function setPendingTokenProviderPositionUpdate(
        address user,
        bytes32[] calldata proof,
        uint256 newTokenPosition
    ) external;

    /**
     * @notice Update user position using merkle proof
     * @param version Version of the merkle root
     * @param proof Merkle proof for the user's new position
     * @param newETHPosition New ETH position (actual ETH amount)
     * @param newTokenPosition New token position (actual token amount)
     */
    function updateUserPosition(
        uint256 version,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition
    ) external;

    /**
     * @notice Update only ETH provider position using merkle proof
     * @param version Version of the merkle root
     * @param proof Merkle proof for the user's new ETH position
     * @param newETHPosition New ETH position (actual ETH amount)
     */
    function updateETHProviderPosition(
        uint256 version,
        bytes32[] calldata proof,
        uint256 newETHPosition
    ) external;

    /**
     * @notice Update only token provider position using merkle proof
     * @param version Version of the merkle root
     * @param proof Merkle proof for the user's new token position
     * @param newTokenPosition New token position (actual token amount)
     */
    function updateTokenProviderPosition(
        uint256 version,
        bytes32[] calldata proof,
        uint256 newTokenPosition
    ) external;

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

    /**
     * @notice Get user's total position in the pool
     * @param user Address of the user
     * @return ethPosition User's ETH position
     * @return tokenPosition User's token position
     * @return ethSharePercent User's ETH share percentage
     * @return tokenSharePercent User's token share percentage
     * @return pendingRewards User's pending rewards
     */
    function getUserPosition(
        address user
    )
        external
        view
        returns (
            uint256 ethPosition,
            uint256 tokenPosition,
            uint256 ethSharePercent,
            uint256 tokenSharePercent,
            uint256 pendingRewards
        );

    /**
     * @notice Get user's provider status
     * @param user Address of the user
     * @return ethProvider Whether user is ETH provider
     * @return tokenProvider Whether user is token provider
     */
    function getUserProviderStatus(
        address user
    ) external view returns (bool ethProvider, bool tokenProvider);

    // View functions for pool state
    function totalETH() external view returns (uint256);

    function totalTokens() external view returns (uint256);

    function userETHPosition(address user) external view returns (uint256);

    function userTokenPosition(address user) external view returns (uint256);

    // Merkle root view functions
    function merkleRoot() external view returns (bytes32);

    function currentVersion() external view returns (uint256);

    function versionMerkleRoots(
        uint256 version
    ) external view returns (bytes32);

    function userLastUpdateVersion(
        address user
    ) external view returns (uint256);

    // Provider status view functions
    function isETHProvider(address user) external view returns (bool);

    function isTokenProvider(address user) external view returns (bool);
}
