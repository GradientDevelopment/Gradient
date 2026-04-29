// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router.sol";
import {IUniswapV2Factory} from "./interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IUniswapV3SwapRouterV2} from "./interfaces/IUniswapV3SwapRouterV2.sol";
import {IUniswapV3Factory} from "./interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {IPancakeV3Pool} from "./interfaces/IPancakeV3Pool.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";
import {IGradientRegistry} from "./interfaces/IGradientRegistry.sol";

/**
 * @title FallbackExecutorV2
 * @notice Handles fallback execution of trades through external AMMs (SwapRouter02 for V3)
 * @dev Integrates with Uniswap V2 and Uniswap V3 SwapRouter02 (Base/BSC)
 */
contract FallbackExecutorV2 is ReentrancyGuard, Ownable {
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
        bool isPancakeType;
        uint256 priority;
    }

    // State variables
    mapping(address => DEXConfig) public dexes;
    address[] public activeDEXes;
    mapping(address => uint256) public dexIndex;

    uint256 public maxDEXs = 5;
    uint256 public constant MAX_DEADLINE = 300; // 5 minutes
    uint256 public minLiquidityThreshold = 10 ether; // Minimum liquidity in ETH equivalent
    // Fee tiers used when searching for V3 pools
    uint24[3] public FEE_TIERS = [500, 3000, 10000];

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
    event EmergencyWithdrawETH(address indexed recipient, uint256 amount);
    event EmergencyWithdrawToken(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );

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
        require(dex != address(0) && router != address(0), "Invalid address");
        require(!dexes[dex].isActive, "DEX already exists");

        address factory = IUniswapV2Router02(router).factory();
        dexes[dex] = DEXConfig({
            router: router,
            factory: factory,
            version: DEXVersion.V2,
            isActive: true,
            isPancakeType: false,
            priority: priority
        });

        _addAndSort(dex);
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
        uint256 priority,
        bool isPancakeType
    ) external onlyOwner {
        require(activeDEXes.length < maxDEXs, "Max DEXs reached");
        require(
            dex != address(0) && router != address(0) && factory != address(0),
            "Invalid address"
        );
        require(!dexes[dex].isActive, "DEX already exists");

        dexes[dex] = DEXConfig({
            router: router,
            factory: factory,
            version: DEXVersion.V3,
            isActive: true,
            isPancakeType: isPancakeType,
            priority: priority
        });

        _addAndSort(dex);
        emit DEXAdded(dex, router, factory, DEXVersion.V3);
    }

    /**
     * @notice Remove a DEX from the fallback system
     * @param dex The DEX to remove
     */
    function removeDEX(address dex) external onlyOwner {
        require(dexes[dex].isActive, "DEX not found");

        uint256 lastIdx = activeDEXes.length - 1;
        address lastDEX = activeDEXes[lastIdx];

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
        require(
            newThreshold > 0 && newThreshold <= 10000 ether,
            "Invalid threshold"
        );
        emit MinLiquidityThresholdUpdated(minLiquidityThreshold, newThreshold);
        minLiquidityThreshold = newThreshold;
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
        amountOut = dexConfig.version == DEXVersion.V2
            ? _executeV2Trade(dexConfig, token, amount, minAmountOut, isBuy)
            : _executeV3Trade(dexConfig, token, amount, minAmountOut, isBuy);

        emit TradeExecuted(token, bestDEX, amount, amountOut, isBuy);
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
        address weth = router.WETH();

        address[] memory path = new address[](2);
        if (isBuy) {
            path[0] = weth;
            path[1] = token;

            uint256 balanceBefore = IERC20(token).balanceOf(msg.sender);
            router.swapExactETHForTokensSupportingFeeOnTransferTokens{
                value: amount
            }(minAmountOut, path, msg.sender, block.timestamp + MAX_DEADLINE);
            amountOut = IERC20(token).balanceOf(msg.sender) - balanceBefore;
        } else {
            path[0] = token;
            path[1] = weth;

            uint256 balanceBefore = address(this).balance;
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            IERC20(token).forceApprove(dexConfig.router, amount);
            router.swapExactTokensForETHSupportingFeeOnTransferTokens(
                amount,
                minAmountOut,
                path,
                address(this),
                block.timestamp + MAX_DEADLINE
            );
            amountOut = address(this).balance - balanceBefore;

            (bool success, ) = msg.sender.call{value: amountOut}("");
            require(success, "ETH transfer failed");
        }

        require(amountOut >= minAmountOut, "Insufficient output amount");
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
        address weth = _getWETHAddress();
        require(weth != address(0), "WETH address not found");

        (address poolAddress, uint24 poolFee) = _findV3Pool(
            dexConfig,
            token,
            weth
        );
        require(poolAddress != address(0), "No V3 pool found");

        IUniswapV3SwapRouterV2 router = IUniswapV3SwapRouterV2(
            dexConfig.router
        );

        if (isBuy) {
            IWETH9(weth).deposit{value: amount}();
            IERC20(weth).forceApprove(dexConfig.router, amount);

            uint256 balanceBefore = IERC20(token).balanceOf(msg.sender);
            router.exactInputSingle(
                IUniswapV3SwapRouterV2.ExactInputSingleParams({
                    tokenIn: weth,
                    tokenOut: token,
                    fee: poolFee,
                    recipient: msg.sender,
                    amountIn: amount,
                    amountOutMinimum: minAmountOut,
                    sqrtPriceLimitX96: 0
                })
            );
            amountOut = IERC20(token).balanceOf(msg.sender) - balanceBefore;
        } else {
            uint256 balanceBefore = address(this).balance;
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            IERC20(token).forceApprove(dexConfig.router, amount);

            router.exactInputSingle(
                IUniswapV3SwapRouterV2.ExactInputSingleParams({
                    tokenIn: token,
                    tokenOut: weth,
                    fee: poolFee,
                    recipient: address(this),
                    amountIn: amount,
                    amountOutMinimum: minAmountOut,
                    sqrtPriceLimitX96: 0
                })
            );

            uint256 wethBalance = IERC20(weth).balanceOf(address(this));
            if (wethBalance > 0) IWETH9(weth).withdraw(wethBalance);

            amountOut = address(this).balance - balanceBefore;

            (bool success, ) = msg.sender.call{value: amountOut}("");
            require(success, "ETH transfer failed");
        }

        require(amountOut >= minAmountOut, "Insufficient output amount");
    }

    // =============================== INTERNAL HELPERS ===============================

    function _addAndSort(address dex) internal {
        activeDEXes.push(dex);
        dexIndex[dex] = activeDEXes.length - 1;
        _sortDEXesByPriority();
    }

    function _getWETHAddress() internal view returns (address) {
        for (uint256 i = 0; i < activeDEXes.length; i++) {
            DEXConfig storage config = dexes[activeDEXes[i]];
            if (config.version == DEXVersion.V2 && config.isActive) {
                try IUniswapV2Router02(config.router).WETH() returns (
                    address weth
                ) {
                    return weth;
                } catch {}
            }
        }
        return address(0);
    }

    function _findV3Pool(
        DEXConfig storage dexConfig,
        address token,
        address weth
    ) internal view returns (address poolAddress, uint24 poolFee) {
        IUniswapV3Factory factory = IUniswapV3Factory(dexConfig.factory);
        (address t0, address t1) = token < weth ? (token, weth) : (weth, token);

        for (uint256 i = 0; i < FEE_TIERS.length; i++) {
            address pool = factory.getPool(t0, t1, FEE_TIERS[i]);
            if (pool == address(0)) continue;

            try IUniswapV3Pool(pool).liquidity() returns (uint128 liquidity) {
                if (liquidity > 0) return (pool, FEE_TIERS[i]);
            } catch {}
        }
    }

    function _getBestDEX(
        address token,
        uint256 amount,
        bool isBuy
    ) internal view returns (address) {
        for (uint256 i = 0; i < activeDEXes.length; i++) {
            address dex = activeDEXes[i];
            if (_isDEXSuitable(dex, token, amount, isBuy)) return dex;
        }
        return address(0);
    }

    function _isDEXSuitable(
        address dex,
        address token,
        uint256 amount,
        bool isBuy
    ) internal view returns (bool) {
        DEXConfig storage dexConfig = dexes[dex];
        if (!dexConfig.isActive) return false;
        return
            dexConfig.version == DEXVersion.V2
                ? _isV2DEXSuitable(dexConfig, token, amount, isBuy)
                : _isV3DEXSuitable(dexConfig, token);
    }

    function _isV2DEXSuitable(
        DEXConfig storage dexConfig,
        address token,
        uint256 amount,
        bool isBuy
    ) internal view returns (bool) {
        IUniswapV2Router02 router = IUniswapV2Router02(dexConfig.router);
        address weth = router.WETH();

        address pair = IUniswapV2Factory(dexConfig.factory).getPair(
            token,
            weth
        );
        if (pair == address(0)) return false;

        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pair)
            .getReserves();
        uint256 tokenReserve = token < weth ? reserve0 : reserve1;
        uint256 ethReserve = token < weth ? reserve1 : reserve0;

        if (ethReserve < minLiquidityThreshold) return false;

        // Require 10% safety margin above the trade amount
        return
            isBuy
                ? ethReserve >= (amount * 11) / 10
                : tokenReserve >= (amount * 11) / 10;
    }

    function _isV3DEXSuitable(
        DEXConfig storage dexConfig,
        address token
    ) internal view returns (bool) {
        address weth = _getWETHAddress();
        if (weth == address(0)) return false;

        (address poolAddress, ) = _findV3Pool(dexConfig, token, weth);

        if (poolAddress == address(0)) return false;

        // Also validate that there is a valid price (sqrtPriceX96 > 0)
        if (dexConfig.isPancakeType) {
            try IPancakeV3Pool(poolAddress).slot0() returns (
                uint160 sqrtPriceX96,
                int24,
                uint16,
                uint16,
                uint16,
                uint32,
                bool
            ) {
                return sqrtPriceX96 > 0;
            } catch {}
        } else {
            try IUniswapV3Pool(poolAddress).slot0() returns (
                uint160 sqrtPriceX96,
                int24,
                uint16,
                uint16,
                uint16,
                uint8,
                bool
            ) {
                return sqrtPriceX96 > 0;
            } catch {}
        }
        return false;
    }

    function _sortDEXesByPriority() internal {
        for (uint256 i = 1; i < activeDEXes.length; i++) {
            address current = activeDEXes[i];
            uint256 currentPriority = dexes[current].priority;
            uint256 j = i;

            while (
                j > 0 && dexes[activeDEXes[j - 1]].priority > currentPriority
            ) {
                address moved = activeDEXes[j - 1];
                activeDEXes[j] = moved;
                dexIndex[moved] = j;
                j--;
            }

            activeDEXes[j] = current;
            dexIndex[current] = j;
        }
    }

    // =============================== VIEWS ===============================

    function getActiveDEXes() external view returns (address[] memory) {
        return activeDEXes;
    }

    function getDEXConfig(
        address dex
    ) external view returns (DEXConfig memory) {
        return dexes[dex];
    }

    // =============================== EMERGENCY ===============================

    function emergencyWithdrawETH(
        address payable recipient,
        uint256 amount
    ) external onlyOwner {
        require(recipient != address(0), "Invalid recipient");
        uint256 bal = address(this).balance;
        require(bal > 0, "No ETH to withdraw");
        uint256 withdrawAmount = amount == 0 ? bal : amount;
        require(withdrawAmount <= bal, "Insufficient ETH balance");

        (bool success, ) = recipient.call{value: withdrawAmount}("");
        require(success, "ETH withdrawal failed");
        emit EmergencyWithdrawETH(recipient, withdrawAmount);
    }

    function emergencyWithdrawTokens(
        address[] calldata tokens,
        address recipient
    ) external onlyOwner {
        require(recipient != address(0), "Invalid recipient");
        require(
            tokens.length > 0 && tokens.length <= 20,
            "Invalid token count"
        );

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

    receive() external payable {}
}
