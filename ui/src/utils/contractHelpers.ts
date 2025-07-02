import { ethers } from 'ethers';

// Contract addresses (update these with your deployed contract addresses)
export const CONTRACT_ADDRESSES = {
  ORDERBOOK: '0x6f66f380a3f044f674273f7c5c5c17281fc75506', // Replace with deployed orderbook address
  MARKET_MAKER_POOL: '0xc2c1af84179d1f158B6c5b539fad061600291f1c', // Replace with deployed market maker pool address
  REGISTRY: '0xA9Fa5F8b495D7Ca13273Ed7Ee31133E39323Eac0', // Replace with deployed registry address
};

// Common token addresses
export const TOKEN_ADDRESSES = {
  ETH: '0x0000000000000000000000000000000000000000', // Native ETH
  USDC: '0xA0b86a33E6441b8c4C8C8C8C8C8C8C8C8C8C8C8', // Replace with actual USDC address
  USDT: '0xdAC17F958D2ee523a2206206994597C13D831ec7', // Mainnet USDT
};

// Contract ABIs (you'll need to import these from your compiled contracts)
export const ORDERBOOK_ABI = [
  // Add your orderbook contract ABI here
  'function createOrder(address token, uint256 amount, uint256 price, bool isBuy) external',
  'function cancelOrder(uint256 orderId) external',
  'function getOrders(address token, bool isBuy) external view returns (tuple(uint256 id, address maker, uint256 amount, uint256 price, bool isBuy, uint8 status)[])',
];

export const MARKET_MAKER_POOL_ABI = [
  // GradientMarketMakerPool ABI
  'function provideLiquidity(address token, uint256 tokenAmount) external payable',
  'function withdrawLiquidity(address token, uint256 shares) external',
  'function claimReward(address token) external',
  'function getPoolInfo(address token) external view returns (tuple(uint256 totalEth, uint256 totalToken, uint256 totalLiquidity, uint256 totalLPShares, uint256 accRewardPerShare, uint256 rewardBalance, address uniswapPair, bool exists))',
  'function getUserSharePercentage(address token, address user) external view returns (uint256 sharePercentage)',
  'function getUserLPShares(address token, address user) external view returns (uint256 lpShares)',
  'function marketMakers(address token, address user) external view returns (tuple(uint256 tokenAmount, uint256 ethAmount, uint256 lpShares, uint256 rewardDebt, uint256 pendingReward))',
];

// Helper function to create contract instances
export const createContractInstance = (
  address: string,
  abi: any[],
  signer: ethers.JsonRpcSigner
) => {
  return new ethers.Contract(address, abi, signer);
};

// Helper function to format token amounts
export const formatTokenAmount = (amount: string, decimals: number = 18): string => {
  try {
    return ethers.formatUnits(amount, decimals);
  } catch (error) {
    console.error('Error formatting token amount:', error);
    return '0';
  }
};

// Helper function to parse token amounts
export const parseTokenAmount = (amount: string, decimals: number = 18): string => {
  try {
    return ethers.parseUnits(amount, decimals).toString();
  } catch (error) {
    console.error('Error parsing token amount:', error);
    return '0';
  }
};

// Helper function to format addresses
export const formatAddress = (address: string): string => {
  if (!address) return '';
  return `${address.slice(0, 6)}...${address.slice(-4)}`;
};

// Helper function to validate address
export const isValidAddress = (address: string): boolean => {
  try {
    ethers.getAddress(address);
    return true;
  } catch {
    return false;
  }
};

// Helper function to get token symbol from address
export const getTokenSymbol = (address: string): string => {
  const tokenMap: { [key: string]: string } = {
    [TOKEN_ADDRESSES.ETH]: 'ETH',
    [TOKEN_ADDRESSES.USDC]: 'USDC',
    [TOKEN_ADDRESSES.USDT]: 'USDT',
  };
  
  return tokenMap[address.toLowerCase()] || 'Unknown';
};

// Helper function to handle transaction errors
export const handleTransactionError = (error: any): string => {
  if (error.code === 4001) {
    return 'Transaction rejected by user';
  } else if (error.code === -32603) {
    return 'Transaction failed - insufficient funds or gas';
  } else if (error.message?.includes('insufficient funds')) {
    return 'Insufficient funds for transaction';
  } else if (error.message?.includes('gas')) {
    return 'Gas estimation failed';
  } else {
    return error.message || 'Transaction failed';
  }
};

// Helper function to wait for transaction confirmation
export const waitForTransaction = async (tx: ethers.ContractTransactionResponse): Promise<ethers.ContractTransactionReceipt> => {
  try {
    const receipt = await tx.wait();
    if (!receipt) {
      throw new Error('Transaction receipt is null');
    }
    return receipt;
  } catch (error) {
    console.error('Transaction failed:', error);
    throw error;
  }
};

// Helper function to get network information
export const getNetworkInfo = async (provider: ethers.BrowserProvider) => {
  try {
    const network = await provider.getNetwork();
    const blockNumber = await provider.getBlockNumber();
    
    return {
      chainId: network.chainId,
      name: network.name,
      blockNumber,
    };
  } catch (error) {
    console.error('Error getting network info:', error);
    return null;
  }
};

// Helper function to check if user is on the correct network
export const checkNetwork = async (provider: ethers.BrowserProvider, targetChainId: bigint): Promise<boolean> => {
  try {
    const network = await provider.getNetwork();
    return network.chainId === targetChainId;
  } catch (error) {
    console.error('Error checking network:', error);
    return false;
  }
};

// Helper function to switch networks (MetaMask)
export const switchNetwork = async (chainId: string) => {
  if (typeof window.ethereum !== 'undefined') {
    try {
      await window.ethereum.request({
        method: 'wallet_switchEthereumChain',
        params: [{ chainId }],
      });
      return true;
    } catch (error: any) {
      if (error.code === 4902) {
        // Chain not added to MetaMask
        console.log('Chain not found in MetaMask');
        return false;
      }
      throw error;
    }
  }
  return false;
};

// Helper function to add network to MetaMask
export const addNetwork = async (networkConfig: {
  chainId: string;
  chainName: string;
  nativeCurrency: { name: string; symbol: string; decimals: number };
  rpcUrls: string[];
  blockExplorerUrls?: string[];
}) => {
  if (typeof window.ethereum !== 'undefined') {
    try {
      await window.ethereum.request({
        method: 'wallet_addEthereumChain',
        params: [networkConfig],
      });
      return true;
    } catch (error) {
      console.error('Error adding network:', error);
      return false;
    }
  }
  return false;
};

// Liquidity management specific helpers
export const getPoolInfo = async (
  contract: ethers.Contract,
  token: string
) => {
  try {
    const poolInfo = await contract.getPoolInfo(token);
    return {
      totalEth: formatTokenAmount(poolInfo.totalEth.toString()),
      totalToken: formatTokenAmount(poolInfo.totalToken.toString()),
      totalLiquidity: formatTokenAmount(poolInfo.totalLiquidity.toString()),
      totalLPShares: formatTokenAmount(poolInfo.totalLPShares.toString()),
      accRewardPerShare: formatTokenAmount(poolInfo.accRewardPerShare.toString()),
      rewardBalance: formatTokenAmount(poolInfo.rewardBalance.toString()),
      uniswapPair: poolInfo.uniswapPair,
      exists: poolInfo.exists,
    };
  } catch (error) {
    console.error('Error getting pool info:', error);
    return null;
  }
};

export const getUserInfo = async (
  contract: ethers.Contract,
  token: string,
  user: string
) => {
  try {
    const userInfo = await contract.marketMakers(token, user);
    return {
      tokenAmount: formatTokenAmount(userInfo.tokenAmount.toString()),
      ethAmount: formatTokenAmount(userInfo.ethAmount.toString()),
      lpShares: formatTokenAmount(userInfo.lpShares.toString()),
      rewardDebt: formatTokenAmount(userInfo.rewardDebt.toString()),
      pendingReward: formatTokenAmount(userInfo.pendingReward.toString()),
    };
  } catch (error) {
    console.error('Error getting user info:', error);
    return null;
  }
};

export const getUserSharePercentage = async (
  contract: ethers.Contract,
  token: string,
  user: string
) => {
  try {
    const sharePercentage = await contract.getUserSharePercentage(token, user);
    return parseFloat(formatTokenAmount(sharePercentage.toString(), 2)); // Basis points
  } catch (error) {
    console.error('Error getting user share percentage:', error);
    return 0;
  }
}; 