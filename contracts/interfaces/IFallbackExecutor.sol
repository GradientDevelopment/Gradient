// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IFallbackExecutor {
    struct DEXConfig {
        address router;
        address factory;
        bool isActive;
        uint256 priority;
    }

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

    function gradientRegistry() external view returns (address);

    // State changing functions
    function addDEX(
        address dex,
        address router,
        address factory,
        uint256 priority
    ) external;

    function removeDEX(address dex) external;

    function executeTrade(
        address token,
        uint256 amount,
        uint256 minAmountOut,
        bool isBuy
    ) external payable returns (uint256 amountOut);
}
