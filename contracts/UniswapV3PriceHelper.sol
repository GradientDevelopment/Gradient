// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IUniswapV3Factory} from "./interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "./interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router.sol";
import {IUniswapV3PriceHelper} from "./interfaces/IUniswapV3PriceHelper.sol";

// Custom errors
error InvalidTokenAddress();
error PairDoesNotExist();

/**
 * @title UniswapV3PriceHelper
 * @notice Helper contract for getting prices from Uniswap V3 (and V2 fallback)
 * @dev This contract reduces pool contract size by handling all V3-specific logic
 */
contract UniswapV3PriceHelper is IUniswapV3PriceHelper, Ownable {
    // Uniswap V3 Factory address for accessing V3 pools
    address public uniswapV3Factory;

    // Common fee tiers for Uniswap V3 (500 = 0.05%, 3000 = 0.3%, 10000 = 1%)
    uint24[] public v3FeeTiers = [500, 3000, 10000];

    // Events
    event UniswapV3FactoryUpdated(
        address indexed oldFactory,
        address indexed newFactory
    );
    event V3FeeTiersUpdated(uint24[] feeTiers);

    constructor(address _uniswapV3Factory) Ownable(msg.sender) {
        uniswapV3Factory = _uniswapV3Factory;
    }

    /**
     * @notice Sets the Uniswap V3 Factory address
     * @param _uniswapV3Factory Address of the Uniswap V3 Factory
     * @dev Only callable by owner
     */
    function setUniswapV3Factory(address _uniswapV3Factory) external onlyOwner {
        if (_uniswapV3Factory == address(0)) revert InvalidTokenAddress();
        address oldFactory = uniswapV3Factory;
        uniswapV3Factory = _uniswapV3Factory;
        emit UniswapV3FactoryUpdated(oldFactory, _uniswapV3Factory);
    }

    /**
     * @notice Sets the V3 fee tiers to check
     * @param _feeTiers Array of fee tiers (e.g., [500, 3000, 10000] for 0.05%, 0.3%, 1%)
     * @dev Only callable by owner
     */
    function setV3FeeTiers(uint24[] calldata _feeTiers) external onlyOwner {
        if (_feeTiers.length == 0) revert InvalidTokenAddress();
        if (_feeTiers.length > 10) revert InvalidTokenAddress();
        v3FeeTiers = _feeTiers;
        emit V3FeeTiersUpdated(_feeTiers);
    }

    /**
     * @notice Get V3 pool address for a token by trying different fee tiers
     * @param token Address of the token
     * @param weth WETH address
     * @return poolAddress Address of the V3 pool, or address(0) if not found
     */
    function getV3PoolAddress(
        address token,
        address weth
    ) external view override returns (address poolAddress) {
        if (uniswapV3Factory == address(0)) {
            return address(0);
        }

        // Try different fee tiers to find an active pool
        for (uint256 i = 0; i < v3FeeTiers.length; i++) {
            address pool = IUniswapV3Factory(uniswapV3Factory).getPool(
                token < weth ? token : weth,
                token < weth ? weth : token,
                uint24(v3FeeTiers[i])
            );

            if (pool != address(0)) {
                // Check if pool has valid price data
                try IUniswapV3Pool(pool).slot0() returns (
                    uint160 sqrtPriceX96,
                    int24,
                    uint16,
                    uint16,
                    uint16,
                    uint8,
                    bool
                ) {
                    if (sqrtPriceX96 > 0) {
                        return pool;
                    }
                } catch {
                    continue;
                }
            }
        }

        return address(0);
    }

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
    ) external view override returns (uint256 price) {
        address poolAddress = this.getV3PoolAddress(token, weth);
        if (poolAddress == address(0)) {
            return 0;
        }

        // Get price data from pool
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(poolAddress)
            .slot0();

        // Calculate price from sqrtPriceX96
        // In Uniswap V3: sqrtPriceX96 = sqrt(amount1/amount0) * 2^96
        // So: price = (sqrtPriceX96 / 2^96)^2 = amount1/amount0

        bool tokenIsToken0 = token < weth;
        uint256 Q96 = 2 ** 96;
        uint256 Q192 = Q96 * Q96;

        // Calculate priceX96 = sqrtPriceX96^2
        uint256 priceX96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96));

        if (tokenIsToken0) {
            // Token is token0, WETH is token1
            // price = amount1/amount0 = WETH/token (in raw amounts)
            // We want: ETH per token in 18 decimals
            if (tokenDecimals <= 18) {
                uint256 adjustment = 10 ** (18 - tokenDecimals);
                price = (priceX96 * adjustment) / Q192;
            } else {
                uint256 adjustment = 10 ** (tokenDecimals - 18);
                price = priceX96 / (Q192 * adjustment);
            }
        } else {
            // Token is token1, WETH is token0
            // price = amount1/amount0 = token/WETH (in raw amounts)
            // We want: ETH per token, so invert: WETH/token = 1/price
            if (tokenDecimals <= 18) {
                uint256 adjustment = 10 ** (18 - tokenDecimals);
                price = (Q192 * adjustment) / priceX96;
            } else {
                uint256 adjustment = 10 ** (tokenDecimals - 18);
                price = Q192 / (priceX96 * adjustment);
            }
        }
    }

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
    ) external view override returns (uint256 price) {
        address weth = address(0);
        address v2PairAddress = address(0);

        // Get WETH and V2 pair address from router if available
        if (routerAddress != address(0)) {
            IUniswapV2Router02 router = IUniswapV2Router02(routerAddress);
            weth = router.WETH();

            // Get V2 pair address
            address factoryAddress = router.factory();
            IUniswapV2Factory factory = IUniswapV2Factory(factoryAddress);
            v2PairAddress = factory.getPair(token, weth);
        }

        // Try V3 first (only if WETH is available)
        if (weth != address(0)) {
            uint256 v3Price = this.getPriceFromV3(token, weth, tokenDecimals);
            if (v3Price > 0) {
                return v3Price;
            }
        }

        // Fall back to V2
        if (v2PairAddress == address(0)) revert PairDoesNotExist();

        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(v2PairAddress)
            .getReserves();
        address token0 = IUniswapV2Pair(v2PairAddress).token0();

        if (token0 == token) {
            // Token is token0, ETH is token1
            price = (uint256(reserve1) * 1e18) / uint256(reserve0);
        } else {
            // ETH is token0, Token is token1
            price = (uint256(reserve0) * 1e18) / uint256(reserve1);
        }
    }
}
