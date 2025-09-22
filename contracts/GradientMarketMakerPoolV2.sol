// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IGradientRegistry} from "./interfaces/IGradientRegistry.sol";
import {IGradientMarketMakerFactory} from "./interfaces/IGradientMarketMakerFactory.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router.sol";
import {IUniswapV2Factory} from "./interfaces/IUniswapV2Factory.sol";
import {IEventAggregator} from "./interfaces/IEventAggregator.sol";

// Custom errors
error InvalidTokenAddress();
error TokenBlocked();
error OnlyRewardDistributor();
error OnlyOrderbook();
error OnlyFactory();
error OnlyOwner();
error AmountZero();
error InsufficientShares();
error InsufficientPoolBalance();
error InsufficientWithdrawal();
error ETHTransferFailed();
error ETHTransferToOrderbookFailed();
error VersionAlreadyProcessed();
error VersionNotAvailable();
error InvalidMerkleProof();
error NoMerkleRootForUpdates();
error InvalidSharesPercentage();
error NoLiquidity();
error NoLiquidityToWithdraw();
error NoSharesToBurn();
error InsufficientSharesToBurn();
error NoRewards();
error NoETHLiquidityOrRewards();
error NoTokenLiquidityOrRewards();
error NoTokenProviderRewards();
error InvalidRecipient();
error InsufficientETHBalance();
error InsufficientTokenBalance();
error ETHWithdrawalFailed();
error TokenWithdrawalFailed();
error RouterNotSet();
error PairDoesNotExist();
error OverflowInETHRewardCalculation();
error OverflowInTokenProviderRewardCalculation();
error OverflowInTokenRewardCalculation();
error ETHAmountMismatch();
error InsufficientTokenLiquidity();
error InsufficientETHLiquidity();
error ETHAmountBelowMinimum();
error TokenAmountBelowMinimum();
error NoETHSent();
error NoLiquidityOrRewards();
error InvalidMinLiquidity();
error InvalidMinTokenLiquidity();
error UnsupportedTokenDecimals();

/**
 * @title GradientMarketMakerPoolV2
 * @notice Individual pool contract for a single token - deployed by factory
 * @dev Each token gets its own pool contract, similar to Uniswap V2 pairs
 * @dev Simplified version without epochs - single pool per token
 * @dev Uses merkle tree for efficient bulk position updates after trades
 */
contract GradientMarketMakerPoolV2 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Immutable token address - this pool is dedicated to one token
    IERC20 public immutable token;
    IGradientMarketMakerFactory public immutable factory;

    // Single pool state (no epochs)
    uint256 public totalETH;
    uint256 public totalTokens;

    // Separate structs for ETH and token providers
    struct ETHProvider {
        uint256 ethPosition;
        uint256 rewardDebt;
        uint256 pendingRewards;
        uint256 lastUpdateVersion;
    }

    struct TokenProvider {
        uint256 tokenPosition;
        uint256 rewardDebt;
        uint256 pendingRewards;
        uint256 lastUpdateVersion;
    }

    // Separate mappings for each provider type
    mapping(address => ETHProvider) public ethProviders;
    mapping(address => TokenProvider) public tokenProviders;

    // Reward tracking - separate ETH pools for each provider type
    uint256 public accRewardPerShare; // For ETH providers (ETH rewards)
    uint256 public accTokenRewardPerShare; // For ETH providers (token rewards)
    uint256 public rewardBalance; // ETH rewards for ETH providers
    uint256 public tokenProviderRewardBalance; // ETH rewards for token providers

    uint256 public constant SCALE = 1e18;

    // Maximum supported token decimals to prevent overflow
    uint8 public constant MAX_TOKEN_DECIMALS = 24;

    // Token decimals for proper reward calculations
    uint8 public tokenDecimals;

    // Configurable minimum liquidity requirements
    uint256 public minLiquidity;
    uint256 public minTokenLiquidity;

    // Track totals for this specific token pool
    uint256 public totalEthAdded; // Total ETH added to this pool
    uint256 public totalEthRemoved; // Total ETH removed from this pool
    uint256 public totalTokensAdded; // Total tokens added to this pool
    uint256 public totalTokensRemoved; // Total tokens removed from this pool
    uint256 public totalTokenRewardsDistributed; // Total token rewards distributed

    // Uniswap pair address
    address public uniswapPair;

    // Merkle root for LP share updates
    bytes32 public merkleRoot;
    uint256 public currentVersion;
    mapping(uint256 => bytes32) public versionMerkleRoots;

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

    event TokenFeeDistributed(
        address indexed from,
        uint256 amount,
        address token
    );

    event FeeClaimed(address indexed user, uint256 amount, address token);

    event FeeRefunded(address indexed recipient, uint256 amount, bool isETH);

    event PoolBalanceUpdated(
        address indexed token,
        uint256 newTotalEth,
        uint256 newTotalTokens
    );

    event MinLiquidityUpdated(uint256 newMinLiquidity);
    event MinTokenLiquidityUpdated(uint256 newMinTokenLiquidity);

    event MerkleRootUpdated(uint256 indexed version, bytes32 merkleRoot);
    event MerkleRootUpdateSkipped(uint256 indexed version, string reason);
    event UserPositionUpdated(
        address indexed user,
        uint256 indexed version,
        uint256 newETHPosition,
        uint256 newTokenPosition
    );

    modifier isNotBlocked() {
        if (getRegistry().blockedTokens(address(token))) revert TokenBlocked();
        _;
    }

    modifier onlyRewardDistributor() {
        if (!getRegistry().isRewardDistributor(msg.sender))
            revert OnlyRewardDistributor();
        _;
    }

    modifier onlyOrderbook() {
        if (msg.sender != getRegistry().orderbook()) revert OnlyOrderbook();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != address(factory)) revert OnlyFactory();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != factory.owner()) revert OnlyOwner();
        _;
    }

    constructor(IERC20 _token, address _factory) {
        if (address(_token) == address(0)) revert InvalidTokenAddress();
        if (_factory == address(0)) revert InvalidRecipient();

        token = _token;
        factory = IGradientMarketMakerFactory(_factory);

        // Initialize token decimals for proper reward calculations
        tokenDecimals = IERC20Metadata(address(_token)).decimals();

        // Validate token decimals to prevent overflow
        if (tokenDecimals > MAX_TOKEN_DECIMALS) {
            revert UnsupportedTokenDecimals();
        }

        minLiquidity = 1e15; // 0.001 ETH minimum (default)
        minTokenLiquidity = 2 * (10 ** tokenDecimals); // Set minimum token liquidity to 2 tokens
    }

    /**
     * @notice Receive ETH for reward distribution
     */
    receive() external payable {}

    /**
     * @notice Get the current owner (factory owner)
     * @return The current owner of the factory
     */
    function owner() public view returns (address) {
        return factory.owner();
    }

    // =============================== INTERNAL FUNCTIONS ===============================

    /**
     * @notice Get the registry address from the factory
     * @return registryAddress Address of the GradientRegistry
     */
    function getRegistry() public view returns (IGradientRegistry) {
        return IGradientRegistry(factory.getRegistry());
    }

    /**
     * @notice Get the event aggregator address from the factory
     * @return eventAggregatorAddress Address of the EventAggregator
     */
    function getEventAggregator() public view returns (IEventAggregator) {
        return IEventAggregator(factory.getEventAggregator());
    }

    /**
     * @notice Updates ETH pool rewards before modifying state
     * @param ethAmount Amount of ETH to distribute as rewards to ETH providers
     */
    function _updatePoolRewards(uint256 ethAmount) internal {
        if (ethAmount == 0) revert AmountZero();

        // Distribute ETH rewards to ETH providers only
        if (totalETH > 0) {
            uint256 newAccRewardPerShare = accRewardPerShare +
                ((ethAmount * SCALE) / totalETH);
            if (newAccRewardPerShare < accRewardPerShare)
                revert OverflowInETHRewardCalculation();
            accRewardPerShare = newAccRewardPerShare;

            // Track ETH rewards
            rewardBalance += ethAmount;
        } else {
            emit FeeRefunded(msg.sender, ethAmount, true);

            (bool success, ) = payable(msg.sender).call{value: ethAmount}("");
            if (!success) revert ETHTransferFailed();
        }
    }

    /**
     * @notice Update token rewards for token providers
     * @param tokenAmount Amount of tokens to distribute as rewards (in token decimals)
     */
    function _updateTokenRewards(uint256 tokenAmount) internal {
        if (tokenAmount == 0) revert AmountZero();

        // Distribute token rewards to token providers only
        if (totalTokens > 0) {
            // Normalize token amount to 18 decimals for consistent calculations
            uint256 normalizedTokenAmount = _normalizeTo18Decimals(tokenAmount);
            uint256 normalizedTotalTokens = _normalizeTo18Decimals(totalTokens);

            uint256 newAccTokenRewardPerShare = accTokenRewardPerShare +
                ((normalizedTokenAmount * SCALE) / normalizedTotalTokens);
            if (newAccTokenRewardPerShare < accTokenRewardPerShare)
                revert OverflowInTokenRewardCalculation();
            accTokenRewardPerShare = newAccTokenRewardPerShare;

            // Track token rewards distributed
            totalTokenRewardsDistributed += tokenAmount;
        } else {
            // No liquidity exists - immediately refund the tokens
            emit FeeRefunded(msg.sender, tokenAmount, false);

            IERC20(token).safeTransfer(msg.sender, tokenAmount);
        }
    }

    /**
     * @notice Normalize token amount to 18 decimals for consistent calculations
     * @param amount Amount in token decimals
     * @return uint256 Amount normalized to 18 decimals
     */
    function _normalizeTo18Decimals(
        uint256 amount
    ) internal view returns (uint256) {
        if (tokenDecimals == 18) {
            return amount;
        } else if (tokenDecimals < 18) {
            return amount * (10 ** (18 - tokenDecimals));
        } else {
            return amount / (10 ** (tokenDecimals - 18));
        }
    }

    /**
     * @notice Denormalize from 18 decimals to token decimals
     * @param amount Amount in 18 decimals
     * @return uint256 Amount in token decimals
     */
    function _denormalizeFrom18Decimals(
        uint256 amount
    ) internal view returns (uint256) {
        if (tokenDecimals == 18) {
            return amount;
        } else if (tokenDecimals < 18) {
            return amount / (10 ** (18 - tokenDecimals));
        } else {
            return amount * (10 ** (tokenDecimals - 18));
        }
    }

    /**
     * @notice Update merkle root after trade execution
     * @param newMerkleRoot New merkle root to set
     */
    function _updateMerkleRootAfterTrade(bytes32 newMerkleRoot) internal {
        if (newMerkleRoot != bytes32(0)) {
            currentVersion++;
            merkleRoot = newMerkleRoot;
            versionMerkleRoots[currentVersion] = newMerkleRoot;

            try
                getEventAggregator().emitMerkleRootUpdated(
                    currentVersion,
                    newMerkleRoot
                )
            {
                // Success - EventAggregator call completed
            } catch {
                // EventAggregator call failed - continue execution
            }

            emit MerkleRootUpdated(currentVersion, newMerkleRoot);
        }
    }

    /**
     * @notice Verify merkle proof for user position update
     * @param user User address
     * @param proof Merkle proof
     * @param newETHPosition New ETH position (actual ETH amount)
     * @param newTokenPosition New token position (actual token amount)
     * @param ethRewardsToAdd Off-chain calculated total ETH rewards
     * @param tokenRewardsToAdd Off-chain calculated total token provider rewards
     * @return isValid Whether the proof is valid
     */
    function _verifyMerkleProof(
        address user,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) internal view returns (bool isValid) {
        bytes32 leaf = keccak256(
            abi.encodePacked(
                user,
                newETHPosition,
                newTokenPosition,
                ethRewardsToAdd,
                tokenRewardsToAdd
            )
        );

        // Special handling for single provider case
        if (proof.length == 0) {
            // For single provider, verify that the leaf equals the merkle root
            return leaf == merkleRoot;
        }

        // For multiple providers, use standard merkle proof verification
        return MerkleProof.verify(proof, merkleRoot, leaf);
    }

    /**
     * @notice Update ETH provider position using merkle proof
     * @param user User address
     * @param newETHPosition New ETH position (actual ETH amount)
     */
    function _updateETHProviderPosition(
        address user,
        uint256 newETHPosition,
        uint256 totalRewards
    ) internal {
        ethProviders[user].pendingRewards = totalRewards;

        // Update user's last update version for ETH provider
        ethProviders[user].lastUpdateVersion = currentVersion;

        // Update ETH provider position
        ethProviders[user].ethPosition = newETHPosition;

        // Update reward debt for the new position to ensure accurate future reward calculations
        ethProviders[user].rewardDebt =
            (newETHPosition * accRewardPerShare) /
            SCALE;
    }

    /**
     * @notice Update token provider position using merkle proof
     * @param user User address
     * @param newTokenPosition New token position (actual token amount)
     */
    function _updateTokenProviderPosition(
        address user,
        uint256 newTokenPosition,
        uint256 totalRewards
    ) internal {
        tokenProviders[user].pendingRewards = totalRewards;

        // Update user's last update version for token provider
        tokenProviders[user].lastUpdateVersion = currentVersion;

        // Update token provider position
        tokenProviders[user].tokenPosition = newTokenPosition;

        // Update reward debt for the new position to ensure accurate future reward calculations
        uint256 normalizedTokenPosition = _normalizeTo18Decimals(
            newTokenPosition
        );
        tokenProviders[user].rewardDebt =
            (normalizedTokenPosition * accTokenRewardPerShare) /
            SCALE;
    }

    /**
     * @notice Update both ETH and token provider positions using merkle proof
     * @param user User address
     * @param newETHPosition New ETH position (actual ETH amount)
     * @param newTokenPosition New token position (actual token amount)
     */
    function _updateUserPosition(
        address user,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethTotalRewards,
        uint256 tokenTotalRewards
    ) internal {
        // Update both provider positions
        _updateETHProviderPosition(user, newETHPosition, ethTotalRewards);
        _updateTokenProviderPosition(user, newTokenPosition, tokenTotalRewards);

        // Emit event for position update
        emit UserPositionUpdated(
            user,
            currentVersion,
            newETHPosition,
            newTokenPosition
        );
    }

    // =============================== INTERNAL HELPER FUNCTIONS ===============================

    /**
     * @notice Check if user needs position update for either asset type
     * @param user User address to check
     * @return needsUpdate True if user needs position update
     */
    function _needsPositionUpdate(address user) internal view returns (bool) {
        return
            (ethProviders[user].ethPosition > 0 &&
                ethProviders[user].lastUpdateVersion < currentVersion) ||
            (tokenProviders[user].tokenPosition > 0 &&
                tokenProviders[user].lastUpdateVersion < currentVersion) ||
            // Also check if user has pending rewards that need position update
            (ethProviders[user].pendingRewards > 0 &&
                ethProviders[user].lastUpdateVersion < currentVersion) ||
            (tokenProviders[user].pendingRewards > 0 &&
                tokenProviders[user].lastUpdateVersion < currentVersion);
    }

    // =============================== PUBLIC FUNCTIONS ===============================

    /**
     * @notice Add ETH liquidity to the pool (internal function)
     * @param user User address to add liquidity for
     * @param ethAmount Amount of ETH to deposit
     */
    function _addETHLiquidity(address user, uint256 ethAmount) internal {
        // Initialize Uniswap pair if not set
        if (uniswapPair == address(0)) {
            uniswapPair = getPairAddress();
        }
        if (uniswapPair == address(0)) revert PairDoesNotExist();

        // Calculate pending rewards before update
        if (ethProviders[user].ethPosition > 0) {
            uint256 pendingReward = (ethProviders[user].ethPosition *
                accRewardPerShare) /
                SCALE -
                ethProviders[user].rewardDebt;
            ethProviders[user].pendingRewards += pendingReward;
        }

        ethProviders[user].ethPosition += ethAmount;

        // Initialize lastUpdateVersion for first-time liquidity providers
        if (ethProviders[user].lastUpdateVersion == 0) {
            ethProviders[user].lastUpdateVersion = currentVersion;
        }

        // Update reward debt
        ethProviders[user].rewardDebt =
            (ethProviders[user].ethPosition * accRewardPerShare) /
            SCALE;

        totalETH += ethAmount;
        totalEthAdded += ethAmount;

        try
            getEventAggregator().emitLiquidityEvent(
                user,
                address(token),
                0, // ETH_ADD
                ethAmount
            )
        {
            // Success - EventAggregator call completed
        } catch {
            // EventAggregator call failed - continue execution
        }

        // Emit local event
        emit ETHLiquidityDeposited(user, address(token), ethAmount);
    }

    /**
     * @notice Add token liquidity to the pool (internal function)
     * @param user User address to add liquidity for
     * @param tokenAmount Amount of tokens to deposit
     */
    function _addTokenLiquidity(address user, uint256 tokenAmount) internal {
        // Initialize Uniswap pair if not set
        if (uniswapPair == address(0)) {
            uniswapPair = getPairAddress();
        }
        if (uniswapPair == address(0)) revert PairDoesNotExist();

        // Record balance before transfer to handle fee-on-transfer tokens
        uint256 balanceBefore = token.balanceOf(address(this));

        // Transfer tokens from user
        token.safeTransferFrom(msg.sender, address(this), tokenAmount);

        // Calculate actual received amount (handles fee-on-transfer and rebasing tokens)
        uint256 actualReceived = token.balanceOf(address(this)) - balanceBefore;

        // Calculate pending rewards before update
        if (tokenProviders[user].tokenPosition > 0) {
            uint256 normalizedPosition = _normalizeTo18Decimals(
                tokenProviders[user].tokenPosition
            );
            uint256 pendingReward = (normalizedPosition *
                accTokenRewardPerShare) /
                SCALE -
                tokenProviders[user].rewardDebt;
            tokenProviders[user].pendingRewards += pendingReward;
        }

        tokenProviders[user].tokenPosition += actualReceived;

        // Initialize lastUpdateVersion for first-time liquidity providers
        if (tokenProviders[user].lastUpdateVersion == 0) {
            tokenProviders[user].lastUpdateVersion = currentVersion;
        }

        // Update reward debt
        uint256 normalizedTokenPosition = _normalizeTo18Decimals(
            tokenProviders[user].tokenPosition
        );
        tokenProviders[user].rewardDebt =
            (normalizedTokenPosition * accTokenRewardPerShare) /
            SCALE;

        totalTokens += actualReceived;
        totalTokensAdded += actualReceived;

        try
            getEventAggregator().emitLiquidityEvent(
                user,
                address(token),
                2, // TOKEN_ADD
                tokenAmount
            )
        {
            // Success - EventAggregator call completed
        } catch {
            // EventAggregator call failed - continue execution
        }

        // Emit local event
        emit TokenLiquidityDeposited(user, address(token), tokenAmount);
    }

    /**
     * @notice Add ETH liquidity to the pool for a specific user
     * @param user User address to add liquidity for
     */
    function addETHLiquidityForUser(
        address user
    ) external payable isNotBlocked nonReentrant onlyFactory {
        if (msg.value < minLiquidity) revert ETHAmountBelowMinimum();
        if (user == address(0)) revert InvalidRecipient();
        _addETHLiquidity(user, msg.value);
    }

    /**
     * @notice Add token liquidity to the pool for a specific user
     * @param user User address to add liquidity for
     * @param tokenAmount Amount of tokens to deposit
     */
    function addTokenLiquidityForUser(
        address user,
        uint256 tokenAmount
    ) external isNotBlocked nonReentrant onlyFactory {
        if (tokenAmount < minTokenLiquidity) revert TokenAmountBelowMinimum();
        if (user == address(0)) revert InvalidRecipient();
        _addTokenLiquidity(user, tokenAmount);
    }

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
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external isNotBlocked nonReentrant {
        if (shares <= 0 || shares > 10000) revert InvalidSharesPercentage();

        // Check if user needs position update for either asset type - only if they have existing liquidity
        bool needsUpdate = _needsPositionUpdate(msg.sender);

        if (needsUpdate) {
            // Proof is required - validate parameters
            if (merkleRoot == bytes32(0)) revert NoMerkleRootForUpdates();

            // Verify merkle proof
            if (
                !_verifyMerkleProof(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition,
                    ethRewardsToAdd,
                    tokenRewardsToAdd
                )
            ) revert InvalidMerkleProof();

            // Update user position first
            _updateUserPosition(
                msg.sender,
                newETHPosition,
                newTokenPosition,
                ethRewardsToAdd,
                tokenRewardsToAdd
            );
        }

        // Then remove liquidity
        _removeETHLiquidity(shares, minEthAmount);
        _removeTokenLiquidity(shares, minTokenAmount);
    }

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
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external isNotBlocked nonReentrant {
        if (shares <= 0 || shares > 10000) revert InvalidSharesPercentage();

        // Check if user needs position update for either asset type - only if they have existing liquidity
        bool needsUpdate = _needsPositionUpdate(msg.sender);

        if (needsUpdate) {
            // Proof is required - validate parameters
            if (merkleRoot == bytes32(0)) revert NoMerkleRootForUpdates();

            // Verify merkle proof
            if (
                !_verifyMerkleProof(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition,
                    ethRewardsToAdd,
                    tokenRewardsToAdd
                )
            ) revert InvalidMerkleProof();

            // Update user position first
            _updateUserPosition(
                msg.sender,
                newETHPosition,
                newTokenPosition,
                ethRewardsToAdd,
                tokenRewardsToAdd
            );
        }

        // Then remove ETH liquidity
        _removeETHLiquidity(shares, minEthAmount);
    }

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
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external isNotBlocked nonReentrant {
        if (shares <= 0 || shares > 10000) revert InvalidSharesPercentage();

        // Check if user needs position update for either asset type - only if they have existing liquidity
        bool needsUpdate = _needsPositionUpdate(msg.sender);

        if (needsUpdate) {
            // Proof is required - validate parameters
            if (merkleRoot == bytes32(0)) revert NoMerkleRootForUpdates();

            // Verify merkle proof
            if (
                !_verifyMerkleProof(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition,
                    ethRewardsToAdd,
                    tokenRewardsToAdd
                )
            ) revert InvalidMerkleProof();

            // Update user position first
            _updateUserPosition(
                msg.sender,
                newETHPosition,
                newTokenPosition,
                ethRewardsToAdd,
                tokenRewardsToAdd
            );
        }

        // Then remove token liquidity
        _removeTokenLiquidity(shares, minTokenAmount);
    }

    // =============================== REMOVAL FUNCTIONS ===============================

    /**
     * @notice Remove ETH liquidity from the pool
     * @param shares Percentage of pool to withdraw (in basis points, 10000 = 100%)
     * @param minEthAmount Minimum amount of ETH to receive
     */
    function _removeETHLiquidity(
        uint256 shares,
        uint256 minEthAmount
    ) internal {
        if (totalETH == 0) revert NoLiquidity();
        if (ethProviders[msg.sender].ethPosition == 0)
            revert NoLiquidityToWithdraw();

        // Calculate pending rewards before withdrawing
        uint256 pendingReward = (ethProviders[msg.sender].ethPosition *
            accRewardPerShare) /
            SCALE -
            ethProviders[msg.sender].rewardDebt;
        ethProviders[msg.sender].pendingRewards += pendingReward;

        // Calculate amount to withdraw based on withdrawal percentage
        uint256 amountToWithdraw = (ethProviders[msg.sender].ethPosition *
            shares) / 10000;
        if (amountToWithdraw == 0) revert NoSharesToBurn();

        // Ensure we don't withdraw more than the user actually has (prevent underflow)
        if (amountToWithdraw > ethProviders[msg.sender].ethPosition) {
            amountToWithdraw = ethProviders[msg.sender].ethPosition;
        }
        if (amountToWithdraw > totalETH) revert InsufficientPoolBalance();

        // Update balances
        ethProviders[msg.sender].ethPosition -= amountToWithdraw;

        // Update reward debt
        ethProviders[msg.sender].rewardDebt =
            (ethProviders[msg.sender].ethPosition * accRewardPerShare) /
            SCALE;

        totalETH -= amountToWithdraw;
        totalEthRemoved += amountToWithdraw;

        // Transfer ETH back to user
        if (amountToWithdraw < minEthAmount) revert InsufficientWithdrawal();
        (bool success, ) = payable(msg.sender).call{value: amountToWithdraw}(
            ""
        );
        if (!success) revert ETHTransferFailed();

        try
            getEventAggregator().emitLiquidityEvent(
                msg.sender,
                address(token),
                1, // ETH_REMOVE
                amountToWithdraw
            )
        {
            // Success - EventAggregator call completed
        } catch {
            // EventAggregator call failed - continue execution
        }

        emit ETHLiquidityWithdrawn(
            msg.sender,
            address(token),
            amountToWithdraw
        );
    }

    /**
     * @notice Remove token liquidity from the pool
     * @param shares Percentage of pool to withdraw (in basis points, 10000 = 100%)
     * @param minTokenAmount Minimum amount of tokens to receive
     */
    function _removeTokenLiquidity(
        uint256 shares,
        uint256 minTokenAmount
    ) internal {
        if (totalTokens == 0) revert NoLiquidity();
        if (tokenProviders[msg.sender].tokenPosition == 0)
            revert NoLiquidityToWithdraw();

        // Calculate pending rewards before withdrawing
        uint256 normalizedPosition = _normalizeTo18Decimals(
            tokenProviders[msg.sender].tokenPosition
        );
        uint256 pendingReward = (normalizedPosition * accTokenRewardPerShare) /
            SCALE -
            tokenProviders[msg.sender].rewardDebt;
        tokenProviders[msg.sender].pendingRewards += pendingReward;

        // Calculate amount to withdraw based on withdrawal percentage
        uint256 amountToWithdraw = (tokenProviders[msg.sender].tokenPosition *
            shares) / 10000;
        if (amountToWithdraw == 0) revert NoSharesToBurn();

        // Ensure we don't withdraw more than the user actually has (prevent underflow)
        if (amountToWithdraw > tokenProviders[msg.sender].tokenPosition) {
            amountToWithdraw = tokenProviders[msg.sender].tokenPosition;
        }

        if (amountToWithdraw > totalTokens) revert InsufficientPoolBalance();

        // Update balances
        tokenProviders[msg.sender].tokenPosition -= amountToWithdraw;

        // Update reward debt
        uint256 normalizedPositionForDebt = _normalizeTo18Decimals(
            tokenProviders[msg.sender].tokenPosition
        );
        tokenProviders[msg.sender].rewardDebt =
            (normalizedPositionForDebt * accTokenRewardPerShare) /
            SCALE;

        totalTokens -= amountToWithdraw;
        totalTokensRemoved += amountToWithdraw;

        // Transfer tokens back to user
        if (amountToWithdraw < minTokenAmount) revert InsufficientWithdrawal();
        if (amountToWithdraw > 0) {
            token.safeTransfer(msg.sender, amountToWithdraw);
        }

        try
            getEventAggregator().emitLiquidityEvent(
                msg.sender,
                address(token),
                3, // TOKEN_REMOVE
                amountToWithdraw
            )
        {
            // Success - EventAggregator call completed
        } catch {
            // EventAggregator call failed - continue execution
        }

        emit TokenLiquidityWithdrawn(
            msg.sender,
            address(token),
            amountToWithdraw
        );
    }

    // =============================== ORDER EXECUTION FUNCTIONS ===============================

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
    ) external payable isNotBlocked onlyOrderbook {
        _executeBuyOrder(ethAmount, tokenAmount, newMerkleRoot);
    }

    /**
     * @notice Internal function to execute buy order
     * @param ethAmount Amount of ETH sent by orderbook
     * @param tokenAmount Amount of tokens to send to orderbook
     * @param newMerkleRoot New merkle root to update after trade
     */
    function _executeBuyOrder(
        uint256 ethAmount,
        uint256 tokenAmount,
        bytes32 newMerkleRoot
    ) internal {
        if (ethAmount == 0) revert AmountZero();
        if (tokenAmount == 0) revert AmountZero();
        if (msg.value != ethAmount) revert ETHAmountMismatch();

        if (totalTokens < tokenAmount) revert InsufficientTokenLiquidity();

        // Pool provides tokens to orderbook
        totalTokens -= tokenAmount;
        totalTokensRemoved += tokenAmount;
        totalETH += msg.value; // Update totalETH with incoming ETH from orderbook
        totalEthAdded += msg.value;

        // Transfer tokens to orderbook
        if (tokenAmount > 0) {
            token.safeTransfer(msg.sender, tokenAmount);
        }

        // Update merkle root if provided
        _updateMerkleRootAfterTrade(newMerkleRoot);

        try
            getEventAggregator().emitTradeExecuted(
                msg.sender, // orderbook address
                0, // BUY trade
                ethAmount,
                tokenAmount
            )
        {
            // Success - EventAggregator call completed
        } catch {
            // EventAggregator call failed - continue execution
        }

        emit PoolBalanceUpdated(address(token), totalETH, totalTokens);
    }

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
    ) external isNotBlocked onlyOrderbook {
        _executeSellOrder(ethAmount, tokenAmount, newMerkleRoot);
    }

    /**
     * @notice Internal function to execute sell order
     * @param ethAmount Amount of ETH to send to orderbook
     * @param tokenAmount Amount of tokens sent by orderbook
     * @param newMerkleRoot New merkle root to update after trade
     */
    function _executeSellOrder(
        uint256 ethAmount,
        uint256 tokenAmount,
        bytes32 newMerkleRoot
    ) internal {
        if (ethAmount == 0) revert AmountZero();
        if (tokenAmount == 0) revert AmountZero();

        if (totalETH < ethAmount) revert InsufficientETHLiquidity();

        // Record balance before transfer to handle fee-on-transfer tokens
        uint256 balanceBefore = token.balanceOf(address(this));

        // Transfer tokens from orderbook to market maker pool
        token.safeTransferFrom(msg.sender, address(this), tokenAmount);

        // Calculate actual received amount (handles fee-on-transfer and rebasing tokens)
        uint256 actualReceived = token.balanceOf(address(this)) - balanceBefore;

        // Pool provides ETH to orderbook
        totalETH -= ethAmount;
        totalEthRemoved += ethAmount;
        totalTokens += actualReceived;
        totalTokensAdded += actualReceived;

        // Transfer ETH to orderbook
        (bool success, ) = payable(msg.sender).call{value: ethAmount}("");
        if (!success) revert ETHTransferToOrderbookFailed();

        // Update merkle root if provided
        _updateMerkleRootAfterTrade(newMerkleRoot);

        try
            getEventAggregator().emitTradeExecuted(
                msg.sender, // orderbook address
                1, // SELL trade
                ethAmount,
                tokenAmount
            )
        {
            // Success - EventAggregator call completed
        } catch {
            // EventAggregator call failed - continue execution
        }

        emit PoolBalanceUpdated(address(token), totalETH, totalTokens);
    }

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
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external nonReentrant {
        // Check if version is newer than the last update for either provider type
        if (
            version <= ethProviders[msg.sender].lastUpdateVersion ||
            version <= tokenProviders[msg.sender].lastUpdateVersion
        ) revert VersionAlreadyProcessed();
        if (version > currentVersion) revert VersionNotAvailable();

        // Verify merkle proof
        if (
            !_verifyMerkleProof(
                msg.sender,
                proof,
                newETHPosition,
                newTokenPosition,
                ethRewardsToAdd,
                tokenRewardsToAdd
            )
        ) revert InvalidMerkleProof();

        // Update user position
        _updateUserPosition(
            msg.sender,
            newETHPosition,
            newTokenPosition,
            ethRewardsToAdd,
            tokenRewardsToAdd
        );
    }

    // =============================== REWARD DISTRIBUTION FUNCTIONS ===============================

    /**
     * @notice Distributes fee distribution from orderbook to be distributed to market makers
     */
    function distributePoolFee()
        external
        payable
        onlyRewardDistributor
        nonReentrant
    {
        if (msg.value == 0) revert NoETHSent();
        totalEthAdded += msg.value;
        _updatePoolRewards(msg.value);

        emit PoolFeeDistributed(msg.sender, msg.value, address(token));
    }

    /**
     * @notice Distributes token fees to token providers only
     * @param tokenAmount Amount of tokens to distribute as fees
     */
    function distributeTokenFee(
        uint256 tokenAmount
    ) external onlyRewardDistributor nonReentrant {
        if (tokenAmount == 0) revert AmountZero();

        // Record balance before transfer to handle fee-on-transfer tokens
        uint256 balanceBefore = token.balanceOf(address(this));

        // Transfer tokens from orderbook to this contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        uint256 actualReceived = token.balanceOf(address(this)) - balanceBefore;

        // Update token rewards using the same pattern as distributePoolFee
        totalTokensAdded += actualReceived;
        _updateTokenRewards(actualReceived);

        emit TokenFeeDistributed(msg.sender, tokenAmount, address(token));
    }

    // =============================== USER FUNCTIONS ===============================

    /**
     * @notice Add ETH liquidity to the pool with optional position update
     * @param proof Merkle proof for position update (required if user has pending updates)
     * @param newETHPosition New ETH position (required if proof provided)
     * @param newTokenPosition New token position (required if proof provided)
     */
    function addETHLiquidityWithProof(
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external payable isNotBlocked nonReentrant {
        if (msg.value < minLiquidity) revert ETHAmountBelowMinimum();

        // Check if user needs position update - only if they have existing liquidity
        if (_needsPositionUpdate(msg.sender)) {
            // Proof is required - validate parameters
            if (merkleRoot == bytes32(0)) revert NoMerkleRootForUpdates();

            // Verify merkle proof
            if (
                !_verifyMerkleProof(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition,
                    ethRewardsToAdd,
                    tokenRewardsToAdd
                )
            ) revert InvalidMerkleProof();

            // Update user position first
            _updateUserPosition(
                msg.sender,
                newETHPosition,
                newTokenPosition,
                ethRewardsToAdd,
                tokenRewardsToAdd
            );
        }

        // Then add ETH liquidity
        _addETHLiquidity(msg.sender, msg.value);
    }

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
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external isNotBlocked nonReentrant {
        if (tokenAmount < minTokenLiquidity) revert TokenAmountBelowMinimum();

        // Check if user needs position update - only if they have existing liquidity
        if (_needsPositionUpdate(msg.sender)) {
            // Proof is required - validate parameters
            if (merkleRoot == bytes32(0)) revert NoMerkleRootForUpdates();

            // Verify merkle proof
            if (
                !_verifyMerkleProof(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition,
                    ethRewardsToAdd,
                    tokenRewardsToAdd
                )
            ) revert InvalidMerkleProof();

            // Update user position first
            _updateUserPosition(
                msg.sender,
                newETHPosition,
                newTokenPosition,
                ethRewardsToAdd,
                tokenRewardsToAdd
            );
        }

        // Then add token liquidity
        _addTokenLiquidity(msg.sender, tokenAmount);
    }

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
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external payable isNotBlocked nonReentrant {
        if (msg.value < minLiquidity) revert ETHAmountBelowMinimum();
        if (tokenAmount < minTokenLiquidity) revert TokenAmountBelowMinimum();

        // Check if user needs position update for either asset type - only if they have existing liquidity
        bool needsUpdate = _needsPositionUpdate(msg.sender);

        if (needsUpdate) {
            // Proof is required - validate parameters
            if (merkleRoot == bytes32(0)) revert NoMerkleRootForUpdates();

            // Verify merkle proof
            if (
                !_verifyMerkleProof(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition,
                    ethRewardsToAdd,
                    tokenRewardsToAdd
                )
            ) revert InvalidMerkleProof();

            // Update user position first
            _updateUserPosition(
                msg.sender,
                newETHPosition,
                newTokenPosition,
                ethRewardsToAdd,
                tokenRewardsToAdd
            );
        }

        // Then add liquidity
        _addETHLiquidity(msg.sender, msg.value);
        _addTokenLiquidity(msg.sender, tokenAmount);
    }

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
    ) external nonReentrant {
        uint256 totalUserPosition = ethProviders[msg.sender].ethPosition +
            tokenProviders[msg.sender].tokenPosition;
        if (
            totalUserPosition == 0 &&
            ethProviders[msg.sender].pendingRewards == 0 &&
            tokenProviders[msg.sender].pendingRewards == 0
        ) revert NoLiquidityOrRewards();

        // Check if user needs position update for either asset type - only if they have existing liquidity
        bool needsUpdate = _needsPositionUpdate(msg.sender);

        if (needsUpdate) {
            // Proof is required - validate parameters
            if (merkleRoot == bytes32(0)) revert NoMerkleRootForUpdates();

            // Verify merkle proof
            if (
                !_verifyMerkleProof(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition,
                    ethRewardsToAdd,
                    tokenRewardsToAdd
                )
            ) revert InvalidMerkleProof();

            // Update user position first
            _updateUserPosition(
                msg.sender,
                newETHPosition,
                newTokenPosition,
                ethRewardsToAdd,
                tokenRewardsToAdd
            );
        }

        // Calculate ETH rewards after position update (if any)
        uint256 ethRewards = 0;
        if (ethProviders[msg.sender].ethPosition > 0) {
            uint256 ethAccumulated = (ethProviders[msg.sender].ethPosition *
                accRewardPerShare) / SCALE;
            ethRewards = ethAccumulated - ethProviders[msg.sender].rewardDebt;
        }
        // Always add pending rewards
        ethRewards += ethProviders[msg.sender].pendingRewards;

        // Calculate token rewards from token positions after position update (if any)
        uint256 tokenProviderRewards = 0;
        if (tokenProviders[msg.sender].tokenPosition > 0) {
            uint256 normalizedTokenPosition = _normalizeTo18Decimals(
                tokenProviders[msg.sender].tokenPosition
            );
            uint256 tokenAccumulated = (normalizedTokenPosition *
                accTokenRewardPerShare) / SCALE;
            tokenProviderRewards =
                tokenAccumulated -
                tokenProviders[msg.sender].rewardDebt;
        }
        // Always add pending rewards
        tokenProviderRewards += tokenProviders[msg.sender].pendingRewards;

        uint256 totalRewards = ethRewards + tokenProviderRewards;
        if (totalRewards == 0) revert NoRewards();

        // Update reward debt for both asset types
        if (ethProviders[msg.sender].ethPosition > 0) {
            ethProviders[msg.sender].rewardDebt =
                (ethProviders[msg.sender].ethPosition * accRewardPerShare) /
                SCALE;
        }
        if (tokenProviders[msg.sender].tokenPosition > 0) {
            uint256 normalizedTokenPosition = _normalizeTo18Decimals(
                tokenProviders[msg.sender].tokenPosition
            );
            tokenProviders[msg.sender].rewardDebt =
                (normalizedTokenPosition * accTokenRewardPerShare) /
                SCALE;
        }

        // Clear pending rewards
        ethProviders[msg.sender].pendingRewards = 0;
        tokenProviders[msg.sender].pendingRewards = 0;

        // Transfer ETH rewards
        if (ethRewards > 0) {
            totalEthRemoved += ethRewards;
            (bool success, ) = payable(msg.sender).call{value: ethRewards}("");
            if (!success) revert ETHWithdrawalFailed();
        }

        // Transfer token rewards
        if (tokenProviderRewards > 0) {
            // Denormalize rewards from 18 decimals back to token decimals
            uint256 denormalizedRewards = _denormalizeFrom18Decimals(
                tokenProviderRewards
            );
            token.safeTransfer(msg.sender, denormalizedRewards);
        }

        // Emit events to EventAggregator
        if (ethRewards > 0) {
            try
                getEventAggregator().emitETHRewardsClaimed(
                    msg.sender,
                    address(token),
                    ethRewards
                )
            {
                // Success - EventAggregator call completed
            } catch {
                // EventAggregator call failed - continue execution
            }
        }
        if (tokenProviderRewards > 0) {
            uint256 denormalizedRewards = _denormalizeFrom18Decimals(
                tokenProviderRewards
            );
            try
                getEventAggregator().emitTokenRewardsClaimed(
                    msg.sender,
                    address(token),
                    denormalizedRewards
                )
            {
                // Success - EventAggregator call completed
            } catch {
                // EventAggregator call failed - continue execution
            }
        }

        emit FeeClaimed(msg.sender, totalRewards, address(token));
    }

    /**
     * @notice Claim only ETH rewards for ETH liquidity providers with optional position update
     * @param proof Merkle proof for position update (required if user has pending updates)
     * @param newETHPosition New ETH position (required if proof provided)
     * @param newTokenPosition New token position (required if proof provided)
     */
    function claimETHRewardsWithProof(
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external nonReentrant {
        // Check if user needs position update for either asset type - only if they have existing liquidity
        bool needsUpdate = _needsPositionUpdate(msg.sender);

        if (needsUpdate) {
            // Proof is required - validate parameters
            if (merkleRoot == bytes32(0)) revert NoMerkleRootForUpdates();

            // Verify merkle proof
            if (
                !_verifyMerkleProof(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition,
                    ethRewardsToAdd,
                    tokenRewardsToAdd
                )
            ) revert InvalidMerkleProof();

            // Update user position first
            _updateUserPosition(
                msg.sender,
                newETHPosition,
                newTokenPosition,
                ethRewardsToAdd,
                tokenRewardsToAdd
            );
        }

        // Calculate ETH rewards from ETH positions only
        uint256 ethRewards = 0;
        if (ethProviders[msg.sender].ethPosition > 0) {
            uint256 ethAccumulated = (ethProviders[msg.sender].ethPosition *
                accRewardPerShare) / SCALE;
            ethRewards = ethAccumulated - ethProviders[msg.sender].rewardDebt;
        }
        // Always add pending rewards
        ethRewards += ethProviders[msg.sender].pendingRewards;

        if (ethRewards == 0) revert NoRewards();

        // Update reward debt
        if (ethProviders[msg.sender].ethPosition > 0) {
            ethProviders[msg.sender].rewardDebt =
                (ethProviders[msg.sender].ethPosition * accRewardPerShare) /
                SCALE;
        }

        // Clear pending rewards
        ethProviders[msg.sender].pendingRewards = 0;

        // Transfer ETH rewards
        totalEthRemoved += ethRewards;
        (bool success, ) = payable(msg.sender).call{value: ethRewards}("");
        if (!success) revert ETHWithdrawalFailed();

        try
            getEventAggregator().emitETHRewardsClaimed(
                msg.sender,
                address(token),
                ethRewards
            )
        {
            // Success - EventAggregator call completed
        } catch {
            // EventAggregator call failed - continue execution
        }

        emit FeeClaimed(msg.sender, ethRewards, address(token));
    }

    /**
     * @notice Claim only ETH rewards for token liquidity providers with optional position update
     * @param proof Merkle proof for position update (required if user has pending updates)
     * @param newETHPosition New ETH position (required if proof provided)
     * @param newTokenPosition New token position (required if proof provided)
     */
    function claimTokenRewardsWithProof(
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external nonReentrant {
        // Check if user needs position update for either asset type - only if they have existing liquidity
        bool needsUpdate = _needsPositionUpdate(msg.sender);

        if (needsUpdate) {
            // Proof is required - validate parameters
            if (merkleRoot == bytes32(0)) revert NoMerkleRootForUpdates();

            // Verify merkle proof
            if (
                !_verifyMerkleProof(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition,
                    ethRewardsToAdd,
                    tokenRewardsToAdd
                )
            ) revert InvalidMerkleProof();

            // Update user position first
            _updateUserPosition(
                msg.sender,
                newETHPosition,
                newTokenPosition,
                ethRewardsToAdd,
                tokenRewardsToAdd
            );
        }

        // Calculate token rewards from token positions only
        uint256 tokenProviderRewards = 0;
        if (tokenProviders[msg.sender].tokenPosition > 0) {
            // Normalize token position to 18 decimals for consistent calculation
            uint256 normalizedTokenPosition = _normalizeTo18Decimals(
                tokenProviders[msg.sender].tokenPosition
            );
            uint256 tokenAccumulated = (normalizedTokenPosition *
                accTokenRewardPerShare) / SCALE;
            tokenProviderRewards =
                tokenAccumulated -
                tokenProviders[msg.sender].rewardDebt;
        }
        // Always add pending rewards
        tokenProviderRewards += tokenProviders[msg.sender].pendingRewards;

        if (tokenProviderRewards == 0) revert NoTokenProviderRewards();

        // Update reward debt
        if (tokenProviders[msg.sender].tokenPosition > 0) {
            uint256 normalizedTokenPosition = _normalizeTo18Decimals(
                tokenProviders[msg.sender].tokenPosition
            );
            tokenProviders[msg.sender].rewardDebt =
                (normalizedTokenPosition * accTokenRewardPerShare) /
                SCALE;
        }

        // Clear pending rewards
        tokenProviders[msg.sender].pendingRewards = 0;

        // Transfer token rewards
        uint256 denormalizedRewards = _denormalizeFrom18Decimals(
            tokenProviderRewards
        );
        totalTokensRemoved += denormalizedRewards;
        token.safeTransfer(msg.sender, denormalizedRewards);

        try
            getEventAggregator().emitTokenRewardsClaimed(
                msg.sender,
                address(token),
                denormalizedRewards
            )
        {
            // Success - EventAggregator call completed
        } catch {
            // EventAggregator call failed - continue execution
        }

        emit FeeClaimed(msg.sender, denormalizedRewards, address(token));
    }

    // =============================== VIEW FUNCTIONS ===============================

    /**
     * @notice Get the Uniswap V2 pair address for this token
     * @return pairAddress Address of the Uniswap V2 pair
     */
    function getPairAddress() public view returns (address pairAddress) {
        address routerAddress = getRegistry().router();
        if (routerAddress == address(0)) revert RouterNotSet();

        IUniswapV2Router02 router = IUniswapV2Router02(routerAddress);
        address factoryAddress = router.factory();
        address weth = router.WETH();

        IUniswapV2Factory factoryContract = IUniswapV2Factory(factoryAddress);
        return factoryContract.getPair(address(token), weth);
    }

    /**
     * @notice Get the reserves for this token pair
     * @return reserveETH ETH reserve amount
     * @return reserveToken Token reserve amount
     */
    function getReserves()
        public
        view
        returns (uint256 reserveETH, uint256 reserveToken)
    {
        address pairAddress = getPairAddress();
        if (pairAddress == address(0)) revert PairDoesNotExist();

        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pairAddress)
            .getReserves();
        address token0 = IUniswapV2Pair(pairAddress).token0();

        (reserveETH, reserveToken) = token0 == address(token)
            ? (reserve1, reserve0)
            : (reserve0, reserve1);
    }

    // =============================== OWNER FUNCTIONS ===============================

    /**
     * @notice Set minimum ETH liquidity requirement
     * @param _minLiquidity New minimum ETH liquidity amount
     */
    function setMinLiquidity(uint256 _minLiquidity) external onlyOwner {
        if (_minLiquidity == 0) revert InvalidMinLiquidity();
        minLiquidity = _minLiquidity;
        emit MinLiquidityUpdated(_minLiquidity);
    }

    /**
     * @notice Set minimum token liquidity requirement
     * @param _minTokenLiquidity New minimum token liquidity amount
     */
    function setMinTokenLiquidity(
        uint256 _minTokenLiquidity
    ) external onlyOwner {
        if (_minTokenLiquidity == 0) revert InvalidMinTokenLiquidity();
        minTokenLiquidity = _minTokenLiquidity;
        emit MinTokenLiquidityUpdated(_minTokenLiquidity);
    }
}
