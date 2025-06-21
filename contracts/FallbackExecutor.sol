// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IUniswapV2Router.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IGradientRegistry.sol";

/**
 * @title FallbackExecutor
 * @notice Handles fallback execution of trades through external AMMs
 * @dev Integrates with Uniswap V2 and can be extended to support other DEXes
 */
contract FallbackExecutor is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // Constants
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_SLIPPAGE = 1000; // 10%

    // Registry contract for checking blocked tokens
    IGradientRegistry public immutable gradientRegistry;

    // DEX configurations
    struct DEXConfig {
        address router;
        address factory;
        bool isActive;
        uint256 priority; // Lower number = higher priority
    }

    // State variables
    mapping(address => DEXConfig) public dexes;
    address[] public activeDEXes;

    // Events
    event DEXAdded(address indexed dex, address router, address factory);
    event DEXRemoved(address indexed dex);
    event TradeExecuted(
        address indexed token,
        address indexed dex,
        uint256 amountIn,
        uint256 amountOut,
        bool isBuy
    );
    event SlippageUpdated(uint256 newSlippage);

    constructor(IGradientRegistry _gradientRegistry) Ownable(msg.sender) {
        gradientRegistry = _gradientRegistry;
    }

    /**
     * @notice Add a new DEX to the fallback system
     * @param dex The DEX address
     * @param router The DEX's router contract
     * @param factory The DEX's factory contract
     * @param priority Priority level (lower = higher priority)
     */
    function addDEX(
        address dex,
        address router,
        address factory,
        uint256 priority
    ) external onlyOwner {
        require(dex != address(0), "Invalid DEX");
        require(router != address(0), "Invalid router");
        require(factory != address(0), "Invalid factory");
        require(!dexes[dex].isActive, "DEX already exists");

        dexes[dex] = DEXConfig({
            router: router,
            factory: factory,
            isActive: true,
            priority: priority
        });

        activeDEXes.push(dex);
        _sortDEXesByPriority();

        emit DEXAdded(dex, router, factory);
    }

    /**
     * @notice Remove a DEX from the fallback system
     * @param dex The DEX to remove
     */
    function removeDEX(address dex) external onlyOwner {
        require(dexes[dex].isActive, "DEX not found");

        dexes[dex].isActive = false;

        // Remove from active DEXes array
        for (uint256 i = 0; i < activeDEXes.length; i++) {
            if (activeDEXes[i] == dex) {
                activeDEXes[i] = activeDEXes[activeDEXes.length - 1];
                activeDEXes.pop();
                break;
            }
        }

        emit DEXRemoved(dex);
    }

    /**
     * @notice Execute a trade through the best available DEX
     * @param token The token to trade
     * @param amount The amount to trade
     * @param minAmountOut Minimum amount to receive
     * @param isBuy Whether this is a buy or sell order
     * @return amountOut The actual amount received from the trade
     */
    function executeTrade(
        address token,
        uint256 amount,
        uint256 minAmountOut,
        bool isBuy
    ) external payable nonReentrant returns (uint256 amountOut) {
        require(token != address(0), "Invalid token");
        require(amount > 0, "Amount must be greater than 0");
        require(!gradientRegistry.blockedTokens(token), "Token is blocked");

        // For buy orders, require ETH to be sent
        if (isBuy) {
            require(msg.value >= amount, "Insufficient ETH sent for buy order");
        }

        // Get the best DEX for this trade
        address bestDEX = _getBestDEX(token, amount, isBuy);
        require(bestDEX != address(0), "No suitable DEX found");

        DEXConfig storage dexConfig = dexes[bestDEX];
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
            }(
                minAmountOut,
                path,
                msg.sender,
                block.timestamp + 300 // 5 minute deadline
            );
            uint256 balanceAfter = IERC20(token).balanceOf(msg.sender);
            amountOut = balanceAfter - balanceBefore;
        } else {
            // Sell tokens for ETH
            uint256 balanceBefore = address(this).balance;
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            IERC20(token).approve(dexConfig.router, amount);

            router.swapExactTokensForETHSupportingFeeOnTransferTokens(
                amount,
                minAmountOut,
                path,
                address(this),
                block.timestamp + 300 // 5 minute deadline
            );

            uint256 balanceAfter = address(this).balance;
            amountOut = balanceAfter - balanceBefore;

            // Transfer ETH to caller
            (bool success, ) = msg.sender.call{value: amountOut}("");
            require(success, "ETH transfer failed");
        }

        emit TradeExecuted(token, bestDEX, amount, amountOut, isBuy);
        return amountOut;
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

        // Ensure sufficient liquidity
        if (isBuy) {
            return ethReserve >= amount;
        } else {
            return tokenReserve >= amount;
        }
    }

    /**
     * @notice Sort DEXes by priority
     */
    function _sortDEXesByPriority() internal {
        // Simple bubble sort
        for (uint256 i = 0; i < activeDEXes.length; i++) {
            for (uint256 j = 0; j < activeDEXes.length - i - 1; j++) {
                if (
                    dexes[activeDEXes[j]].priority >
                    dexes[activeDEXes[j + 1]].priority
                ) {
                    address temp = activeDEXes[j];
                    activeDEXes[j] = activeDEXes[j + 1];
                    activeDEXes[j + 1] = temp;
                }
            }
        }
    }

    receive() external payable {}
}
