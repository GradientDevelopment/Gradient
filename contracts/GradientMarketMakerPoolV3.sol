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
import {IGradientMarketMakerPoolV3} from "./interfaces/IGradientMarketMakerPoolV3.sol";

// Custom errors
error InvalidTokenAddress();
error TokenBlocked();
error OnlyRewardDistributor();
error OnlyOrderbook();
error OnlyFactory();
error OnlyOwner();
error UnsupportedTokenDecimals();
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
error InvalidPriceRange();
error PriceOutOfRange();
error InvalidPriceOrder();
error OverlappingPriceRange();

/**
 * @title GradientMarketMakerPoolV3
 * @notice Individual pool contract for a single token with price range functionality
 * @dev Each token gets its own pool contract with concentrated liquidity price ranges
 * @dev Users can specify min/max price ranges when adding liquidity
 * @dev Enhanced version with better gas optimization and security
 */
contract GradientMarketMakerPoolV3 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Price range struct for concentrated liquidity
    struct PriceRange {
        uint256 minPrice; // Minimum price (in wei per token)
        uint256 maxPrice; // Maximum price (in wei per token)
        bool isActive; // Whether this range is active
    }

    // Provider position with price range support
    struct ProviderPosition {
        uint256 position;
        uint256 rewardDebt;
        uint256 pendingRewards;
        uint256 lastUpdateVersion;
    }

    // Pool metrics with price range support
    struct PoolMetrics {
        uint256 position; // Total ETH or tokens
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
        uint256 positionMinted,
        bool isETH,
        uint256 minPrice,
        uint256 maxPrice
    );

    event LiquidityWithdrawn(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 positionBurned,
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

    event FeeRefunded(address indexed recipient, uint256 amount, bool isETH);

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
        uint256 newETHPositions,
        uint256 newTokenPositions
    );

    event MinLiquidityUpdated(uint256 newMinLiquidity, bool isETH);

    event PriceRangePercentageUpdated(
        uint256 newMinPriceRangePercentage,
        uint256 newMaxPriceRangePercentage
    );

    event EmergencyWithdraw(
        address indexed token,
        address indexed recipient,
        uint256 amount,
        bool isETH
    );

    // Position events
    event PositionCreated(
        uint256 indexed positionId,
        address indexed owner,
        uint256 amount,
        uint256 minPrice,
        uint256 maxPrice,
        bool isETH
    );

    event PositionUpdated(
        uint256 indexed positionId,
        address indexed owner,
        uint256 newAmount,
        uint256 newMinPrice,
        uint256 newMaxPrice
    );

    event PositionClosed(
        uint256 indexed positionId,
        address indexed owner,
        uint256 amount,
        uint256 rewards
    );

    // Immutable token address - this pool is dedicated to one token
    IERC20 public immutable tokenContract;
    IGradientMarketMakerFactory public immutable factoryContract;

    // Pool state with price range support
    uint256 public totalETH;
    uint256 public totalTokens;

    // Single position per user (like V2 but with price range)
    mapping(address => ProviderPosition) public ethProviders;
    mapping(address => ProviderPosition) public tokenProviders;

    // User price ranges (shared between ETH and token positions)
    mapping(address => PriceRange) public userPriceRanges;

    // Reward tracking - separate ETH pools for each provider type (same as V2)
    uint256 public accRewardPerShare; // For ETH providers (ETH rewards)
    uint256 public accTokenRewardPerShare; // For token providers (token rewards)
    uint256 public rewardBalance; // ETH rewards for ETH providers
    uint256 public tokenProviderRewardBalance; // ETH rewards for token providers

    uint256 public constant SCALE = 1e18;

    // Maximum supported token decimals to prevent overflow
    uint8 public constant MAX_TOKEN_DECIMALS = 24;

    uint8 public tokenDecimals;

    // Configurable minimum liquidity requirements
    uint256 public minLiquidity;
    uint256 public minTokenLiquidity;

    // Track totals for this specific token pool
    uint256 public totalEthAdded;
    uint256 public totalEthRemoved;
    uint256 public totalTokensAdded;
    uint256 public totalTokensRemoved; // Total tokens removed from this pool
    uint256 public totalTokenRewardsDistributed; // Total token rewards distributed

    // Uniswap pair address
    address public uniswapPair;

    // Merkle root for LP share updates
    bytes32 public merkleRoot;
    uint256 public currentVersion;
    mapping(uint256 => bytes32) public versionMerkleRoots;

    // Price range variables (configurable by owner)
    uint256 public minPriceRangePercentage = 100; // 1% minimum range
    uint256 public maxPriceRangePercentage = 100000; // 1000% maximum range

    // Position limits

    // Events are inherited from interface

    modifier isNotBlocked() {
        if (getRegistry().blockedTokens(address(tokenContract)))
            revert TokenBlocked();
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
        if (msg.sender != address(factoryContract)) revert OnlyFactory();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != factoryContract.owner()) revert OnlyOwner();
        _;
    }

    constructor(IERC20 _token, address _factory) {
        if (address(_token) == address(0)) revert InvalidTokenAddress();
        if (_factory == address(0)) revert InvalidRecipient();

        tokenContract = _token;
        factoryContract = IGradientMarketMakerFactory(_factory);

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
        return factoryContract.owner();
    }

    // =============================== INTERNAL FUNCTIONS ===============================

    /**
     * @notice Get the registry address from the factory
     * @return registryAddress Address of the GradientRegistry
     */
    function getRegistry() public view returns (IGradientRegistry) {
        return IGradientRegistry(factoryContract.getRegistry());
    }

    /**
     * @notice Get the event aggregator address from the factory
     * @return eventAggregatorAddress Address of the EventAggregator
     */
    function getEventAggregator() public view returns (IEventAggregator) {
        return IEventAggregator(factoryContract.getEventAggregator());
    }

    /**
     * @notice Validate price range parameters
     * @param minPrice Minimum price
     * @param maxPrice Maximum price
     */
    function _validatePriceRange(
        uint256 minPrice,
        uint256 maxPrice
    ) internal view {
        if (minPrice == 0 || maxPrice == 0) revert InvalidPriceRange();
        if (minPrice >= maxPrice) revert InvalidPriceOrder();

        // Check if range is too narrow (less than 1%)
        uint256 rangePercentage = ((maxPrice - minPrice) * 10000) / minPrice;
        if (rangePercentage < minPriceRangePercentage)
            revert InvalidPriceRange();

        // Check if range is too wide (more than maximum percentage)
        if (rangePercentage > maxPriceRangePercentage)
            revert InvalidPriceRange();
    }

    /**
     * @notice Check if current price is within a given range
     * @param price Current price to check
     * @param minPrice Minimum price
     * @param maxPrice Maximum price
     * @return isWithinRange True if price is within range
     */
    function _isPriceWithinRange(
        uint256 price,
        uint256 minPrice,
        uint256 maxPrice
    ) internal pure returns (bool isWithinRange) {
        return price >= minPrice && price <= maxPrice;
    }

    /**
     * @notice Get current market price from Uniswap
     * @return price Current market price in wei per token
     */
    function _getCurrentPrice() internal view returns (uint256 price) {
        address pairAddress = getPairAddress();
        if (pairAddress == address(0)) revert PairDoesNotExist();

        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pairAddress)
            .getReserves();
        address token0 = IUniswapV2Pair(pairAddress).token0();

        if (token0 == address(tokenContract)) {
            // Token is token0, ETH is token1
            price = (uint256(reserve1) * 1e18) / uint256(reserve0);
        } else {
            // ETH is token0, Token is token1
            price = (uint256(reserve0) * 1e18) / uint256(reserve1);
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
     * @param newETHPosition New ETH position value
     * @param newTokenPosition New token position value
     * @param ethRewardsToAdd ETH rewards to add
     * @param tokenRewardsToAdd Token rewards to add
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

        // Use standard merkle proof verification
        return MerkleProof.verify(proof, merkleRoot, leaf);
    }

    /**
     * @notice Check if user needs position update for either asset type
     * @param user User address to check
     * @return needsUpdate True if user needs position update
     */
    function _needsPositionUpdate(address user) internal view returns (bool) {
        // Check ETH position
        if (
            ethProviders[user].position > 0 &&
            ethProviders[user].lastUpdateVersion < currentVersion
        ) {
            return true;
        }
        if (
            ethProviders[user].pendingRewards > 0 &&
            ethProviders[user].lastUpdateVersion < currentVersion
        ) {
            return true;
        }

        // Check token position
        if (
            tokenProviders[user].position > 0 &&
            tokenProviders[user].lastUpdateVersion < currentVersion
        ) {
            return true;
        }
        if (
            tokenProviders[user].pendingRewards > 0 &&
            tokenProviders[user].lastUpdateVersion < currentVersion
        ) {
            return true;
        }

        return false;
    }

    // =============================== PUBLIC FUNCTIONS ===============================

    /**
     * @notice Add ETH liquidity with price range and optional position update
     * @param minPrice Minimum price for this liquidity position
     * @param maxPrice Maximum price for this liquidity position
     * @param proof Merkle proof for position update (required if user has pending updates)
     * @param newETHPosition New ETH position value (required if proof provided)
     * @param newTokenPosition New token position value (required if proof provided)
     * @param ethRewardsToAdd ETH rewards to add
     * @param tokenRewardsToAdd Token rewards to add
     */
    function addETHLiquidity(
        uint256 minPrice,
        uint256 maxPrice,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external payable isNotBlocked nonReentrant {
        if (msg.value < minLiquidity) revert ETHAmountBelowMinimum();
        _validatePriceRange(minPrice, maxPrice);

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

        // Then add ETH liquidity with price range
        _addETHLiquidity(msg.sender, msg.value, minPrice, maxPrice);
    }

    /**
     * @notice Add token liquidity with price range and optional position update
     * @param tokenAmount Amount of tokens to deposit
     * @param minPrice Minimum price for this liquidity position
     * @param maxPrice Maximum price for this liquidity position
     * @param proof Merkle proof for position update (required if user has pending updates)
     * @param newETHPosition New ETH position value (required if proof provided)
     * @param newTokenPosition New token position value (required if proof provided)
     * @param ethRewardsToAdd ETH rewards to add
     * @param tokenRewardsToAdd Token rewards to add
     */
    function addTokenLiquidity(
        uint256 tokenAmount,
        uint256 minPrice,
        uint256 maxPrice,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external isNotBlocked nonReentrant {
        if (tokenAmount < minTokenLiquidity) revert TokenAmountBelowMinimum();
        _validatePriceRange(minPrice, maxPrice);

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

        // Then add token liquidity with price range
        _addTokenLiquidity(msg.sender, tokenAmount, minPrice, maxPrice);
    }

    /**
     * @notice Add both ETH and token liquidity with price range and optional position update
     * @param tokenAmount Amount of tokens to deposit
     * @param minPrice Minimum price for liquidity position (applies to both ETH and token positions)
     * @param maxPrice Maximum price for liquidity position (applies to both ETH and token positions)
     * @param proof Merkle proof for position update (required if user has pending updates)
     * @param newETHPosition New ETH position value (required if proof provided)
     * @param newTokenPosition New token position value (required if proof provided)
     * @param ethRewardsToAdd ETH rewards to add
     * @param tokenRewardsToAdd Token rewards to add
     */
    function addLiquidity(
        uint256 tokenAmount,
        uint256 minPrice,
        uint256 maxPrice,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external payable isNotBlocked nonReentrant {
        if (msg.value < minLiquidity) revert ETHAmountBelowMinimum();
        if (tokenAmount < minTokenLiquidity) revert TokenAmountBelowMinimum();
        _validatePriceRange(minPrice, maxPrice);

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

        // Then add liquidity with price ranges
        _addETHLiquidity(msg.sender, msg.value, minPrice, maxPrice);
        _addTokenLiquidity(msg.sender, tokenAmount, minPrice, maxPrice);
    }

    /**
     * @notice Add ETH liquidity to the pool with price range (internal function)
     * @param user User address to add liquidity for
     * @param ethAmount Amount of ETH to deposit
     * @param minPrice Minimum price for this liquidity position
     * @param maxPrice Maximum price for this liquidity position
     */
    function _addETHLiquidity(
        address user,
        uint256 ethAmount,
        uint256 minPrice,
        uint256 maxPrice
    ) internal {
        // Initialize Uniswap pair if not set
        if (uniswapPair == address(0)) {
            uniswapPair = getPairAddress();
        }
        if (uniswapPair == address(0)) revert PairDoesNotExist();

        // Get current market price
        _getCurrentPrice();

        // Calculate pending rewards for existing position
        if (ethProviders[user].position > 0) {
            uint256 pendingReward = (ethProviders[user].position *
                accRewardPerShare) /
                SCALE -
                ethProviders[user].rewardDebt;
            ethProviders[user].pendingRewards += pendingReward;
        }

        // Add to existing position or create new one
        if (ethProviders[user].position > 0) {
            // User already has ETH position, add to it
            ethProviders[user].position += ethAmount;
        } else {
            // Create new ETH position
            ethProviders[user] = ProviderPosition({
                position: ethAmount,
                rewardDebt: 0,
                pendingRewards: 0,
                lastUpdateVersion: currentVersion
            });
        }

        // Set or update user price range (allow updates when inactive)
        if (!userPriceRanges[user].isActive) {
            userPriceRanges[user] = PriceRange({
                minPrice: minPrice,
                maxPrice: maxPrice,
                isActive: true
            });
        }

        // Update reward debt for the position
        ethProviders[user].rewardDebt =
            (ethProviders[user].position * accRewardPerShare) /
            SCALE;

        totalETH += ethAmount;
        totalEthAdded += ethAmount;

        uint256 eventMinPrice = userPriceRanges[user].isActive
            ? userPriceRanges[user].minPrice
            : minPrice;
        uint256 eventMaxPrice = userPriceRanges[user].isActive
            ? userPriceRanges[user].maxPrice
            : maxPrice;

        try
            getEventAggregator().emitLiquidityEvent(
                user,
                address(tokenContract),
                0, // ETH_ADD
                ethAmount,
                eventMinPrice,
                eventMaxPrice
            )
        {
            // Success - EventAggregator call completed
        } catch {
            // EventAggregator call failed - continue execution
        }

        // Emit local event
        emit LiquidityDeposited(
            user,
            address(tokenContract),
            ethAmount,
            ethAmount,
            true,
            eventMinPrice,
            eventMaxPrice
        );
    }

    /**
     * @notice Add token liquidity to the pool with price range (internal function)
     * @param user User address to add liquidity for
     * @param tokenAmount Amount of tokens to deposit
     * @param minPrice Minimum price for this liquidity position
     * @param maxPrice Maximum price for this liquidity position
     */
    function _addTokenLiquidity(
        address user,
        uint256 tokenAmount,
        uint256 minPrice,
        uint256 maxPrice
    ) internal {
        // Initialize Uniswap pair if not set
        if (uniswapPair == address(0)) {
            uniswapPair = getPairAddress();
        }
        if (uniswapPair == address(0)) revert PairDoesNotExist();

        // Record balance before transfer to handle fee-on-transfer tokens
        uint256 balanceBefore = tokenContract.balanceOf(address(this));

        // Transfer tokens from user
        tokenContract.safeTransferFrom(msg.sender, address(this), tokenAmount);

        // Calculate actual received amount (handles fee-on-transfer and rebasing tokens)
        uint256 actualReceived = tokenContract.balanceOf(address(this)) -
            balanceBefore;

        // Get current market price
        _getCurrentPrice();

        // Calculate pending rewards for existing position
        if (tokenProviders[user].position > 0) {
            uint256 pendingReward = (tokenProviders[user].position *
                accTokenRewardPerShare) /
                SCALE -
                tokenProviders[user].rewardDebt;
            tokenProviders[user].pendingRewards += pendingReward;
        }

        // Add to existing position or create new one
        if (tokenProviders[user].position > 0) {
            // User already has token position, add to it
            tokenProviders[user].position += actualReceived;
        } else {
            // Create new token position
            tokenProviders[user] = ProviderPosition({
                position: actualReceived,
                rewardDebt: 0,
                pendingRewards: 0,
                lastUpdateVersion: currentVersion
            });
        }

        // Set or update user price range
        if (!userPriceRanges[user].isActive) {
            userPriceRanges[user] = PriceRange({
                minPrice: minPrice,
                maxPrice: maxPrice,
                isActive: true
            });
        }

        // Update reward debt for the position
        tokenProviders[user].rewardDebt =
            (tokenProviders[user].position * accTokenRewardPerShare) /
            SCALE;

        totalTokens += actualReceived;
        totalTokensAdded += actualReceived;

        uint256 eventMinPrice = userPriceRanges[user].isActive
            ? userPriceRanges[user].minPrice
            : minPrice;
        uint256 eventMaxPrice = userPriceRanges[user].isActive
            ? userPriceRanges[user].maxPrice
            : maxPrice;

        try
            getEventAggregator().emitLiquidityEvent(
                user,
                address(tokenContract),
                2, // TOKEN_ADD
                actualReceived,
                eventMinPrice,
                eventMaxPrice
            )
        {
            // Success - EventAggregator call completed
        } catch {
            // EventAggregator call failed - continue execution
        }

        // Emit local event
        emit LiquidityDeposited(
            user,
            address(tokenContract),
            actualReceived,
            actualReceived,
            false,
            eventMinPrice,
            eventMaxPrice
        );
    }

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

        IUniswapV2Factory uniswapFactory = IUniswapV2Factory(factoryAddress);
        return uniswapFactory.getPair(address(tokenContract), weth);
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

        (reserveETH, reserveToken) = token0 == address(tokenContract)
            ? (reserve1, reserve0)
            : (reserve0, reserve1);
    }

    /**
     * @notice Update both ETH and token provider positions using merkle proof
     * @param user User address
     * @param newETHPosition New ETH position value
     * @param newTokenPosition New token position value
     * @param ethRewardsToAdd Total ETH rewards (accumulated)
     * @param tokenRewardsToAdd Total token rewards (accumulated)
     */
    function _updateUserPosition(
        address user,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) internal {
        // Update ETH position
        ethProviders[user].position = newETHPosition;
        ethProviders[user].pendingRewards = ethRewardsToAdd;
        ethProviders[user].lastUpdateVersion = currentVersion;
        ethProviders[user].rewardDebt =
            (newETHPosition * accRewardPerShare) /
            SCALE;

        // Update token position
        tokenProviders[user].position = newTokenPosition;
        tokenProviders[user].pendingRewards = tokenRewardsToAdd;
        tokenProviders[user].lastUpdateVersion = currentVersion;
        uint256 normalizedPosition = _normalizeTo18Decimals(newTokenPosition);
        tokenProviders[user].rewardDebt =
            (normalizedPosition * accTokenRewardPerShare) /
            SCALE;

        // Emit event for position update
        emit UserPositionUpdated(
            user,
            currentVersion,
            newETHPosition,
            newTokenPosition
        );
    }

    function removeETHLiquidityWithProof(
        uint256 shares,
        uint256 minEthAmount,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external {
        if (shares <= 0 || shares > 10000) revert InvalidSharesPercentage();
        if (totalETH == 0) revert NoLiquidity();
        if (ethProviders[msg.sender].position == 0)
            revert NoLiquidityToWithdraw();

        bool needsUpdate = _needsPositionUpdate(msg.sender);
        if (needsUpdate) {
            if (merkleRoot == bytes32(0)) revert NoMerkleRootForUpdates();
            if (
                !_verifyMerkleProof(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition,
                    ethRewardsToAdd,
                    tokenRewardsToAdd
                )
            ) {
                revert InvalidMerkleProof();
            }
            _updateUserPosition(
                msg.sender,
                newETHPosition,
                newTokenPosition,
                ethRewardsToAdd,
                tokenRewardsToAdd
            );
        }

        uint256 pendingReward = (ethProviders[msg.sender].position *
            accRewardPerShare) /
            SCALE -
            ethProviders[msg.sender].rewardDebt;
        ethProviders[msg.sender].pendingRewards += pendingReward;

        uint256 amountToWithdraw = (ethProviders[msg.sender].position *
            shares) / 10000;
        if (amountToWithdraw == 0) revert NoSharesToBurn();
        if (amountToWithdraw > ethProviders[msg.sender].position) {
            amountToWithdraw = ethProviders[msg.sender].position;
        }
        if (amountToWithdraw > totalETH) revert InsufficientPoolBalance();

        ethProviders[msg.sender].position -= amountToWithdraw;
        ethProviders[msg.sender].rewardDebt =
            (ethProviders[msg.sender].position * accRewardPerShare) /
            SCALE;

        // Deactivate price range only if both positions are empty
        if (
            ethProviders[msg.sender].position == 0 &&
            tokenProviders[msg.sender].position == 0
        ) {
            userPriceRanges[msg.sender].isActive = false;
        }

        totalETH -= amountToWithdraw;
        totalEthRemoved += amountToWithdraw;

        if (amountToWithdraw < minEthAmount) revert InsufficientWithdrawal();
        (bool success, ) = payable(msg.sender).call{value: amountToWithdraw}(
            ""
        );
        if (!success) revert ETHTransferFailed();

        emit LiquidityWithdrawn(
            msg.sender,
            address(tokenContract),
            amountToWithdraw,
            amountToWithdraw,
            true,
            userPriceRanges[msg.sender].minPrice,
            userPriceRanges[msg.sender].maxPrice
        );
    }

    function removeTokenLiquidityWithProof(
        uint256 shares,
        uint256 minTokenAmount,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external {
        if (shares <= 0 || shares > 10000) revert InvalidSharesPercentage();
        if (totalTokens == 0) revert NoLiquidity();
        if (tokenProviders[msg.sender].position == 0)
            revert NoLiquidityToWithdraw();

        bool needsUpdate = _needsPositionUpdate(msg.sender);
        if (needsUpdate) {
            if (merkleRoot == bytes32(0)) revert NoMerkleRootForUpdates();
            if (
                !_verifyMerkleProof(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition,
                    ethRewardsToAdd,
                    tokenRewardsToAdd
                )
            ) {
                revert InvalidMerkleProof();
            }
            _updateUserPosition(
                msg.sender,
                newETHPosition,
                newTokenPosition,
                ethRewardsToAdd,
                tokenRewardsToAdd
            );
        }

        uint256 normalizedLpShares = _normalizeTo18Decimals(
            tokenProviders[msg.sender].position
        );
        uint256 pendingReward = (normalizedLpShares * accTokenRewardPerShare) /
            SCALE -
            tokenProviders[msg.sender].rewardDebt;
        tokenProviders[msg.sender].pendingRewards += pendingReward;

        uint256 amountToWithdraw = (tokenProviders[msg.sender].position *
            shares) / 10000;
        if (amountToWithdraw == 0) revert NoSharesToBurn();
        if (amountToWithdraw > tokenProviders[msg.sender].position) {
            amountToWithdraw = tokenProviders[msg.sender].position;
        }
        if (amountToWithdraw > totalTokens) revert InsufficientPoolBalance();

        tokenProviders[msg.sender].position -= amountToWithdraw;
        tokenProviders[msg.sender].rewardDebt =
            (tokenProviders[msg.sender].position * accTokenRewardPerShare) /
            SCALE;

        // Deactivate price range only if both positions are empty
        if (
            ethProviders[msg.sender].position == 0 &&
            tokenProviders[msg.sender].position == 0
        ) {
            userPriceRanges[msg.sender].isActive = false;
        }

        totalTokens -= amountToWithdraw;
        totalTokensRemoved += amountToWithdraw;

        if (amountToWithdraw < minTokenAmount) revert InsufficientWithdrawal();
        tokenContract.safeTransfer(msg.sender, amountToWithdraw);

        emit LiquidityWithdrawn(
            msg.sender,
            address(tokenContract),
            amountToWithdraw,
            amountToWithdraw,
            false,
            userPriceRanges[msg.sender].minPrice,
            userPriceRanges[msg.sender].maxPrice
        );
    }

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
    ) external {
        if (ethShares <= 0 || ethShares > 10000)
            revert InvalidSharesPercentage();
        if (tokenShares <= 0 || tokenShares > 10000)
            revert InvalidSharesPercentage();
        if (totalETH == 0 && totalTokens == 0) revert NoLiquidity();
        if (
            ethProviders[msg.sender].position == 0 &&
            tokenProviders[msg.sender].position == 0
        ) {
            revert NoLiquidityToWithdraw();
        }

        bool needsUpdate = _needsPositionUpdate(msg.sender);
        if (needsUpdate) {
            if (merkleRoot == bytes32(0)) revert NoMerkleRootForUpdates();
            if (
                !_verifyMerkleProof(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition,
                    ethRewardsToAdd,
                    tokenRewardsToAdd
                )
            ) {
                revert InvalidMerkleProof();
            }
            _updateUserPosition(
                msg.sender,
                newETHPosition,
                newTokenPosition,
                ethRewardsToAdd,
                tokenRewardsToAdd
            );
        }

        uint256 ethAmountToWithdraw = 0;
        uint256 tokenAmountToWithdraw = 0;

        if (ethProviders[msg.sender].position > 0) {
            uint256 ethPendingReward = (ethProviders[msg.sender].position *
                accRewardPerShare) /
                SCALE -
                ethProviders[msg.sender].rewardDebt;
            ethProviders[msg.sender].pendingRewards += ethPendingReward;

            ethAmountToWithdraw =
                (ethProviders[msg.sender].position * ethShares) /
                10000;
            if (ethAmountToWithdraw > ethProviders[msg.sender].position) {
                ethAmountToWithdraw = ethProviders[msg.sender].position;
            }
            if (ethAmountToWithdraw > totalETH) {
                ethAmountToWithdraw = totalETH;
            }

            ethProviders[msg.sender].position -= ethAmountToWithdraw;
            ethProviders[msg.sender].rewardDebt =
                (ethProviders[msg.sender].position * accRewardPerShare) /
                SCALE;

            totalETH -= ethAmountToWithdraw;
            totalEthRemoved += ethAmountToWithdraw;
        }

        if (tokenProviders[msg.sender].position > 0) {
            uint256 normalizedTokenLpShares = _normalizeTo18Decimals(
                tokenProviders[msg.sender].position
            );
            uint256 tokenPendingReward = (normalizedTokenLpShares *
                accTokenRewardPerShare) /
                SCALE -
                tokenProviders[msg.sender].rewardDebt;
            tokenProviders[msg.sender].pendingRewards += tokenPendingReward;

            tokenAmountToWithdraw =
                (tokenProviders[msg.sender].position * tokenShares) /
                10000;
            if (tokenAmountToWithdraw > tokenProviders[msg.sender].position) {
                tokenAmountToWithdraw = tokenProviders[msg.sender].position;
            }
            if (tokenAmountToWithdraw > totalTokens) {
                tokenAmountToWithdraw = totalTokens;
            }

            tokenProviders[msg.sender].position -= tokenAmountToWithdraw;
            tokenProviders[msg.sender].rewardDebt =
                (tokenProviders[msg.sender].position * accTokenRewardPerShare) /
                SCALE;

            totalTokens -= tokenAmountToWithdraw;
            totalTokensRemoved += tokenAmountToWithdraw;
        }

        if (
            ethAmountToWithdraw < minEthAmount &&
            tokenAmountToWithdraw < minTokenAmount
        ) revert InsufficientWithdrawal();

        if (ethAmountToWithdraw > 0) {
            (bool success, ) = payable(msg.sender).call{
                value: ethAmountToWithdraw
            }("");
            if (!success) revert ETHTransferFailed();
        }

        if (tokenAmountToWithdraw > 0) {
            tokenContract.safeTransfer(msg.sender, tokenAmountToWithdraw);
        }

        // Deactivate price range only if both positions are empty
        if (
            ethProviders[msg.sender].position == 0 &&
            tokenProviders[msg.sender].position == 0
        ) {
            userPriceRanges[msg.sender].isActive = false;
        }

        // Emit separate events for each position
        if (ethAmountToWithdraw > 0) {
            emit LiquidityWithdrawn(
                msg.sender,
                address(tokenContract),
                ethAmountToWithdraw,
                ethAmountToWithdraw,
                true,
                userPriceRanges[msg.sender].minPrice,
                userPriceRanges[msg.sender].maxPrice
            );
        }

        if (tokenAmountToWithdraw > 0) {
            emit LiquidityWithdrawn(
                msg.sender,
                address(tokenContract),
                tokenAmountToWithdraw,
                tokenAmountToWithdraw,
                false,
                userPriceRanges[msg.sender].minPrice,
                userPriceRanges[msg.sender].maxPrice
            );
        }
    }

    function executeBuyOrder(
        uint256 ethAmount,
        uint256 tokenAmount,
        bytes32 newMerkleRoot
    ) external payable isNotBlocked onlyOrderbook {
        if (ethAmount == 0) revert AmountZero();
        if (tokenAmount == 0) revert AmountZero();
        if (msg.value != ethAmount) revert ETHAmountMismatch();
        if (totalTokens < tokenAmount) revert InsufficientTokenLiquidity();

        totalTokens -= tokenAmount;
        totalTokensRemoved += tokenAmount;
        totalETH += msg.value;
        totalEthAdded += msg.value;

        if (tokenAmount > 0) {
            tokenContract.safeTransfer(msg.sender, tokenAmount);
        }

        _updateMerkleRootAfterTrade(newMerkleRoot);
        emit PoolBalanceUpdated(
            address(tokenContract),
            totalETH,
            totalTokens,
            totalETH,
            totalTokens
        );
    }

    function executeSellOrder(
        uint256 ethAmount,
        uint256 tokenAmount,
        bytes32 newMerkleRoot
    ) external isNotBlocked onlyOrderbook {
        if (ethAmount == 0) revert AmountZero();
        if (tokenAmount == 0) revert AmountZero();
        if (totalETH < ethAmount) revert InsufficientETHLiquidity();

        tokenContract.safeTransferFrom(msg.sender, address(this), tokenAmount);

        totalETH -= ethAmount;
        totalEthRemoved += ethAmount;
        totalTokens += tokenAmount;
        totalTokensAdded += tokenAmount;

        (bool success, ) = payable(msg.sender).call{value: ethAmount}("");
        if (!success) revert ETHTransferToOrderbookFailed();

        _updateMerkleRootAfterTrade(newMerkleRoot);
        emit PoolBalanceUpdated(
            address(tokenContract),
            totalETH,
            totalTokens,
            totalETH,
            totalTokens
        );
    }

    /**
     * @notice Distribute pool fee as ETH rewards to liquidity providers
     * @dev Only callable by reward distributor
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
        emit PoolFeeDistributed(
            msg.sender,
            msg.value,
            address(tokenContract),
            true
        );
    }

    /**
     * @notice Update pool rewards distribution
     * @param ethAmount Amount of ETH to distribute as rewards
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
        } else {
            // No liquidity exists - immediately refund the ETH
            (bool success, ) = payable(msg.sender).call{value: ethAmount}("");
            if (!success) revert ETHTransferFailed();
            emit FeeRefunded(msg.sender, ethAmount, true);
        }

        // Track ETH rewards
        rewardBalance += ethAmount;
    }

    /**
     * @notice Update token pool rewards distribution
     * @param tokenAmount Amount of tokens to distribute as rewards
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
            tokenContract.safeTransfer(msg.sender, tokenAmount);
            emit FeeRefunded(msg.sender, tokenAmount, false);
        }
    }

    /**
     * @notice Distribute token fee as rewards to liquidity providers
     * @param tokenAmount Amount of tokens to distribute as rewards
     * @dev Only callable by reward distributor
     */
    function distributeTokenFee(
        uint256 tokenAmount
    ) external onlyRewardDistributor nonReentrant {
        if (tokenAmount == 0) revert AmountZero();

        // Record balance before transfer to handle fee-on-transfer tokens
        uint256 balanceBefore = tokenContract.balanceOf(address(this));

        // Transfer tokens from orderbook to this contract
        tokenContract.safeTransferFrom(msg.sender, address(this), tokenAmount);

        // Calculate actual received amount (handles fee-on-transfer and rebasing tokens)
        uint256 actualReceived = tokenContract.balanceOf(address(this)) -
            balanceBefore;

        totalTokensAdded += actualReceived;
        _updateTokenRewards(actualReceived);
        emit PoolFeeDistributed(
            msg.sender,
            actualReceived,
            address(tokenContract),
            false
        );
    }

    function claimRewardsWithProof(
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external nonReentrant {
        // Calculate total user position
        uint256 totalUserPosition = 0;
        uint256 totalPendingRewards = 0;

        // Sum up ETH and token positions
        totalUserPosition += ethProviders[msg.sender].position;
        totalPendingRewards += ethProviders[msg.sender].pendingRewards;

        totalUserPosition += tokenProviders[msg.sender].position;
        totalPendingRewards += tokenProviders[msg.sender].pendingRewards;

        if (totalUserPosition == 0 && totalPendingRewards == 0) {
            revert NoLiquidityOrRewards();
        }

        bool needsUpdate = _needsPositionUpdate(msg.sender);
        if (needsUpdate) {
            if (merkleRoot == bytes32(0)) revert NoMerkleRootForUpdates();
            if (
                !_verifyMerkleProof(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition,
                    ethRewardsToAdd,
                    tokenRewardsToAdd
                )
            ) {
                revert InvalidMerkleProof();
            }
            _updateUserPosition(
                msg.sender,
                newETHPosition,
                newTokenPosition,
                ethRewardsToAdd,
                tokenRewardsToAdd
            );
        }

        uint256 ethRewards = 0;
        // Calculate ETH rewards from ETH position
        if (ethProviders[msg.sender].position > 0) {
            uint256 ethAccumulated = (ethProviders[msg.sender].position *
                accRewardPerShare) / SCALE;
            ethRewards += ethAccumulated - ethProviders[msg.sender].rewardDebt;
        }
        ethRewards += ethProviders[msg.sender].pendingRewards;

        uint256 tokenProviderRewards = 0;
        // Calculate token rewards from token position
        if (tokenProviders[msg.sender].position > 0) {
            uint256 normalizedLpShares = _normalizeTo18Decimals(
                tokenProviders[msg.sender].position
            );
            uint256 tokenAccumulated = (normalizedLpShares *
                accTokenRewardPerShare) / SCALE;
            tokenProviderRewards +=
                tokenAccumulated -
                tokenProviders[msg.sender].rewardDebt;
        }
        tokenProviderRewards += tokenProviders[msg.sender].pendingRewards;

        uint256 totalRewards = ethRewards + tokenProviderRewards;
        if (totalRewards == 0) revert NoRewards();

        // Reset reward debt and pending rewards for positions
        if (ethProviders[msg.sender].position > 0) {
            ethProviders[msg.sender].rewardDebt =
                (ethProviders[msg.sender].position * accRewardPerShare) /
                SCALE;
        }
        ethProviders[msg.sender].pendingRewards = 0;

        if (tokenProviders[msg.sender].position > 0) {
            uint256 normalizedLpShares = _normalizeTo18Decimals(
                tokenProviders[msg.sender].position
            );
            tokenProviders[msg.sender].rewardDebt =
                (normalizedLpShares * accTokenRewardPerShare) /
                SCALE;
        }
        tokenProviders[msg.sender].pendingRewards = 0;

        if (ethRewards > 0) {
            totalEthRemoved += ethRewards;
            (bool success, ) = payable(msg.sender).call{value: ethRewards}("");
            if (!success) revert ETHWithdrawalFailed();
        }

        if (tokenProviderRewards > 0) {
            uint256 denormalizedRewards = _denormalizeFrom18Decimals(
                tokenProviderRewards
            );
            tokenContract.safeTransfer(msg.sender, denormalizedRewards);
        }

        emit FeeClaimed(msg.sender, totalRewards, address(tokenContract), true);
    }

    function claimETHRewardsWithProof(
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external nonReentrant {
        bool needsUpdate = _needsPositionUpdate(msg.sender);
        if (needsUpdate) {
            if (merkleRoot == bytes32(0)) revert NoMerkleRootForUpdates();
            if (
                !_verifyMerkleProof(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition,
                    ethRewardsToAdd,
                    tokenRewardsToAdd
                )
            ) {
                revert InvalidMerkleProof();
            }
            _updateUserPosition(
                msg.sender,
                newETHPosition,
                newTokenPosition,
                ethRewardsToAdd,
                tokenRewardsToAdd
            );
        }

        uint256 ethRewards = 0;
        // Calculate ETH rewards from ETH position
        if (ethProviders[msg.sender].position > 0) {
            uint256 ethAccumulated = (ethProviders[msg.sender].position *
                accRewardPerShare) / SCALE;
            ethRewards += ethAccumulated - ethProviders[msg.sender].rewardDebt;
        }
        ethRewards += ethProviders[msg.sender].pendingRewards;

        if (ethRewards == 0) revert NoRewards();

        // Reset reward debt and pending rewards for ETH position
        if (ethProviders[msg.sender].position > 0) {
            ethProviders[msg.sender].rewardDebt =
                (ethProviders[msg.sender].position * accRewardPerShare) /
                SCALE;
        }
        ethProviders[msg.sender].pendingRewards = 0;

        totalEthRemoved += ethRewards;
        (bool success, ) = payable(msg.sender).call{value: ethRewards}("");
        if (!success) revert ETHWithdrawalFailed();

        emit FeeClaimed(msg.sender, ethRewards, address(tokenContract), true);
    }

    function claimTokenRewardsWithProof(
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external nonReentrant {
        bool needsUpdate = _needsPositionUpdate(msg.sender);
        if (needsUpdate) {
            if (merkleRoot == bytes32(0)) revert NoMerkleRootForUpdates();
            if (
                !_verifyMerkleProof(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition,
                    ethRewardsToAdd,
                    tokenRewardsToAdd
                )
            ) {
                revert InvalidMerkleProof();
            }
            _updateUserPosition(
                msg.sender,
                newETHPosition,
                newTokenPosition,
                ethRewardsToAdd,
                tokenRewardsToAdd
            );
        }

        uint256 tokenProviderRewards = 0;
        // Calculate token rewards from token position
        if (tokenProviders[msg.sender].position > 0) {
            uint256 normalizedLpShares = _normalizeTo18Decimals(
                tokenProviders[msg.sender].position
            );
            uint256 tokenAccumulated = (normalizedLpShares *
                accTokenRewardPerShare) / SCALE;
            tokenProviderRewards +=
                tokenAccumulated -
                tokenProviders[msg.sender].rewardDebt;
        }
        tokenProviderRewards += tokenProviders[msg.sender].pendingRewards;

        if (tokenProviderRewards == 0) revert NoTokenProviderRewards();

        // Reset reward debt and pending rewards for token position
        if (tokenProviders[msg.sender].position > 0) {
            uint256 normalizedLpShares = _normalizeTo18Decimals(
                tokenProviders[msg.sender].position
            );
            tokenProviders[msg.sender].rewardDebt =
                (normalizedLpShares * accTokenRewardPerShare) /
                SCALE;
        }
        tokenProviders[msg.sender].pendingRewards = 0;

        uint256 denormalizedRewards = _denormalizeFrom18Decimals(
            tokenProviderRewards
        );
        totalTokensRemoved += denormalizedRewards;
        tokenContract.safeTransfer(msg.sender, denormalizedRewards);

        emit FeeClaimed(
            msg.sender,
            denormalizedRewards,
            address(tokenContract),
            false
        );
    }

    /**
     * @notice Update user position using merkle proof
     * @param version Version of the merkle root
     * @param proof Merkle proof for position update
     * @param newETHPosition New ETH position value
     * @param newTokenPosition New token position value
     * @param ethRewardsToAdd ETH rewards to add
     * @param tokenRewardsToAdd Token rewards to add
     */
    function updateUserPosition(
        uint256 version,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition,
        uint256 ethRewardsToAdd,
        uint256 tokenRewardsToAdd
    ) external {
        // Check if positions have already been updated to this version
        if (version <= ethProviders[msg.sender].lastUpdateVersion) {
            revert VersionAlreadyProcessed();
        }
        if (version <= tokenProviders[msg.sender].lastUpdateVersion) {
            revert VersionAlreadyProcessed();
        }
        if (version > currentVersion) revert VersionNotAvailable();

        if (
            !_verifyMerkleProof(
                msg.sender,
                proof,
                newETHPosition,
                newTokenPosition,
                ethRewardsToAdd,
                tokenRewardsToAdd
            )
        ) {
            revert InvalidMerkleProof();
        }

        _updateUserPosition(
            msg.sender,
            newETHPosition,
            newTokenPosition,
            ethRewardsToAdd,
            tokenRewardsToAdd
        );
    }

    /**
     * @notice Add ETH liquidity for a specific user (factory only)
     * @param user User address to add liquidity for
     * @dev Only callable by factory contract
     */
    function addETHLiquidityForUser(
        address user,
        uint256 minPrice,
        uint256 maxPrice
    ) external payable onlyFactory {
        if (msg.value < minLiquidity) revert ETHAmountBelowMinimum();
        if (user == address(0)) revert InvalidRecipient();

        _addETHLiquidity(user, msg.value, minPrice, maxPrice);
    }

    /**
     * @notice Add token liquidity for a specific user (factory only)
     * @param user User address to add liquidity for
     * @param tokenAmount Amount of tokens to add
     * @dev Only callable by factory contract
     */
    function addTokenLiquidityForUser(
        address user,
        uint256 tokenAmount,
        uint256 minPrice,
        uint256 maxPrice
    ) external onlyFactory {
        if (tokenAmount < minTokenLiquidity) revert TokenAmountBelowMinimum();
        if (user == address(0)) revert InvalidRecipient();

        _addTokenLiquidity(user, tokenAmount, minPrice, maxPrice);
    }

    /**
     * @notice Get user position details including ETH and token positions
     * @param user User address
     * @return ethPosition ETH position amount
     * @return tokenPosition Token position amount
     * @return ethLPShares ETH LP shares
     * @return tokenLPShares Token LP shares
     * @return ethPendingRewards ETH pending rewards
     * @return tokenPendingRewards Token pending rewards
     * @return lastUpdateVersion Last update version
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
        )
    {
        // Get ETH position data
        ethPosition = ethProviders[user].position;
        ethLPShares = ethProviders[user].position;
        ethPendingRewards = ethProviders[user].pendingRewards;
        if (ethProviders[user].lastUpdateVersion > lastUpdateVersion) {
            lastUpdateVersion = ethProviders[user].lastUpdateVersion;
        }

        // Get token position data
        tokenPosition = tokenProviders[user].position;
        tokenLPShares = tokenProviders[user].position;
        tokenPendingRewards = tokenProviders[user].pendingRewards;
        if (tokenProviders[user].lastUpdateVersion > lastUpdateVersion) {
            lastUpdateVersion = tokenProviders[user].lastUpdateVersion;
        }
    }

    /**
     * @notice Get ETH pool metrics
     * @return metrics ETH pool metrics including position, rewards, and current price
     */
    function getETHPoolMetrics()
        external
        view
        returns (PoolMetrics memory metrics)
    {
        metrics.position = totalETH;
        metrics.totalLPShares = totalETH;
        metrics.accRewardPerShare = accRewardPerShare;
        metrics.rewardBalance = rewardBalance;
        metrics.accountedPosition = totalETH;
        metrics.currentPrice = _getCurrentPrice();
    }

    /**
     * @notice Get token pool metrics
     * @return metrics Token pool metrics including position, rewards, and current price
     */
    function getTokenPoolMetrics()
        external
        view
        returns (PoolMetrics memory metrics)
    {
        metrics.position = totalTokens;
        metrics.totalLPShares = totalTokens;
        metrics.accRewardPerShare = accTokenRewardPerShare;
        metrics.rewardBalance = tokenProviderRewardBalance;
        metrics.accountedPosition = totalTokens;
        metrics.currentPrice = _getCurrentPrice();
    }

    /**
     * @notice Get current market price from Uniswap
     * @return price Current market price in wei per token
     */
    function getCurrentPrice() external view returns (uint256 price) {
        return _getCurrentPrice();
    }

    /**
     * @notice Check if a price is within the specified range
     * @param price Price to check
     * @param minPrice Minimum price of the range
     * @param maxPrice Maximum price of the range
     * @return isWithinRange True if price is within range
     */
    function isPriceWithinRange(
        uint256 price,
        uint256 minPrice,
        uint256 maxPrice
    ) external pure returns (bool isWithinRange) {
        return _isPriceWithinRange(price, minPrice, maxPrice);
    }

    /**
     * @notice Set minimum ETH liquidity requirement
     * @param _minLiquidity Minimum ETH liquidity amount
     * @dev Only callable by owner
     */
    function setMinLiquidity(uint256 _minLiquidity) external onlyOwner {
        if (_minLiquidity == 0) revert InvalidMinLiquidity();
        minLiquidity = _minLiquidity;
        emit MinLiquidityUpdated(_minLiquidity, true);
    }

    /**
     * @notice Set minimum token liquidity requirement
     * @param _minTokenLiquidity Minimum token liquidity amount
     * @dev Only callable by owner
     */
    function setMinTokenLiquidity(
        uint256 _minTokenLiquidity
    ) external onlyOwner {
        if (_minTokenLiquidity == 0) revert InvalidMinTokenLiquidity();
        minTokenLiquidity = _minTokenLiquidity;
        emit MinLiquidityUpdated(_minTokenLiquidity, false);
    }

    /**
     * @notice Emergency withdraw ETH from the contract
     * @param recipient Address to receive the ETH
     * @param amount Amount of ETH to withdraw
     * @dev Only callable by owner in emergency situations
     */
    function emergencyWithdrawETH(
        address payable recipient,
        uint256 amount
    ) external onlyOwner {
        if (recipient == address(0)) revert InvalidRecipient();
        if (address(this).balance == 0) revert InsufficientETHBalance();

        uint256 withdrawAmount = amount == 0 ? address(this).balance : amount;
        if (withdrawAmount > address(this).balance)
            revert InsufficientETHBalance();

        (bool success, ) = recipient.call{value: withdrawAmount}("");
        if (!success) revert ETHWithdrawalFailed();

        emit EmergencyWithdraw(
            address(tokenContract),
            recipient,
            withdrawAmount,
            true
        );
    }

    /**
     * @notice Set minimum price range percentage
     * @param _minPriceRangePercentage Minimum price range percentage (in basis points)
     * @dev Only callable by owner
     */
    function setMinPriceRangePercentage(
        uint256 _minPriceRangePercentage
    ) external onlyOwner {
        if (_minPriceRangePercentage == 0) revert InvalidPriceRange();
        if (_minPriceRangePercentage >= maxPriceRangePercentage)
            revert InvalidPriceRange();

        minPriceRangePercentage = _minPriceRangePercentage;
        emit PriceRangePercentageUpdated(
            minPriceRangePercentage,
            maxPriceRangePercentage
        );
    }

    /**
     * @notice Set maximum price range percentage
     * @param _maxPriceRangePercentage Maximum price range percentage (in basis points)
     * @dev Only callable by owner
     */
    function setMaxPriceRangePercentage(
        uint256 _maxPriceRangePercentage
    ) external onlyOwner {
        if (_maxPriceRangePercentage == 0) revert InvalidPriceRange();
        if (_maxPriceRangePercentage <= minPriceRangePercentage)
            revert InvalidPriceRange();

        maxPriceRangePercentage = _maxPriceRangePercentage;
        emit PriceRangePercentageUpdated(
            minPriceRangePercentage,
            maxPriceRangePercentage
        );
    }

    /**
     * @notice Emergency withdraw tokens from the contract
     * @param tokenAddress Address of the token to withdraw
     * @param recipient Address to receive the tokens
     * @param amount Amount of tokens to withdraw
     * @dev Only callable by owner in emergency situations
     */
    function emergencyWithdrawToken(
        address tokenAddress,
        address recipient,
        uint256 amount
    ) external onlyOwner {
        if (tokenAddress == address(0)) revert InvalidTokenAddress();
        if (recipient == address(0)) revert InvalidRecipient();

        IERC20 emergencyToken = IERC20(tokenAddress);
        uint256 balance = emergencyToken.balanceOf(address(this));
        if (balance == 0) revert InsufficientTokenBalance();

        uint256 withdrawAmount = amount == 0 ? balance : amount;
        if (withdrawAmount > balance) revert InsufficientTokenBalance();

        emergencyToken.safeTransfer(recipient, withdrawAmount);

        emit EmergencyWithdraw(tokenAddress, recipient, withdrawAmount, false);
    }
}
