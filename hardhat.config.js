import { defineConfig } from "hardhat/config";
import hardhatEthers from "@nomicfoundation/hardhat-ethers";
import hardhatEthersChaiMatchers from "@nomicfoundation/hardhat-ethers-chai-matchers";
import hardhatMocha from "@nomicfoundation/hardhat-mocha";

const bscAccounts = process.env.DEPLOYER_KEY ? [process.env.DEPLOYER_KEY] : [];

export default defineConfig({
  plugins: [hardhatEthers, hardhatEthersChaiMatchers, hardhatMocha],
  solidity: {
    version: "0.8.24",
    preferWasm: true,
    settings: {
      evmVersion: "paris",
      optimizer: {
        enabled: true,
        runs: 1
      },
      viaIR: true
    }
  },
  paths: {
    sources: "./Contracts",
    tests: {
      mocha: "./test"
    },
    cache: "./cache",
    artifacts: "./artifacts"
  },
  networks: {
    bsc: {
      type: "http",
      chainType: "generic",
      url: process.env.BSC_RPC_URL || "https://bsc-dataseed.bnbchain.org",
      chainId: 56,
      accounts: bscAccounts
    },
    bsc_testnet: {
      type: "http",
      chainType: "generic",
      url: process.env.BSC_TESTNET_RPC_URL || "https://bsc-testnet-dataseed.bnbchain.org",
      chainId: 97,
      accounts: bscAccounts
    }
  },
  test: {
    mocha: {
      timeout: 120000
    }
  }
});
