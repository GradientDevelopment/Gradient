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
     * @notice Add ETH liquidity to the pool
     * @param token Address of the token to provide ETH liquidity for
     * @dev Requires ETH to be sent with the transaction
     */
    function addETHLiquidity(
        address token
    ) external payable isNotBlocked(token) nonReentrant {
        require(msg.value > 0, "Must provide ETH");
        require(token != address(0), "Invalid token address");

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
        uint256 lpSharesToMint;
        if (pool.totalLPShares == 0) {
            // First ETH provider gets shares equal to their contribution
            lpSharesToMint = msg.value;
        } else {
            // Calculate shares based on proportional contribution
            lpSharesToMint = (msg.value * pool.totalLPShares) / pool.totalETH;
        }

        provider.lpShares += lpSharesToMint;
        provider.ethAmount += msg.value;
        provider.rewardDebt =
            (provider.lpShares * pool.accRewardPerShare) /
            SCALE;
        provider.tokenRewardDebt =
            (provider.lpShares * pool.accTokenRewardPerShare) /
            SCALE;

        pool.totalETH += msg.value;
        pool.totalLPShares += lpSharesToMint;

        emit ETHLiquidityDeposited(
            msg.sender,
            token,
            msg.value,
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
    ) external isNotBlocked(token) nonReentrant {
        require(tokenAmount > 0, "Must provide tokens");
        require(token != address(0), "Invalid token address");

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
        uint256 lpSharesToMint;
        if (pool.totalLPShares == 0) {
            // First token provider gets shares equal to their contribution
            lpSharesToMint = tokenAmount;
        } else {
            // Calculate shares based on proportional contribution
            lpSharesToMint =
                (tokenAmount * pool.totalLPShares) /
                pool.totalTokens;
        }

        provider.lpShares += lpSharesToMint;
        provider.tokenAmount += tokenAmount;
        provider.rewardDebt =
            (provider.lpShares * pool.accRewardPerShare) /
            SCALE;
        provider.ethRewardDebt =
            (provider.lpShares * pool.accETHRewardPerShare) /
            SCALE;

        pool.totalTokens += tokenAmount;
        pool.totalLPShares += lpSharesToMint;

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
     * @notice Remove ETH liquidity from the pool
     * @param token Address of the token to withdraw from
     * @param shares Percentage of pool to withdraw (in basis points, 10000 = 100%)
     */
    function removeETHLiquidity(
        address token,
        uint256 shares
    ) external nonReentrant {
        require(shares > 0 && shares <= 10000, "Invalid shares percentage");

        ETHPoolInfo storage pool = ethPools[token];
        ETHProvider storage provider = ethProviders[token][msg.sender];

        require(pool.totalETH > 0, "No ETH liquidity in pool");
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

        // Calculate actual withdrawal amounts based on LP shares
        uint256 actualEthWithdraw = (pool.totalETH * lpSharesToBurn) /
            pool.totalLPShares;

        // Update balances
        provider.ethAmount -= actualEthWithdraw;
        provider.lpShares -= lpSharesToBurn;

        pool.totalETH -= actualEthWithdraw;
        pool.totalLPShares -= lpSharesToBurn;

        // Update reward debt for remaining shares
        provider.rewardDebt =
            (provider.lpShares * pool.accRewardPerShare) /
            SCALE;
        provider.tokenRewardDebt =
            (provider.lpShares * pool.accTokenRewardPerShare) /
            SCALE;

        // Transfer ETH back to user
        (bool success, ) = payable(msg.sender).call{value: actualEthWithdraw}(
            ""
        );
        require(success, "ETH transfer failed");

        // Transfer accumulated token rewards to user
        if (provider.pendingTokenReward > 0) {
            uint256 tokenRewards = provider.pendingTokenReward;
            provider.pendingTokenReward = 0;
            IERC20(token).safeTransfer(msg.sender, tokenRewards);
        }

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
     */
    function removeTokenLiquidity(
        address token,
        uint256 shares
    ) external nonReentrant {
        require(shares > 0 && shares <= 10000, "Invalid shares percentage");

        TokenPoolInfo storage pool = tokenPools[token];
        TokenProvider storage provider = tokenProviders[token][msg.sender];

        require(pool.totalTokens > 0, "No token liquidity in pool");
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

        // Calculate LP shares to burn based on withdrawal percentage
        uint256 lpSharesToBurn = (provider.lpShares * shares) / 10000;
        require(lpSharesToBurn > 0, "No shares to burn");

        // Calculate actual withdrawal amounts based on LP shares
        uint256 actualTokenWithdraw = (pool.totalTokens * lpSharesToBurn) /
            pool.totalLPShares;

        // Update balances
        provider.tokenAmount -= actualTokenWithdraw;
        provider.lpShares -= lpSharesToBurn;

        pool.totalTokens -= actualTokenWithdraw;
        pool.totalLPShares -= lpSharesToBurn;

        // Update reward debt for remaining shares
        provider.rewardDebt =
            (provider.lpShares * pool.accRewardPerShare) /
            SCALE;
        provider.ethRewardDebt =
            (provider.lpShares * pool.accETHRewardPerShare) /
            SCALE;

        // Transfer tokens back to user
        IERC20(token).safeTransfer(msg.sender, actualTokenWithdraw);

        // Transfer accumulated ETH rewards to user
        if (provider.pendingETHReward > 0) {
            uint256 ethRewards = provider.pendingETHReward;
            provider.pendingETHReward = 0;
            (bool success, ) = payable(msg.sender).call{value: ethRewards}("");
            require(success, "ETH reward transfer failed");
        }

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

    /**
     * @notice Transfer ETH to orderbook for order fulfillment (for buy orders)
     * @param token The token being traded
     * @param amount The amount of ETH to transfer
     * @dev Only callable by the orderbook contract
     * @dev ETH pool provides ETH, token pool receives rewards
     */
    function transferETHToOrderbook(
        address token,
        uint256 amount
    ) external isNotBlocked(token) onlyOrderbook {
        require(amount > 0, "Amount must be greater than 0");
        require(token != address(0), "Invalid token address");

        ETHPoolInfo storage ethPool = ethPools[token];
        require(ethPool.totalETH >= amount, "Insufficient ETH liquidity");

        // Update ETH pool balances
        ethPool.totalETH -= amount;

        // Transfer ETH to orderbook
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "ETH transfer to orderbook failed");

        emit PoolBalanceUpdated(
            token,
            ethPool.totalETH,
            tokenPools[token].totalTokens,
            ethPool.totalLPShares,
            tokenPools[token].totalLPShares
        );
    }

    /**
     * @notice Transfer tokens to orderbook for order fulfillment (for sell orders)
     * @param token The token to transfer
     * @param amount The amount of tokens to transfer
     * @dev Only callable by the orderbook contract
     * @dev Token pool provides tokens, ETH pool receives rewards
     */
    function transferTokenToOrderbook(
        address token,
        uint256 amount
    ) external isNotBlocked(token) onlyOrderbook {
        require(amount > 0, "Amount must be greater than 0");
        require(token != address(0), "Invalid token address");

        TokenPoolInfo storage tokenPool = tokenPools[token];
        require(
            tokenPool.totalTokens >= amount,
            "Insufficient token liquidity"
        );

        // Update token pool balances
        tokenPool.totalTokens -= amount;

        // Transfer tokens to orderbook
        IERC20(token).safeTransfer(msg.sender, amount);

        emit PoolBalanceUpdated(
            token,
            ethPools[token].totalETH,
            tokenPool.totalTokens,
            ethPools[token].totalLPShares,
            tokenPool.totalLPShares
        );
    }

    /**
     * @notice Receive ETH deposit from orderbook for order fulfillment
     * @param token The token being traded
     * @param amount The amount of ETH to deposit
     * @dev Only callable by the orderbook contract
     * @dev For buy orders: ETH goes to token pool as rewards
     * @dev For sell orders: ETH goes to ETH pool as replenishment
     */
    function receiveETHFromOrderbook(
        address token,
        uint256 amount
    ) external payable isNotBlocked(token) onlyOrderbook {
        require(amount > 0, "Amount must be greater than 0");
        require(msg.value == amount, "ETH amount mismatch");

        // For buy orders: ETH should go to token pool as rewards
        // For sell orders: ETH should go to ETH pool as replenishment
        // We'll let the orderbook specify which pool should receive it
        // For now, we'll add it to ETH pool as replenishment

        ETHPoolInfo storage ethPool = ethPools[token];

        // Update ETH pool balances
        ethPool.totalETH += amount;

        emit ETHReceivedFromOrderbook(msg.sender, amount, token);
        emit PoolBalanceUpdated(
            token,
            ethPool.totalETH,
            tokenPools[token].totalTokens,
            ethPool.totalLPShares,
            tokenPools[token].totalLPShares
        );
    }

    /**
     * @notice Receive token deposit from orderbook for order fulfillment
     * @param token The token to deposit
     * @param amount The amount of tokens to deposit
     * @dev Only callable by the orderbook contract
     * @dev For buy orders: tokens go to ETH pool as rewards
     * @dev For sell orders: tokens go to token pool as replenishment
     */
    function receiveTokenFromOrderbook(
        address token,
        uint256 amount
    ) external isNotBlocked(token) onlyOrderbook {
        require(amount > 0, "Amount must be greater than 0");
        require(token != address(0), "Invalid token address");

        // For buy orders: tokens should go to ETH pool as rewards
        // For sell orders: tokens should go to token pool as replenishment
        // We'll let the orderbook specify which pool should receive it
        // For now, we'll add it to token pool as replenishment

        TokenPoolInfo storage tokenPool = tokenPools[token];

        // Transfer tokens from orderbook to token pool
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Update token pool balances
        tokenPool.totalTokens += amount;

        emit TokenReceivedFromOrderbook(msg.sender, token, amount);
        emit PoolBalanceUpdated(
            token,
            ethPools[token].totalETH,
            tokenPool.totalTokens,
            ethPools[token].totalLPShares,
            tokenPool.totalLPShares
        );
    }

    /// @notice Receives fee distribution from orderbook to be distributed to market makers
    /// @param token Address of the token pool to distribute fees for
    /// @param isETHPool Whether to distribute to ETH pool (true) or token pool (false)
    function receiveFeeDistribution(
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

        emit RewardDeposited(token, msg.value);
    }

    /// @notice Claim ETH rewards for ETH providers
    /// @param token Address of the token pool to claim rewards from
    function claimETHRewards(address token) external nonReentrant {
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

        emit RewardClaimed(msg.sender, reward);
    }

    /// @notice Claim token rewards for token providers
    /// @param token Address of the token pool to claim rewards from
    function claimTokenRewards(address token) external nonReentrant {
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

        IERC20(token).safeTransfer(msg.sender, reward);

        emit RewardClaimed(msg.sender, reward);
    }

    /// @notice Claim token rewards for ETH providers
    /// @param token Address of the token pool to claim rewards from
    function claimETHTokenRewards(address token) external nonReentrant {
        ETHPoolInfo storage pool = ethPools[token];
        ETHProvider storage provider = ethProviders[token][msg.sender];
        require(
            provider.lpShares > 0 || provider.pendingTokenReward > 0,
            "No liquidity or token rewards"
        );

        uint256 accumulated = (provider.lpShares *
            pool.accTokenRewardPerShare) / SCALE;
        uint256 reward = accumulated -
            provider.tokenRewardDebt +
            provider.pendingTokenReward;
        require(reward > 0, "No token rewards");

        provider.tokenRewardDebt = accumulated;
        provider.pendingTokenReward = 0;

        // Transfer tokens to ETH provider
        IERC20(token).safeTransfer(msg.sender, reward);

        emit RewardClaimed(msg.sender, reward);
    }

    /// @notice Claim ETH rewards for token providers
    /// @param token Address of the token pool to claim rewards from
    function claimTokenETHRewards(address token) external nonReentrant {
        TokenPoolInfo storage pool = tokenPools[token];
        TokenProvider storage provider = tokenProviders[token][msg.sender];
        require(
            provider.lpShares > 0 || provider.pendingETHReward > 0,
            "No liquidity or ETH rewards"
        );

        uint256 accumulated = (provider.lpShares * pool.accETHRewardPerShare) /
            SCALE;
        uint256 reward = accumulated -
            provider.ethRewardDebt +
            provider.pendingETHReward;
        require(reward > 0, "No ETH rewards");

        provider.ethRewardDebt = accumulated;
        provider.pendingETHReward = 0;

        (bool success, ) = payable(msg.sender).call{value: reward}("");
        require(success, "ETH transfer failed");

        emit RewardClaimed(msg.sender, reward);
    }

    /**
     * @notice Emergency withdraw function for owner to withdraw all ETH and tokens
     * @param tokens Array of token addresses to withdraw
     * @dev Only callable by contract owner
     */
    function emergencyWithdraw(address[] calldata tokens) external onlyOwner {
        // Withdraw all ETH
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            (bool success, ) = owner().call{value: ethBalance}("");
            require(success, "ETH withdrawal failed");
        }

        // Withdraw all specified tokens
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            if (token != address(0)) {
                uint256 tokenBalance = IERC20(token).balanceOf(address(this));
                if (tokenBalance > 0) {
                    IERC20(token).safeTransfer(owner(), tokenBalance);
                }
            }
        }
    }

    /**
     * @notice Emergency withdraw function for owner to withdraw all ETH
     * @dev Only callable by contract owner
     */
    function emergencyWithdrawETH() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool success, ) = owner().call{value: balance}("");
            require(success, "ETH withdrawal failed");
        }
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
            _gradientRegistry.marketMakerPool() != address(0),
            "Invalid gradient registry"
        );
        gradientRegistry = _gradientRegistry;
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
}
