// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGradientRegistry} from "./interfaces/IGradientRegistry.sol";
import {IGradientMarketMakerPool} from "./interfaces/IGradientMarketMakerPool.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router.sol";
import {IUniswapV2Factory} from "./interfaces/IUniswapV2Factory.sol";

contract GradientMarketMakerPool is
    Ownable,
    ReentrancyGuard,
    IGradientMarketMakerPool
{
    using SafeERC20 for IERC20;
    IGradientRegistry public gradientRegistry;

    // Epoch-based storage
    // token => currentEpoch (for ETH pool)
    mapping(address => uint256) public currentETHEpochs;
    // token => currentEpoch (for token pool)
    mapping(address => uint256) public currentTokenEpochs;

    // token => epoch => ETHPoolInfo
    mapping(address => mapping(uint256 => ETHPoolInfo)) public ethPools;
    // token => epoch => TokenPoolInfo
    mapping(address => mapping(uint256 => TokenPoolInfo)) public tokenPools;

    // User positions in each epoch
    // token => user => epoch => ETHProvider
    mapping(address => mapping(address => mapping(uint256 => ETHProvider)))
        public ethProviders;
    // token => user => epoch => TokenProvider
    mapping(address => mapping(address => mapping(uint256 => TokenProvider)))
        public tokenProviders;

    // Track user's participated epochs
    // token => user => ETH epochIds[]
    mapping(address => mapping(address => uint256[]))
        public userParticipatedETHEpochs;
    // token => user => token epochIds[]
    mapping(address => mapping(address => uint256[]))
        public userParticipatedTokenEpochs;

    uint256 public constant SCALE = 1e18;

    // Configurable minimum liquidity requirements
    uint256 public minLiquidity = 1e15; // 0.001 ETH minimum (default)
    uint256 public minTokenLiquidity = 1e15; // 0.001 tokens minimum (default)

    // Track overall totals across all pools
    uint256 public totalEthAdded; // Total ETH added across all pools
    uint256 public totalEthRemoved; // Total ETH removed across all pools

    mapping(address => uint256) public totalTokensAdded; // Total tokens added across all pools (per token)
    mapping(address => uint256) public totalTokensRemoved; // Total tokens removed across all pools (per token)

    modifier isNotBlocked(address token) {
        require(!gradientRegistry.blockedTokens(token), "Token is blocked");
        _;
    }

    modifier onlyRewardDistributor() {
        require(
            gradientRegistry.isRewardDistributor(msg.sender),
            "Only reward distributor can call this function"
        );
        _;
    }

    modifier onlyOrderbook() {
        require(
            msg.sender == gradientRegistry.orderbook(),
            "Only orderbook can call this function"
        );
        _;
    }

    constructor(IGradientRegistry _gradientRegistry) Ownable(msg.sender) {
        gradientRegistry = _gradientRegistry;
    }

    /**
     * @notice Receive ETH for reward distribution
     */
    receive() external payable {}

    /**
     * @notice Calculate LP shares using a more secure formula to prevent precision loss
     * @param amount Amount being deposited
     * @param totalAmount Total amount in pool
     * @param totalShares Total shares in pool
     * @return sharesToMint Number of shares to mint
     */
    function _calculateLPShares(
        uint256 amount,
        uint256 totalAmount,
        uint256 totalShares
    ) internal pure returns (uint256 sharesToMint) {
        require(amount > 0, "Amount must be greater than 0");

        if (totalShares == 0) {
            // First liquidity provider gets shares equal to their contribution
            return amount;
        }

        // Calculate shares proportionally
        sharesToMint = (amount * totalShares) / totalAmount;

        // Ensure minimum share requirement to prevent dust attacks
        require(sharesToMint > 0, "Insufficient shares to mint");

        return sharesToMint;
    }

    /**
     * @notice Updates ETH pool rewards before modifying state
     * @param token Address of the token for the pool
     * @param epoch Epoch to update
     * @param ethAmount Amount of ETH to distribute as rewards
     */
    function _updateETHPool(
        address token,
        uint256 epoch,
        uint256 ethAmount
    ) internal {
        require(ethAmount > 0, "ETH amount must be greater than 0");
        require(token != address(0), "Invalid token address");
        ETHPoolInfo storage pool = ethPools[token][epoch];

        if (pool.totalLPShares == 0) return;

        uint256 newAccRewardPerShare = pool.accRewardPerShare +
            ((ethAmount * SCALE) / pool.totalLPShares);
        require(
            newAccRewardPerShare >= pool.accRewardPerShare,
            "Overflow in reward calculation"
        );

        pool.accRewardPerShare = newAccRewardPerShare;
        pool.rewardBalance += ethAmount;
    }

    /**
     * @notice Updates Token pool rewards before modifying state
     * @param token Address of the token for the pool
     * @param ethAmount Amount of ETH to distribute as rewards
     */
    function _updateTokenPool(
        address token,
        uint256 epoch,
        uint256 ethAmount
    ) internal {
        require(ethAmount > 0, "ETH amount must be greater than 0");
        require(token != address(0), "Invalid token address");
        TokenPoolInfo storage pool = tokenPools[token][epoch];

        if (pool.totalLPShares == 0) return;

        uint256 newAccRewardPerShare = pool.accRewardPerShare +
            ((ethAmount * SCALE) / pool.totalLPShares);
        require(
            newAccRewardPerShare >= pool.accRewardPerShare,
            "Overflow in reward calculation"
        );

        pool.accRewardPerShare = newAccRewardPerShare;
        pool.rewardBalance += ethAmount;
    }

    /**
     * @notice Updates ETH pool token rewards before modifying state
     * @param token Address of the token for the pool
     * @param tokenAmount Amount of tokens to distribute as rewards
     */
    function _updateETHPoolTokenRewards(
        address token,
        uint256 tokenAmount
    ) internal {
        require(tokenAmount > 0, "Token amount must be greater than 0");
        require(token != address(0), "Invalid token address");
        ETHPoolInfo storage pool = ethPools[token][currentETHEpochs[token]];

        if (pool.totalLPShares == 0) return;

        uint256 newAccTokenRewardPerShare = pool.accTokenRewardPerShare +
            ((tokenAmount * SCALE) / pool.totalLPShares);
        require(
            newAccTokenRewardPerShare >= pool.accTokenRewardPerShare,
            "Overflow in token reward calculation"
        );

        pool.accTokenRewardPerShare = newAccTokenRewardPerShare;
        pool.tokenRewardBalance += tokenAmount;
    }

    /**
     * @notice Updates Token pool ETH rewards before modifying state
     * @param token Address of the token for the pool
     * @param ethAmount Amount of ETH to distribute as rewards
     */
    function _updateTokenPoolETHRewards(
        address token,
        uint256 ethAmount
    ) internal {
        require(ethAmount > 0, "ETH amount must be greater than 0");
        require(token != address(0), "Invalid token address");
        TokenPoolInfo storage pool = tokenPools[token][
            currentTokenEpochs[token]
        ];

        if (pool.totalLPShares == 0) return;

        uint256 newAccETHRewardPerShare = pool.accETHRewardPerShare +
            ((ethAmount * SCALE) / pool.totalLPShares);
        require(
            newAccETHRewardPerShare >= pool.accETHRewardPerShare,
            "Overflow in ETH reward calculation"
        );

        pool.accETHRewardPerShare = newAccETHRewardPerShare;
        pool.ethRewardBalance += ethAmount;
    }

    /**
     * @notice Add liquidity to the pool
     * @param token Address of the token to provide liquidity for
     * @param tokenAmount Amount of tokens to deposit
     */
    function addLiquidity(
        address token,
        uint256 tokenAmount
    ) external payable isNotBlocked(token) nonReentrant {
        require(msg.value >= minLiquidity, "ETH amount below minimum");
        require(tokenAmount >= minTokenLiquidity, "Token amount below minimum");
        require(token != address(0), "Invalid token address");

        _addETHLiquidity(token, msg.value);
        _addTokenLiquidity(token, tokenAmount);
    }

    /**
     * @notice Add ETH liquidity to the pool
     * @param token Address of the token to provide ETH liquidity for
     * @dev Requires ETH to be sent with the transaction
     */
    function addETHLiquidity(
        address token
    ) public payable isNotBlocked(token) nonReentrant {
        require(msg.value >= minLiquidity, "ETH amount below minimum");
        require(token != address(0), "Invalid token address");

        _addETHLiquidity(token, msg.value);
    }

    /**
     * @notice Add ETH liquidity to the pool
     * @param token Address of the token to provide ETH liquidity for
     * @param ethAmount Amount of ETH to deposit
     */
    function _addETHLiquidity(address token, uint256 ethAmount) internal {
        ETHPoolInfo storage pool = ethPools[token][currentETHEpochs[token]];

        if (pool.uniswapPair == address(0)) {
            pool.uniswapPair = getPairAddress(token);
        }
        require(pool.uniswapPair != address(0), "Pair does not exist");

        ETHProvider storage provider = ethProviders[token][msg.sender][
            currentETHEpochs[token]
        ];

        // Add user to participated epochs
        _addUserToParticipatedEpochs(
            token,
            msg.sender,
            currentETHEpochs[token],
            true
        );

        // Calculate pending ETH rewards before update
        if (provider.lpShares > 0) {
            uint256 pendingEth = (provider.lpShares * pool.accRewardPerShare) /
                SCALE -
                provider.rewardDebt;
            provider.pendingReward += pendingEth;

            // Calculate pending token rewards before update
            uint256 pendingTokens = (provider.lpShares *
                pool.accTokenRewardPerShare) /
                SCALE -
                provider.tokenRewardDebt;
            provider.pendingTokenReward += pendingTokens;
        }

        // Calculate LP shares to mint
        uint256 lpSharesToMint = _calculateLPShares(
            ethAmount,
            pool.accountedEth,
            pool.totalLPShares
        );

        provider.lpShares += lpSharesToMint;
        provider.ethAmount += ethAmount;
        provider.rewardDebt =
            (provider.lpShares * pool.accRewardPerShare) /
            SCALE;
        provider.tokenRewardDebt =
            (provider.lpShares * pool.accTokenRewardPerShare) /
            SCALE;

        pool.totalETH += ethAmount;
        pool.accountedEth += ethAmount;
        pool.totalLPShares += lpSharesToMint;

        // Track total ETH added by LPs
        totalEthAdded += ethAmount;

        emit ETHLiquidityDeposited(
            msg.sender,
            token,
            ethAmount,
            lpSharesToMint
        );
    }

    /**
     * @notice Add token liquidity to the pool
     * @param token Address of the token to provide liquidity for
     * @param tokenAmount Amount of tokens to deposit
     */
    function addTokenLiquidity(
        address token,
        uint256 tokenAmount
    ) public isNotBlocked(token) nonReentrant {
        require(tokenAmount >= minTokenLiquidity, "Token amount below minimum");
        require(token != address(0), "Invalid token address");

        _addTokenLiquidity(token, tokenAmount);
    }

    /**
     * @notice Add token liquidity to the pool
     * @param token Address of the token to provide liquidity for
     * @param tokenAmount Amount of tokens to deposit
     */
    function _addTokenLiquidity(address token, uint256 tokenAmount) internal {
        TokenPoolInfo storage pool = tokenPools[token][
            currentTokenEpochs[token]
        ];

        if (pool.uniswapPair == address(0)) {
            pool.uniswapPair = getPairAddress(token);
        }
        require(pool.uniswapPair != address(0), "Pair does not exist");

        TokenProvider storage provider = tokenProviders[token][msg.sender][
            currentTokenEpochs[token]
        ];

        // Add user to participated epochs
        _addUserToParticipatedEpochs(
            token,
            msg.sender,
            currentTokenEpochs[token],
            false
        );

        // Calculate pending token rewards before update
        if (provider.lpShares > 0) {
            uint256 pendingTokens = (provider.lpShares *
                pool.accRewardPerShare) /
                SCALE -
                provider.rewardDebt;
            provider.pendingReward += pendingTokens;

            // Calculate pending ETH rewards before update
            uint256 pendingEth = (provider.lpShares *
                pool.accETHRewardPerShare) /
                SCALE -
                provider.ethRewardDebt;
            provider.pendingETHReward += pendingEth;
        }

        // Calculate LP shares to mint
        uint256 lpSharesToMint = _calculateLPShares(
            tokenAmount,
            pool.accountedToken,
            pool.totalLPShares
        );

        provider.lpShares += lpSharesToMint;
        provider.tokenAmount += tokenAmount;
        provider.rewardDebt =
            (provider.lpShares * pool.accRewardPerShare) /
            SCALE;
        provider.ethRewardDebt =
            (provider.lpShares * pool.accETHRewardPerShare) /
            SCALE;

        pool.totalTokens += tokenAmount;
        pool.accountedToken += tokenAmount;
        pool.totalLPShares += lpSharesToMint;

        // Track total tokens added by LPs
        totalTokensAdded[token] += tokenAmount;

        // Transfer tokens from user
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        emit TokenLiquidityDeposited(
            msg.sender,
            token,
            tokenAmount,
            lpSharesToMint
        );
    }

    /**
     * @notice Remove all liquidity from the pool by providing epochs, shares and min amounts
     * @param token Address of the token to withdraw from
     * @param ethEpochs Epochs to remove liquidity from
     * @param tokenEpochs Epochs to remove liquidity from
     * @param ethShares Percentages of pool to withdraw (in basis points, 10000 = 100%)
     * @param tokenShares Percentages of pool to withdraw (in basis points, 10000 = 100%)
     * @param minEthAmounts Minimum amounts of ETH to receive
     * @param minTokenAmounts Minimum amounts of tokens to receive
     */
    function removeAllEpochsLiquidity(
        address token,
        uint256[] memory ethEpochs,
        uint256[] memory tokenEpochs,
        uint256[] memory ethShares,
        uint256[] memory tokenShares,
        uint256[] memory minEthAmounts,
        uint256[] memory minTokenAmounts
    ) external isNotBlocked(token) nonReentrant {
        require(token != address(0), "Invalid token address");
        require(
            ethEpochs.length == ethShares.length &&
                ethEpochs.length == minEthAmounts.length,
            "Invalid ETH epochs length"
        );
        require(
            tokenEpochs.length == tokenShares.length &&
                tokenEpochs.length == minTokenAmounts.length,
            "Invalid token epochs length"
        );

        for (uint256 i = 0; i < ethEpochs.length; i++) {
            require(
                ethShares[i] > 0 && ethShares[i] <= 10000,
                "Invalid shares percentage"
            );
            require(ethEpochs[i] <= currentETHEpochs[token], "Invalid epoch");
            _removeETHLiquidity(
                token,
                ethShares[i],
                minEthAmounts[i],
                ethEpochs[i]
            );
        }

        for (uint256 i = 0; i < tokenEpochs.length; i++) {
            require(
                tokenShares[i] > 0 && tokenShares[i] <= 10000,
                "Invalid shares percentage"
            );
            require(
                tokenEpochs[i] <= currentTokenEpochs[token],
                "Invalid epoch"
            );
            _removeTokenLiquidity(
                token,
                tokenShares[i],
                minTokenAmounts[i],
                tokenEpochs[i]
            );
        }
    }

    /**
     * @notice Remove liquidity from the pool
     * @param token Address of the token to withdraw from
     * @param shares Percentage of pool to withdraw (in basis points, 10000 = 100%)
     * @param minEthAmount Minimum amount of ETH to receive
     * @param minTokenAmount Minimum amount of tokens to receive
     * @param currentETHEpoch Current ETH epoch
     * @param currentTokenEpoch Current token epoch
     */
    function removeLiquidity(
        address token,
        uint256 shares,
        uint256 minEthAmount,
        uint256 minTokenAmount,
        uint256 currentETHEpoch,
        uint256 currentTokenEpoch
    ) external isNotBlocked(token) nonReentrant {
        require(shares > 0 && shares <= 10000, "Invalid shares percentage");
        require(token != address(0), "Invalid token address");

        _removeETHLiquidity(token, shares, minEthAmount, currentETHEpoch);
        _removeTokenLiquidity(token, shares, minTokenAmount, currentTokenEpoch);
    }

    /**
     * @notice Remove all ETH liquidity from the pool by providing epochs, shares and minEthAmounts
     * @param token Address of the token to withdraw from
     * @param epochs Epochs to remove liquidity from
     * @param shares Percentages of pool to withdraw (in basis points, 10000 = 100%)
     * @param minEthAmounts Minimum amounts of ETH to receive
     */
    function removeAllETHLiquidity(
        address token,
        uint256[] memory epochs,
        uint256[] memory shares,
        uint256[] memory minEthAmounts
    ) external isNotBlocked(token) nonReentrant {
        require(token != address(0), "Invalid token address");
        require(
            epochs.length == shares.length &&
                epochs.length == minEthAmounts.length,
            "Invalid epochs length"
        );

        for (uint256 i = 0; i < epochs.length; i++) {
            require(
                shares[i] > 0 && shares[i] <= 10000,
                "Invalid shares percentage"
            );
            require(epochs[i] <= currentETHEpochs[token], "Invalid epoch");

            _removeETHLiquidity(token, shares[i], minEthAmounts[i], epochs[i]);
        }
    }

    /**
     * @notice Remove ETH liquidity from the pool
     * @param token Address of the token to withdraw from
     * @param shares Percentage of pool to withdraw (in basis points, 10000 = 100%)
     * @param minEthAmount Minimum amount of ETH to receive
     * @param epoch Epoch to remove liquidity from
     */
    function removeETHLiquidity(
        address token,
        uint256 shares,
        uint256 minEthAmount,
        uint256 epoch
    ) external isNotBlocked(token) nonReentrant {
        require(shares > 0 && shares <= 10000, "Invalid shares percentage");
        require(token != address(0), "Invalid token address");
        _removeETHLiquidity(token, shares, minEthAmount, epoch);
    }

    /**
     * @notice Remove ETH liquidity from the pool
     * @param token Address of the token to withdraw from
     * @param shares Percentage of pool to withdraw (in basis points, 10000 = 100%)
     * @param minEthAmount Minimum amount of ETH to receive
     * @param epoch Epoch to remove liquidity from
     */
    function _removeETHLiquidity(
        address token,
        uint256 shares,
        uint256 minEthAmount,
        uint256 epoch
    ) internal {
        ETHPoolInfo storage pool = ethPools[token][epoch];
        ETHProvider storage provider = ethProviders[token][msg.sender][epoch];

        require(pool.totalLPShares > 0, "No ETH liquidity in pool");
        require(provider.ethAmount > 0, "No ETH liquidity to withdraw");

        // Calculate pending ETH rewards before withdrawing
        uint256 pendingEth = (provider.lpShares * pool.accRewardPerShare) /
            SCALE -
            provider.rewardDebt;
        provider.pendingReward += pendingEth;

        // Calculate pending token rewards before withdrawing
        uint256 pendingTokens = (provider.lpShares *
            pool.accTokenRewardPerShare) /
            SCALE -
            provider.tokenRewardDebt;
        provider.pendingTokenReward += pendingTokens;

        // Calculate LP shares to burn based on withdrawal percentage
        uint256 lpSharesToBurn = (provider.lpShares * shares) / 10000;
        require(lpSharesToBurn > 0, "No shares to burn");
        require(
            lpSharesToBurn <= provider.lpShares,
            "Insufficient shares to burn"
        );

        // Calculate actual withdrawal amounts based on LP shares
        uint256 actualEthWithdraw = _calculateWithdrawalAmount(
            lpSharesToBurn,
            pool.totalETH,
            pool.totalLPShares
        );
        require(actualEthWithdraw <= pool.totalETH, "Insufficient ETH in pool");

        // Update balances
        provider.ethAmount -= actualEthWithdraw;
        provider.lpShares -= lpSharesToBurn;

        // Calculate accounted values BEFORE reducing totalLPShares
        uint256 accountedEthToRemove = (pool.accountedEth * lpSharesToBurn) /
            pool.totalLPShares;

        pool.totalETH -= actualEthWithdraw;
        pool.totalLPShares -= lpSharesToBurn;
        pool.accountedEth -= accountedEthToRemove;

        // Update reward debt for remaining shares
        provider.rewardDebt =
            (provider.lpShares * pool.accRewardPerShare) /
            SCALE;
        provider.tokenRewardDebt =
            (provider.lpShares * pool.accTokenRewardPerShare) /
            SCALE;

        // Transfer ETH back to user
        require(
            actualEthWithdraw >= minEthAmount,
            "Insufficient ETH withdrawn"
        );
        (bool success, ) = payable(msg.sender).call{value: actualEthWithdraw}(
            ""
        );
        require(success, "ETH transfer failed");

        // Transfer accumulated token rewards to user
        if (provider.pendingTokenReward > 0) {
            uint256 tokenRewards = provider.pendingTokenReward;
            provider.pendingTokenReward = 0;
            IERC20(token).safeTransfer(msg.sender, tokenRewards);

            emit PoolSharesClaimed(
                msg.sender,
                tokenRewards,
                token,
                epoch,
                false
            );
        }

        // Track total ETH removed by LPs
        totalEthRemoved += actualEthWithdraw;

        emit ETHLiquidityWithdrawn(
            msg.sender,
            token,
            epoch,
            actualEthWithdraw,
            lpSharesToBurn
        );
    }

    /**
     * @notice Remove all token liquidity from the pool by providing epochs, shares and minTokenAmounts
     * @param token Address of the token to withdraw from
     * @param epochs Epochs to remove liquidity from
     * @param shares Percentages of pool to withdraw (in basis points, 10000 = 100%)
     * @param minTokenAmounts Minimum amounts of tokens to receive
     */
    function removeAllTokenLiquidity(
        address token,
        uint256[] memory epochs,
        uint256[] memory shares,
        uint256[] memory minTokenAmounts
    ) external isNotBlocked(token) nonReentrant {
        require(token != address(0), "Invalid token address");
        require(
            epochs.length == shares.length &&
                epochs.length == minTokenAmounts.length,
            "Invalid epochs length"
        );

        for (uint256 i = 0; i < epochs.length; i++) {
            require(
                shares[i] > 0 && shares[i] <= 10000,
                "Invalid shares percentage"
            );
            require(epochs[i] <= currentTokenEpochs[token], "Invalid epoch");
            _removeTokenLiquidity(
                token,
                shares[i],
                minTokenAmounts[i],
                epochs[i]
            );
        }
    }

    /**
     * @notice Remove token liquidity from the pool
     * @param token Address of the token to withdraw from
     * @param shares Percentage of pool to withdraw (in basis points, 10000 = 100%)
     * @param minTokenAmount Minimum amount of tokens to receive
     */
    function removeTokenLiquidity(
        address token,
        uint256 shares,
        uint256 minTokenAmount,
        uint256 epoch
    ) external isNotBlocked(token) nonReentrant {
        require(shares > 0 && shares <= 10000, "Invalid shares percentage");
        require(token != address(0), "Invalid token address");

        _removeTokenLiquidity(token, shares, minTokenAmount, epoch);
    }

    /**
     * @notice Remove token liquidity from the pool
     * @param token Address of the token to withdraw from
     * @param shares Percentage of pool to withdraw (in basis points, 10000 = 100%)
     * @param minTokenAmount Minimum amount of tokens to receive
     * @param epoch Epoch to remove liquidity from
     */
    function _removeTokenLiquidity(
        address token,
        uint256 shares,
        uint256 minTokenAmount,
        uint256 epoch
    ) internal {
        TokenPoolInfo storage pool = tokenPools[token][epoch];
        TokenProvider storage provider = tokenProviders[token][msg.sender][
            epoch
        ];

        require(pool.totalLPShares > 0, "No token liquidity in pool");
        require(provider.tokenAmount > 0, "No token liquidity to withdraw");

        // Calculate pending token rewards before withdrawing
        uint256 pendingTokens = (provider.lpShares * pool.accRewardPerShare) /
            SCALE -
            provider.rewardDebt;
        provider.pendingReward += pendingTokens;

        // Calculate pending ETH rewards before withdrawing
        uint256 pendingEth = (provider.lpShares * pool.accETHRewardPerShare) /
            SCALE -
            provider.ethRewardDebt;
        provider.pendingETHReward += pendingEth;

        uint256 lpSharesToBurn;

        lpSharesToBurn = (provider.lpShares * shares) / 10000;
        require(lpSharesToBurn > 0, "No shares to burn");
        require(
            lpSharesToBurn <= provider.lpShares,
            "Insufficient shares to burn"
        );

        // Calculate actual withdrawal amounts based on LP shares
        uint256 actualTokenWithdraw = _calculateWithdrawalAmount(
            lpSharesToBurn,
            pool.totalTokens,
            pool.totalLPShares
        );
        require(
            actualTokenWithdraw <= pool.totalTokens,
            "Insufficient tokens in pool"
        );

        // Update balances
        provider.tokenAmount -= actualTokenWithdraw;
        provider.lpShares -= lpSharesToBurn;

        // Calculate accounted values BEFORE reducing totalLPShares
        uint256 accountedTokenToRemove = (pool.accountedToken *
            lpSharesToBurn) / pool.totalLPShares;

        pool.totalTokens -= actualTokenWithdraw;
        pool.totalLPShares -= lpSharesToBurn;
        pool.accountedToken -= accountedTokenToRemove;

        // Update reward debt for remaining shares
        provider.rewardDebt =
            (provider.lpShares * pool.accRewardPerShare) /
            SCALE;
        provider.ethRewardDebt =
            (provider.lpShares * pool.accETHRewardPerShare) /
            SCALE;

        // Transfer tokens back to user
        require(
            actualTokenWithdraw >= minTokenAmount,
            "Insufficient token withdrawn"
        );
        IERC20(token).safeTransfer(msg.sender, actualTokenWithdraw);

        // Transfer accumulated ETH rewards to user
        if (provider.pendingETHReward > 0) {
            uint256 ethRewards = provider.pendingETHReward;
            provider.pendingETHReward = 0;
            (bool success, ) = payable(msg.sender).call{value: ethRewards}("");
            require(success, "ETH reward transfer failed");

            emit PoolSharesClaimed(msg.sender, ethRewards, token, epoch, true);
        }

        // Track total tokens removed by LPs
        totalTokensRemoved[token] += actualTokenWithdraw;

        emit TokenLiquidityWithdrawn(
            msg.sender,
            token,
            epoch,
            actualTokenWithdraw,
            lpSharesToBurn
        );
    }

    /**
     * @notice Execute buy order - Orderbook sends ETH, receives tokens
     * @param token The token being bought
     * @param ethAmount Amount of ETH sent by orderbook
     * @param tokenAmount Amount of tokens to send to orderbook
     * @dev Only callable by the orderbook contract
     */
    function executeBuyOrder(
        address token,
        uint256 ethAmount,
        uint256 tokenAmount
    ) external payable isNotBlocked(token) onlyOrderbook {
        require(ethAmount > 0, "ETH amount must be greater than 0");
        require(tokenAmount > 0, "Token amount must be greater than 0");
        require(msg.value == ethAmount, "ETH amount mismatch");

        TokenPoolInfo storage tokenPool = tokenPools[token][
            currentTokenEpochs[token]
        ];
        require(
            tokenPool.totalTokens >= tokenAmount,
            "Insufficient token liquidity"
        );

        // Token pool provides tokens to orderbook
        tokenPool.totalTokens -= tokenAmount;
        totalTokensRemoved[token] += tokenAmount;
        // Token pool receives ETH rewards for providing tokens
        _updateTokenPoolETHRewards(token, ethAmount);

        // Transfer tokens to orderbook
        IERC20(token).safeTransfer(msg.sender, tokenAmount);

        // Check if token pool is empty and increment token epoch if needed
        _checkAndIncrementTokenEpoch(token);

        emit PoolBalanceUpdated(
            token,
            ethPools[token][currentETHEpochs[token]].totalETH,
            tokenPool.totalTokens,
            ethPools[token][currentETHEpochs[token]].totalLPShares,
            tokenPool.totalLPShares,
            currentETHEpochs[token]
        );
    }

    /**
     * @notice Execute sell order - Orderbook sends tokens, receives ETH
     * @param token The token being sold
     * @param ethAmount Amount of ETH to send to orderbook
     * @param tokenAmount Amount of tokens sent by orderbook
     * @dev Only callable by the orderbook contract
     */
    function executeSellOrder(
        address token,
        uint256 ethAmount,
        uint256 tokenAmount
    ) external isNotBlocked(token) onlyOrderbook {
        require(ethAmount > 0, "ETH amount must be greater than 0");
        require(tokenAmount > 0, "Token amount must be greater than 0");

        ETHPoolInfo storage ethPool = ethPools[token][currentETHEpochs[token]];
        require(ethPool.totalETH >= ethAmount, "Insufficient ETH liquidity");

        // Transfer tokens from orderbook to market maker pool
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        // ETH pool provides ETH to orderbook
        ethPool.totalETH -= ethAmount;
        totalEthRemoved += ethAmount;

        // ETH pool receives token rewards for providing ETH
        _updateETHPoolTokenRewards(token, tokenAmount);

        // Transfer ETH to orderbook
        (bool success, ) = payable(msg.sender).call{value: ethAmount}("");
        require(success, "ETH transfer to orderbook failed");

        // Check if ETH pool is empty and increment ETH epoch if needed
        _checkAndIncrementETHEpoch(token);

        emit PoolBalanceUpdated(
            token,
            ethPool.totalETH,
            tokenPools[token][currentTokenEpochs[token]].totalTokens,
            ethPool.totalLPShares,
            tokenPools[token][currentTokenEpochs[token]].totalLPShares,
            currentTokenEpochs[token]
        );
    }

    /// @notice Distributes fee distribution from orderbook to be distributed to market makers
    /// @param token Address of the token pool to distribute fees for
    /// @param epoch Epoch to distribute fee.
    /// @param isETHPool Whether to distribute to ETH pool (true) or token pool (false)
    function distributePoolFee(
        address token,
        uint256 epoch,
        bool isETHPool
    ) external payable onlyRewardDistributor {
        require(msg.value > 0, "No ETH sent");

        if (isETHPool) {
            ETHPoolInfo storage pool = ethPools[token][epoch];
            require(pool.totalLPShares > 0, "No ETH liquidity");
            _updateETHPool(token, epoch, msg.value);
        } else {
            TokenPoolInfo storage pool = tokenPools[token][epoch];
            require(pool.totalLPShares > 0, "No token liquidity");
            _updateTokenPool(token, epoch, msg.value);
        }

        emit PoolFeeDistributed(msg.sender, msg.value, token, epoch, isETHPool);
    }

    /**
     * @notice Claim all epochs pool fees for a token
     * @param token Address of the token pool to claim rewards from
     * @param epochs Epochs to claim rewards from
     * @param isETHPool Whether to claim ETH pool fees (true) or token pool fees (false)
     */
    function claimAllEpochsPoolFee(
        address token,
        uint256[] memory epochs,
        bool isETHPool
    ) external nonReentrant {
        for (uint256 i = 0; i < epochs.length; i++) {
            if (isETHPool) {
                _claimEthPoolFee(token, epochs[i]);
            } else {
                _claimTokenPoolFee(token, epochs[i]);
            }
        }
    }

    /// @notice Claim ETH rewards for ETH providers
    /// @param token Address of the token pool to claim rewards from
    /// @param epoch Epoch to claim rewards from
    function claimEthPoolFee(
        address token,
        uint256 epoch
    ) external nonReentrant {
        _claimEthPoolFee(token, epoch);
    }

    /**
     * @notice Claim ETH rewards for ETH providers
     * @param token Address of the token pool to claim rewards from
     * @param epoch Epoch to claim rewards from
     */
    function _claimEthPoolFee(address token, uint256 epoch) internal {
        ETHPoolInfo storage pool = ethPools[token][epoch];
        ETHProvider storage provider = ethProviders[token][msg.sender][epoch];

        require(
            provider.lpShares > 0 || provider.pendingReward > 0,
            "No liquidity or rewards"
        );

        uint256 accumulated = (provider.lpShares * pool.accRewardPerShare) /
            SCALE;
        uint256 reward = accumulated -
            provider.rewardDebt +
            provider.pendingReward;
        require(reward > 0, "No rewards");

        provider.rewardDebt = accumulated;
        provider.pendingReward = 0;

        (bool success, ) = payable(msg.sender).call{value: reward}("");
        require(success, "ETH transfer failed");

        emit PoolFeeClaimed(msg.sender, reward, token, epoch, false);
    }

    /// @notice Claim token rewards for token providers
    /// @param token Address of the token pool to claim rewards from
    /// @param epoch Epoch to claim rewards from
    function claimTokenPoolFee(
        address token,
        uint256 epoch
    ) external nonReentrant {
        _claimTokenPoolFee(token, epoch);
    }

    /**
     * @notice Claim token rewards for token providers
     * @param token Address of the token pool to claim rewards from
     * @param epoch Epoch to claim rewards from
     */
    function _claimTokenPoolFee(address token, uint256 epoch) internal {
        TokenPoolInfo storage pool = tokenPools[token][epoch];
        TokenProvider storage provider = tokenProviders[token][msg.sender][
            epoch
        ];
        require(
            provider.lpShares > 0 || provider.pendingReward > 0,
            "No liquidity or rewards"
        );

        uint256 accumulated = (provider.lpShares * pool.accRewardPerShare) /
            SCALE;
        uint256 reward = accumulated -
            provider.rewardDebt +
            provider.pendingReward;
        require(reward > 0, "No rewards");

        provider.rewardDebt = accumulated;
        provider.pendingReward = 0;

        (bool success, ) = payable(msg.sender).call{value: reward}("");
        require(success, "ETH transfer failed");

        emit PoolFeeClaimed(msg.sender, reward, token, epoch, false);
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
        require(sharesToBurn > 0, "Shares to burn must be greater than 0");
        require(totalShares > 0, "Total shares must be greater than 0");

        // Calculate withdrawal amount proportionally
        withdrawalAmount = (sharesToBurn * totalAmount) / totalShares;

        require(
            withdrawalAmount <= totalAmount,
            "Withdrawal amount exceeds pool balance"
        );

        return withdrawalAmount;
    }

    /**
     * @notice Gets ETH pool information for a specific token
     * @param token Address of the token to get ETH pool info for
     * @param epoch Epoch to get ETH pool info for
     * @return ETHPoolInfo struct containing ETH pool details
     */
    function getETHPoolInfo(
        address token,
        uint256 epoch
    ) external view returns (ETHPoolInfo memory) {
        return ethPools[token][epoch];
    }

    /**
     * @notice Gets token pool information for a specific token
     * @param token Address of the token to get token pool info for
     * @param epoch Epoch to get token pool info for
     * @return TokenPoolInfo struct containing token pool details
     */
    function getTokenPoolInfo(
        address token,
        uint256 epoch
    ) external view returns (TokenPoolInfo memory) {
        return tokenPools[token][epoch];
    }

    /**
     * @notice Gets a user's LP shares for token pool
     * @param token Address of the token
     * @param user Address of the user
     * @param epoch Epoch to get token provider LP shares for
     * @return lpShares User's LP shares in token pool
     */
    function getTokenProviderLPShares(
        address token,
        address user,
        uint256 epoch
    ) external view returns (uint256 lpShares) {
        return tokenProviders[token][user][epoch].lpShares;
    }

    /**
     * @notice Sets the gradient registry address
     * @param _gradientRegistry New gradient registry address
     * @dev Only callable by the contract owner
     */
    function setRegistry(
        IGradientRegistry _gradientRegistry
    ) external onlyOwner {
        require(
            address(_gradientRegistry) != address(0),
            "Invalid gradient registry"
        );
        emit RegistryUpdated(
            address(gradientRegistry),
            address(_gradientRegistry)
        );
        gradientRegistry = _gradientRegistry;
    }

    /**
     * @notice Set minimum ETH liquidity requirement
     * @param _minLiquidity New minimum ETH liquidity amount
     * @dev Only callable by the contract owner
     */
    function setMinLiquidity(uint256 _minLiquidity) external onlyOwner {
        require(_minLiquidity > 0, "Minimum liquidity must be greater than 0");
        minLiquidity = _minLiquidity;
        emit MinLiquidityUpdated(_minLiquidity);
    }

    /**
     * @notice Set minimum token liquidity requirement
     * @param _minTokenLiquidity New minimum token liquidity amount
     * @dev Only callable by the contract owner
     */
    function setMinTokenLiquidity(
        uint256 _minTokenLiquidity
    ) external onlyOwner {
        require(
            _minTokenLiquidity > 0,
            "Minimum token liquidity must be greater than 0"
        );
        minTokenLiquidity = _minTokenLiquidity;
        emit MinTokenLiquidityUpdated(_minTokenLiquidity);
    }

    /**
     * @notice Get the Uniswap V2 pair address for a given token
     * @param token Address of the token
     * @return pairAddress Address of the Uniswap V2 pair
     */
    function getPairAddress(
        address token
    ) public view returns (address pairAddress) {
        address routerAddress = gradientRegistry.router();
        require(routerAddress != address(0), "Router not set");

        IUniswapV2Router02 router = IUniswapV2Router02(routerAddress);
        address factory = router.factory();
        address weth = router.WETH();

        IUniswapV2Factory factoryContract = IUniswapV2Factory(factory);
        return factoryContract.getPair(token, weth);
    }

    /**
     * @notice Get the reserves for a token pair
     * @param token Address of the token
     * @return reserveETH ETH reserve amount
     * @return reserveToken Token reserve amount
     */
    function getReserves(
        address token
    ) public view returns (uint256 reserveETH, uint256 reserveToken) {
        address pairAddress = getPairAddress(token);
        require(pairAddress != address(0), "Pair does not exist");

        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pairAddress)
            .getReserves();
        address token0 = IUniswapV2Pair(pairAddress).token0();

        (reserveETH, reserveToken) = token0 == token
            ? (reserve1, reserve0)
            : (reserve0, reserve1);
    }

    /**
     * @notice Withdraw excessive funds that exceed LP contributions
     * @param token Address of the token to withdraw excessive funds for
     * @dev Only callable by contract owner
     */
    function withdrawExcessiveFunds(
        address token
    ) external onlyOwner nonReentrant {
        require(token != address(0), "Invalid token address");

        // Calculate excessive ETH (overall contract balance)
        uint256 currentEthBalance = address(this).balance;
        uint256 totalEthContributed = totalEthAdded - totalEthRemoved;
        uint256 excessiveEth = 0;

        if (currentEthBalance > totalEthContributed) {
            excessiveEth = currentEthBalance - totalEthContributed;
        }

        // Calculate excessive tokens (overall contract balance)
        uint256 currentTokenBalance = IERC20(token).balanceOf(address(this));
        uint256 totalTokensContributed = totalTokensAdded[token] -
            totalTokensRemoved[token];
        uint256 excessiveTokens = 0;

        if (currentTokenBalance > totalTokensContributed) {
            excessiveTokens = currentTokenBalance - totalTokensContributed;
        }

        require(
            excessiveEth > 0 || excessiveTokens > 0,
            "No excessive funds to withdraw"
        );

        // Withdraw excessive ETH
        if (excessiveEth > 0) {
            (bool success, ) = owner().call{value: excessiveEth}("");
            require(success, "ETH withdrawal failed");

            emit ExcessiveFundsWithdrawn(
                owner(),
                address(0),
                excessiveEth,
                "Excessive ETH"
            );
        }

        // Withdraw excessive tokens
        if (excessiveTokens > 0) {
            IERC20(token).safeTransfer(owner(), excessiveTokens);

            emit ExcessiveFundsWithdrawn(
                owner(),
                token,
                excessiveTokens,
                "Excessive tokens"
            );
        }
    }

    /**
     * @notice Get excessive funds information for a token
     * @param token Address of the token
     * @return excessiveEth Amount of excessive ETH
     * @return excessiveTokens Amount of excessive tokens
     */
    function getExcessiveFunds(
        address token
    ) external view returns (uint256 excessiveEth, uint256 excessiveTokens) {
        require(token != address(0), "Invalid token address");

        // Calculate excessive ETH (overall contract balance)
        uint256 currentEthBalance = address(this).balance;
        uint256 totalEthContributed = totalEthAdded - totalEthRemoved;

        if (currentEthBalance > totalEthContributed) {
            excessiveEth = currentEthBalance - totalEthContributed;
        }

        // Calculate excessive tokens (overall contract balance)
        uint256 currentTokenBalance = IERC20(token).balanceOf(address(this));
        uint256 totalTokensContributed = totalTokensAdded[token] -
            totalTokensRemoved[token];

        if (currentTokenBalance > totalTokensContributed) {
            excessiveTokens = currentTokenBalance - totalTokensContributed;
        }
    }

    /**
     * @notice Check if ETH pool is empty and increment ETH epoch if needed
     * @param token Address of the token
     */
    function _checkAndIncrementETHEpoch(address token) internal {
        ETHPoolInfo storage ethPool = ethPools[token][currentETHEpochs[token]];

        // Only increment ETH epoch if ETH pool is empty
        if (ethPool.totalETH == 0) {
            currentETHEpochs[token]++;
            emit EpochIncremented(token, currentETHEpochs[token]);
        }
    }

    /**
     * @notice Check if token pool is empty and increment token epoch if needed
     * @param token Address of the token
     */
    function _checkAndIncrementTokenEpoch(address token) internal {
        TokenPoolInfo storage tokenPool = tokenPools[token][
            currentTokenEpochs[token]
        ];

        // Only increment token epoch if token pool is empty
        if (tokenPool.totalTokens == 0) {
            currentTokenEpochs[token]++;
            emit EpochIncremented(token, currentTokenEpochs[token]);
        }
    }

    /**
     * @notice Get current ETH epoch for a token
     * @param token Address of the token
     * @return Current ETH epoch number
     */
    function getCurrentETHEpoch(address token) external view returns (uint256) {
        return currentETHEpochs[token];
    }

    /**
     * @notice Get current token epoch for a token
     * @param token Address of the token
     * @return Current token epoch number
     */
    function getCurrentTokenEpoch(
        address token
    ) external view returns (uint256) {
        return currentTokenEpochs[token];
    }

    /**
     * @notice Add user to participated epochs if not already present
     * @param token Address of the token
     * @param user Address of the user
     * @param epochId Epoch ID to add
     * @param isETHEpoch Whether this is an ETH epoch (true) or token epoch (false)
     */
    function _addUserToParticipatedEpochs(
        address token,
        address user,
        uint256 epochId,
        bool isETHEpoch
    ) internal {
        uint256[] storage epochs = isETHEpoch
            ? userParticipatedETHEpochs[token][user]
            : userParticipatedTokenEpochs[token][user];
        bool found = false;

        for (uint256 i = 0; i < epochs.length; i++) {
            if (epochs[i] == epochId) {
                found = true;
                break;
            }
        }

        if (!found) {
            epochs.push(epochId);
        }
    }

    function getUserParticipatedETHEpochs(
        address token,
        address user
    ) public view returns (uint256[] memory) {
        return userParticipatedETHEpochs[token][user];
    }

    function getUserParticipatedTokenEpochs(
        address token,
        address user
    ) public view returns (uint256[] memory) {
        return userParticipatedTokenEpochs[token][user];
    }
}
