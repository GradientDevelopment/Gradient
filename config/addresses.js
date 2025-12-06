// Router addresses for different networks
const ROUTER_ADDRESSES = {
  // Mainnet addresses
  mainnet: {
    uniswapV2Router: "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D",
    uniswapV2Factory: "0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f",
    uniswapV3Router: "0xE592427A0AEce92De3Edee1F18E0157C05861564", // Uniswap V3 SwapRouter
    uniswapV3Factory: "0x1F98431c8aD98523631AE4a59f267346ea31F984", // Uniswap V3 Factory
  },
  // Testnet addresses (using same as mainnet for most testnets)
  bsctest: {
    uniswapV2Router: "0xD99D1c33F9fC3444f8101754aBC46c52416550D1", // PancakeSwap router
    uniswapV2Factory: "0x6725F303b657a9451d8BA641348b6761A6CC7a17",
    uniswapV3Router: "0x1b81D678ffb9C0263b24A97847620C99d213eB14", // PancakeSwap V3 SwapRouter
    uniswapV3Factory: "0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865", // PancakeSwap V3 Factory
  },
  base: {
    uniswapV2Router: "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D", // BaseSwap router
    uniswapV2Factory: "0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f",
    uniswapV3Router: "0x2626664c2603336E57B271c5C0b26F421741e481", // BaseSwap V3 SwapRouter (Uniswap V3 on Base)
    uniswapV3Factory: "0x33128a8fC17869897dcE68Ed026d694621f6FDfD", // BaseSwap V3 Factory
  },
  // Local development
  hardhat: {
    uniswapV2Router: "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D",
    uniswapV2Factory: "0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f",
    uniswapV3Router: "0xE592427A0AEce92De3Edee1F18E0157C05861564", // Uniswap V3 SwapRouter
    uniswapV3Factory: "0x1F98431c8aD98523631AE4a59f267346ea31F984", // Uniswap V3 Factory
  },
};

const GREY_TOKEN_ADDRESS = "0xa776A95223C500E81Cb0937B291140fF550ac3E4";

module.exports = {
  ROUTER_ADDRESSES,
  GREY_TOKEN_ADDRESS,
};