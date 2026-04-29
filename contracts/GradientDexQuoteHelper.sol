// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router.sol";
import {IUniswapV2Factory} from "./interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IUniswapV3Factory} from "./interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {IPancakeV3Pool} from "./interfaces/IPancakeV3Pool.sol";
import {IGradientDexQuoteHelper} from "./interfaces/IGradientDexQuoteHelper.sol";

// Custom errors
error InvalidTokenAddress();
error PairDoesNotExist();

/**
 * @title GradientDexQuoteHelper
 * @notice Liquidity-aware DEX venue selection for orderbook pricing
 */
contract GradientDexQuoteHelper is IGradientDexQuoteHelper, Ownable {
    // Common fee tiers for Uniswap V3 (500 = 0.05%, 3000 = 0.3%, 10000 = 1%)
    uint24[] public v3FeeTiers = [500, 3000, 10000];
    uint256 public minWethLiquidity = 1e15;

    struct Venue {
        address v2Router;
        address v3FactoryAddress;
        bool isPancakeType;
    }

    Venue[] private _venues;

    // Events
    event VenueAdded(
        uint256 indexed index,
        address v2Router,
        address v3FactoryAddress,
        bool isPancakeType
    );
    event VenueRemoved(uint256 indexed index);
    event VenuesCleared(uint256 count);
    event V3FeeTiersUpdated(uint24[] feeTiers);
    event MinWethLiquidityUpdated(uint256 minWethLiquidity);

    constructor() Ownable(msg.sender) {}

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
     * @notice Sets the minimum WETH liquidity requirement
     * @param _minWethLiquidity New minimum WETH liquidity amount
     * @dev Only callable by owner
     */
    function setMinWethLiquidity(uint256 _minWethLiquidity) external onlyOwner {
        if (_minWethLiquidity == 0) revert InvalidTokenAddress();
        minWethLiquidity = _minWethLiquidity;
        emit MinWethLiquidityUpdated(_minWethLiquidity);
    }

    /// @notice Append a venue (lower index = higher priority)
    function addVenue(
        address v2Router,
        address v3FactoryAddress,
        bool isPancakeType
    ) external onlyOwner {
        require(v2Router != address(0), "Invalid v2 router");
        _venues.push(
            Venue({
                v2Router: v2Router,
                v3FactoryAddress: v3FactoryAddress,
                isPancakeType: isPancakeType
            })
        );
        emit VenueAdded(
            _venues.length - 1,
            v2Router,
            v3FactoryAddress,
            isPancakeType
        );
    }

    /// @notice Remove venue at index (swap-and-pop)
    function removeVenue(uint256 index) external onlyOwner {
        require(index < _venues.length, "Invalid index");
        uint256 last = _venues.length - 1;
        if (index != last) {
            _venues[index] = _venues[last];
        }
        _venues.pop();
        emit VenueRemoved(index);
    }

    /// @notice Remove all venues (e.g. before reconfiguring)
    function clearVenues() external onlyOwner {
        uint256 n = _venues.length;
        delete _venues;
        emit VenuesCleared(n);
    }

    /// @inheritdoc IGradientDexQuoteHelper
    function venueCount() external view returns (uint256) {
        return _venues.length;
    }

    /// @inheritdoc IGradientDexQuoteHelper
    function getVenue(
        uint256 index
    ) external view returns (address v2Router, address v3FactoryAddress) {
        require(index < _venues.length, "Invalid index");
        Venue storage v = _venues[index];
        return (v.v2Router, v.v3FactoryAddress);
    }

    /// @inheritdoc IGradientDexQuoteHelper
    function getReserves(
        address token
    ) external view returns (uint256 reserveETH, uint256 reserveToken) {
        require(_venues.length > 0, "No venues");
        (, address bestPair, uint256 rEth, uint256 rTok) = getBestV2Pool(token);
        require(bestPair != address(0), "Pair does not exist");
        return (rEth, rTok);
    }

    /// @inheritdoc IGradientDexQuoteHelper
    function hasV3Pool(address token) external view returns (bool) {
        (, address pool, uint128 liq) = getV3PoolAddress(token);
        if (pool != address(0) && liq > 0) {
            return true;
        }

        return false;
    }

    function getV3PoolAddress(
        address token
    )
        public
        view
        returns (
            address selectedRouter,
            address bestPool,
            uint128 bestLiquidity
        )
    {
        for (uint256 j = 0; j < _venues.length; j++) {
            address weth = IUniswapV2Router02(_venues[j].v2Router).WETH();
            address v3FactoryAddress = _venues[j].v3FactoryAddress;
            if (v3FactoryAddress == address(0)) {
                continue;
            }
            address token0 = token < weth ? token : weth;
            address token1 = token < weth ? weth : token;
            // Try different fee tiers to find an active pool
            for (uint256 i = 0; i < v3FeeTiers.length; i++) {
                address pool = IUniswapV3Factory(v3FactoryAddress).getPool(
                    token0,
                    token1,
                    uint24(v3FeeTiers[i])
                );
                if (pool == address(0)) continue;

                uint128 liq = IUniswapV3Pool(pool).liquidity();

                if (liq > bestLiquidity) {
                    bestLiquidity = liq;
                    bestPool = pool;
                }
            }
        }
    }

    function hasV2Pool(address token) external view returns (bool) {
        for (uint256 i = 0; i < _venues.length; i++) {
            Venue storage v = _venues[i];
            if (address(v.v2Router) == address(0)) continue;

            address weth = IUniswapV2Router02(v.v2Router).WETH();
            address factory = IUniswapV2Router02(v.v2Router).factory();

            address pair = IUniswapV2Factory(factory).getPair(token, weth);

            if (pair == address(0)) {
                continue;
            }
            (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pair)
                .getReserves();

            uint256 wethReserve = token < weth ? reserve1 : reserve0;

            if (wethReserve >= minWethLiquidity) {
                return true;
            }
        }
        return false;
    }

    function getBestV2Pool(
        address token
    )
        public
        view
        returns (
            address selectedRouter,
            address bestPair,
            uint256 bestWethLiq,
            uint256 bestTokenLiq
        )
    {
        for (uint256 i = 0; i < _venues.length; i++) {
            Venue storage v = _venues[i];
            if (address(v.v2Router) == address(0)) continue;
            address weth = IUniswapV2Router02(v.v2Router).WETH();
            address factory = IUniswapV2Router02(v.v2Router).factory();

            address pair = IUniswapV2Factory(factory).getPair(token, weth);
            if (pair == address(0)) continue;

            (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pair)
                .getReserves();

            // Normalize: figure out which side is WETH
            (uint112 reserveToken, uint112 reserveWETH) = token < weth
                ? (reserve0, reserve1)
                : (reserve1, reserve0);

            if (reserveWETH > bestWethLiq && reserveWETH >= minWethLiquidity) {
                selectedRouter = v.v2Router;
                bestWethLiq = reserveWETH;
                bestTokenLiq = reserveToken;
                bestPair = pair;
            }
        }
    }

    /// @inheritdoc IGradientDexQuoteHelper
    function getCurrentMarketPriceV2(
        address token
    ) external view returns (uint256 marketPrice) {
        if (_venues.length == 0) {
            return 0;
        }

        (
            ,
            address poolAddress,
            uint256 wethReserves,
            uint256 tokenReserves
        ) = getBestV2Pool(token);
        if (poolAddress != address(0)) {
            return _priceFromV2(token, wethReserves, tokenReserves);
        }

        return 0;
    }

    function _bestV2VenueByWethReserve(
        address token
    )
        private
        view
        returns (
            bool found,
            uint256 bestIndex,
            uint256 reserveETH,
            uint256 reserveToken
        )
    {
        uint256 bestReserveETH = 0;

        for (uint256 i = 0; i < _venues.length; i++) {
            (bool ok, uint256 rEth, uint256 rTok) = _tryGetReserves(
                token,
                _venues[i].v2Router
            );
            if (!ok) {
                continue;
            }
            if (rEth > bestReserveETH) {
                bestReserveETH = rEth;
                bestIndex = i;
                reserveETH = rEth;
                reserveToken = rTok;
                found = true;
            }
        }
    }

    function _getV2PairAddress(
        address token,
        address routerAddress
    ) private view returns (address pairAddress) {
        IUniswapV2Router02 router = IUniswapV2Router02(routerAddress);
        address factory = router.factory();
        address weth = router.WETH();
        return IUniswapV2Factory(factory).getPair(token, weth);
    }

    function _tryGetReserves(
        address token,
        address routerAddress
    ) private view returns (bool, uint256 reserveETH, uint256 reserveToken) {
        IUniswapV2Router02 router = IUniswapV2Router02(routerAddress);
        address factory = router.factory();
        address weth = router.WETH();
        address pairAddress = IUniswapV2Factory(factory).getPair(token, weth);
        if (pairAddress == address(0)) {
            return (false, 0, 0);
        }
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pairAddress)
            .getReserves();
        address token0 = IUniswapV2Pair(pairAddress).token0();
        if (token0 == token) {
            reserveETH = reserve1;
            reserveToken = reserve0;
        } else {
            reserveETH = reserve0;
            reserveToken = reserve1;
        }
        return (true, reserveETH, reserveToken);
    }

    function _priceFromV2(
        address token,
        uint256 reserveETH,
        uint256 reserveToken
    ) private view returns (uint256 price) {
        if (reserveETH == 0 || reserveToken == 0) {
            return 0;
        }
        uint8 decimals = IERC20Metadata(token).decimals();
        if (decimals == 18) {
            price = (reserveETH * 1e18) / reserveToken;
        } else if (decimals < 18) {
            uint256 scalingFactor = 10 ** (18 - decimals);
            uint256 scaledReserveETH = reserveETH / scalingFactor;
            price = (scaledReserveETH * 1e18) / reserveToken;
        } else {
            uint256 scalingFactor = 10 ** (decimals - 18);
            uint256 scaledReserveToken = reserveToken / scalingFactor;
            price = (reserveETH * 1e18) / scaledReserveToken;
        }
    }
}
