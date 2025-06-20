// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IFallbackExecutor {
    struct DEXConfig {
        address router;
        address factory;
        bool isActive;
        uint256 priority;
    }

    struct TokenConfig {
        bool isSupported;
        uint256 minAmount;
        uint256 maxAmount;
        address[] preferredDEXes;
    }

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
        uint256 amountOut,
        bool isBuy
    );
    event SlippageUpdated(uint256 newSlippage);

    // View functions
    function dexes(
        address dex
    )
        external
        view
        returns (
            address router,
            address factory,
            bool isActive,
            uint256 priority
        );

    function supportedTokens(
        address token
    )
        external
        view
        returns (
            bool isSupported,
            uint256 minAmount,
            uint256 maxAmount,
            address[] memory preferredDEXes
        );

    // State changing functions
    function addDEX(
        address dex,
        address router,
        address factory,
        uint256 priority
    ) external;

    function removeDEX(address dex) external;

    function addToken(
        address token,
        uint256 minAmount,
        uint256 maxAmount,
        address[] calldata preferredDEXes
    ) external;

    function removeToken(address token) external;

    function executeTrade(
        address token,
        uint256 amount,
        uint256 minAmountOut,
        bool isBuy
    ) external returns (uint256 amountOut);
}
