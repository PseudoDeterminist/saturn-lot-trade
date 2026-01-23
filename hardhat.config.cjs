require("dotenv").config();
require("@nomicfoundation/hardhat-toolbox");
const { subtask } = require("hardhat/config");
const {
  TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS,
} = require("hardhat/builtin-tasks/task-names");

subtask(TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS).setAction(
  async (args, hre, runSuper) => {
    const paths = await runSuper(args);
    if (process.env.PROD_COMPILE !== "1") return paths;
    return paths.filter(
      (filePath) =>
        !filePath.includes("/contracts/test/") &&
        !filePath.includes("\\contracts\\test\\")
    );
  }
);

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: { enabled: true, runs: 5000 },
      viaIR: true,
    },
  },
  etherscan: {
    apiKey: {
      mordor: process.env.MORDOR_BLOCKSCOUT_API_KEY || "",
      etc: process.env.MAINNET_BLOCKSCOUT_API_KEY || "",
    },
    customChains: [
      {
        network: "mordor",
        chainId: 63,
        urls: {
          apiURL: "https://etc-mordor.blockscout.com/api",
          browserURL: "https://etc-mordor.blockscout.com",
        },
      },
      {
        network: "etc",
        chainId: 61,
        urls: {
          apiURL: "https://etc.blockscout.com/api",
          browserURL: "https://etc.blockscout.com",
        },
      },
    ],
  },
  networks: {
    local: {
      url: "http://127.0.0.1:8545",
      accounts: "remote",
    },
    localhost: {
      url: "http://127.0.0.1:8545",
      accounts: "remote",
    },
    mordor: {
      url: process.env.MORDOR_RPC_URL || "",
      accounts: process.env.MORDOR_DEPLOYER_PK ? [process.env.MORDOR_DEPLOYER_PK] : [],
      chainId: 63,
    },
    etc: {
      url: process.env.MAINNET_RPC_URL || process.env.ETC_RPC_URL || "",
      accounts: process.env.MAINNET_DEPLOYER_PK ? [process.env.MAINNET_DEPLOYER_PK] : [],
      chainId: 61,
    },
  },
};
