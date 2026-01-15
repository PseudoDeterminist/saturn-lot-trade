const fs = require("fs");
const path = require("path");
const { ethers, network } = require("hardhat");

const ROOT = path.join(__dirname, "..");
const ENV_PATH = path.join(ROOT, ".env");
const UI_CONFIG_PATH = path.join(ROOT, "ui", "config.js");

function updateEnvFile(filePath, entries) {
  let lines = [];
  if (fs.existsSync(filePath)) {
    lines = fs.readFileSync(filePath, "utf8").split(/\r?\n/);
  }
  const used = new Set();
  const next = lines.map((line) => {
    for (const [key, value] of Object.entries(entries)) {
      if (line.startsWith(`${key}=`)) {
        used.add(key);
        return `${key}=${value}`;
      }
    }
    return line;
  });
  for (const [key, value] of Object.entries(entries)) {
    if (!used.has(key)) next.push(`${key}=${value}`);
  }
  let last = next.length - 1;
  while (last >= 0 && next[last] === "") last -= 1;
  const output = last >= 0 ? `${next.slice(0, last + 1).join("\n")}\n` : "";
  fs.writeFileSync(filePath, output);
}

function updateUiConfig(filePath, entries) {
  if (!fs.existsSync(filePath)) return;
  let text = fs.readFileSync(filePath, "utf8");
  const mapping = {
    tetcAddress: entries.TETC_ADDRESS,
    tkn10kAddress: entries.TKN10K_ADDRESS,
    simpleLotTradeAddress: entries.SIMPLE_LOT_TRADE_ADDRESS
  };
  for (const [key, value] of Object.entries(mapping)) {
    const re = new RegExp(`${key}:\\s*\"[^\"]*\"`);
    if (re.test(text)) {
      text = text.replace(re, `${key}: \"${value}\"`);
    }
  }
  fs.writeFileSync(filePath, text);
}

function writeAddresses(entries) {
  updateEnvFile(ENV_PATH, entries);
  updateUiConfig(UI_CONFIG_PATH, entries);
}

async function seedOrders(clob, tetc, tkn10k, waitForReceipt) {
  const maxApprove = ethers.MaxUint256;

  await waitForReceipt(await tetc.approve(clob.target, maxApprove), "TETC approve");
  await waitForReceipt(await tkn10k.approve(clob.target, maxApprove), "TKN10K approve");

  const sellSeeds = [
    { tick: 121, lots: 60 },
    { tick: 122, lots: 56 },
    { tick: 123, lots: 52 },
    { tick: 124, lots: 48 },
    { tick: 125, lots: 44 }
  ];

  const buySeeds = [
    { tick: 120, lots: 60 },
    { tick: 119, lots: 56 },
    { tick: 118, lots: 52 },
    { tick: 117, lots: 48 },
    { tick: 116, lots: 44 }
  ];

  for (const order of sellSeeds) {
    await waitForReceipt(
      await clob.placeSell(order.tick, order.lots),
      `seed sell ${order.tick}`
    );
  }

  for (const order of buySeeds) {
    await waitForReceipt(
      await clob.placeBuy(order.tick, order.lots),
      `seed buy ${order.tick}`
    );
  }
}

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Network:", network.name, network.config.url || "in-process");
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

  await seedOrders(clob, tetc, tkn10k, waitForReceipt);
  console.log("Seeded initial book orders.");

  const addresses = {
    TETC_ADDRESS: tetc.target,
    TKN10K_ADDRESS: tkn10k.target,
    SIMPLE_LOT_TRADE_ADDRESS: clob.target
  };
  writeAddresses(addresses);
  console.log("Saved addresses to .env and ui/config.js");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
