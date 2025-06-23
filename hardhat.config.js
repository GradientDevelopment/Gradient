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
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    hardhat: {
      chainId: 31337,
    },
    mainnet: {
      url: `https://snowy-convincing-frost.quiknode.pro/${process.env.QUICKNODE_API_KEY}/`,
      accounts: [privateKey],
      allowUnlimitedContractSize: true,
    },
    bsctest: {
      url: "https://data-seed-prebsc-1-s1.binance.org:8545/",
      accounts: [privateKeyTest],
      allowUnlimitedContractSize: true,
    },
    base: {
      url: `https://base-mainnet.g.alchemy.com/v2/${process.env.ALCHEMY_KEY}`,
      accounts: [privateKeyTest],
      allowUnlimitedContractSize: true,
    },
  },
  etherscan: {
    apiKey: {
      mainnet: process.env.ETHERSCAN_API_KEY,
      bscTestnet: process.env.BSCSCAN_API_KEY,
    },
  },
};
