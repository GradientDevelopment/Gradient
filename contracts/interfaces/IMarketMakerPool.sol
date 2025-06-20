// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMarketMakerPool {
    struct PoolInfo {
        uint256 totalLiquidity;
        uint256 totalShares;
        uint256 lastUpdateTime;
        uint256 accumulatedFees;
    }

    struct ProviderInfo {
        uint256 liquidity;
        uint256 shares;
        uint256 lastClaimTime;
        uint256 accumulatedFees;
    }

    // Events
    event LiquidityAdded(
        address indexed provider,
        address indexed token,
        uint256 amount,
        uint256 shares
    );
    event LiquidityRemoved(
        address indexed provider,
        address indexed token,
        uint256 amount,
        uint256 shares
    );
    event FeesClaimed(
        address indexed provider,
        address indexed token,
        uint256 amount
    );
    event FeeRateUpdated(address indexed token, uint256 newRate);

    // View functions
    function getPoolInfo(
        address token,
        bool isBuy
    )
        external
        view
        returns (
            uint256 totalLiquidity,
            uint256 totalShares,
            uint256 lastUpdateTime,
            uint256 accumulatedFees
        );

    function getProviderInfo(
        address provider,
        address token,
        bool isBuy
    )
        external
        view
        returns (
            uint256 liquidity,
            uint256 shares,
            uint256 lastClaimTime,
            uint256 accumulatedFees
        );

    // State changing functions
    function addLiquidity(
        address token,
        bool isBuy
    ) external payable returns (uint256 shares);

    function removeLiquidity(
        address token,
        bool isBuy,
        uint256 shares
    ) external returns (uint256 amount);

    function claimFees(
        address token,
        bool isBuy
    ) external returns (uint256 amount);

    function updateFeeRate(address token, uint256 newRate) external;
}
