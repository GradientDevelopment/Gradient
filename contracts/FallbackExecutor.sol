// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router.sol";
import {IUniswapV2Factory} from "./interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IUniswapV3SwapRouter} from "./interfaces/IUniswapV3SwapRouter.sol";
import {IUniswapV3Factory} from "./interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";
import {IGradientRegistry} from "./interfaces/IGradientRegistry.sol";

/**
 * @title FallbackExecutor
 * @notice Handles fallback execution of trades through external AMMs
 * @dev Integrates with Uniswap V2 and V3
 */
contract FallbackExecutor is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // Registry contract for checking blocked tokens
    IGradientRegistry public immutable gradientRegistry;

    // DEX version enum
    enum DEXVersion {
        V2,
        V3
    }

    // DEX configurations
    struct DEXConfig {
        address router;
        address factory;
        DEXVersion version;
        bool isActive;
        uint256 priority; // Lower number = higher priority
    }

    // State variables
    mapping(address => DEXConfig) public dexes;
    address[] public activeDEXes;
    mapping(address => uint256) public dexIndex; // Track DEX position in array for O(1) removal

    uint256 public maxDEXs = 5;
    uint256 public constant MAX_DEADLINE = 300; // 5 minutes
    uint256 public minLiquidityThreshold = 10 ether; // Minimum liquidity in ETH equivalent

    // Events
    event DEXAdded(
        address indexed dex,
        address router,
        address factory,
        DEXVersion version
    );
    event DEXRemoved(address indexed dex);
    event MinLiquidityThresholdUpdated(
        uint256 oldThreshold,
        uint256 newThreshold
    );
    event TradeExecuted(
        address indexed token,
        address indexed dex,
        uint256 amountIn,
        uint256 amountOut,
        bool isBuy
    );

    // Modifiers
    modifier onlyOrderbook() {
        require(
            msg.sender == gradientRegistry.orderbook(),
            "FallbackExecutor: Only orderbook can call"
        );
        _;
    }

    constructor(IGradientRegistry _gradientRegistry) Ownable(msg.sender) {
        gradientRegistry = _gradientRegistry;
    }

    /**
     * @notice Add a new V2 DEX to the fallback system
     * @param dex The DEX address
     * @param router The DEX's router contract
     * @param priority Priority level (lower = higher priority)
     */
    function addDEX(
        address dex,
        address router,
        uint256 priority
    ) external onlyOwner {
        require(activeDEXes.length < maxDEXs, "Max DEXs reached");
        require(dex != address(0), "Invalid DEX");
        require(router != address(0), "Invalid router");
        require(!dexes[dex].isActive, "DEX already exists");

        address factory = IUniswapV2Router02(router).factory();
        dexes[dex] = DEXConfig({
            router: router,
            factory: factory,
            version: DEXVersion.V2,
            isActive: true,
            priority: priority
        });

        activeDEXes.push(dex);
        dexIndex[dex] = activeDEXes.length - 1; // Set initial index
        _sortDEXesByPriority();

        emit DEXAdded(dex, router, factory, DEXVersion.V2);
    }

    /**
     * @notice Add a new V3 DEX to the fallback system
     * @param dex The DEX address
     * @param router The DEX's router contract (SwapRouter)
     * @param factory The V3 factory address
     * @param priority Priority level (lower = higher priority)
     */
    function addV3DEX(
        address dex,
        address router,
        address factory,
        uint256 priority
    ) external onlyOwner {
        require(activeDEXes.length < maxDEXs, "Max DEXs reached");
        require(dex != address(0), "Invalid DEX");
        require(router != address(0), "Invalid router");
        require(factory != address(0), "Invalid factory");
        require(!dexes[dex].isActive, "DEX already exists");

        dexes[dex] = DEXConfig({
            router: router,
            factory: factory,
            version: DEXVersion.V3,
            isActive: true,
            priority: priority
        });

        activeDEXes.push(dex);
        dexIndex[dex] = activeDEXes.length - 1; // Set initial index
        _sortDEXesByPriority();

        emit DEXAdded(dex, router, factory, DEXVersion.V3);
    }

    /**
     * @notice Remove a DEX from the fallback system
     * @param dex The DEX to remove
     */
    function removeDEX(address dex) external onlyOwner {
        require(dexes[dex].isActive, "DEX not found");

        uint256 lastDEXIndex = activeDEXes.length - 1;
        address lastDEX = activeDEXes[lastDEXIndex];

        // Swap the element to remove with the last element
        activeDEXes[dexIndex[dex]] = lastDEX;
        dexIndex[lastDEX] = dexIndex[dex];

        // Remove the last element
        activeDEXes.pop();
        delete dexIndex[dex];

        dexes[dex].isActive = false;

        emit DEXRemoved(dex);
    }

    /**
     * @notice Set the minimum liquidity threshold to protect against price manipulation
     * @param newThreshold The new minimum liquidity threshold in ETH equivalent
     * @dev Only callable by contract owner
     * @dev Higher thresholds provide better protection but may exclude more DEXes
     */
    function setMinLiquidityThreshold(uint256 newThreshold) external onlyOwner {
        require(newThreshold > 0, "Threshold must be greater than 0");
        require(newThreshold <= 1000 ether, "Threshold too high"); // Reasonable upper limit

        uint256 oldThreshold = minLiquidityThreshold;
        minLiquidityThreshold = newThreshold;

        emit MinLiquidityThresholdUpdated(oldThreshold, newThreshold);
    }

    /**
     * @notice Execute a trade through the best available DEX
     * @param token The token to trade
     * @param amount The amount to trade
     * @param minAmountOut Minimum amount to receive
     * @param isBuy Whether this is a buy or sell order
     * @return amountOut The actual amount received from the trade
     * @dev Only callable by the orderbook contract to prevent fee bypass
     */
    function executeTrade(
        address token,
        uint256 amount,
        uint256 minAmountOut,
        bool isBuy
    ) external payable onlyOrderbook nonReentrant returns (uint256 amountOut) {
        require(token != address(0), "Invalid token");
        require(amount > 0, "Amount must be greater than 0");
        require(minAmountOut > 0, "Invalid minAmountOut");
        require(!gradientRegistry.blockedTokens(token), "Token is blocked");

        // For buy orders, require ETH to be sent
        if (isBuy) {
            require(msg.value >= amount, "Insufficient ETH sent for buy order");
        }

        // Get the best DEX for this trade
        address bestDEX = _getBestDEX(token, amount, isBuy);
        require(bestDEX != address(0), "No suitable DEX found");

        DEXConfig storage dexConfig = dexes[bestDEX];

        // Route to V2 or V3 based on DEX version
        if (dexConfig.version == DEXVersion.V2) {
            amountOut = _executeV2Trade(
                dexConfig,
                token,
                amount,
                minAmountOut,
                isBuy
            );
        } else {
            amountOut = _executeV3Trade(
                dexConfig,
                token,
                amount,
                minAmountOut,
                isBuy
            );
        }

        emit TradeExecuted(token, bestDEX, amount, amountOut, isBuy);
        return amountOut;
    }

    /**
     * @notice Execute a trade using Uniswap V2
     * @param dexConfig The DEX configuration
     * @param token The token to trade
     * @param amount The amount to trade
     * @param minAmountOut Minimum amount to receive
     * @param isBuy Whether this is a buy or sell order
     * @return amountOut The actual amount received from the trade
     */
    function _executeV2Trade(
        DEXConfig storage dexConfig,
        address token,
        uint256 amount,
        uint256 minAmountOut,
        bool isBuy
    ) internal returns (uint256 amountOut) {
        IUniswapV2Router02 router = IUniswapV2Router02(dexConfig.router);

        // Prepare path
        address[] memory path = new address[](2);
        if (isBuy) {
            path[0] = router.WETH(); // WETH
            path[1] = token;
        } else {
            path[0] = token;
            path[1] = router.WETH(); // WETH
        }

        // Execute trade
        if (isBuy) {
            // Buy tokens with ETH
            uint256 balanceBefore = IERC20(token).balanceOf(msg.sender);

            router.swapExactETHForTokensSupportingFeeOnTransferTokens{
                value: amount
            }(minAmountOut, path, msg.sender, block.timestamp + MAX_DEADLINE);

            uint256 balanceAfter = IERC20(token).balanceOf(msg.sender);
            amountOut = balanceAfter - balanceBefore;

            // Validate slippage protection
            require(amountOut >= minAmountOut, "Insufficient output amount");
        } else {
            // Sell tokens for ETH
            uint256 balanceBefore = address(this).balance;
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

            // Safe approval pattern
            _safeApprove(token, dexConfig.router, amount);

            router.swapExactTokensForETHSupportingFeeOnTransferTokens(
                amount,
                minAmountOut,
                path,
                address(this),
                block.timestamp + MAX_DEADLINE
            );

            uint256 balanceAfter = address(this).balance;
            amountOut = balanceAfter - balanceBefore;

            // Validate slippage protection
            require(amountOut >= minAmountOut, "Insufficient output amount");

            // Transfer ETH to caller
            (bool success, ) = msg.sender.call{value: amountOut}("");
            require(success, "ETH transfer failed");
        }
    }

    /**
     * @notice Execute a trade using Uniswap V3
     * @param dexConfig The DEX configuration
     * @param token The token to trade
     * @param amount The amount to trade
     * @param minAmountOut Minimum amount to receive
     * @param isBuy Whether this is a buy or sell order
     * @return amountOut The actual amount received from the trade
     */
    function _executeV3Trade(
        DEXConfig storage dexConfig,
        address token,
        uint256 amount,
        uint256 minAmountOut,
        bool isBuy
    ) internal returns (uint256 amountOut) {
        IUniswapV3SwapRouter router = IUniswapV3SwapRouter(dexConfig.router);
        IUniswapV3Factory factory = IUniswapV3Factory(dexConfig.factory);

        // Get WETH address - for V3, we need to get it from a V2 router or store it
        // For now, we'll use a common approach: try to get it from the first V2 DEX if available
        address weth = _getWETHAddress();
        require(weth != address(0), "WETH address not found");

        // Find the best V3 pool (try common fee tiers: 500, 3000, 10000)
        uint24[] memory feeTiers = new uint24[](3);
        feeTiers[0] = 500; // 0.05%
        feeTiers[1] = 3000; // 0.3%
        feeTiers[2] = 10000; // 1%

        address poolAddress = address(0);
        uint24 poolFee = 0;

        for (uint256 i = 0; i < feeTiers.length; i++) {
            address pool = factory.getPool(
                token < weth ? token : weth,
                token < weth ? weth : token,
                feeTiers[i]
            );
            if (pool != address(0)) {
                // Check if pool has liquidity
                try IUniswapV3Pool(pool).liquidity() returns (
                    uint128 liquidity
                ) {
                    if (liquidity > 0) {
                        poolAddress = pool;
                        poolFee = feeTiers[i];
                        break;
                    }
                } catch {
                    continue;
                }
            }
        }

        require(poolAddress != address(0), "No V3 pool found");

        // Execute trade
        if (isBuy) {
            // Buy tokens with ETH
            // Wrap ETH to WETH first, then swap
            IWETH9(weth).deposit{value: amount}();
            _safeApprove(weth, dexConfig.router, amount);

            uint256 balanceBefore = IERC20(token).balanceOf(msg.sender);

            IUniswapV3SwapRouter.ExactInputSingleParams
                memory params = IUniswapV3SwapRouter.ExactInputSingleParams({
                    tokenIn: weth,
                    tokenOut: token,
                    fee: poolFee,
                    recipient: msg.sender,
                    deadline: block.timestamp + MAX_DEADLINE,
                    amountIn: amount,
                    amountOutMinimum: minAmountOut,
                    sqrtPriceLimitX96: 0
                });

            router.exactInputSingle(params);

            uint256 balanceAfter = IERC20(token).balanceOf(msg.sender);
            amountOut = balanceAfter - balanceBefore;

            // Validate slippage protection
            require(amountOut >= minAmountOut, "Insufficient output amount");
        } else {
            // Sell tokens for ETH
            uint256 balanceBefore = address(this).balance;
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

            // Safe approval pattern
            _safeApprove(token, dexConfig.router, amount);

            IUniswapV3SwapRouter.ExactInputSingleParams
                memory params = IUniswapV3SwapRouter.ExactInputSingleParams({
                    tokenIn: token,
                    tokenOut: weth,
                    fee: poolFee,
                    recipient: address(this),
                    deadline: block.timestamp + MAX_DEADLINE,
                    amountIn: amount,
                    amountOutMinimum: minAmountOut,
                    sqrtPriceLimitX96: 0
                });

            router.exactInputSingle(params);

            // Unwrap WETH to ETH
            uint256 wethBalance = IERC20(weth).balanceOf(address(this));
            if (wethBalance > 0) {
                IWETH9(weth).withdraw(wethBalance);
            }

            uint256 balanceAfter = address(this).balance;
            amountOut = balanceAfter - balanceBefore;

            // Validate slippage protection
            require(amountOut >= minAmountOut, "Insufficient output amount");

            // Transfer ETH to caller
            (bool success, ) = msg.sender.call{value: amountOut}("");
            require(success, "ETH transfer failed");
        }
    }

    /**
     * @notice Get WETH address from any V2 DEX or return a stored address
     * @return weth The WETH address
     */
    function _getWETHAddress() internal view returns (address weth) {
        // Try to get WETH from any V2 DEX
        for (uint256 i = 0; i < activeDEXes.length; i++) {
            DEXConfig storage config = dexes[activeDEXes[i]];
            if (config.version == DEXVersion.V2 && config.isActive) {
                try IUniswapV2Router02(config.router).WETH() returns (
                    address wethAddr
                ) {
                    return wethAddr;
                } catch {
                    continue;
                }
            }
        }
        return address(0);
    }

    /**
     * @notice Get the best DEX for a trade
     * @param token The token to trade
     * @param amount The amount to trade
     * @param isBuy Whether this is a buy or sell order
     * @return The address of the best DEX
     */
    function _getBestDEX(
        address token,
        uint256 amount,
        bool isBuy
    ) internal view returns (address) {
        // Try all active DEXes in priority order
        for (uint256 i = 0; i < activeDEXes.length; i++) {
            address dex = activeDEXes[i];
            if (_isDEXSuitable(dex, token, amount, isBuy)) {
                return dex;
            }
        }

        return address(0);
    }

    /**
     * @notice Get all active DEXes in priority order
     * @return Array of DEX addresses sorted by priority (lowest first)
     */
    function getActiveDEXes() external view returns (address[] memory) {
        return activeDEXes;
    }

    /**
     * @notice Get DEX configuration by address
     * @param dex The DEX address
     * @return DEXConfig struct containing router, factory, isActive, and priority
     */
    function getDEXConfig(
        address dex
    ) external view returns (DEXConfig memory) {
        return dexes[dex];
    }

    /**
     * @notice Check if a DEX is suitable for a trade
     * @param dex The DEX to check
     * @param token The token to trade
     * @param amount The amount to trade
     * @param isBuy Whether this is a buy or sell order
     */
    function _isDEXSuitable(
        address dex,
        address token,
        uint256 amount,
        bool isBuy
    ) internal view returns (bool) {
        DEXConfig storage dexConfig = dexes[dex];
        if (!dexConfig.isActive) return false;

        if (dexConfig.version == DEXVersion.V2) {
            return _isV2DEXSuitable(dexConfig, token, amount, isBuy);
        } else {
            return _isV3DEXSuitable(dexConfig, token, amount, isBuy);
        }
    }

    /**
     * @notice Check if a V2 DEX is suitable for a trade
     * @param dexConfig The DEX configuration
     * @param token The token to trade
     * @param amount The amount to trade
     * @param isBuy Whether this is a buy or sell order
     */
    function _isV2DEXSuitable(
        DEXConfig storage dexConfig,
        address token,
        uint256 amount,
        bool isBuy
    ) internal view returns (bool) {
        // Get WETH address from router
        IUniswapV2Router02 router = IUniswapV2Router02(dexConfig.router);
        address weth = router.WETH();

        // Check if the pair exists
        address pair = IUniswapV2Factory(dexConfig.factory).getPair(
            token,
            weth
        );
        if (pair == address(0)) return false;

        // Check liquidity
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pair)
            .getReserves();
        uint256 tokenReserve = token < weth ? reserve0 : reserve1;
        uint256 ethReserve = token < weth ? reserve1 : reserve0;

        // Check minimum liquidity threshold (protects against flash loan attacks)
        if (ethReserve < minLiquidityThreshold) {
            return false;
        }

        // Ensure sufficient liquidity with safety margin for the specific trade
        if (isBuy) {
            return ethReserve >= (amount * 11) / 10; // 10% safety margin
        } else {
            return tokenReserve >= (amount * 11) / 10; // 10% safety margin
        }
    }

    /**
     * @notice Check if a V3 DEX is suitable for a trade
     * @param dexConfig The DEX configuration
     * @param token The token to trade
     */
    function _isV3DEXSuitable(
        DEXConfig storage dexConfig,
        address token,
        uint256 /* amount */,
        bool /* isBuy */
    ) internal view returns (bool) {
        // Get WETH address
        address weth = _getWETHAddress();
        if (weth == address(0)) return false;

        IUniswapV3Factory factory = IUniswapV3Factory(dexConfig.factory);

        // Try common fee tiers: 500, 3000, 10000
        uint24[] memory feeTiers = new uint24[](3);
        feeTiers[0] = 500; // 0.05%
        feeTiers[1] = 3000; // 0.3%
        feeTiers[2] = 10000; // 1%

        for (uint256 i = 0; i < feeTiers.length; i++) {
            address pool = factory.getPool(
                token < weth ? token : weth,
                token < weth ? weth : token,
                feeTiers[i]
            );
            if (pool != address(0)) {
                // Check if pool has liquidity and valid price
                try IUniswapV3Pool(pool).slot0() returns (
                    uint160 sqrtPriceX96,
                    int24,
                    uint16,
                    uint16,
                    uint16,
                    uint8,
                    bool
                ) {
                    if (sqrtPriceX96 > 0) {
                        // Check liquidity
                        try IUniswapV3Pool(pool).liquidity() returns (
                            uint128 liquidity
                        ) {
                            if (liquidity > 0) {
                                return true;
                            }
                        } catch {
                            continue;
                        }
                    }
                } catch {
                    continue;
                }
            }
        }

        return false;
    }

    /**
     * @notice Safe approval pattern that resets approval to 0 first
     * @param token The token to approve
     * @param spender The spender address
     * @param amount The amount to approve
     */
    function _safeApprove(
        address token,
        address spender,
        uint256 amount
    ) internal {
        IERC20(token).approve(spender, 0); // Reset approval
        IERC20(token).approve(spender, amount); // Set new approval
    }

    /**
     * @notice Sort DEXes by priority
     */
    function _sortDEXesByPriority() internal {
        // Insertion sort - more efficient than bubble sort for small arrays
        for (uint256 i = 1; i < activeDEXes.length; i++) {
            address currentDEX = activeDEXes[i];
            uint256 currentPriority = dexes[currentDEX].priority;
            uint256 j = i;

            // Move elements that are greater than current one position ahead
            while (
                j > 0 && dexes[activeDEXes[j - 1]].priority > currentPriority
            ) {
                address movedDEX = activeDEXes[j - 1];
                activeDEXes[j] = movedDEX;
                dexIndex[movedDEX] = j; // Update index for the moved DEX
                j--;
            }

            // Place current element in correct position
            activeDEXes[j] = currentDEX;
            dexIndex[currentDEX] = j; // Update index mapping
        }
    }

    receive() external payable {}

    // =============================== EMERGENCY FUNCTIONS ===============================

    /**
     * @notice Emergency function to withdraw ETH from the contract
     * @param recipient Address to receive the ETH
     * @param amount Amount of ETH to withdraw (0 = withdraw all)
     * @dev Only callable by contract owner in emergency situations
     */
    function emergencyWithdrawETH(
        address payable recipient,
        uint256 amount
    ) external onlyOwner {
        require(recipient != address(0), "Invalid recipient");
        require(address(this).balance > 0, "No ETH to withdraw");

        uint256 withdrawAmount = amount == 0 ? address(this).balance : amount;
        require(
            withdrawAmount <= address(this).balance,
            "Insufficient ETH balance"
        );

        (bool success, ) = recipient.call{value: withdrawAmount}("");
        require(success, "ETH withdrawal failed");

        emit EmergencyWithdrawETH(recipient, withdrawAmount);
    }

    /**
     * @notice Emergency function to withdraw ERC20 tokens from the contract
     * @param token Address of the token to withdraw
     * @param recipient Address to receive the tokens
     * @param amount Amount of tokens to withdraw (0 = withdraw all)
     * @dev Only callable by contract owner in emergency situations
     */
    function emergencyWithdrawToken(
        address token,
        address recipient,
        uint256 amount
    ) external onlyOwner {
        require(token != address(0), "Invalid token address");
        require(recipient != address(0), "Invalid recipient");

        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "No tokens to withdraw");

        uint256 withdrawAmount = amount == 0 ? balance : amount;
        require(withdrawAmount <= balance, "Insufficient token balance");

        IERC20(token).safeTransfer(recipient, withdrawAmount);

        emit EmergencyWithdrawToken(token, recipient, withdrawAmount);
    }

    /**
     * @notice Emergency function to withdraw multiple tokens at once
     * @param tokens Array of token addresses to withdraw
     * @param recipient Address to receive all tokens
     * @dev Only callable by contract owner in emergency situations
     * @dev More gas efficient than calling emergencyWithdrawToken multiple times
     */
    function emergencyWithdrawMultipleTokens(
        address[] calldata tokens,
        address recipient
    ) external onlyOwner {
        require(recipient != address(0), "Invalid recipient");
        require(tokens.length > 0, "No tokens specified");
        require(tokens.length <= 20, "Too many tokens to withdraw at once");

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            require(token != address(0), "Invalid token address");

            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance > 0) {
                IERC20(token).safeTransfer(recipient, balance);
                emit EmergencyWithdrawToken(token, recipient, balance);
            }
        }
    }

    // Events for emergency withdrawals
    event EmergencyWithdrawETH(address indexed recipient, uint256 amount);
    event EmergencyWithdrawToken(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );
}
