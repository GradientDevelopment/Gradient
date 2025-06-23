// Router addresses for different networks
const ROUTER_ADDRESSES = {
  // Mainnet addresses
  mainnet: {
    uniswapV2Router: "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D",
    uniswapV2Factory: "0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f",
  },
  // Testnet addresses (using same as mainnet for most testnets)
  bsctest: {
    uniswapV2Router: "0xD99D1c33F9fC3444f8101754aBC46c52416550D1", // PancakeSwap router
    uniswapV2Factory: "0x6725F303b657a9451d8BA641348b6761A6CC7a17",
  },
  base: {
    uniswapV2Router: "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D", // BaseSwap router
    uniswapV2Factory: "0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f",
  },
  // Local development
  hardhat: {
    uniswapV2Router: "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D",
    uniswapV2Factory: "0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f",
  },
};

const GREY_TOKEN_ADDRESS = "0xa776A95223C500E81Cb0937B291140fF550ac3E4";

module.exports = {
  ROUTER_ADDRESSES,
  GREY_TOKEN_ADDRESS,
};
