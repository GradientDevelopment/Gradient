// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
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
error AmountZero();
error InsufficientShares();
error InsufficientPoolBalance();
error InsufficientWithdrawal();
error ETHTransferFailed();
error ETHTransferToOrderbookFailed();
error VersionAlreadyProcessed();
error VersionNotAvailable();
error InvalidMerkleProof();
error NoMerkleRoot();
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
error InvalidMerkleRoot();
error VersionMustBeGreater();
error InvalidRecipient();
error InsufficientETHBalance();
error InsufficientTokenBalance();
error ETHWithdrawalFailed();
error TokenWithdrawalFailed();
error RouterNotSet();
error PairDoesNotExist();
error OverflowInETHRewardCalculation();
error OverflowInTokenProviderRewardCalculation();
error ETHAmountMismatch();
error InsufficientTokenLiquidity();
error InsufficientETHLiquidity();
error ETHAmountBelowMinimum();
error TokenAmountBelowMinimum();
error NoETHSent();
error NoLiquidityOrRewards();
error InvalidMinLiquidity();
error InvalidMinTokenLiquidity();

/**
 * @title GradientMarketMakerPoolV2
 * @notice Individual pool contract for a single token - deployed by factory
 * @dev Each token gets its own pool contract, similar to Uniswap V2 pairs
 * @dev Simplified version without epochs - single pool per token
 * @dev Uses merkle tree for efficient bulk position updates after trades
 */
contract GradientMarketMakerPoolV2 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Immutable token address - this pool is dedicated to one token
    IERC20 public immutable token;
    IGradientMarketMakerFactory public immutable factory;

    // Single pool state (no epochs)
    uint256 public totalETH;
    uint256 public totalTokens;

    // Separate LP shares tracking for each asset type
    uint256 public totalETHLPShares;
    uint256 public totalTokenLPShares;

    // Separate structs for ETH and token providers
    struct ETHProvider {
        uint256 ethPosition;
        uint256 ethLPShares;
        uint256 rewardDebt;
        uint256 pendingRewards;
        uint256 lastUpdateVersion;
    }

    struct TokenProvider {
        uint256 tokenPosition;
        uint256 tokenLPShares;
        uint256 rewardDebt;
        uint256 pendingRewards;
        uint256 lastUpdateVersion;
    }

    // Separate mappings for each provider type
    mapping(address => ETHProvider) public ethProviders;
    mapping(address => TokenProvider) public tokenProviders;

    // Reward tracking - separate ETH pools for each provider type
    uint256 public accRewardPerShare; // For ETH providers (ETH rewards)
    uint256 public accTokenProviderRewardPerShare; // For token providers (ETH rewards)
    uint256 public rewardBalance; // ETH rewards for ETH providers
    uint256 public tokenProviderRewardBalance; // ETH rewards for token providers

    uint256 public constant SCALE = 1e18;

    // Configurable minimum liquidity requirements
    uint256 public minLiquidity = 1e15; // 0.001 ETH minimum (default)
    uint256 public minTokenLiquidity = 1e15; // 0.001 tokens minimum (default)

    // Track totals for this specific token pool
    uint256 public totalEthAdded; // Total ETH added to this pool
    uint256 public totalEthRemoved; // Total ETH removed from this pool
    uint256 public totalTokensAdded; // Total tokens added to this pool
    uint256 public totalTokensRemoved; // Total tokens removed from this pool

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

    event PoolFeeDistributed(
        address indexed from,
        uint256 amount,
        address token
    );

    event FeeClaimed(address indexed user, uint256 amount, address token);

    event PoolBalanceUpdated(
        address indexed token,
        uint256 newTotalEth,
        uint256 newTotalTokens,
        uint256 newTotalETHLPShares,
        uint256 newTotalTokenLPShares
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

    constructor(IERC20 _token, address _owner) Ownable(_owner) {
        if (address(_token) == address(0)) revert InvalidTokenAddress();
        if (_owner == address(0)) revert InvalidRecipient();

        token = _token;
        factory = IGradientMarketMakerFactory(msg.sender);
    }

    /**
     * @notice Receive ETH for reward distribution
     */
    receive() external payable {}

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
     * @notice Calculate LP shares using a more secure formula to prevent precision loss
     * @param amount Amount being deposited
     * @param totalAmount Total amount in pool
     * @param totalShares Total shares in pool
     * @return sharesToMint Number of shares to mint
     */
    function calculateLPShares(
        uint256 amount,
        uint256 totalAmount,
        uint256 totalShares
    ) public pure returns (uint256 sharesToMint) {
        if (amount == 0) revert AmountZero();

        if (totalShares == 0) {
            return amount;
        }

        sharesToMint = (amount * totalShares) / totalAmount;
        if (sharesToMint == 0) revert InsufficientShares();

        return sharesToMint;
    }

    /**
     * @notice Updates ETH pool rewards before modifying state
     * @param ethAmount Amount of ETH to distribute as rewards to ETH providers
     */
    function _updatePoolRewards(uint256 ethAmount) internal {
        if (ethAmount == 0) revert AmountZero();

        // Distribute ETH rewards to ETH providers only
        if (totalETHLPShares > 0) {
            uint256 newAccRewardPerShare = accRewardPerShare +
                ((ethAmount * SCALE) / totalETHLPShares);
            if (newAccRewardPerShare < accRewardPerShare)
                revert OverflowInETHRewardCalculation();
            accRewardPerShare = newAccRewardPerShare;
        }

        // Track ETH rewards
        rewardBalance += ethAmount;
    }

    /**
     * @notice Calculate withdrawal amount with proper validation
     * @param sharesToBurn Number of shares being burned
     * @param totalAmount Total amount in pool
     * @param totalShares Total shares in pool
     * @return withdrawalAmount Amount to withdraw
     */
    function _calculateWithdrawalAmount(
        uint256 sharesToBurn,
        uint256 totalAmount,
        uint256 totalShares
    ) internal pure returns (uint256 withdrawalAmount) {
        if (sharesToBurn == 0) revert AmountZero();
        if (totalShares == 0) revert NoLiquidity();

        withdrawalAmount = (sharesToBurn * totalAmount) / totalShares;
        if (withdrawalAmount > totalAmount) revert InsufficientPoolBalance();

        return withdrawalAmount;
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

            // Emit to EventAggregator instead of local event
            getEventAggregator().emitMerkleRootUpdated(
                currentVersion,
                newMerkleRoot
            );

            emit MerkleRootUpdated(currentVersion, newMerkleRoot);
        }
    }

    /**
     * @notice Verify merkle proof for user position update
     * @param user User address
     * @param proof Merkle proof
     * @param newETHPosition New ETH position (actual ETH amount)
     * @param newTokenPosition New token position (actual token amount)
     * @return isValid Whether the proof is valid
     */
    function _verifyMerkleProof(
        address user,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition
    ) internal view returns (bool isValid) {
        bytes32 leaf = keccak256(
            abi.encodePacked(user, newETHPosition, newTokenPosition)
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
        uint256 newETHPosition
    ) internal {
        // Calculate pending rewards BEFORE updating position to preserve earned fees
        uint256 pendingReward = 0;
        if (ethProviders[user].ethLPShares > 0) {
            pendingReward =
                (ethProviders[user].ethLPShares * accRewardPerShare) /
                SCALE -
                ethProviders[user].rewardDebt;
            ethProviders[user].pendingRewards += pendingReward;
        }

        // Store old LP shares before updating
        uint256 oldUserLPShares = ethProviders[user].ethLPShares;

        // Update user's last update version for ETH provider
        ethProviders[user].lastUpdateVersion = currentVersion;

        // Update ETH provider position and calculate corresponding LP shares
        ethProviders[user].ethPosition = newETHPosition;
        if (totalETH > 0 && totalETHLPShares > 0) {
            // Calculate new LP shares based on position and current pool ratio
            uint256 newUserLPShares = (newETHPosition * totalETHLPShares) /
                totalETH;

            // Update totalETHLPShares by the difference (old - old + new = new - old)
            totalETHLPShares =
                totalETHLPShares -
                oldUserLPShares +
                newUserLPShares;

            // Set user's new LP shares
            ethProviders[user].ethLPShares = newUserLPShares;
        } else if (totalETH > 0 && totalETHLPShares == 0) {
            // First user getting ETH position after trade - initialize
            ethProviders[user].ethLPShares = newETHPosition;
            totalETHLPShares = newETHPosition;
        } else {
            // If pool is empty, LP shares = position
            ethProviders[user].ethLPShares = newETHPosition;
        }

        // Update reward debt for the new LP shares to ensure accurate future reward calculations
        ethProviders[user].rewardDebt =
            (ethProviders[user].ethLPShares * accRewardPerShare) /
            SCALE;
    }

    /**
     * @notice Update token provider position using merkle proof
     * @param user User address
     * @param newTokenPosition New token position (actual token amount)
     */
    function _updateTokenProviderPosition(
        address user,
        uint256 newTokenPosition
    ) internal {
        // Calculate pending rewards BEFORE updating position to preserve earned fees
        uint256 pendingReward = 0;
        if (tokenProviders[user].tokenLPShares > 0) {
            pendingReward =
                (tokenProviders[user].tokenLPShares *
                    accTokenProviderRewardPerShare) /
                SCALE -
                tokenProviders[user].rewardDebt;
            tokenProviders[user].pendingRewards += pendingReward;
        }

        // Store old LP shares before updating
        uint256 oldUserLPShares = tokenProviders[user].tokenLPShares;

        // Update user's last update version for token provider
        tokenProviders[user].lastUpdateVersion = currentVersion;

        // Update token provider position and calculate corresponding LP shares
        tokenProviders[user].tokenPosition = newTokenPosition;
        if (totalTokens > 0 && totalTokenLPShares > 0) {
            // Calculate new LP shares based on position and current pool ratio
            uint256 newUserLPShares = (newTokenPosition * totalTokenLPShares) /
                totalTokens;

            // Update totalTokenLPShares by the difference (old - old + new = new - old)
            totalTokenLPShares =
                totalTokenLPShares -
                oldUserLPShares +
                newUserLPShares;

            // Set user's new LP shares
            tokenProviders[user].tokenLPShares = newUserLPShares;
        } else if (totalTokens > 0 && totalTokenLPShares == 0) {
            // First user getting token position after trade - initialize
            tokenProviders[user].tokenLPShares = newTokenPosition;
            totalTokenLPShares = newTokenPosition;
        } else {
            // If pool is empty, LP shares = position
            tokenProviders[user].tokenLPShares = newTokenPosition;
        }

        // Update reward debt for the new LP shares to ensure accurate future reward calculations
        tokenProviders[user].rewardDebt =
            (tokenProviders[user].tokenLPShares *
                accTokenProviderRewardPerShare) /
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
        uint256 newTokenPosition
    ) internal {
        // Update both provider positions
        _updateETHProviderPosition(user, newETHPosition);
        _updateTokenProviderPosition(user, newTokenPosition);

        // Emit event for position update
        emit UserPositionUpdated(
            user,
            currentVersion,
            newETHPosition,
            newTokenPosition
        );
    }

    /**
     * @notice Update only ETH provider position using merkle proof
     * @param user User address
     * @param newETHPosition New ETH position (actual ETH amount)
     */
    function _updateOnlyETHProviderPosition(
        address user,
        uint256 newETHPosition
    ) internal {
        _updateETHProviderPosition(user, newETHPosition);

        // Emit event for ETH-only position update
        emit UserPositionUpdated(
            user,
            currentVersion,
            newETHPosition,
            tokenProviders[user].tokenPosition
        );
    }

    /**
     * @notice Update only token provider position using merkle proof
     * @param user User address
     * @param newTokenPosition New token position (actual token amount)
     */
    function _updateOnlyTokenProviderPosition(
        address user,
        uint256 newTokenPosition
    ) internal {
        _updateTokenProviderPosition(user, newTokenPosition);

        // Emit event for token-only position update
        emit UserPositionUpdated(
            user,
            currentVersion,
            ethProviders[user].ethPosition,
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
            (ethProviders[user].ethLPShares > 0 &&
                ethProviders[user].lastUpdateVersion < currentVersion) ||
            (tokenProviders[user].tokenLPShares > 0 &&
                tokenProviders[user].lastUpdateVersion < currentVersion) ||
            // Also check if user has pending rewards that need position update
            (ethProviders[user].pendingRewards > 0 &&
                ethProviders[user].lastUpdateVersion < currentVersion) ||
            (tokenProviders[user].pendingRewards > 0 &&
                tokenProviders[user].lastUpdateVersion < currentVersion);
    }

    /**
     * @notice Check if an empty proof is valid for a user
     * @dev Empty proofs are valid for single providers where the leaf equals the merkle root
     * @param user User address
     * @param proof Merkle proof array
     * @param newETHPosition New ETH position
     * @param newTokenPosition New token position
     * @return isValid Whether the empty proof is valid for this user
     */
    function _isEmptyProofValid(
        address user,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition
    ) internal view returns (bool isValid) {
        // Empty proof is only valid if it's a single provider scenario
        if (proof.length == 0) {
            // Check if this user is the only provider
            bool isUserOnlyProvider = (totalETHLPShares == 0 ||
                ethProviders[user].ethLPShares == totalETHLPShares) &&
                (totalTokenLPShares == 0 ||
                    tokenProviders[user].tokenLPShares == totalTokenLPShares);

            if (isUserOnlyProvider) {
                // For single provider, verify that the leaf equals the merkle root
                bytes32 leaf = keccak256(
                    abi.encodePacked(user, newETHPosition, newTokenPosition)
                );
                return leaf == merkleRoot;
            }
        }
        return false;
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

        // Calculate pending rewards before update - only use ETH LP shares
        if (ethProviders[user].ethLPShares > 0) {
            uint256 pendingReward = (ethProviders[user].ethLPShares *
                accRewardPerShare) /
                SCALE -
                ethProviders[user].rewardDebt;
            ethProviders[user].pendingRewards += pendingReward;
        }

        // Calculate LP shares to mint
        uint256 lpSharesToMint = calculateLPShares(
            ethAmount,
            totalETH,
            totalETHLPShares
        );

        ethProviders[user].ethLPShares += lpSharesToMint;
        ethProviders[user].ethPosition += ethAmount;

        // Initialize lastUpdateVersion for first-time liquidity providers
        if (ethProviders[user].lastUpdateVersion == 0) {
            ethProviders[user].lastUpdateVersion = currentVersion;
        }

        // Update reward debt using only ETH LP shares
        ethProviders[user].rewardDebt =
            (ethProviders[user].ethLPShares * accRewardPerShare) /
            SCALE;

        totalETH += ethAmount;
        totalETHLPShares += lpSharesToMint;
        totalEthAdded += ethAmount;

        // Emit to EventAggregator
        getEventAggregator().emitLiquidityEvent(
            user,
            address(token),
            0, // ETH_ADD
            ethAmount,
            lpSharesToMint
        );

        // Emit local event
        emit ETHLiquidityDeposited(
            user,
            address(token),
            ethAmount,
            lpSharesToMint
        );
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

        // Transfer tokens from user
        token.safeTransferFrom(msg.sender, address(this), tokenAmount);

        // Calculate pending rewards before update - only use token LP shares
        if (tokenProviders[user].tokenLPShares > 0) {
            uint256 pendingReward = (tokenProviders[user].tokenLPShares *
                accTokenProviderRewardPerShare) /
                SCALE -
                tokenProviders[user].rewardDebt;
            tokenProviders[user].pendingRewards += pendingReward;
        }

        // Calculate LP shares to mint
        uint256 lpSharesToMint = calculateLPShares(
            tokenAmount,
            totalTokens,
            totalTokenLPShares
        );

        tokenProviders[user].tokenLPShares += lpSharesToMint;
        tokenProviders[user].tokenPosition += tokenAmount;

        // Initialize lastUpdateVersion for first-time liquidity providers
        if (tokenProviders[user].lastUpdateVersion == 0) {
            tokenProviders[user].lastUpdateVersion = currentVersion;
        }

        // Update reward debt using only token LP shares
        tokenProviders[user].rewardDebt =
            (tokenProviders[user].tokenLPShares *
                accTokenProviderRewardPerShare) /
            SCALE;

        totalTokens += tokenAmount;
        totalTokenLPShares += lpSharesToMint;
        totalTokensAdded += tokenAmount;

        // Emit to EventAggregator
        getEventAggregator().emitLiquidityEvent(
            user,
            address(token),
            2, // TOKEN_ADD
            tokenAmount,
            lpSharesToMint
        );

        // Emit local event
        emit TokenLiquidityDeposited(
            user,
            address(token),
            tokenAmount,
            lpSharesToMint
        );
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
        uint256 newTokenPosition
    ) external isNotBlocked nonReentrant {
        if (shares <= 0 || shares > 10000) revert InvalidSharesPercentage();

        // Check if user needs position update for either asset type - only if they have existing liquidity
        bool needsUpdate = _needsPositionUpdate(msg.sender);

        if (needsUpdate) {
            // Proof is required - validate parameters
            // Allow empty proof for single provider scenarios
            if (
                proof.length == 0 &&
                !_isEmptyProofValid(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition
                )
            ) {
                revert InvalidMerkleProof();
            }
            if (merkleRoot == bytes32(0)) revert NoMerkleRootForUpdates();

            // Verify merkle proof
            if (
                !_verifyMerkleProof(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition
                )
            ) revert InvalidMerkleProof();

            // Update user position first
            _updateUserPosition(msg.sender, newETHPosition, newTokenPosition);
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
        uint256 newTokenPosition
    ) external isNotBlocked nonReentrant {
        if (shares <= 0 || shares > 10000) revert InvalidSharesPercentage();

        // Check if user needs position update for either asset type - only if they have existing liquidity
        bool needsUpdate = _needsPositionUpdate(msg.sender);

        if (needsUpdate) {
            // Proof is required - validate parameters
            // Allow empty proof for single provider scenarios
            if (
                proof.length == 0 &&
                !_isEmptyProofValid(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition
                )
            ) {
                revert InvalidMerkleProof();
            }
            if (merkleRoot == bytes32(0)) revert NoMerkleRootForUpdates();

            // Verify merkle proof
            if (
                !_verifyMerkleProof(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition
                )
            ) revert InvalidMerkleProof();

            // Update user position first
            _updateUserPosition(msg.sender, newETHPosition, newTokenPosition);
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
        uint256 newTokenPosition
    ) external isNotBlocked nonReentrant {
        if (shares <= 0 || shares > 10000) revert InvalidSharesPercentage();

        // Check if user needs position update for either asset type - only if they have existing liquidity
        bool needsUpdate = _needsPositionUpdate(msg.sender);

        if (needsUpdate) {
            // Proof is required - validate parameters
            // Allow empty proof for single provider scenarios
            if (
                proof.length == 0 &&
                !_isEmptyProofValid(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition
                )
            ) {
                revert InvalidMerkleProof();
            }
            if (merkleRoot == bytes32(0)) revert NoMerkleRootForUpdates();

            // Verify merkle proof
            if (
                !_verifyMerkleProof(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition
                )
            ) revert InvalidMerkleProof();

            // Update user position first
            _updateUserPosition(msg.sender, newETHPosition, newTokenPosition);
        }

        // Then remove token liquidity
        _removeTokenLiquidity(shares, minTokenAmount);
    }

    /**
     * @notice Update user position using merkle proof
     * @param user User address
     * @param proof Merkle proof for position update
     * @param newETHPosition New ETH position (actual ETH amount)
     * @param newTokenPosition New token position (actual token amount)
     */
    function _updatePositionWithProof(
        address user,
        bytes32[] calldata proof,
        uint256 newETHPosition,
        uint256 newTokenPosition
    ) internal {
        // Verify merkle proof is valid and current
        if (!_verifyMerkleProof(user, proof, newETHPosition, newTokenPosition))
            revert InvalidMerkleProof();

        // Additional validation: ensure proof is for current merkle root
        if (merkleRoot == bytes32(0)) revert NoMerkleRoot();

        // Update user position
        _updateUserPosition(user, newETHPosition, newTokenPosition);
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
        if (totalETHLPShares == 0) revert NoLiquidity();
        if (ethProviders[msg.sender].ethPosition == 0)
            revert NoLiquidityToWithdraw();

        // Calculate pending rewards before withdrawing - only use ETH LP shares
        uint256 pendingReward = (ethProviders[msg.sender].ethLPShares *
            accRewardPerShare) /
            SCALE -
            ethProviders[msg.sender].rewardDebt;
        ethProviders[msg.sender].pendingRewards += pendingReward;

        // Calculate LP shares to burn based on withdrawal percentage - only use ETH LP shares
        uint256 lpSharesToBurn = (ethProviders[msg.sender].ethLPShares *
            shares) / 10000;
        if (lpSharesToBurn == 0) revert NoSharesToBurn();

        // Ensure we don't burn more LP shares than the user actually has (prevent underflow)
        if (lpSharesToBurn > ethProviders[msg.sender].ethLPShares) {
            lpSharesToBurn = ethProviders[msg.sender].ethLPShares;
        }

        // Calculate actual withdrawal amounts based on LP shares
        uint256 actualEthWithdraw = _calculateWithdrawalAmount(
            lpSharesToBurn,
            totalETH,
            totalETHLPShares
        );
        if (actualEthWithdraw > totalETH) revert InsufficientPoolBalance();

        // Ensure we don't withdraw more than the user's actual position (prevent underflow)
        if (actualEthWithdraw > ethProviders[msg.sender].ethPosition) {
            actualEthWithdraw = ethProviders[msg.sender].ethPosition;
        }

        // Update balances
        ethProviders[msg.sender].ethPosition -= actualEthWithdraw;
        ethProviders[msg.sender].ethLPShares -= lpSharesToBurn; // Remove from ETH LP shares

        // Update reward debt using only ETH LP shares
        ethProviders[msg.sender].rewardDebt =
            (ethProviders[msg.sender].ethLPShares * accRewardPerShare) /
            SCALE;

        totalETH -= actualEthWithdraw;
        totalETHLPShares -= lpSharesToBurn;

        // Transfer ETH back to user
        if (actualEthWithdraw < minEthAmount) revert InsufficientWithdrawal();
        (bool success, ) = payable(msg.sender).call{value: actualEthWithdraw}(
            ""
        );
        if (!success) revert ETHTransferFailed();

        // Track total ETH removed by LPs
        totalEthRemoved += actualEthWithdraw;

        // Emit to EventAggregator instead of local event
        getEventAggregator().emitLiquidityEvent(
            msg.sender,
            address(token),
            1, // ETH_REMOVE
            actualEthWithdraw,
            lpSharesToBurn
        );

        emit ETHLiquidityWithdrawn(
            msg.sender,
            address(token),
            actualEthWithdraw,
            lpSharesToBurn
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
        if (totalTokenLPShares == 0) revert NoLiquidity();
        if (tokenProviders[msg.sender].tokenPosition == 0)
            revert NoLiquidityToWithdraw();

        // Calculate pending rewards before withdrawing - only use token LP shares
        uint256 pendingReward = (tokenProviders[msg.sender].tokenLPShares *
            accTokenProviderRewardPerShare) /
            SCALE -
            tokenProviders[msg.sender].rewardDebt;
        tokenProviders[msg.sender].pendingRewards += pendingReward;

        // Calculate LP shares to burn based on withdrawal percentage - only use token LP shares
        uint256 lpSharesToBurn = (tokenProviders[msg.sender].tokenLPShares *
            shares) / 10000;
        if (lpSharesToBurn == 0) revert NoSharesToBurn();

        // Ensure we don't burn more LP shares than the user actually has (prevent underflow)
        if (lpSharesToBurn > tokenProviders[msg.sender].tokenLPShares) {
            lpSharesToBurn = tokenProviders[msg.sender].tokenLPShares;
        }

        // Calculate actual withdrawal amounts based on LP shares
        uint256 actualTokenWithdraw = _calculateWithdrawalAmount(
            lpSharesToBurn,
            totalTokens,
            totalTokenLPShares
        );
        if (actualTokenWithdraw > totalTokens) revert InsufficientPoolBalance();

        // Ensure we don't withdraw more than the user's actual position (prevent underflow)
        if (actualTokenWithdraw > tokenProviders[msg.sender].tokenPosition) {
            actualTokenWithdraw = tokenProviders[msg.sender].tokenPosition;
        }

        // Update balances
        tokenProviders[msg.sender].tokenPosition -= actualTokenWithdraw;
        tokenProviders[msg.sender].tokenLPShares -= lpSharesToBurn; // Remove from token LP shares

        // Update reward debt using only token LP shares
        tokenProviders[msg.sender].rewardDebt =
            (tokenProviders[msg.sender].tokenLPShares *
                accTokenProviderRewardPerShare) /
            SCALE;

        totalTokens -= actualTokenWithdraw;
        totalTokenLPShares -= lpSharesToBurn;

        // Transfer tokens back to user
        if (actualTokenWithdraw < minTokenAmount)
            revert InsufficientWithdrawal();
        if (actualTokenWithdraw > 0) {
            token.safeTransfer(msg.sender, actualTokenWithdraw);
        }

        // Track total tokens removed by LPs
        totalTokensRemoved += actualTokenWithdraw;

        // Emit to EventAggregator instead of local event
        getEventAggregator().emitLiquidityEvent(
            msg.sender,
            address(token),
            3, // TOKEN_REMOVE
            actualTokenWithdraw,
            lpSharesToBurn
        );

        emit TokenLiquidityWithdrawn(
            msg.sender,
            address(token),
            actualTokenWithdraw,
            lpSharesToBurn
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

        // Emit trade event to EventAggregator
        getEventAggregator().emitTradeExecuted(
            msg.sender, // orderbook address
            0, // BUY trade
            ethAmount,
            tokenAmount
        );

        emit PoolBalanceUpdated(
            address(token),
            totalETH,
            totalTokens,
            totalETHLPShares,
            totalTokenLPShares
        );
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

        // Transfer tokens from orderbook to market maker pool
        token.safeTransferFrom(msg.sender, address(this), tokenAmount);

        // Pool provides ETH to orderbook
        totalETH -= ethAmount;
        totalEthRemoved += ethAmount;
        totalTokens += tokenAmount; // CRITICAL: Update totalTokens with incoming tokens from orderbook
        totalTokensAdded += tokenAmount;

        // Transfer ETH to orderbook
        (bool success, ) = payable(msg.sender).call{value: ethAmount}("");
        if (!success) revert ETHTransferToOrderbookFailed();

        // Update merkle root if provided
        _updateMerkleRootAfterTrade(newMerkleRoot);

        // Emit trade event to EventAggregator
        getEventAggregator().emitTradeExecuted(
            msg.sender, // orderbook address
            1, // SELL trade
            ethAmount,
            tokenAmount
        );

        emit PoolBalanceUpdated(
            address(token),
            totalETH,
            totalTokens,
            totalETHLPShares,
            totalTokenLPShares
        );
    }

    // =============================== MERKLE ROOT FUNCTIONS ===============================

    /**
     * @notice Update Merkle root for LP share updates
     * @param version New version number
     * @param newMerkleRoot New Merkle root
     * @dev Only callable by owner (off-chain server)
     */
    function updateMerkleRoot(
        uint256 version,
        bytes32 newMerkleRoot
    ) external onlyOwner {
        if (version <= currentVersion) revert VersionAlreadyProcessed();
        if (newMerkleRoot == bytes32(0)) revert InvalidMerkleRoot();

        currentVersion = version;
        merkleRoot = newMerkleRoot;
        versionMerkleRoots[version] = newMerkleRoot;

        // Emit to EventAggregator instead of local event
        getEventAggregator().emitMerkleRootUpdated(version, newMerkleRoot);

        emit MerkleRootUpdated(version, newMerkleRoot);
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
        uint256 newTokenPosition
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
                newTokenPosition
            )
        ) revert InvalidMerkleProof();

        // Update user position
        _updateUserPosition(msg.sender, newETHPosition, newTokenPosition);
    }

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
    ) external nonReentrant {
        // Check if version is newer than the last update for ETH provider
        if (version <= ethProviders[msg.sender].lastUpdateVersion)
            revert VersionAlreadyProcessed();
        if (version > currentVersion) revert VersionNotAvailable();

        // Verify merkle proof (only ETH position)
        if (
            !_verifyMerkleProof(
                msg.sender,
                proof,
                newETHPosition,
                tokenProviders[msg.sender].tokenPosition
            )
        ) revert InvalidMerkleProof();

        // Update only ETH provider position
        _updateOnlyETHProviderPosition(msg.sender, newETHPosition);
    }

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
    ) external nonReentrant {
        // Check if version is newer than the last update for token provider
        if (version <= tokenProviders[msg.sender].lastUpdateVersion)
            revert VersionAlreadyProcessed();
        if (version > currentVersion) revert VersionNotAvailable();

        // Verify merkle proof (only token position)
        if (
            !_verifyMerkleProof(
                msg.sender,
                proof,
                ethProviders[msg.sender].ethPosition,
                newTokenPosition
            )
        ) revert InvalidMerkleProof();

        // Update only token provider position
        _updateOnlyTokenProviderPosition(msg.sender, newTokenPosition);
    }

    // =============================== REWARD DISTRIBUTION FUNCTIONS ===============================

    /**
     * @notice Distributes fee distribution from orderbook to be distributed to market makers
     */
    function distributePoolFee() external payable onlyRewardDistributor {
        if (msg.value == 0) revert NoETHSent();
        totalEthAdded += msg.value;
        _updatePoolRewards(msg.value);

        emit PoolFeeDistributed(msg.sender, msg.value, address(token));
    }

    /**
     * @notice Distributes ETH fees to token providers only
     */
    function distributeTokenProviderFee()
        external
        payable
        onlyRewardDistributor
    {
        if (msg.value == 0) revert NoETHSent();

        // Distribute ETH rewards to token providers only
        if (totalTokenLPShares > 0) {
            uint256 newAccTokenProviderRewardPerShare = accTokenProviderRewardPerShare +
                    ((msg.value * SCALE) / totalTokenLPShares);
            if (
                newAccTokenProviderRewardPerShare <
                accTokenProviderRewardPerShare
            ) revert OverflowInTokenProviderRewardCalculation();
            accTokenProviderRewardPerShare = newAccTokenProviderRewardPerShare;
        }

        // Track ETH rewards for token providers
        tokenProviderRewardBalance += msg.value;

        emit PoolFeeDistributed(msg.sender, msg.value, address(token));
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
        uint256 newTokenPosition
    ) external payable isNotBlocked nonReentrant {
        if (msg.value < minLiquidity) revert ETHAmountBelowMinimum();

        // Check if user needs position update - only if they have existing liquidity
        if (_needsPositionUpdate(msg.sender)) {
            // Proof is required - validate parameters
            // Allow empty proof for single provider scenarios
            if (
                proof.length == 0 &&
                !_isEmptyProofValid(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition
                )
            ) {
                revert InvalidMerkleProof();
            }
            if (merkleRoot == bytes32(0)) revert NoMerkleRootForUpdates();

            // Verify merkle proof
            if (
                !_verifyMerkleProof(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition
                )
            ) revert InvalidMerkleProof();

            // Update user position first
            _updateUserPosition(msg.sender, newETHPosition, newTokenPosition);
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
        uint256 newTokenPosition
    ) external isNotBlocked nonReentrant {
        if (tokenAmount < minTokenLiquidity) revert TokenAmountBelowMinimum();

        // Check if user needs position update - only if they have existing liquidity
        if (_needsPositionUpdate(msg.sender)) {
            // Proof is required - validate parameters
            // Allow empty proof for single provider scenarios
            if (
                proof.length == 0 &&
                !_isEmptyProofValid(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition
                )
            ) {
                revert InvalidMerkleProof();
            }
            if (merkleRoot == bytes32(0)) revert NoMerkleRootForUpdates();

            // Verify merkle proof
            if (
                !_verifyMerkleProof(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition
                )
            ) revert InvalidMerkleProof();

            // Update user position first
            _updateUserPosition(msg.sender, newETHPosition, newTokenPosition);
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
        uint256 newTokenPosition
    ) external payable isNotBlocked nonReentrant {
        if (msg.value < minLiquidity) revert ETHAmountBelowMinimum();
        if (tokenAmount < minTokenLiquidity) revert TokenAmountBelowMinimum();

        // Check if user needs position update for either asset type - only if they have existing liquidity
        bool needsUpdate = _needsPositionUpdate(msg.sender);

        if (needsUpdate) {
            // Proof is required - validate parameters
            // Allow empty proof for single provider scenarios
            if (
                proof.length == 0 &&
                !_isEmptyProofValid(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition
                )
            ) {
                revert InvalidMerkleProof();
            }
            if (merkleRoot == bytes32(0)) revert NoMerkleRootForUpdates();

            // Verify merkle proof
            if (
                !_verifyMerkleProof(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition
                )
            ) revert InvalidMerkleProof();

            // Update user position first
            _updateUserPosition(msg.sender, newETHPosition, newTokenPosition);
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
        uint256 newTokenPosition
    ) external nonReentrant {
        uint256 totalUserLPShares = ethProviders[msg.sender].ethLPShares +
            tokenProviders[msg.sender].tokenLPShares;
        if (
            totalUserLPShares == 0 &&
            ethProviders[msg.sender].pendingRewards == 0 &&
            tokenProviders[msg.sender].pendingRewards == 0
        ) revert NoLiquidityOrRewards();

        // Check if user needs position update for either asset type - only if they have existing liquidity
        bool needsUpdate = _needsPositionUpdate(msg.sender);

        if (needsUpdate) {
            // Proof is required - validate parameters
            // Allow empty proof for single provider scenarios
            if (
                proof.length == 0 &&
                !_isEmptyProofValid(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition
                )
            ) {
                revert InvalidMerkleProof();
            }
            if (merkleRoot == bytes32(0)) revert NoMerkleRootForUpdates();

            // Verify merkle proof
            if (
                !_verifyMerkleProof(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition
                )
            ) revert InvalidMerkleProof();

            // Update user position first
            _updateUserPosition(msg.sender, newETHPosition, newTokenPosition);
        }

        // Calculate ETH rewards after position update (if any)
        uint256 ethRewards = 0;
        if (ethProviders[msg.sender].ethLPShares > 0) {
            uint256 ethAccumulated = (ethProviders[msg.sender].ethLPShares *
                accRewardPerShare) / SCALE;
            ethRewards = ethAccumulated - ethProviders[msg.sender].rewardDebt;
        }
        // Always add pending rewards (even if LP shares = 0)
        ethRewards += ethProviders[msg.sender].pendingRewards;

        // Calculate ETH rewards from token LP shares after position update (if any)
        uint256 tokenProviderRewards = 0;
        if (tokenProviders[msg.sender].tokenLPShares > 0) {
            uint256 tokenAccumulated = (tokenProviders[msg.sender]
                .tokenLPShares * accTokenProviderRewardPerShare) / SCALE;
            tokenProviderRewards =
                tokenAccumulated -
                tokenProviders[msg.sender].rewardDebt;
        }
        // Always add pending rewards (even if LP shares = 0)
        tokenProviderRewards += tokenProviders[msg.sender].pendingRewards;

        uint256 totalRewards = ethRewards + tokenProviderRewards;
        if (totalRewards == 0) revert NoRewards();

        // Update reward debt for both asset types
        if (ethProviders[msg.sender].ethLPShares > 0) {
            ethProviders[msg.sender].rewardDebt =
                (ethProviders[msg.sender].ethLPShares * accRewardPerShare) /
                SCALE;
        }
        if (tokenProviders[msg.sender].tokenLPShares > 0) {
            tokenProviders[msg.sender].rewardDebt =
                (tokenProviders[msg.sender].tokenLPShares *
                    accTokenProviderRewardPerShare) /
                SCALE;
        }

        // Clear pending rewards
        ethProviders[msg.sender].pendingRewards = 0;
        tokenProviders[msg.sender].pendingRewards = 0;

        // Transfer total ETH rewards
        totalEthRemoved += totalRewards;
        (bool success, ) = payable(msg.sender).call{value: totalRewards}("");
        if (!success) revert ETHWithdrawalFailed();

        // Emit to EventAggregator instead of local event
        getEventAggregator().emitRewardsClaimed(
            msg.sender,
            address(token),
            totalRewards
        );

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
        uint256 newTokenPosition
    ) external nonReentrant {
        if (
            ethProviders[msg.sender].ethLPShares == 0 &&
            ethProviders[msg.sender].pendingRewards == 0
        ) revert NoETHLiquidityOrRewards();

        // Check if user needs position update for either asset type - only if they have existing liquidity
        bool needsUpdate = _needsPositionUpdate(msg.sender);

        if (needsUpdate) {
            // Proof is required - validate parameters
            // Allow empty proof for single provider scenarios
            if (
                proof.length == 0 &&
                !_isEmptyProofValid(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition
                )
            ) {
                revert InvalidMerkleProof();
            }
            if (merkleRoot == bytes32(0)) revert NoMerkleRootForUpdates();

            // Verify merkle proof
            if (
                !_verifyMerkleProof(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition
                )
            ) revert InvalidMerkleProof();

            // Update user position first
            _updateUserPosition(msg.sender, newETHPosition, newTokenPosition);
        }

        // Calculate ETH rewards from ETH LP shares only
        uint256 ethRewards = 0;
        if (ethProviders[msg.sender].ethLPShares > 0) {
            uint256 ethAccumulated = (ethProviders[msg.sender].ethLPShares *
                accRewardPerShare) / SCALE;
            ethRewards = ethAccumulated - ethProviders[msg.sender].rewardDebt;
        }
        // Always add pending rewards (even if LP shares = 0)
        ethRewards += ethProviders[msg.sender].pendingRewards;

        if (ethRewards == 0) revert NoRewards();

        // Update reward debt
        if (ethProviders[msg.sender].ethLPShares > 0) {
            ethProviders[msg.sender].rewardDebt =
                (ethProviders[msg.sender].ethLPShares * accRewardPerShare) /
                SCALE;
        }

        // Clear pending rewards
        ethProviders[msg.sender].pendingRewards = 0;

        // Transfer ETH rewards
        totalEthRemoved += ethRewards;
        (bool success, ) = payable(msg.sender).call{value: ethRewards}("");
        if (!success) revert ETHWithdrawalFailed();

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
        uint256 newTokenPosition
    ) external nonReentrant {
        if (
            tokenProviders[msg.sender].tokenLPShares == 0 &&
            tokenProviders[msg.sender].pendingRewards == 0
        ) revert NoTokenLiquidityOrRewards();

        // Check if user needs position update for either asset type - only if they have existing liquidity
        bool needsUpdate = _needsPositionUpdate(msg.sender);

        if (needsUpdate) {
            // Proof is required - validate parameters
            // Allow empty proof for single provider scenarios
            if (
                proof.length == 0 &&
                !_isEmptyProofValid(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition
                )
            ) {
                revert InvalidMerkleProof();
            }
            if (merkleRoot == bytes32(0)) revert NoMerkleRootForUpdates();

            // Verify merkle proof
            if (
                !_verifyMerkleProof(
                    msg.sender,
                    proof,
                    newETHPosition,
                    newTokenPosition
                )
            ) revert InvalidMerkleProof();

            // Update user position first
            _updateUserPosition(msg.sender, newETHPosition, newTokenPosition);
        }

        // Calculate ETH rewards from token LP shares only
        uint256 tokenProviderRewards = 0;
        if (tokenProviders[msg.sender].tokenLPShares > 0) {
            uint256 tokenAccumulated = (tokenProviders[msg.sender]
                .tokenLPShares * accTokenProviderRewardPerShare) / SCALE;
            tokenProviderRewards =
                tokenAccumulated -
                tokenProviders[msg.sender].rewardDebt;
        }
        // Always add pending rewards (even if LP shares = 0)
        tokenProviderRewards += tokenProviders[msg.sender].pendingRewards;

        if (tokenProviderRewards == 0) revert NoTokenProviderRewards();

        // Update reward debt
        if (tokenProviders[msg.sender].tokenLPShares > 0) {
            tokenProviders[msg.sender].rewardDebt =
                (tokenProviders[msg.sender].tokenLPShares *
                    accTokenProviderRewardPerShare) /
                SCALE;
        }

        // Clear pending rewards
        tokenProviders[msg.sender].pendingRewards = 0;

        // Transfer ETH rewards (not tokens!)
        totalEthRemoved += tokenProviderRewards;
        (bool success, ) = payable(msg.sender).call{
            value: tokenProviderRewards
        }("");
        if (!success) revert ETHWithdrawalFailed();

        emit FeeClaimed(msg.sender, tokenProviderRewards, address(token));
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

    /**
     * @notice Get user's total position in the pool
     * @param user Address of the user
     * @return ethPosition User's ETH position
     * @return tokenPosition User's token position
     * @return ethLPShares User's ETH LP shares
     * @return tokenLPShares User's token LP shares
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
            uint256 ethLPShares,
            uint256 tokenLPShares,
            uint256 pendingRewards
        )
    {
        ethPosition = ethProviders[user].ethPosition;
        tokenPosition = tokenProviders[user].tokenPosition;
        ethLPShares = ethProviders[user].ethLPShares;
        tokenLPShares = tokenProviders[user].tokenLPShares;

        // Calculate pending rewards for each asset type separately
        uint256 ethPendingRewards = 0;
        if (ethProviders[user].ethLPShares > 0) {
            ethPendingRewards =
                (ethProviders[user].ethLPShares * accRewardPerShare) /
                SCALE -
                ethProviders[user].rewardDebt +
                ethProviders[user].pendingRewards;
        } else {
            ethPendingRewards = ethProviders[user].pendingRewards;
        }

        uint256 tokenPendingRewards = 0;
        if (tokenProviders[user].tokenLPShares > 0) {
            tokenPendingRewards =
                (tokenProviders[user].tokenLPShares *
                    accTokenProviderRewardPerShare) /
                SCALE -
                tokenProviders[user].rewardDebt +
                tokenProviders[user].pendingRewards;
        } else {
            tokenPendingRewards = tokenProviders[user].pendingRewards;
        }

        // Total pending rewards (ETH + ETH from token provider pool)
        pendingRewards = ethPendingRewards + tokenPendingRewards;
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

    /**
     * @notice Emergency function to withdraw specific amount of ETH from the contract
     * @param recipient Address to receive the ETH
     * @param amount Amount of ETH to withdraw
     */
    function emergencyWithdrawETH(
        address payable recipient,
        uint256 amount
    ) external onlyOwner {
        if (recipient == address(0)) revert InvalidRecipient();
        if (amount == 0) revert AmountZero();
        if (address(this).balance < amount) revert InsufficientETHBalance();

        (bool success, ) = recipient.call{value: amount}("");
        if (!success) revert ETHWithdrawalFailed();
    }

    /**
     * @notice Emergency function to withdraw specific amount of tokens from the contract
     * @param recipient Address to receive the tokens
     * @param amount Amount of tokens to withdraw
     */
    function emergencyWithdrawToken(
        address recipient,
        uint256 amount
    ) external onlyOwner {
        if (recipient == address(0)) revert InvalidRecipient();
        if (amount == 0) revert AmountZero();

        uint256 balance = token.balanceOf(address(this));
        if (balance < amount) revert InsufficientTokenBalance();

        token.safeTransfer(recipient, amount);
    }
}
