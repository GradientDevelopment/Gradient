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

    // Separate pools for ETH and Token providers
    mapping(address => ETHPoolInfo) public ethPools; // token => ETHPoolInfo
    mapping(address => TokenPoolInfo) public tokenPools; // token => TokenPoolInfo

    // User positions in each pool
    mapping(address => mapping(address => ETHProvider)) public ethProviders; // token => user => info
    mapping(address => mapping(address => TokenProvider)) public tokenProviders; // token => user => info

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
     * @param ethAmount Amount of ETH to distribute as rewards
     */
    function _updateETHPool(address token, uint256 ethAmount) internal {
        require(ethAmount > 0, "ETH amount must be greater than 0");
        require(token != address(0), "Invalid token address");
        ETHPoolInfo storage pool = ethPools[token];

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
    function _updateTokenPool(address token, uint256 ethAmount) internal {
        require(ethAmount > 0, "ETH amount must be greater than 0");
        require(token != address(0), "Invalid token address");
        TokenPoolInfo storage pool = tokenPools[token];

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
        ETHPoolInfo storage pool = ethPools[token];

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
        TokenPoolInfo storage pool = tokenPools[token];

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
        ETHPoolInfo storage pool = ethPools[token];

        if (pool.uniswapPair == address(0)) {
            pool.uniswapPair = getPairAddress(token);
        }
        require(pool.uniswapPair != address(0), "Pair does not exist");

        ETHProvider storage provider = ethProviders[token][msg.sender];

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
        TokenPoolInfo storage pool = tokenPools[token];

        if (pool.uniswapPair == address(0)) {
            pool.uniswapPair = getPairAddress(token);
        }
        require(pool.uniswapPair != address(0), "Pair does not exist");

        TokenProvider storage provider = tokenProviders[token][msg.sender];

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
     * @notice Remove liquidity from the pool
     * @param token Address of the token to withdraw from
     * @param shares Percentage of pool to withdraw (in basis points, 10000 = 100%)
     * @param minEthAmount Minimum amount of ETH to receive
     * @param minTokenAmount Minimum amount of tokens to receive
     */
    function removeLiquidity(
        address token,
        uint256 shares,
        uint256 minEthAmount,
        uint256 minTokenAmount
    ) external isNotBlocked(token) nonReentrant {
        require(shares > 0 && shares <= 10000, "Invalid shares percentage");
        require(token != address(0), "Invalid token address");

        _removeETHLiquidity(token, shares, minEthAmount);
        _removeTokenLiquidity(token, shares, minTokenAmount);
    }

    /**
     * @notice Remove ETH liquidity from the pool
     * @param token Address of the token to withdraw from
     * @param shares Percentage of pool to withdraw (in basis points, 10000 = 100%)
     * @param minEthAmount Minimum amount of ETH to receive
     */
    function removeETHLiquidity(
        address token,
        uint256 shares,
        uint256 minEthAmount
    ) external isNotBlocked(token) nonReentrant {
        require(shares > 0 && shares <= 10000, "Invalid shares percentage");
        require(token != address(0), "Invalid token address");
        _removeETHLiquidity(token, shares, minEthAmount);
    }

    /**
     * @notice Remove ETH liquidity from the pool
     * @param token Address of the token to withdraw from
     * @param shares Percentage of pool to withdraw (in basis points, 10000 = 100%)
     * @param minEthAmount Minimum amount of ETH to receive
     */
    function _removeETHLiquidity(
        address token,
        uint256 shares,
        uint256 minEthAmount
    ) internal {
        ETHPoolInfo storage pool = ethPools[token];
        ETHProvider storage provider = ethProviders[token][msg.sender];

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

            emit PoolSharesClaimed(msg.sender, tokenRewards, token, false);
        }

        // Track total ETH removed by LPs
        totalEthRemoved += actualEthWithdraw;

        emit ETHLiquidityWithdrawn(
            msg.sender,
            token,
            actualEthWithdraw,
            lpSharesToBurn
        );
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
        uint256 minTokenAmount
    ) external isNotBlocked(token) nonReentrant {
        require(shares > 0 && shares <= 10000, "Invalid shares percentage");
        require(token != address(0), "Invalid token address");

        _removeTokenLiquidity(token, shares, minTokenAmount);
    }

    function _removeTokenLiquidity(
        address token,
        uint256 shares,
        uint256 minTokenAmount
    ) internal {
        TokenPoolInfo storage pool = tokenPools[token];
        TokenProvider storage provider = tokenProviders[token][msg.sender];

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

            emit PoolSharesClaimed(msg.sender, ethRewards, token, true);
        }

        // Track total tokens removed by LPs
        totalTokensRemoved[token] += actualTokenWithdraw;

        emit TokenLiquidityWithdrawn(
            msg.sender,
            token,
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

        TokenPoolInfo storage tokenPool = tokenPools[token];
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

        emit PoolBalanceUpdated(
            token,
            ethPools[token].totalETH,
            tokenPool.totalTokens,
            ethPools[token].totalLPShares,
            tokenPool.totalLPShares
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

        ETHPoolInfo storage ethPool = ethPools[token];
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

        emit PoolBalanceUpdated(
            token,
            ethPool.totalETH,
            tokenPools[token].totalTokens,
            ethPool.totalLPShares,
            tokenPools[token].totalLPShares
        );
    }

    /// @notice Distributes fee distribution from orderbook to be distributed to market makers
    /// @param token Address of the token pool to distribute fees for
    /// @param isETHPool Whether to distribute to ETH pool (true) or token pool (false)
    function distributePoolFee(
        address token,
        bool isETHPool
    ) external payable onlyRewardDistributor {
        require(msg.value > 0, "No ETH sent");

        if (isETHPool) {
            ETHPoolInfo storage pool = ethPools[token];
            require(pool.totalLPShares > 0, "No ETH liquidity");
            _updateETHPool(token, msg.value);
        } else {
            TokenPoolInfo storage pool = tokenPools[token];
            require(pool.totalLPShares > 0, "No token liquidity");
            _updateTokenPool(token, msg.value);
        }

        emit PoolFeeDistributed(msg.sender, msg.value, token, isETHPool);
    }

    /// @notice Claim ETH rewards for ETH providers
    /// @param token Address of the token pool to claim rewards from
    function claimEthPoolFee(address token) external nonReentrant {
        ETHPoolInfo storage pool = ethPools[token];
        ETHProvider storage provider = ethProviders[token][msg.sender];
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

        emit PoolFeeClaimed(msg.sender, reward, token, false);
    }

    /// @notice Claim token rewards for token providers
    /// @param token Address of the token pool to claim rewards from
    function claimTokenPoolFee(address token) external nonReentrant {
        TokenPoolInfo storage pool = tokenPools[token];
        TokenProvider storage provider = tokenProviders[token][msg.sender];
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

        emit PoolFeeClaimed(msg.sender, reward, token, false);
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
     * @return ETHPoolInfo struct containing ETH pool details
     */
    function getETHPoolInfo(
        address token
    ) external view returns (ETHPoolInfo memory) {
        return ethPools[token];
    }

    /**
     * @notice Gets token pool information for a specific token
     * @param token Address of the token to get token pool info for
     * @return TokenPoolInfo struct containing token pool details
     */
    function getTokenPoolInfo(
        address token
    ) external view returns (TokenPoolInfo memory) {
        return tokenPools[token];
    }

    /**
     * @notice Gets a user's current share percentage of the ETH pool
     * @param token Address of the token
     * @param user Address of the user
     * @return sharePercentage User's share percentage in basis points (10000 = 100%)
     */
    function getETHProviderSharePercentage(
        address token,
        address user
    ) internal view returns (uint256 sharePercentage) {
        ETHPoolInfo storage pool = ethPools[token];
        ETHProvider storage provider = ethProviders[token][user];

        if (pool.totalLPShares == 0) {
            return 0;
        }

        return (provider.lpShares * 10000) / pool.totalLPShares;
    }

    /**
     * @notice Gets a user's current share percentage of the token pool
     * @param token Address of the token
     * @param user Address of the user
     * @return sharePercentage User's share percentage in basis points (10000 = 100%)
     */
    function getTokenProviderSharePercentage(
        address token,
        address user
    ) internal view returns (uint256 sharePercentage) {
        TokenPoolInfo storage pool = tokenPools[token];
        TokenProvider storage provider = tokenProviders[token][user];

        if (pool.totalLPShares == 0) {
            return 0;
        }

        return (provider.lpShares * 10000) / pool.totalLPShares;
    }

    /**
     * @notice Gets a user's LP shares for ETH pool
     * @param token Address of the token
     * @param user Address of the user
     * @return lpShares User's LP shares in ETH pool
     */
    function getETHProviderLPShares(
        address token,
        address user
    ) external view returns (uint256 lpShares) {
        return ethProviders[token][user].lpShares;
    }

    /**
     * @notice Gets a user's LP shares for token pool
     * @param token Address of the token
     * @param user Address of the user
     * @return lpShares User's LP shares in token pool
     */
    function getTokenProviderLPShares(
        address token,
        address user
    ) external view returns (uint256 lpShares) {
        return tokenProviders[token][user].lpShares;
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

    // Legacy interface compatibility - these functions now delegate to the new structure
    function getPoolInfo(
        address token
    ) external view returns (PoolInfo memory) {
        ETHPoolInfo storage ethPool = ethPools[token];
        TokenPoolInfo storage tokenPool = tokenPools[token];

        return
            PoolInfo({
                totalEth: ethPool.totalETH,
                totalToken: tokenPool.totalTokens,
                totalLiquidity: ethPool.totalETH + tokenPool.totalTokens,
                totalLPShares: ethPool.totalLPShares + tokenPool.totalLPShares,
                accRewardPerShare: 0, // Not applicable in new structure
                rewardBalance: ethPool.rewardBalance + tokenPool.rewardBalance,
                uniswapPair: ethPool.uniswapPair,
                accountedEth: ethPool.totalETH,
                accountedToken: tokenPool.totalTokens
            });
    }

    function getUserSharePercentage(
        address token,
        address user
    ) external view returns (uint256 sharePercentage) {
        uint256 ethShare = getETHProviderSharePercentage(token, user);
        uint256 tokenShare = getTokenProviderSharePercentage(token, user);
        return ethShare > tokenShare ? ethShare : tokenShare;
    }

    function getUserLPShares(
        address token,
        address user
    ) external view returns (uint256 lpShares) {
        return
            ethProviders[token][user].lpShares +
            tokenProviders[token][user].lpShares;
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
}
