// Router addresses for different networks
const ROUTER_ADDRESSES = {
  // Mainnet addresses
  mainnet: {
    uniswapV2Router: "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D",
    uniswapV2Factory: "0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f",
    uniswapV3Router: "0xE592427A0AEce92De3Edee1F18E0157C05861564", // Uniswap V3 SwapRouter
    uniswapV3Factory: "0x1F98431c8aD98523631AE4a59f267346ea31F984", // Uniswap V3 Factory
  },
  bsc: {
    uniswapV2Router: "0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24", // Uniswap router
    uniswapV2Factory: "0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6", // Uniswap Factory
    uniswapV3Router: "0xB971eF87ede563556b2ED4b1C0b0019111Dd85d2", // Uniswap V3 SwapRouter
    uniswapV3Factory: "0xdB1d10011AD0Ff90774D0C6Bb92e5C5c8b4461F7", // Uniswap V3 Factory,

    pancakeV2Router: "0x10ED43C718714eb63d5aA57B78B54704E256024E", // Pancakeswap router
    pancakeV2Factory: "0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73", // Pancakeswap Factory
    pancakeV3Router: "0x1b81D678ffb9C0263b24A97847620C99d213eB14", // Pancakeswap V3 SwapRouter
    pancakeV3Factory: "0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865", // Pancakeswap V3 Factory,
  },
  base: {
    uniswapV2Router: "0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24", // BaseSwap router
    uniswapV2Factory: "0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6",
    uniswapV3Router: "0x2626664c2603336E57B271c5C0b26F421741e481", // BaseSwap V3 SwapRouter (Uniswap V3 on Base)
    uniswapV3Factory: "0x33128a8fC17869897dcE68Ed026d694621f6FDfD", // BaseSwap V3 Factory
  },
  // Testnet addresses (using same as mainnet for most testnets)
  bsctest: {
    uniswapV2Router: "0xD99D1c33F9fC3444f8101754aBC46c52416550D1", // Uniswap router
    uniswapV2Factory: "0x6725F303b657a9451d8BA641348b6761A6CC7a17",
    uniswapV3Router: "0x1b81D678ffb9C0263b24A97847620C99d213eB14", // Uniswap V3 SwapRouter
    uniswapV3Factory: "0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865", // Uniswap V3 Factory

    pancakeV2Router: "0xD99D1c33F9fC3444f8101754aBC46c52416550D1",
    pancakeV2Factory: "0x6725F303b657a9451d8BA641348b6761A6CC7a17",
    pancakeV3Router: "0x1b81D678ffb9C0263b24A97847620C99d213eB14", // Pancakeswap V3 SwapRouter
    pancakeV3Factory: "0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865", // Pancakeswap V3 Factory,
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
