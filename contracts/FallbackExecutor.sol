// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IUniswapV2Router.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Pair.sol";

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

    // DEX configurations
    struct DEXConfig {
        address router;
        address factory;
        bool isActive;
        uint256 priority; // Lower number = higher priority
    }

    // Token configurations
    struct TokenConfig {
        bool isSupported;
        uint256 minAmount;
        uint256 maxAmount;
        address[] preferredDEXes; // Ordered list of preferred DEXes for this token
    }

    // State variables
    mapping(address => DEXConfig) public dexes;
    mapping(address => TokenConfig) public supportedTokens;
    address[] public activeDEXes;

    // Events
    event DEXAdded(address indexed dex, address router, address factory);
    event DEXRemoved(address indexed dex);
    event TokenAdded(
        address indexed token,
        uint256 minAmount,
        uint256 maxAmount
    );
    event TokenRemoved(address indexed token);
    event TradeExecuted(
        address indexed token,
        address indexed dex,
        uint256 amountIn,
        bool isBuy
    );
    event SlippageUpdated(uint256 newSlippage);

    constructor() Ownable(msg.sender) {}

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
     * @notice Add a new token to the fallback system
     * @param token The token to add
     * @param minAmount Minimum trade amount
     * @param maxAmount Maximum trade amount
     * @param preferredDEXes Ordered list of preferred DEXes
     */
    function addToken(
        address token,
        uint256 minAmount,
        uint256 maxAmount,
        address[] calldata preferredDEXes
    ) external onlyOwner {
        require(token != address(0), "Invalid token");
        require(minAmount < maxAmount, "Invalid amounts");
        require(!supportedTokens[token].isSupported, "Token already exists");

        // Validate preferred DEXes
        for (uint256 i = 0; i < preferredDEXes.length; i++) {
            require(dexes[preferredDEXes[i]].isActive, "Invalid DEX");
        }

        supportedTokens[token] = TokenConfig({
            isSupported: true,
            minAmount: minAmount,
            maxAmount: maxAmount,
            preferredDEXes: preferredDEXes
        });

        emit TokenAdded(token, minAmount, maxAmount);
    }

    /**
     * @notice Remove a token from the fallback system
     * @param token The token to remove
     */
    function removeToken(address token) external onlyOwner {
        require(supportedTokens[token].isSupported, "Token not found");

        supportedTokens[token].isSupported = false;
        delete supportedTokens[token].preferredDEXes;

        emit TokenRemoved(token);
    }

    /**
     * @notice Execute a trade through the best available DEX
     * @param token The token to trade
     * @param amount The amount to trade
     * @param minAmountOut Minimum amount to receive
     * @param isBuy Whether this is a buy or sell order
     */
    function executeTrade(
        address token,
        uint256 amount,
        uint256 minAmountOut,
        bool isBuy
    ) external nonReentrant {
        require(supportedTokens[token].isSupported, "Token not supported");
        require(amount >= supportedTokens[token].minAmount, "Below min amount");
        require(amount <= supportedTokens[token].maxAmount, "Above max amount");

        // Get the best DEX for this trade
        address bestDEX = _getBestDEX(token, amount, isBuy);
        require(bestDEX != address(0), "No suitable DEX found");

        DEXConfig storage dexConfig = dexes[bestDEX];
        IUniswapV2Router02 router = IUniswapV2Router02(dexConfig.router);

        // Prepare path
        address[] memory path = new address[](2);
        if (isBuy) {
            path[0] = address(0); // ETH
            path[1] = token;
        } else {
            path[0] = token;
            path[1] = address(0); // ETH
        }

        // Execute trade
        if (isBuy) {
            // Buy tokens with ETH
            router.swapExactETHForTokensSupportingFeeOnTransferTokens{
                value: amount
            }(
                minAmountOut,
                path,
                msg.sender,
                block.timestamp + 300 // 5 minute deadline
            );
        } else {
            // Sell tokens for ETH
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            IERC20(token).approve(dexConfig.router, amount);

            router.swapExactTokensForETHSupportingFeeOnTransferTokens(
                amount,
                minAmountOut,
                path,
                msg.sender,
                block.timestamp + 300 // 5 minute deadline
            );
        }

        emit TradeExecuted(token, bestDEX, amount, isBuy);
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
        // First try preferred DEXes for this token
        address[] storage preferredDEXes = supportedTokens[token]
            .preferredDEXes;
        for (uint256 i = 0; i < preferredDEXes.length; i++) {
            address dex = preferredDEXes[i];
            if (_isDEXSuitable(dex, token, amount, isBuy)) {
                return dex;
            }
        }

        // If no preferred DEX is suitable, try all active DEXes in priority order
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

        // Check if the pair exists
        address pair = IUniswapV2Factory(dexConfig.factory).getPair(
            token,
            address(0) // ETH
        );
        if (pair == address(0)) return false;

        // Check liquidity
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pair)
            .getReserves();
        uint256 tokenReserve = token < address(0) ? reserve0 : reserve1;
        uint256 ethReserve = token < address(0) ? reserve1 : reserve0;

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
