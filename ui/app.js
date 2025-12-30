const state = {
  provider: null,
  signer: null,
  tetc: null,
  tkn: null,
  clob: null,
  blockListener: null,
  refreshInFlight: false,
};

const el = (id) => document.getElementById(id);
const logBox = el("log");

const erc20Abi = [
  "function approve(address spender, uint256 value) external returns (bool)",
  "function balanceOf(address account) external view returns (uint256)",
  "function decimals() external view returns (uint8)",
  "function name() external view returns (string)",
  "function symbol() external view returns (string)",
];

const clobAbi = [
  "function placeBuy(int256 tick, uint256 lots) external returns (uint256)",
  "function placeSell(int256 tick, uint256 lots) external returns (uint256)",
  "function takeBuyFOK(int256 limitTick, uint256 lots) external",
  "function takeSellFOK(int256 limitTick, uint256 lots) external",
  "function cancel(uint256 id) external",
  "function TETC() external view returns (address)",
  "function TKN10K() external view returns (address)",
  "function getBuyBookDepth(uint256 maxLevels) external view returns (tuple(int256 tick,uint256 totalLots,uint256 orderCount)[] out, uint256 n)",
  "function getSellBookDepth(uint256 maxLevels) external view returns (tuple(int256 tick,uint256 totalLots,uint256 orderCount)[] out, uint256 n)",
  "function getFullBuyBook(uint256 maxOrders) external view returns (tuple(uint256 id,address owner,int256 tick,uint256 lotsRemaining)[] out, uint256 n)",
  "function getFullSellBook(uint256 maxOrders) external view returns (tuple(uint256 id,address owner,int256 tick,uint256 lotsRemaining)[] out, uint256 n)",
  "function priceAtTick(int256 tick) external pure returns (uint256)",
  "function hasBestBuy() external view returns (bool)",
  "function hasBestSell() external view returns (bool)",
  "function bestBuyTick() external view returns (int256)",
  "function bestSellTick() external view returns (int256)",
];

function addLog(title, detail) {
  const entry = document.createElement("div");
  entry.className = "log-entry";
  entry.innerHTML = `<strong>${title}</strong><div>${detail}</div>`;
  logBox.prepend(entry);
}

async function loadDepth() {
  if (!state.clob) return;
  const maxLevels = el("bookLevels").value.trim();
  if (!maxLevels) return;
  let tetcDecimals = 18;
  try {
    if (state.tetc) {
      tetcDecimals = await state.tetc.decimals();
    }
  } catch {
    tetcDecimals = 18;
  }
  const [buy, sell] = await Promise.all([
    state.clob.getBuyBookDepth(BigInt(maxLevels)),
    state.clob.getSellBookDepth(BigInt(maxLevels)),
  ]);
    const buyLevels = buy[0].slice(0, Number(buy[1]));
    const sellLevels = sell[0].slice(0, Number(sell[1]));
    const priceCalls = [
      ...buyLevels.map((lvl) => state.clob.priceAtTick(lvl.tick)),
      ...sellLevels.map((lvl) => state.clob.priceAtTick(lvl.tick)),
    ];
    const prices = await Promise.all(priceCalls);
    const buyPrices = prices.slice(0, buyLevels.length);
    const sellPrices = prices.slice(buyLevels.length);
    const buyRows = buyLevels.map((lvl, i) => [
      String(lvl.tick),
      String(lvl.totalLots),
      ethers.formatUnits(buyPrices[i], tetcDecimals),
    ]);
    const sellRows = sellLevels.map((lvl, i) => [
      String(lvl.tick),
      String(lvl.totalLots),
      ethers.formatUnits(sellPrices[i], tetcDecimals),
    ]);
    renderTable("buyDepth", ["Tick", "Lots", "Price"], buyRows);
    renderTable("sellDepth", ["Tick", "Lots", "Price"], sellRows);
}

async function loadOrders() {
  if (!state.clob) return;
  const maxOrders = el("bookOrders").value.trim();
  if (!maxOrders) return;
  const [buy, sell] = await Promise.all([
    state.clob.getFullBuyBook(BigInt(maxOrders)),
    state.clob.getFullSellBook(BigInt(maxOrders)),
  ]);
  const buyRows = buy[0].slice(0, Number(buy[1])).map((ord) => [
    String(ord.id),
    String(ord.tick),
    String(ord.lotsRemaining),
  ]);
  const sellRows = sell[0].slice(0, Number(sell[1])).map((ord) => [
    String(ord.id),
    String(ord.tick),
    String(ord.lotsRemaining),
  ]);
  renderTable("buyOrders", ["ID", "Tick", "Lots"], buyRows);
  renderTable("sellOrders", ["ID", "Tick", "Lots"], sellRows);
}

function setOrdersVisible(enabled) {
  const controls = el("orderControlsOrders");
  const buyOrders = el("orderTablesOrders");
  const sellOrders = el("orderTablesOrdersSell");
  const button = el("loadOrdersBtn");
  if (controls) controls.style.display = enabled ? "" : "none";
  if (buyOrders) buyOrders.style.display = enabled ? "" : "none";
  if (sellOrders) sellOrders.style.display = enabled ? "" : "none";
  if (button) button.style.display = enabled ? "" : "none";
}

async function refreshOrderbook() {
  if (!state.clob || state.refreshInFlight) return;
  state.refreshInFlight = true;
  try {
    const tasks = [refreshBestTicks(), loadDepth()];
    if (el("showOrdersToggle")?.checked) {
      tasks.push(loadOrders());
    }
    await Promise.all(tasks);
  } catch (err) {
    addLog("Error", err.message);
  } finally {
    state.refreshInFlight = false;
  }
}

function startBlockListener() {
  if (!state.provider) return;
  if (state.blockListener) {
    state.provider.off("block", state.blockListener);
  }
  state.blockListener = async () => {
    await refreshOrderbook();
  };
  state.provider.on("block", state.blockListener);
}

function renderTable(targetId, headers, rows) {
  const table = el(targetId);
  table.innerHTML = "";
  const headerRow = document.createElement("div");
  headerRow.className = "book-row header";
  headerRow.innerHTML = headers.map((h) => `<div>${h}</div>`).join("");
  table.appendChild(headerRow);
  if (!rows.length) {
    const empty = document.createElement("div");
    empty.className = "book-row";
    empty.innerHTML = `<div>-</div><div>-</div><div>-</div>`;
    table.appendChild(empty);
    return;
  }
  rows.forEach((row) => {
    const line = document.createElement("div");
    line.className = "book-row";
    line.innerHTML = row.map((cell) => `<div>${cell}</div>`).join("");
    table.appendChild(line);
  });
}

function setStatus(text, ok = false) {
  el("statusText").textContent = text;
  el("statusBox").style.borderColor = ok ? "#3c8f5c" : "#d8c6b8";
}

async function refreshBalances() {
  if (!state.signer || !state.tetc || !state.tkn) {
    return;
  }
  const address = await state.signer.getAddress();
  const tetcDecimals = await state.tetc.decimals();
  const tknDecimals = await state.tkn.decimals();
  const [tetcBal, tknBal, ethBal] = await Promise.all([
    state.tetc.balanceOf(address),
    state.tkn.balanceOf(address),
    state.provider.getBalance(address),
  ]);
  el("walletBalance").textContent = `${ethers.formatEther(ethBal)} ETH`;
  addLog(
    "Balances",
    `TETC: ${ethers.formatUnits(tetcBal, tetcDecimals)}, TKN10K: ${ethers.formatUnits(
      tknBal,
      tknDecimals,
    )}`,
  );
}

async function refreshTokenMeta() {
  if (!state.tetc || !state.tkn) return;
  const [tetcName, tetcSymbol, tetcDecimals] = await Promise.all([
    state.tetc.name(),
    state.tetc.symbol(),
    state.tetc.decimals(),
  ]);
  const [tknName, tknSymbol, tknDecimals] = await Promise.all([
    state.tkn.name(),
    state.tkn.symbol(),
    state.tkn.decimals(),
  ]);
  el("tetcMeta").textContent = `${tetcName} (${tetcSymbol}) d=${tetcDecimals}`;
  el("tknMeta").textContent = `${tknName} (${tknSymbol}) d=${tknDecimals}`;
}

async function refreshBestTicks() {
  if (!state.clob) return;
  const [hasBuy, hasSell, buyTick, sellTick] = await Promise.all([
    state.clob.hasBestBuy(),
    state.clob.hasBestSell(),
    state.clob.bestBuyTick(),
    state.clob.bestSellTick(),
  ]);
  el("bestBuy").textContent = hasBuy ? String(buyTick) : "-";
  el("bestSell").textContent = hasSell ? String(sellTick) : "-";
}

el("connectBtn").addEventListener("click", async () => {
  const rpcUrl = el("rpcUrl").value.trim();
  const pk = el("privateKey").value.trim();
  const chainId = el("chainId").value.trim();
  if (!rpcUrl || !pk) {
    addLog("Error", "RPC URL and private key are required.");
    return;
  }
  try {
    const provider = new ethers.JsonRpcProvider(rpcUrl, chainId ? Number(chainId) : undefined);
    const network = await provider.getNetwork();
    const signer = new ethers.Wallet(pk, provider);
    const address = await signer.getAddress();
    state.provider = provider;
    state.signer = signer;
    el("walletAddress").textContent = address;
    el("chainDisplay").textContent = String(network.chainId);
    if (!chainId) {
      el("chainId").value = String(network.chainId);
    }
    setStatus("Connected", true);
    addLog("Connected", `Wallet ${address}`);
    await refreshBalances();
    startBlockListener();
  } catch (err) {
    setStatus("Connection failed");
    addLog("Error", err.message);
  }
});

async function connectWithNodeAccount({ silent } = {}) {
  const rpcUrl = el("rpcUrl").value.trim();
  const chainId = el("chainId").value.trim();
  if (!rpcUrl) {
    if (!silent) addLog("Error", "RPC URL is required.");
    return;
  }
  try {
    const provider = new ethers.JsonRpcProvider(rpcUrl, chainId ? Number(chainId) : undefined);
    const network = await provider.getNetwork();
    const accounts = await provider.listAccounts();
    if (!accounts.length) {
      if (!silent) addLog("Error", "No node accounts available (eth_accounts empty).");
      return;
    }
    const signer = await provider.getSigner(accounts[0].address ?? accounts[0]);
    const address = await signer.getAddress();
    state.provider = provider;
    state.signer = signer;
    el("walletAddress").textContent = address;
    el("chainDisplay").textContent = String(network.chainId);
    if (!chainId) {
      el("chainId").value = String(network.chainId);
    }
    setStatus("Connected (node account)", true);
    addLog("Connected", `Node account ${address}`);
    await refreshBalances();
    startBlockListener();
  } catch (err) {
    setStatus("Connection failed");
    if (!silent) addLog("Error", err.message);
  }
}

el("useNodeAccountBtn").addEventListener("click", async () => {
  await connectWithNodeAccount({ silent: false });
});

window.addEventListener("DOMContentLoaded", async () => {
  await connectWithNodeAccount({ silent: true });
});

el("loadContractsBtn").addEventListener("click", async () => {
  if (!state.signer) {
    addLog("Error", "Connect wallet first.");
    return;
  }
  const tetcAddress = el("tetcAddress").value.trim();
  const tknAddress = el("tknAddress").value.trim();
  const clobAddress = el("clobAddress").value.trim();
  if (!tetcAddress || !tknAddress || !clobAddress) {
    addLog("Error", "Enter all contract addresses.");
    return;
  }
  try {
    state.tetc = new ethers.Contract(tetcAddress, erc20Abi, state.signer);
    state.tkn = new ethers.Contract(tknAddress, erc20Abi, state.signer);
    state.clob = new ethers.Contract(clobAddress, clobAbi, state.signer);
    addLog("Contracts loaded", "Ready to trade.");
    await refreshTokenMeta();
    await refreshBalances();
    await refreshOrderbook();
  } catch (err) {
    addLog("Error", err.message);
  }
});

el("autoFillBtn").addEventListener("click", async () => {
  if (!state.signer) {
    addLog("Error", "Connect wallet first.");
    return;
  }
  const clobAddress = el("clobAddress").value.trim();
  if (!clobAddress) {
    addLog("Error", "Enter the SimpleLotTrade address.");
    return;
  }
  try {
    const clob = new ethers.Contract(clobAddress, clobAbi, state.signer);
    const [tetcAddress, tknAddress] = await Promise.all([clob.TETC(), clob.TKN10K()]);
    el("tetcAddress").value = tetcAddress;
    el("tknAddress").value = tknAddress;
    state.tetc = new ethers.Contract(tetcAddress, erc20Abi, state.signer);
    state.tkn = new ethers.Contract(tknAddress, erc20Abi, state.signer);
    state.clob = clob;
    addLog("Auto-filled", "Loaded token addresses from CLOB.");
    await refreshTokenMeta();
    await refreshBalances();
    await refreshOrderbook();
  } catch (err) {
    addLog("Error", err.message);
  }
});

el("approveTetcBtn").addEventListener("click", async () => {
  if (!state.tetc || !state.clob) {
    addLog("Error", "Load contracts first.");
    return;
  }
  const amount = el("approveAmount").value.trim();
  if (!amount) {
    addLog("Error", "Enter an approval amount.");
    return;
  }
  try {
    const tx = await state.tetc.approve(state.clob.target, BigInt(amount));
    addLog("Approve TETC", `tx ${tx.hash}`);
    await tx.wait();
    addLog("Approved", "TETC allowance updated.");
  } catch (err) {
    addLog("Error", err.message);
  }
});

el("approveTknBtn").addEventListener("click", async () => {
  if (!state.tkn || !state.clob) {
    addLog("Error", "Load contracts first.");
    return;
  }
  const amount = el("approveAmount").value.trim();
  if (!amount) {
    addLog("Error", "Enter an approval amount.");
    return;
  }
  try {
    const tx = await state.tkn.approve(state.clob.target, BigInt(amount));
    addLog("Approve TKN10K", `tx ${tx.hash}`);
    await tx.wait();
    addLog("Approved", "TKN10K allowance updated.");
  } catch (err) {
    addLog("Error", err.message);
  }
});

el("placeOrderBtn").addEventListener("click", async () => {
  if (!state.clob) {
    addLog("Error", "Load contracts first.");
    return;
  }
  const side = el("orderSide").value;
  const tick = el("orderTick").value.trim();
  const lots = el("orderLots").value.trim();
  if (!tick || !lots) {
    addLog("Error", "Enter tick and lots.");
    return;
  }
  try {
    const method = side === "buy" ? "placeBuy" : "placeSell";
    const tx = await state.clob[method](BigInt(tick), BigInt(lots));
    addLog("Order submitted", `tx ${tx.hash}`);
    const receipt = await tx.wait();
    addLog("Order confirmed", `block ${receipt.blockNumber}`);
    await refreshBestTicks();
    await refreshBalances();
  } catch (err) {
    addLog("Error", err.message);
  }
});

el("takeBtn").addEventListener("click", async () => {
  if (!state.clob) {
    addLog("Error", "Load contracts first.");
    return;
  }
  const side = el("takeSide").value;
  const limitTick = el("takeLimitTick").value.trim();
  const lots = el("takeLots").value.trim();
  if (!limitTick || !lots) {
    addLog("Error", "Enter limit tick and lots.");
    return;
  }
  try {
    const method = side === "buy" ? "takeBuyFOK" : "takeSellFOK";
    const tx = await state.clob[method](BigInt(limitTick), BigInt(lots));
    addLog("FOK submitted", `tx ${tx.hash}`);
    const receipt = await tx.wait();
    addLog("FOK confirmed", `block ${receipt.blockNumber}`);
    await refreshBestTicks();
    await refreshBalances();
  } catch (err) {
    addLog("Error", err.message);
  }
});

el("cancelBtn").addEventListener("click", async () => {
  if (!state.clob) {
    addLog("Error", "Load contracts first.");
    return;
  }
  const id = el("cancelId").value.trim();
  if (!id) {
    addLog("Error", "Enter order id.");
    return;
  }
  try {
    const tx = await state.clob.cancel(BigInt(id));
    addLog("Cancel submitted", `tx ${tx.hash}`);
    const receipt = await tx.wait();
    addLog("Cancel confirmed", `block ${receipt.blockNumber}`);
    await refreshBestTicks();
    await refreshBalances();
  } catch (err) {
    addLog("Error", err.message);
  }
});

el("loadDepthBtn").addEventListener("click", async () => {
  try {
    await loadDepth();
    addLog("Orderbook", "Depth loaded.");
  } catch (err) {
    addLog("Error", err.message);
  }
});

el("loadOrdersBtn").addEventListener("click", async () => {
  try {
    await loadOrders();
    addLog("Orderbook", "Orders loaded.");
  } catch (err) {
    addLog("Error", err.message);
  }
});

el("showOrdersToggle").addEventListener("change", async (event) => {
  const enabled = event.target.checked;
  setOrdersVisible(enabled);
  if (enabled) {
    await loadOrders();
  }
});

setOrdersVisible(false);
import { ethers } from "https://cdn.jsdelivr.net/npm/ethers@6.16.0/+esm";
