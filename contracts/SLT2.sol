// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/*
  SimpleLotTrade v0.5.0 (Design)
  ------------------------------
  - Tick-only Central Limit Order Book for TKN10K lots (decimals=0), priced in TETC (18 decimals)
  - FOK takers only
  - NO internal deposit/withdraw balances:
      * Makers escrow tokens inside the contract on order placement
      * Escrow is released on fill/partial fill/cancel
  - Price grid:
      * 464 ticks per decade (~0.5% per tick)
      * Mantissa table: 464 uint16 values (1000..9950), packed into a single bytes constant
      * Tick 0 price = 1e18 (1.000 TETC per lot)
      * Tick range: [-2320, +2320]  (i.e., [-5 decades, +5 decades])

  Added for "no-backend / IPFS UI" support:
  - Events for OrderPlaced / OrderCanceled / OrderFilled
  - Ring buffer of recent trades (constant-size, fast eth_call)
  - Weekly OHLCV candles (block-based week buckets, fast eth_call)
*/

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/* ===================== Lot CLOB ===================== */

contract SimpleLotTrade {
    // Tick range: -464*5 .. +464*5
    int256 private constant MIN_TICK = -2320;
    int256 private constant MAX_TICK =  2320;

    // 464 uint16 values packed big-endian, 2 bytes each.
    // Total bytes = 928 (29*32)

    // Packed mantissa bytes
    bytes internal constant MANT =
        hex"03e803ed03f203f703fc04010406040b04100416041b04200425042b04300435"
        hex"043b04400445044b04500456045b04610466046c04720477047d04830489048e"
        hex"0494049a04a004a604ac04b204b804be04c404ca04d004d604dc04e204e804ef"
        hex"04f504fb05020508050e0515051b05220528052f0536053c0543054a05500557"
        hex"055e0565056c0572057905800587058e0595059d05a405ab05b205b905c105c8"
        hex"05cf05d705de05e605ed05f505fc0604060c0613061b0623062b0632063a0642"
        hex"064a0652065a0662066b0673067b0683068b0694069c06a506ad06b606be06c7"
        hex"06cf06d806e106e906f206fb0704070d0716071f07280731073a0744074d0756"
        hex"075f07690772077c0785078f079807a207ac07b607bf07c907d307dd07e707f1"
        hex"07fb08060810081a0824082f08390844084e08590863086e08790884088e0899"
        hex"08a408af08ba08c508d108dc08e708f208fe090909150920092c09380943094f"
        hex"095b09670973097f098b099709a309b009bc09c809d509e109ee09fb0a070a14"
        hex"0a210a2e0a3b0a480a550a620a6f0a7d0a8a0a970aa50ab20ac00ace0adb0ae9"
        hex"0af70b050b130b210b2f0b3e0b4c0b5a0b690b770b860b950ba30bb20bc10bd0"
        hex"0bdf0bee0bfe0c0d0c1c0c2c0c3b0c4b0c5a0c6a0c7a0c8a0c9a0caa0cba0cca"
        hex"0cda0ceb0cfb0d0c0d1c0d2d0d3e0d4f0d600d710d820d930da40db60dc70dd9"
        hex"0dea0dfc0e0e0e200e320e440e560e680e7b0e8d0e9f0eb20ec50ed80eeb0efe"
        hex"0f110f240f370f4a0f5e0f720f850f990fad0fc10fd50fe90ffd10121026103b"
        hex"104f10641079108e10a310b810ce10e310f8110e1124113a11501166117c1192"
        hex"11a811bf11d511ec1203121a12311248125f1277128e12a612be12d612ee1306"
        hex"131e1336134f13671380139913b213cb13e413fd14171430144a1464147e1498"
        hex"14b214cd14e71502151d15371552156e158915a415c015dc15f716131630164c"
        hex"1668168516a116be16db16f8171617331750176e178c17aa17c817e618051823"
        hex"184218611880189f18bf18de18fe191e193e195e197e199f19bf19e01a011a22"
        hex"1a431a651a861aa81aca1aec1b0f1b311b541b761b991bbd1be01c031c271c4b"
        hex"1c6f1c931cb81cdc1d011d261d4b1d701d961dbb1de11e071e2e1e541e7b1ea1"
        hex"1ec81ef01f171f3f1f661f8e1fb71fdf200820302059208320ac20d620ff2129"
        hex"2154217e21a921d421ff222a2256228122ad22d923062332235f238c23b923e7"
        hex"241524432471249f24ce24fd252c255b258b25bb25eb261b264b267c26ad26de";

    // Precomputed order of magnitude factors (1e10 .. 1e19), big-endian uint256 words.
    bytes internal constant DECADES =
        hex"00000000000000000000000000000000000000000000000000000002540be400"  // 1e10
        hex"000000000000000000000000000000000000000000000000000000174876e800"  // 1e11
        hex"000000000000000000000000000000000000000000000000000000e8d4a51000"  // 1e12
        hex"000000000000000000000000000000000000000000000000000009184e72a000"  // 1e13
        hex"00000000000000000000000000000000000000000000000000005af3107a4000"  // 1e14
        hex"00000000000000000000000000000000000000000000000000038d7ea4c68000"  // 1e15
        hex"000000000000000000000000000000000000000000000000002386f26fc10000"  // 1e16
        hex"000000000000000000000000000000000000000000000000016345785d8a0000"  // 1e17
        hex"0000000000000000000000000000000000000000000000000de0b6b3a7640000"  // 1e18
        hex"0000000000000000000000000000000000000000000000008ac7230489e80000"; // 1e19

    IERC20 public immutable TETC;    // quote token (18 decimals)
    IERC20 public immutable TKN10K;  // base token (0 decimals, integer lots)

    int256 private constant NONE = type(int256).min;

    /* ---------- Events (UI change stream) ---------- */

    event OrderPlaced(
        uint256 indexed id,
        address indexed owner,
        bool indexed isBuy,
        int256 tick,
        uint256 lots,
        uint256 escrowedAmount // TETC for buys, TKN10K-lots for sells
    );

    event OrderCanceled(
        uint256 indexed id,
        address indexed owner,
        bool indexed isBuy,
        int256 tick,
        uint256 lotsCanceled,
        uint256 refundAmount // TETC for buys, TKN10K-lots for sells
    );

    event OrderFilled(
        uint256 indexed id,
        address indexed maker,
        address indexed taker,
        bool makerIsBuy,
        int256 tick,
        uint256 lotsFilled,
        uint256 quotePaid // TETC amount
    );

    /* ---------- "Recent trades" ring buffer (fast eth_call tape) ---------- */

    uint256 public constant RECENT_N = 512;
    uint256 public recentTradeIndex; // monotonically increasing

    struct RecentTrade {
        uint64 blockNumber;
        int32  tick;
        uint128 lots;
        uint8  flags; // bit0 = takerIsBuy
    }

    mapping(uint256 => RecentTrade) private _recentTrades; // index%RECENT_N -> RecentTrade

    function getRecentTrades(uint256 count) external view returns (RecentTrade[] memory out) {
        if (count > RECENT_N) count = RECENT_N;
        uint256 end = recentTradeIndex; // one past last
        uint256 start = end > count ? end - count : 0;
        uint256 n = end - start;
        out = new RecentTrade[](n);

        for (uint256 k = 0; k < n; k++) {
            out[k] = _recentTrades[(start + k) % RECENT_N];
        }
    }

    function _recordRecentTrade(int256 tick, uint256 lots, bool takerIsBuy) internal {
        // Clamp only by type-casts that should be safe for your intended market sizes.
        // If you expect > 2^128 lots per fill, you should widen this.
        require(lots <= type(uint128).max, "lots too big");

        uint256 i = recentTradeIndex++;
        _recentTrades[i % RECENT_N] = RecentTrade({
            blockNumber: uint64(block.number),
            tick: int32(tick),
            lots: uint128(lots),
            flags: takerIsBuy ? uint8(1) : uint8(0)
        });
    }

    /* ---------- Weekly OHLCV candles (block-based buckets) ---------- */

    // ETC target is ~13s; 7 days ~ 46500 blocks. Adjust if you want a different cadence.
    uint256 public constant BLOCKS_PER_WEEK = 46500;

    struct Candle {
        bool   exists;
        int32  open;
        int32  high;
        int32  low;
        int32  close;
        uint128 volumeLots;
        uint64  firstBlock;
        uint64  lastBlock;
    }

    mapping(uint256 => Candle) public weekly; // weekIndex => Candle

    function currentWeekIndex() public view returns (uint256) {
        return block.number / BLOCKS_PER_WEEK;
    }

    function getWeeklyCandles(uint256 startWeek, uint256 count) external view returns (Candle[] memory out) {
        out = new Candle[](count);
        for (uint256 i = 0; i < count; i++) {
            out[i] = weekly[startWeek + i];
        }
    }

    function _updateWeeklyCandle(int256 tick, uint256 lots) internal {
        require(lots <= type(uint128).max, "lots too big");
        uint256 w = block.number / BLOCKS_PER_WEEK;

        Candle storage c = weekly[w];
        int32 t = int32(tick);

        if (!c.exists) {
            c.exists = true;
            c.open = t;
            c.high = t;
            c.low = t;
            c.close = t;
            c.volumeLots = uint128(lots);
            c.firstBlock = uint64(block.number);
            c.lastBlock  = uint64(block.number);
        } else {
            if (t > c.high) c.high = t;
            if (t < c.low)  c.low  = t;
            c.close = t;
            c.volumeLots += uint128(lots);
            c.lastBlock = uint64(block.number);
        }
    }

    /* ---------- Oracle ---------- */

    int256 public lastTradeTick;
    uint256 public lastTradeBlock;

    /* ---------- Reentrancy guard (token transfers) ---------- */

    uint256 private _lock = 1;
    modifier nonReentrant() {
        require(_lock == 1, "reentrancy");
        _lock = 2;
        _;
        _lock = 1;
    }

    /* ---------- Book structures ---------- */

    struct Order {
        address owner;
        int256 tick;
        uint256 lotsRemaining;
        bool isBuy;     // buy lots for TETC, or sell lots for TETC
        uint256 prev;
        uint256 next;
        bool exists;
    }

    struct TickLevel {
        bool exists;
        int256 prev;
        int256 next;
        uint256 head;
        uint256 tail;
        uint256 orderCount;
        uint256 totalLots;
    }

    uint256 public nextOrderId = 1;

    mapping(uint256 => Order) public orders;
    mapping(int256 => TickLevel) public buyLevels;
    mapping(int256 => TickLevel) public sellLevels;

    bool public hasBestBuy;
    bool public hasBestSell;
    int256 public bestBuyTick;
    int256 public bestSellTick;

    // Book return structs
    struct BookOrder {
        uint256 id;
        address owner;
        int256 tick;
        uint256 lotsRemaining;
    }

    struct BookLevel {
        int256 tick;
        uint256 totalLots;
        uint256 orderCount;
    }

    constructor(address tetcToken, address tkn10kToken) {
        require(tetcToken != address(0), "zero TETC");
        require(tkn10kToken != address(0), "zero TKN10K");
        TETC = IERC20(tetcToken);
        TKN10K = IERC20(tkn10kToken);
        bestBuyTick = NONE;
        bestSellTick = NONE;
    }

    function priceAtTick(int256 tick) public pure returns (uint256 result) {
        require(tick >= MIN_TICK && tick <= MAX_TICK, "tick out of range");

        uint256 t = uint256(tick - MIN_TICK); // safe because of require above
        uint256 d = t / 464;                  // decade index
        uint256 r = t % 464;                  // mantissa index

        uint256 i = r * 2;
        uint256 m = (uint256(uint8(MANT[i])) << 8) | uint256(uint8(MANT[i + 1]));

        // Copy DECADES to memory so we can reference it in assembly
        bytes memory decadesData = DECADES;
        uint256 factor;
        assembly {
            factor := mload(add(add(decadesData, 0x20), mul(d, 0x20)))
        }

        result = factor * m;
    }

    /* ---------- Maker Orders (escrow on placement) ---------- */

    function placeBuy(int256 tick, uint256 lots) external nonReentrant returns (uint256 id) {
        require(lots > 0, "zero lots");
        require(!hasBestSell || bestSellTick > tick, "crossing sell book");

        uint256 cost = uint256(lots) * priceAtTick(tick);

        // Escrow TETC in this contract
        require(TETC.transferFrom(msg.sender, address(this), cost), "TETC transferFrom failed");

        id = _newOrder(true, tick, lots);
        _enqueue(true, tick, id);

        emit OrderPlaced(id, msg.sender, true, tick, lots, cost);
    }

    function placeSell(int256 tick, uint256 lots) external nonReentrant returns (uint256 id) {
        require(lots > 0, "zero lots");
        require(!hasBestBuy || bestBuyTick < tick, "crossing buy book");

        // Escrow TKN10K lots in this contract (integer token)
        require(TKN10K.transferFrom(msg.sender, address(this), uint256(lots)), "TKN10K transferFrom failed");

        id = _newOrder(false, tick, lots);
        _enqueue(false, tick, id);

        emit OrderPlaced(id, msg.sender, false, tick, lots, lots);
    }

    function cancel(uint256 id) external nonReentrant {
        Order storage o = orders[id];
        require(o.exists && o.owner == msg.sender, "not owner");

        // Refund remaining escrow
        if (o.isBuy) {
            uint256 refund = uint256(o.lotsRemaining) * priceAtTick(o.tick);
            require(TETC.transfer(msg.sender, refund), "TETC refund failed");
            buyLevels[o.tick].totalLots -= o.lotsRemaining;

            emit OrderCanceled(id, msg.sender, true, o.tick, o.lotsRemaining, refund);
        } else {
            uint256 refundLots = uint256(o.lotsRemaining);
            require(TKN10K.transfer(msg.sender, refundLots), "TKN10K refund failed");
            sellLevels[o.tick].totalLots -= o.lotsRemaining;

            emit OrderCanceled(id, msg.sender, false, o.tick, o.lotsRemaining, refundLots);
        }

        _unlinkOrder(o.isBuy, o.tick, id);
        delete orders[id];
    }

    /* ---------- Taker FOK ---------- */

    function takeBuyFOK(int256 limitTick, uint256 lots) external nonReentrant {
        require(hasBestSell, "no sells");
        require(lots > 0, "zero lots");

        uint256 remain = lots;
        int256 t = bestSellTick;

        while (remain > 0) {
            require(t <= limitTick, "FOK");
            TickLevel storage lvl = sellLevels[t];
            uint256 oid = lvl.head;
            require(oid != 0, "empty level");

            Order storage m = orders[oid];
            uint256 f = m.lotsRemaining > remain ? remain : m.lotsRemaining;

            uint256 pay = uint256(f) * priceAtTick(t);

            // Taker pays maker in TETC
            require(TETC.transferFrom(msg.sender, m.owner, pay), "TETC pay failed");

            // Contract releases escrowed TKN10K to taker
            require(TKN10K.transfer(msg.sender, uint256(f)), "TKN10K deliver failed");

            // Book accounting
            m.lotsRemaining -= f;
            lvl.totalLots -= f;
            remain -= f;

            // UI + derived data
            emit OrderFilled(oid, m.owner, msg.sender, false /*makerIsBuy*/, t, f, pay);
            _recordRecentTrade(t, f, true /*takerIsBuy*/);
            _updateWeeklyCandle(t, f);

            lastTradeTick = t;
            lastTradeBlock = block.number;

            if (m.lotsRemaining == 0) {
                _removeHead(false, t);
                delete orders[oid];
            }

            if (lvl.head == 0) {
                int256 nxt = lvl.next;
                _removeTick(false, t);
                if (nxt == NONE) break;
                t = nxt;
            }
        }

        require(remain == 0, "unfilled");
    }

    function takeSellFOK(int256 limitTick, uint256 lots) external nonReentrant {
        require(hasBestBuy, "no buys");
        require(lots > 0, "zero lots");

        uint256 remain = lots;
        int256 t = bestBuyTick;

        while (remain > 0) {
            require(t >= limitTick, "FOK");
            TickLevel storage lvl = buyLevels[t];
            uint256 oid = lvl.head;
            require(oid != 0, "empty level");

            Order storage m = orders[oid];
            uint256 f = m.lotsRemaining > remain ? remain : m.lotsRemaining;

            uint256 pay = uint256(f) * priceAtTick(t);

            // Taker delivers TKN10K to maker (buyer)
            require(TKN10K.transferFrom(msg.sender, m.owner, uint256(f)), "TKN10K pay failed");

            // Contract releases escrowed TETC to taker
            require(TETC.transfer(msg.sender, pay), "TETC deliver failed");

            // Book accounting
            m.lotsRemaining -= f;
            lvl.totalLots -= f;
            remain -= f;

            // UI + derived data
            emit OrderFilled(oid, m.owner, msg.sender, true /*makerIsBuy*/, t, f, pay);
            _recordRecentTrade(t, f, false /*takerIsBuy*/);
            _updateWeeklyCandle(t, f);

            lastTradeTick = t;
            lastTradeBlock = block.number;

            if (m.lotsRemaining == 0) {
                _removeHead(true, t);
                delete orders[oid];
            }

            if (lvl.head == 0) {
                int256 nxt = lvl.next;
                _removeTick(true, t);
                if (nxt == NONE) break;
                t = nxt;
            }
        }

        require(remain == 0, "unfilled");
    }

    /* ---------- Full Book + Depth Views (single-pass, bounded) ---------- */

    function getFullBuyBook(uint256 maxOrders)
        external
        view
        returns (BookOrder[] memory out, uint256 n)
    {
        return _getFullBookSinglePass(true, maxOrders);
    }

    function getFullSellBook(uint256 maxOrders)
        external
        view
        returns (BookOrder[] memory out, uint256 n)
    {
        return _getFullBookSinglePass(false, maxOrders);
    }

    function _getFullBookSinglePass(bool isBuy, uint256 maxOrders)
        internal
        view
        returns (BookOrder[] memory out, uint256 n)
    {
        if (maxOrders == 0) return (new BookOrder[](0), 0);

        if (isBuy) {
            if (!hasBestBuy) return (new BookOrder[](0), 0);
        } else {
            if (!hasBestSell) return (new BookOrder[](0), 0);
        }

        out = new BookOrder[](maxOrders);
        n = 0;

        if (isBuy) {
            int256 t = bestBuyTick;
            while (t != NONE && n < maxOrders) {
                TickLevel storage lvl = buyLevels[t];
                uint256 oid = lvl.head;
                while (oid != 0 && n < maxOrders) {
                    Order storage o = orders[oid];
                    out[n++] = BookOrder(oid, o.owner, o.tick, o.lotsRemaining);
                    oid = o.next;
                }
                t = lvl.next;
            }
        } else {
            int256 t = bestSellTick;
            while (t != NONE && n < maxOrders) {
                TickLevel storage lvl = sellLevels[t];
                uint256 oid = lvl.head;
                while (oid != 0 && n < maxOrders) {
                    Order storage o = orders[oid];
                    out[n++] = BookOrder(oid, o.owner, o.tick, o.lotsRemaining);
                    oid = o.next;
                }
                t = lvl.next;
            }
        }
    }

    function getBuyBookDepth(uint256 maxLevels)
        external
        view
        returns (BookLevel[] memory out, uint256 n)
    {
        return _getDepthSinglePass(true, maxLevels);
    }

    function getSellBookDepth(uint256 maxLevels)
        external
        view
        returns (BookLevel[] memory out, uint256 n)
    {
        return _getDepthSinglePass(false, maxLevels);
    }

    function _getDepthSinglePass(bool isBuy, uint256 maxLevels)
        internal
        view
        returns (BookLevel[] memory out, uint256 n)
    {
        if (maxLevels == 0) return (new BookLevel[](0), 0);

        if (isBuy) {
            if (!hasBestBuy) return (new BookLevel[](0), 0);
        } else {
            if (!hasBestSell) return (new BookLevel[](0), 0);
        }

        out = new BookLevel[](maxLevels);
        n = 0;

        if (isBuy) {
            int256 t = bestBuyTick;
            while (t != NONE && n < maxLevels) {
                TickLevel storage lvl = buyLevels[t];
                if (lvl.totalLots > 0) out[n++] = BookLevel(t, lvl.totalLots, lvl.orderCount);
                t = lvl.next;
            }
        } else {
            int256 t = bestSellTick;
            while (t != NONE && n < maxLevels) {
                TickLevel storage lvl = sellLevels[t];
                if (lvl.totalLots > 0) out[n++] = BookLevel(t, lvl.totalLots, lvl.orderCount);
                t = lvl.next;
            }
        }
    }

    function getTopOfBook() external view returns (
        bool hasBuy, int256 buyTick, uint256 buyLots, uint256 buyOrders,
        bool hasSell, int256 sellTick, uint256 sellLots, uint256 sellOrders
    ) {
        hasBuy = hasBestBuy;
        buyTick = bestBuyTick;
        if (hasBuy) {
            TickLevel storage b = buyLevels[buyTick];
            buyLots = b.totalLots;
            buyOrders = b.orderCount;
        }

        hasSell = hasBestSell;
        sellTick = bestSellTick;
        if (hasSell) {
            TickLevel storage s = sellLevels[sellTick];
            sellLots = s.totalLots;
            sellOrders = s.orderCount;
        }
    }

    /* ---------- Internals: Orders / Levels ---------- */

    function _newOrder(bool isBuy, int256 tick, uint256 lots) internal returns (uint256 id) {
        id = nextOrderId++;
        orders[id] = Order(msg.sender, tick, lots, isBuy, 0, 0, true);
    }

    function _enqueue(bool isBuy, int256 tick, uint256 id) internal {
        TickLevel storage lvl = isBuy ? buyLevels[tick] : sellLevels[tick];

        if (!lvl.exists) {
            _insertTick(isBuy, tick);
            lvl = isBuy ? buyLevels[tick] : sellLevels[tick];
        }

        if (lvl.tail == 0) {
            lvl.head = id;
            lvl.tail = id;
        } else {
            orders[lvl.tail].next = id;
            orders[id].prev = lvl.tail;
            lvl.tail = id;
        }

        lvl.orderCount++;
        lvl.totalLots += orders[id].lotsRemaining;
    }

    function _insertTick(bool isBuy, int256 tick) internal {
        TickLevel storage lvl = isBuy ? buyLevels[tick] : sellLevels[tick];
        lvl.exists = true;
        lvl.prev = NONE;
        lvl.next = NONE;

        if (isBuy) {
            if (!hasBestBuy) {
                hasBestBuy = true;
                bestBuyTick = tick;
                return;
            }
            int256 cur = bestBuyTick;
            if (tick > cur) {
                lvl.next = cur;
                buyLevels[cur].prev = tick;
                bestBuyTick = tick;
                return;
            }
            while (true) {
                int256 nxt = buyLevels[cur].next;
                if (nxt == NONE || tick > nxt) {
                    lvl.prev = cur;
                    lvl.next = nxt;
                    buyLevels[cur].next = tick;
                    if (nxt != NONE) buyLevels[nxt].prev = tick;
                    return;
                }
                cur = nxt;
            }
        } else {
            if (!hasBestSell) {
                hasBestSell = true;
                bestSellTick = tick;
                return;
            }
            int256 cur = bestSellTick;
            if (tick < cur) {
                lvl.next = cur;
                sellLevels[cur].prev = tick;
                bestSellTick = tick;
                return;
            }
            while (true) {
                int256 nxt = sellLevels[cur].next;
                if (nxt == NONE || tick < nxt) {
                    lvl.prev = cur;
                    lvl.next = nxt;
                    sellLevels[cur].next = tick;
                    if (nxt != NONE) sellLevels[nxt].prev = tick;
                    return;
                }
                cur = nxt;
            }
        }
    }

    function _removeHead(bool isBuy, int256 tick) internal {
        TickLevel storage lvl = isBuy ? buyLevels[tick] : sellLevels[tick];
        uint256 id = lvl.head;
        uint256 n = orders[id].next;
        lvl.head = n;
        if (n == 0) lvl.tail = 0;
        else orders[n].prev = 0;
        lvl.orderCount--;
    }

    function _unlinkOrder(bool isBuy, int256 tick, uint256 id) internal {
        TickLevel storage lvl = isBuy ? buyLevels[tick] : sellLevels[tick];
        Order storage o = orders[id];

        if (o.prev == 0) lvl.head = o.next;
        else orders[o.prev].next = o.next;

        if (o.next == 0) lvl.tail = o.prev;
        else orders[o.next].prev = o.prev;

        lvl.orderCount--;
        if (lvl.head == 0) _removeTick(isBuy, tick);
    }

    function _removeTick(bool isBuy, int256 tick) internal {
        TickLevel storage lvl = isBuy ? buyLevels[tick] : sellLevels[tick];
        int256 p = lvl.prev;
        int256 n = lvl.next;

        if (isBuy) {
            if (p == NONE) bestBuyTick = n;
            else buyLevels[p].next = n;
            if (n != NONE) buyLevels[n].prev = p;
            if (bestBuyTick == NONE) hasBestBuy = false;
            delete buyLevels[tick];
        } else {
            if (p == NONE) bestSellTick = n;
            else sellLevels[p].next = n;
            if (n != NONE) sellLevels[n].prev = p;
            if (bestSellTick == NONE) hasBestSell = false;
            delete sellLevels[tick];
        }
    }

    /* ---------- Convenience Views ---------- */

    function getBestTicks() external view returns (bool, int256, bool, int256) {
        return (hasBestBuy, bestBuyTick, hasBestSell, bestSellTick);
    }

    function getLevel(bool isBuy, int256 tick) external view returns (
        bool exists,
        int256 prev,
        int256 next,
        uint256 head,
        uint256 tail,
        uint256 orderCount,
        uint256 totalLots
    ) {
        TickLevel storage l = isBuy ? buyLevels[tick] : sellLevels[tick];
        return (l.exists, l.prev, l.next, l.head, l.tail, l.orderCount, l.totalLots);
    }
}
