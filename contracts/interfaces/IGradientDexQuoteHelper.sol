// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IGradientDexQuoteHelper
 * @notice Aggregates V2/V3 spot quotes across one or more compatible DEX venues (e.g. Uniswap, PancakeSwap)
 */
interface IGradientDexQuoteHelper {
    /// @notice V3 fee tiers checked when searching for pools (e.g. 500, 3000, 10000)
    function v3FeeTiers(uint256 index) external view returns (uint24);

    /// @notice Minimum wrapped-native liquidity required for a venue pool to be considered
    function minWethLiquidity() external view returns (uint256);

    /// @notice Best-effort ETH-per-token price (18 decimals), 0 if no liquidity found on any venue
    function getCurrentMarketPriceV2(
        address token
    ) external view returns (uint256 marketPrice);

    /// @notice V2 reserves for token vs wrapped native on the first venue that has a pair
    function getReserves(
        address token
    ) external view returns (uint256 reserveETH, uint256 reserveToken);

    /// @notice True if any configured venue has a V3 pool for token / wrapped native
    function hasV3Pool(address token) external view returns (bool);

    /// @notice True if any configured venue has a V2 pair for token / wrapped native meeting liquidity threshold
    function hasV2Pool(address token) external view returns (bool);

    /// @notice Returns the best V3 pool found across all venues and fee tiers by liquidity
    function getV3PoolAddress(
        address token
    )
        external
        view
        returns (
            address selectedRouter,
            address bestPool,
            uint128 bestLiquidity
        );

    /// @notice Returns the best V2 pair found across venues by wrapped-native reserves
    function getBestV2Pool(
        address token
    )
        external
        view
        returns (
            address selectedRouter,
            address bestPair,
            uint256 bestWethLiq,
            uint256 bestTokenLiq
        );

    /// @notice Number of configured venues (priority order: lower index first)
    function venueCount() external view returns (uint256);

    /// @notice Venue configuration at index
    function getVenue(
        uint256 index
    ) external view returns (address v2Router, address v3FactoryAddress);

    // --- Owner-admin venue configuration ---

    /// @notice Append a venue (lower index = higher priority)
    function addVenue(
        address v2Router,
        address v3FactoryAddress,
        bool isPancakeType
    ) external;

    /// @notice Remove venue at index (swap-and-pop)
    function removeVenue(uint256 index) external;

    /// @notice Remove all venues (e.g. before reconfiguring)
    function clearVenues() external;

    /// @notice Sets the V3 fee tiers to check
    function setV3FeeTiers(uint24[] calldata _feeTiers) external;

    /// @notice Sets the minimum wrapped-native liquidity requirement
    function setMinWethLiquidity(uint256 _minWethLiquidity) external;
}
