require("@nomicfoundation/hardhat-toolbox");
require("@nomicfoundation/hardhat-verify");
require("dotenv").config();

/** @type import('hardhat/config').HardhatUserConfig */
const privateKey = process.env.MAIN_PRIVATE_KEY ?? "";
const privateKeyTest = process.env.PRIVATE_KEY_2 ?? "";
module.exports = {
  defaultNetwork: "hardhat",
  solidity: {
    version: "0.8.26",
    settings: {
      viaIR: true,
      optimizer: {
        enabled: true,
        runs: 1,
      },
    },
  },
  networks: {
    hardhat: {
      chainId: 31337,
    },
    mainnet: {
      url: `https://mainnet.infura.io/v3/${process.env.MAIN_INFURA_API_KEY}`,
      // url: `https://eth-mainnet.nodereal.io/v1/${process.env.NODEREAL_API_KEY}`,
      accounts: [privateKey],
      allowUnlimitedContractSize: true,
    },
    base: {
      url: `https://base-mainnet.infura.io/v3/${process.env.MAIN_INFURA_API_KEY}`,
      accounts: [privateKey],
      allowUnlimitedContractSize: true,
    },
    bsc: {
      url: `https://bsc-dataseed.bnbchain.org`,
      accounts: [privateKey],
      allowUnlimitedContractSize: true,
    },
    bsctest: {
      url: "https://data-seed-prebsc-1-s1.binance.org:8545/",
      accounts: [privateKey],
      allowUnlimitedContractSize: true,
    },
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY,
    customChains: [
      {
        network: "bsctest",
        chainId: 97,
        urls: {
          apiURL: "https://api.etherscan.io/v2/api?chainid=97",
          browserURL: "https://testnet.bscscan.com",
        },
      },
    ],
  },
};
