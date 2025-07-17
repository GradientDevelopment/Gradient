// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router.sol";
import {IUniswapV2Factory} from "./interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IGradientRegistry} from "./interfaces/IGradientRegistry.sol";

/**
 * @title FallbackExecutor
 * @notice Handles fallback execution of trades through external AMMs
 * @dev Integrates with Uniswap V2 and can be extended to support other DEXes
 */
contract FallbackExecutor is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

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
    mapping(address => uint256) public dexIndex; // Track DEX position in array for O(1) removal

    uint256 public maxDEXs = 5;
    uint256 public constant MAX_DEADLINE = 300; // 5 minutes
    uint256 public minLiquidityThreshold = 10 ether; // Minimum liquidity in ETH equivalent

    // Events
    event DEXAdded(address indexed dex, address router, address factory);
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
     * @notice Add a new DEX to the fallback system
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
            isActive: true,
            priority: priority
        });

        activeDEXes.push(dex);
        dexIndex[dex] = activeDEXes.length - 1; // Set initial index
        _sortDEXesByPriority();

        emit DEXAdded(dex, router, factory);
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

    /**
     * @notice Emergency withdraw function for owner to withdraw all ETH and tokens
     * @param tokens Array of token addresses to withdraw
     * @dev Only callable by contract owner
     * @dev Use this function ONLY in emergency situations such as:
     *      - Contract vulnerability or exploit detected
     *      - Critical bug in liquidity management logic
     *      - Migration to new contract version
     *      - Recovery of stuck or locked funds
     *      - Security incident requiring immediate asset protection
     * @dev This function bypasses all normal withdrawal logic and directly transfers assets
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
     * @dev Use this function ONLY in emergency situations such as:
     *      - Contract vulnerability or exploit detected
     *      - Critical bug in liquidity management logic
     *      - Migration to new contract version
     *      - Recovery of stuck or locked funds
     *      - Security incident requiring immediate asset protection
     * @dev This function bypasses all normal withdrawal logic and directly transfers ETH
     */
    function emergencyWithdrawETH() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool success, ) = owner().call{value: balance}("");
            require(success, "ETH withdrawal failed");
        }
    }

    receive() external payable {}
}
