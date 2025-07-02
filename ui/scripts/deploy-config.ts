// Deployment configuration for Gradient OTC Platform
// Update these addresses after deploying your contracts

export const DEPLOYMENT_CONFIG = {
  // Network configurations
  networks: {
    localhost: {
      chainId: '0x7A69', // 31337
      chainName: 'Hardhat Local',
      nativeCurrency: {
        name: 'Ether',
        symbol: 'ETH',
        decimals: 18,
      },
      rpcUrls: ['http://127.0.0.1:8545'],
      blockExplorerUrls: [],
    },
    sepolia: {
      chainId: '0xaa36a7', // 11155111
      chainName: 'Sepolia Testnet',
      nativeCurrency: {
        name: 'Sepolia Ether',
        symbol: 'SEP',
        decimals: 18,
      },
      rpcUrls: ['https://sepolia.infura.io/v3/YOUR-PROJECT-ID'],
      blockExplorerUrls: ['https://sepolia.etherscan.io'],
    },
    mainnet: {
      chainId: '0x1', // 1
      chainName: 'Ethereum Mainnet',
      nativeCurrency: {
        name: 'Ether',
        symbol: 'ETH',
        decimals: 18,
      },
      rpcUrls: ['https://mainnet.infura.io/v3/YOUR-PROJECT-ID'],
      blockExplorerUrls: ['https://etherscan.io'],
    },
  },

  // Contract addresses (update these after deployment)
  contracts: {
    localhost: {
      orderbook: '0x5FbDB2315678afecb367f032d93F642f64180aa3',
      marketMakerPool: '0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512',
      registry: '0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0',
    },
    sepolia: {
      orderbook: '0x...', // Replace with deployed address
      marketMakerPool: '0x...', // Replace with deployed address
      registry: '0x...', // Replace with deployed address
    },
    mainnet: {
      orderbook: '0x...', // Replace with deployed address
      marketMakerPool: '0x...', // Replace with deployed address
      registry: '0x...', // Replace with deployed address
    },
  },

  // Token addresses
  tokens: {
    localhost: {
      ETH: '0x0000000000000000000000000000000000000000',
      USDC: '0x...', // Deploy or use existing USDC
      USDT: '0x...', // Deploy or use existing USDT
    },
    sepolia: {
      ETH: '0x0000000000000000000000000000000000000000',
      USDC: '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238', // Sepolia USDC
      USDT: '0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0', // Sepolia USDT
    },
    mainnet: {
      ETH: '0x0000000000000000000000000000000000000000',
      USDC: '0xA0b86a33E6441b8c4C8C8C8C8C8C8C8C8C8C8C8', // Mainnet USDC
      USDT: '0xdAC17F958D2ee523a2206206994597C13D831ec7', // Mainnet USDT
    },
  },
};

// Helper function to get contract addresses for current network
export const getContractAddresses = (networkName: string) => {
  return DEPLOYMENT_CONFIG.contracts[networkName as keyof typeof DEPLOYMENT_CONFIG.contracts] || {};
};

// Helper function to get token addresses for current network
export const getTokenAddresses = (networkName: string) => {
  return DEPLOYMENT_CONFIG.tokens[networkName as keyof typeof DEPLOYMENT_CONFIG.tokens] || {};
};

// Helper function to get network configuration
export const getNetworkConfig = (networkName: string) => {
  return DEPLOYMENT_CONFIG.networks[networkName as keyof typeof DEPLOYMENT_CONFIG.networks];
};

// Helper function to update contract addresses in the UI
export const updateContractAddresses = (networkName: string) => {
  const addresses = getContractAddresses(networkName);
  
  // This would typically update environment variables or a config file
  console.log(`Updating contract addresses for ${networkName}:`, addresses);
  
  return addresses;
};

// Example usage:
// const addresses = updateContractAddresses('localhost');
// console.log('Orderbook address:', addresses.orderbook); 