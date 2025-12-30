const { expect } = require("chai");
const { ethers } = require("hardhat");

function envInt(name, fallback) {
  const raw = process.env[name];
  if (!raw) return fallback;
  const parsed = Number(raw);
  return Number.isFinite(parsed) ? parsed : fallback;
}

describe("SimpleLotTrade load tests", function () {
  this.timeout(120000);

  const BUY_ORDERS = envInt("BUY_ORDERS", 120);
  const SELL_ORDERS = envInt("SELL_ORDERS", 120);
  const CANCEL_COUNT = envInt("CANCEL_COUNT", 10);
  const TAKE_LOTS = envInt("TAKE_LOTS", 25);

  let deployer;
  let traders;
  let tetc;
  let tkn10k;
  let clob;

  before(async () => {
    [deployer, ...traders] = await ethers.getSigners();

    const deployedClob = process.env.CLOB_ADDRESS;
    if (deployedClob) {
      const SimpleLotTrade = await ethers.getContractFactory("SimpleLotTrade");
      clob = SimpleLotTrade.attach(deployedClob);
      const tetcAddress = await clob.TETC();
      const tknAddress = await clob.TKN10K();
      const TestERC20 = await ethers.getContractFactory("TestERC20");
      tetc = TestERC20.attach(tetcAddress);
      tkn10k = TestERC20.attach(tknAddress);
      traders = [deployer];
    } else {
      const TestERC20 = await ethers.getContractFactory("TestERC20");
      const traderCount = traders.length;
      const tetcPerTrader = ethers.parseUnits("250000", 18);
      const tknPerTrader = 250000n;
      const tetcSupply = tetcPerTrader * BigInt(traderCount + 1);
      const tknSupply = tknPerTrader * BigInt(traderCount + 1);

      tetc = await TestERC20.deploy("Test ETC", "TETC", 18, tetcSupply);
      tkn10k = await TestERC20.deploy("TKN10K", "TKN10K", 0, tknSupply);

      const SimpleLotTrade = await ethers.getContractFactory("SimpleLotTrade");
      clob = await SimpleLotTrade.deploy(tetc.target, tkn10k.target);

      const fundPerTrader = tetcPerTrader;
      const lotsPerTrader = tknPerTrader;
      for (const trader of traders) {
        await tetc.transfer(trader.address, fundPerTrader);
        await tkn10k.transfer(trader.address, lotsPerTrader);
      }
    }

    const approveAmount = ethers.parseUnits("1000000", 18);
    const approveLots = 1000000n;
    const all = [deployer, ...traders];
    for (const trader of all) {
      const provider = trader.provider;
      const feeData = await provider.getFeeData();
      let nonce = await provider.getTransactionCount(trader.address, "pending");
      const tx1 = await tetc.connect(trader).approve(clob.target, approveAmount, {
        nonce,
        gasPrice: feeData.gasPrice ?? undefined,
      });
      await tx1.wait();
      nonce += 1;
      const tx2 = await tkn10k.connect(trader).approve(clob.target, approveLots, {
        nonce,
        gasPrice: feeData.gasPrice ?? undefined,
      });
      await tx2.wait();
    }
  });

  it("builds depth under load", async () => {
    const tick = 0;
    const lots = 1n;

    let nextId = await clob.nextOrderId();
    const buyIds = [];
    const sellIds = [];

    for (let i = 0; i < BUY_ORDERS; i += 1) {
      const trader = traders[i % traders.length];
      await clob.connect(trader).placeBuy(tick, lots);
      buyIds.push(nextId);
      nextId += 1n;
    }

    for (let i = 0; i < SELL_ORDERS; i += 1) {
      const trader = traders[i % traders.length];
      await clob.connect(trader).placeSell(tick, lots);
      sellIds.push(nextId);
      nextId += 1n;
    }

    const buyDepth = await clob.getBuyBookDepth(10n);
    const sellDepth = await clob.getSellBookDepth(10n);
    expect(buyDepth[1]).to.equal(1n);
    expect(sellDepth[1]).to.equal(1n);
    expect(buyDepth[0][0].totalLots).to.equal(BigInt(BUY_ORDERS));
    expect(sellDepth[0][0].totalLots).to.equal(BigInt(SELL_ORDERS));

    const fullBuy = await clob.getFullBuyBook(BigInt(BUY_ORDERS));
    const fullSell = await clob.getFullSellBook(BigInt(SELL_ORDERS));
    expect(fullBuy[1]).to.equal(BigInt(BUY_ORDERS));
    expect(fullSell[1]).to.equal(BigInt(SELL_ORDERS));

    // Cancel a slice of buys to exercise removal paths.
    for (let i = 0; i < Math.min(CANCEL_COUNT, buyIds.length); i += 1) {
      const trader = traders[i % traders.length];
      await clob.connect(trader).cancel(buyIds[i]);
    }

    const afterCancel = await clob.getFullBuyBook(BigInt(BUY_ORDERS));
    expect(afterCancel[1]).to.equal(BigInt(BUY_ORDERS - Math.min(CANCEL_COUNT, buyIds.length)));
  });

  it("handles taker FOK across depth", async () => {
    const limitTick = 0;
    const lots = BigInt(TAKE_LOTS);
    const taker = traders[0];

    const before = await clob.getSellBookDepth(1n);
    if (before[1] === 0n) {
      return this.skip();
    }

    await clob.connect(taker).takeBuyFOK(limitTick, lots);
    const after = await clob.getSellBookDepth(1n);
    expect(after[0][0].totalLots).to.equal(before[0][0].totalLots - lots);
  });
});
