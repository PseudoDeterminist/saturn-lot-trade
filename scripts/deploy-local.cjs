const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  async function waitForReceipt(tx, label) {
    const hash = tx.hash;
    for (let i = 0; i < 30; i += 1) {
      try {
        const receipt = await ethers.provider.getTransactionReceipt(hash);
        if (receipt) {
          return receipt;
        }
      } catch (err) {
        if (!String(err).includes("transaction indexing is in progress")) {
          throw err;
        }
      }
      await new Promise((r) => setTimeout(r, 1000));
    }
    throw new Error(`Timed out waiting for ${label} tx receipt: ${hash}`);
  }

  const TestERC20 = await ethers.getContractFactory("TestERC20");

  const tetcSupply = ethers.parseUnits("1000000", 18); // 1,000,000 TETC
  const tknSupply = ethers.parseUnits("100000", 0);  // 100,000 lots

  const tetc = await TestERC20.deploy("Test ETC", "TETC", 18, tetcSupply);
  await waitForReceipt(tetc.deploymentTransaction(), "TETC deploy");
  console.log("TETC:", tetc.target);

  const tkn10k = await TestERC20.deploy("TKN10K", "TKN10K", 0, tknSupply);
  await waitForReceipt(tkn10k.deploymentTransaction(), "TKN10K deploy");
  console.log("TKN10K:", tkn10k.target);

  const SimpleLotTrade = await ethers.getContractFactory("SimpleLotrade");
  const clob = await SimpleLotTrade.deploy(tetc.target, tkn10k.target);
  await waitForReceipt(clob.deploymentTransaction(), "SimpleLotTrade deploy");
  console.log("SimpleLotTrade:", clob.target);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
