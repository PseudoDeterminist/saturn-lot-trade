require("@nomicfoundation/hardhat-toolbox");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: "0.8.28",
  networks: {
    local: {
      url: "http://127.0.0.1:8545",
      accounts: "remote",
    },
    localhost: {
      url: "http://127.0.0.1:8545",
      accounts: "remote",
    },
  },
};
