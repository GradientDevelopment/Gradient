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

    function getActiveDEXes() external view returns (address[] memory);

    function getDEXConfig(address dex) external view returns (DEXConfig memory);

    // State changing functions
    function addDEX(address dex, address router, uint256 priority) external;

    function removeDEX(address dex) external;

    function executeTrade(
        address token,
        uint256 amount,
        uint256 minAmountOut,
        bool isBuy
    ) external payable returns (uint256 amountOut);

    function emergencyWithdraw(address[] calldata tokens) external;

    function emergencyWithdrawETH() external;
}
