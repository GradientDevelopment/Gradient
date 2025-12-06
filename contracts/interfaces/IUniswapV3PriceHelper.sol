// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IUniswapV3PriceHelper
 * @notice Interface for Uniswap V3 price helper contract
 * @dev This helper reduces pool contract size by handling all V3-specific logic
 */
interface IUniswapV3PriceHelper {
    /**
     * @notice Get V3 pool address for a token by trying different fee tiers
     * @param token Address of the token
     * @param weth WETH address
     * @return poolAddress Address of the V3 pool, or address(0) if not found
     */
    function getV3PoolAddress(
        address token,
        address weth
    ) external view returns (address poolAddress);

    /**
     * @notice Get price from Uniswap V3 pool
     * @param token Address of the token
     * @param weth WETH address
     * @param tokenDecimals Number of decimals for the token
     * @return price Price in ETH per token (18 decimals), or 0 if pool doesn't exist
     */
    function getPriceFromV3(
        address token,
        address weth,
        uint8 tokenDecimals
    ) external view returns (uint256 price);

    /**
     * @notice Get current market price from Uniswap (checks V3 first, then V2)
     * @param token Address of the token
     * @param routerAddress Address of the Uniswap V2 Router (to get WETH and V2 factory)
     * @param tokenDecimals Number of decimals for the token
     * @return price Current market price in wei per token
     */
    function getCurrentPrice(
        address token,
        address routerAddress,
        uint8 tokenDecimals
    ) external view returns (uint256 price);
}
