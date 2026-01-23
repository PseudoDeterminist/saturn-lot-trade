const params = new URLSearchParams(window.location.search);
const net = params.get("net") || "local";

const LOCAL = {
  rpcUrl: "http://127.0.0.1:8545",
  chainId: 31337,
  wetcAddress: "0x5FbDB2315678afecb367f032d93F642f64180aa3",
  strn10kAddress: "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",
  simpleLotTradeAddress: "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0",
  maxLevels: 25,
  maxOrders: 50,
};

const ETC = {
  rpcUrl: "http://127.0.0.1:8545",
  chainId: 61,
  wetcAddress: "0x82A618305706B14e7bcf2592D4B9324A366b6dAd",
  strn10kAddress: "0x7d35D3938c3b4446473a4ac29351Bd93694b5DEF",
  simpleLotTradeAddress: "0x989445dA165F787Bb07B9C04946D87BbF9051EEf",
  maxLevels: 25,
  maxOrders: 50,
};

window.APP_CONFIG = net === "etc" ? ETC : LOCAL;
window.APP_CONFIG.net = net;
