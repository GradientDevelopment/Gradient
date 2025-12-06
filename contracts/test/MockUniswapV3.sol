// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IUniswapV3SwapRouter.sol";
import "../interfaces/IUniswapV3Factory.sol";
import "../interfaces/IUniswapV3Pool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockUniswapV3Pool is IUniswapV3Pool {
    address public token0;
    address public token1;
    uint24 public fee;
    uint128 public liquidityVal;
    uint160 public sqrtPriceX96Val;

    constructor(address _token0, address _token1, uint24 _fee) {
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        liquidityVal = 1000000; // Default liquidity
        sqrtPriceX96Val = 79228162514264337593543950336; // 1:1 price
    }

    function slot0()
        external
        view
        override
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        return (sqrtPriceX96Val, 0, 0, 0, 0, 0, true);
    }

    function liquidity() external view override returns (uint128) {
        return liquidityVal;
    }

    function setLiquidity(uint128 _liquidity) external {
        liquidityVal = _liquidity;
    }
}

contract MockUniswapV3Factory is IUniswapV3Factory {
    mapping(address => mapping(address => mapping(uint24 => address)))
        public pools;

    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external returns (address pool) {
        require(tokenA != tokenB, "Identical addresses");
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        require(token0 != address(0), "Zero address");
        require(pools[token0][token1][fee] == address(0), "Pool exists");

        MockUniswapV3Pool newPool = new MockUniswapV3Pool(token0, token1, fee);
        pool = address(newPool);
        pools[token0][token1][fee] = pool;
    }

    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external view override returns (address pool) {
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        return pools[token0][token1][fee];
    }
}

contract MockUniswapV3SwapRouter is IUniswapV3SwapRouter {
    address public factory;
    address public WETH;

    constructor(address _factory, address _weth) {
        factory = _factory;
        WETH = _weth;
    }

    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable override returns (uint256 amountOut) {
        // Mock swap logic: 1:1 swap for simplicity, or based on params
        // Transfer tokens from sender to this contract (simulating pool interaction)
        if (params.tokenIn != WETH || msg.value == 0) {
            IERC20(params.tokenIn).transferFrom(
                msg.sender,
                address(this),
                params.amountIn
            );
        }

        // Calculate amountOut (1:1 for now)
        amountOut = params.amountIn;
        if (params.amountOutMinimum > 0) {
            require(
                amountOut >= params.amountOutMinimum,
                "Too little received"
            );
        }

        // Transfer output tokens to recipient
        if (params.tokenOut == WETH) {
            // If output is WETH, we just transfer ETH if the caller expects unwrapped ETH?
            // No, Router usually returns the tokenOut.
            // But FallbackExecutor expects WETH if it's selling token for ETH, then it unwraps.
            // Wait, FallbackExecutor unwraps WETH itself if selling token for ETH.
            // So Router just returns WETH.
            IERC20(params.tokenOut).transfer(params.recipient, amountOut);
        } else {
            IERC20(params.tokenOut).transfer(params.recipient, amountOut);
        }
    }

    function exactOutputSingle(
        ExactOutputSingleParams calldata params
    ) external payable override returns (uint256 amountIn) {
        amountIn = params.amountOut; // 1:1
        // Transfer logic omitted for brevity as FallbackExecutor uses exactInputSingle
    }

    function refundETH() external payable override {
        if (address(this).balance > 0) {
            payable(msg.sender).transfer(address(this).balance);
        }
    }

    // Helper to receive ETH
    receive() external payable {}
}

contract MockV2Router {
    address public WETH;
    address public factory;

    constructor(address _factory, address _weth) {
        factory = _factory;
        WETH = _weth;
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable {}

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external {}
}
