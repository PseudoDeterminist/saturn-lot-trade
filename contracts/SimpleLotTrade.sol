// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/*
  SimpleLotTrade v0.6.2 (Design / Mordor Testnet)
  -----------------------------------------------
  Core goals:
  - This is a Test Contract version, using test tokens we have created
      * TETC (Test ETC) as quote token and TKN10K (Test Token 10K) as base Lot token
      * TKN is base token but we wrap that in integer TKN10K lots (1 lot = 10,000 TKN)
  - Price grid:
      * 464 ticks exponential growth curve from 1000 to 9950, repeating at "decades"  every 10x price 
      * Approximately 0.5% increase per tick
      * Mantissa table: 464 uint16 values (1000..9950) = 1 decade packed big-endian into bytes constant
      * Tick 0 price = 1e18 (1.000 TETC per lot)
      * Tick range: [-464, +1392] (5 decades down/up)
  - Tick-only Central Limit Order Book for TKN10K lots (decimals=0), priced in TETC (18 decimals)
  - Fill Or Kill takers only
  - No internal balances:
      * Makers escrow tokens in the contract on order placement
      * Escrow released on fill/partial fill/cancel
  - Events + integrity:
      * historySeq increments per emitted event
      * historyHash chains over record hashes of each emitted event
      * each event includes (seq, newHash) for easy verification
*/

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/* ===================== Lot CLOB ===================== */

contract SimpleLotTrade {
    // Tick range: -464 .. +464*3
    int256 private constant MIN_TICK = -464;
    int256 private constant MAX_TICK =  1392;

    int256 private constant NONE = type(int256).min;

    IERC20 public immutable TETC;    // quote token (18 decimals)
    IERC20 public immutable TKN10K;  // base token (0 decimals, integer lots)

    // Event integrity chain (increments once per emitted event)
    uint256 public historySeq; // defaults to 0
    bytes32 public historyHash; // defaults to 0x00..00

    // Oracle
    int256 public lastTradeTick;
    uint256 public lastTradeBlock;

    // Reentrancy guard (token transfers)
    uint256 private _lock = 1;
    modifier nonReentrant() {
        require(_lock == 1, "reentrancy");
        _lock = 2;
        _;
        _lock = 1;
    }

    /* -------------------- Events -------------------- */

    // Event type tags used in hash records
    uint8 private constant EVT_PLACE  = 1;
    uint8 private constant EVT_CANCEL = 2;
    uint8 private constant EVT_TRADE  = 3;

    event OrderPlaced(
        uint256 indexed seq,
        bytes32 indexed newHash,
        uint256 indexed orderId,
        address owner,
        bool isBuy,
        int256 tick,
        uint256 lots,
        uint256 escrowAmount
    );

    event OrderCanceled(
        uint256 indexed seq,
        bytes32 indexed newHash,
        uint256 indexed orderId,
        address owner,
        bool isBuy,
        int256 tick,
        uint256 lotsCanceled,
        uint256 refundAmount
    );

    // One Trade event per maker fill (FOK taker may generate multiple)
    event Trade(
        uint256 indexed seq,
        bytes32 indexed newHash,
        uint256 indexed makerOrderId,
        address taker,
        address maker,
        bool takerIsBuy,
        int256 tick,
        uint256 lotsFilled,
        uint256 pricePerLot,
        uint256 quoteAmount,
        uint256 makerLotsRemainingAfter
    );

    /* -------------------- Order book data -------------------- */

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

    /* -------------------- Price grid tables -------------------- */

    // Packed mantissa bytes (464 uint16, big-endian, 2 bytes each)
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

    constructor(address tetcToken, address tkn10kToken) {
        require(tetcToken != address(0), "zero TETC");
        require(tkn10kToken != address(0), "zero TKN10K");
        TETC = IERC20(tetcToken);
        TKN10K = IERC20(tkn10kToken);
        bestBuyTick = NONE;
        bestSellTick = NONE;
    }

    /* -------------------- Price -------------------- */

    function priceAtTick(int256 tick) public pure returns (uint256 result) {
    require(tick >= MIN_TICK && tick <= MAX_TICK, "tick out of range");

    uint256 t = uint256(tick - MIN_TICK); // safe because of require above
    uint256 d = t / 464;                  // decade index (0..4)
    uint256 r = t % 464;                  // mantissa index

    uint256 i = r * 2;
    uint256 m = (uint256(uint8(MANT[i])) << 8) | uint256(uint8(MANT[i + 1]));

    uint256 factor;
    if (d == 0) factor = 1e14;
    else if (d == 1) factor = 1e15;
    else if (d == 2) factor = 1e16;
    else if (d == 3) factor = 1e17;
    else factor = 1e18; // d == 4

    result = factor * m;
}

    /* -------------------- Hash chain helpers -------------------- */

    function _chainHash(bytes32 recordHash) internal returns (uint256 seq, bytes32 newHash) {
        // We include seq inside recordHash construction (see callers).
        // Here we just advance the chain.
        seq = historySeq + 1;
        newHash = keccak256(abi.encodePacked(historyHash, recordHash));
        historySeq = seq;
        historyHash = newHash;
    }

    function _emitPlaced(
        uint256 orderId,
        address owner,
        bool isBuy,
        int256 tick,
        uint256 lots,
        uint256 escrowAmount
    ) internal {
        uint256 seq = historySeq + 1;
        bytes32 rec = keccak256(abi.encode(EVT_PLACE, seq, orderId, owner, isBuy, tick, lots, escrowAmount));
        (, bytes32 nh) = _chainHash(rec);
        emit OrderPlaced(seq, nh, orderId, owner, isBuy, tick, lots, escrowAmount);
    }

    function _emitCanceled(
        uint256 orderId,
        address owner,
        bool isBuy,
        int256 tick,
        uint256 lotsCanceled,
        uint256 refundAmount
    ) internal {
        uint256 seq = historySeq + 1;
        bytes32 rec = keccak256(abi.encode(EVT_CANCEL, seq, orderId, owner, isBuy, tick, lotsCanceled, refundAmount));
        (, bytes32 nh) = _chainHash(rec);
        emit OrderCanceled(seq, nh, orderId, owner, isBuy, tick, lotsCanceled, refundAmount);
    }

    function _emitTrade(
        uint256 makerOrderId,
        address taker,
        address maker,
        bool takerIsBuy,
        int256 tick,
        uint256 lotsFilled,
        uint256 pricePerLot,
        uint256 quoteAmount,
        uint256 makerLotsRemainingAfter
    ) internal {
        uint256 seq = historySeq + 1;
        bytes32 rec = keccak256(
            abi.encode(
                EVT_TRADE,
                seq,
                makerOrderId,
                taker,
                maker,
                takerIsBuy,
                tick,
                lotsFilled,
                pricePerLot,
                quoteAmount,
                makerLotsRemainingAfter
            )
        );
        (, bytes32 nh) = _chainHash(rec);
        emit Trade(
            seq,
            nh,
            makerOrderId,
            taker,
            maker,
            takerIsBuy,
            tick,
            lotsFilled,
            pricePerLot,
            quoteAmount,
            makerLotsRemainingAfter
        );
    }

    /* -------------------- Maker Orders (escrow on placement) -------------------- */

    function placeBuy(int256 tick, uint256 lots) external nonReentrant returns (uint256 id) {
        require(lots > 0, "zero lots");
        require(!hasBestSell || bestSellTick > tick, "crossing sell book");
        require(tick >= MIN_TICK && tick <= MAX_TICK, "tick out of range");

        uint256 price = priceAtTick(tick);
        uint256 cost = uint256(lots) * price;

        // Escrow TETC in this contract
        require(TETC.transferFrom(msg.sender, address(this), cost), "TETC transferFrom failed");

        id = _newOrder(true, tick, lots);
        _enqueue(true, tick, id);

        _emitPlaced(id, msg.sender, true, tick, lots, cost);
    }

    function placeSell(int256 tick, uint256 lots) external nonReentrant returns (uint256 id) {
        require(lots > 0, "zero lots");
        require(!hasBestBuy || bestBuyTick < tick, "crossing buy book");
        require(tick >= MIN_TICK && tick <= MAX_TICK, "tick out of range");

        // Escrow TKN10K lots in this contract
        require(TKN10K.transferFrom(msg.sender, address(this), uint256(lots)), "TKN10K transferFrom failed");

        id = _newOrder(false, tick, lots);
        _enqueue(false, tick, id);

        _emitPlaced(id, msg.sender, false, tick, lots, lots);
    }

    function cancel(uint256 id) external nonReentrant {
        Order storage o = orders[id];
        require(o.exists && o.owner == msg.sender, "not owner");

        uint256 refundAmount;
        uint256 lotsCanceled = o.lotsRemaining;

        // Refund remaining escrow
        if (o.isBuy) {
            refundAmount = uint256(o.lotsRemaining) * priceAtTick(o.tick);
            require(TETC.transfer(msg.sender, refundAmount), "TETC refund failed");
            buyLevels[o.tick].totalLots -= o.lotsRemaining;
        } else {
            refundAmount = uint256(o.lotsRemaining);
            require(TKN10K.transfer(msg.sender, refundAmount), "TKN10K refund failed");
            sellLevels[o.tick].totalLots -= o.lotsRemaining;
        }

        _unlinkOrder(o.isBuy, o.tick, id);
        _emitCanceled(id, msg.sender, o.isBuy, o.tick, lotsCanceled, refundAmount);

        delete orders[id];
    }

    /* -------------------- Taker FOK -------------------- */

    function takeBuyFOK(int256 limitTick, uint256 lots, uint256 maxQuoteIn, uint256 deadlineBlock) external nonReentrant {
        require(block.number <= deadlineBlock, "expired");
        require(hasBestSell, "no sells");
        require(lots > 0, "zero lots");
    
        uint256 remain = lots;
        uint256 spent = 0;
    
        int256 t = bestSellTick;
        int256 lastFilledTick;
    
        while (remain > 0) {
            require(t <= limitTick, "FOK");
            TickLevel storage lvl = sellLevels[t];
            require(lvl.head != 0, "empty level");
    
            uint256 price = priceAtTick(t); // once per tick
    
            while (remain > 0) {
                uint256 oid = lvl.head;
                if (oid == 0) break;
    
                Order storage m = orders[oid];
                uint256 f = m.lotsRemaining > remain ? remain : m.lotsRemaining;
    
                uint256 pay = f * price;
    
                // Slippage guard: total quote spent cannot exceed maxQuoteIn
                spent += pay;
                require(spent <= maxQuoteIn, "slippage");
    
                // Taker delivers TETC to maker (seller)
                require(TETC.transferFrom(msg.sender, m.owner, pay), "TETC pay failed");
    
                // Contract releases escrowed TKN10K to taker
                require(TKN10K.transfer(msg.sender, f), "TKN10K deliver failed");
    
                m.lotsRemaining -= f;
                lvl.totalLots -= f;
                remain -= f;
    
                _emitTrade(oid, msg.sender, m.owner, true, t, f, price, pay, m.lotsRemaining);
    
                lastFilledTick = t;
    
                if (m.lotsRemaining == 0) {
                    _removeHead(false, t);
                    delete orders[oid];
                }
            }
    
            if (lvl.head == 0) {
                int256 nxt = lvl.next;
                _removeTick(false, t);
                if (nxt == NONE) break;
                t = nxt;
            }
        }
    
        require(remain == 0, "unfilled");
    
        lastTradeTick = lastFilledTick;
        lastTradeBlock = block.number;
    }
    
    function takeSellFOK(int256 limitTick, uint256 lots, uint256 minQuoteOut, uint256 deadlineBlock) external nonReentrant {
        require(block.number <= deadlineBlock, "expired");
        require(hasBestBuy, "no buys");
        require(lots > 0, "zero lots");
    
        uint256 remain = lots;
        uint256 got = 0;
    
        int256 t = bestBuyTick;
        int256 lastFilledTick;
    
        while (remain > 0) {
            require(t >= limitTick, "FOK");
            TickLevel storage lvl = buyLevels[t];
            require(lvl.head != 0, "empty level");
    
            uint256 price = priceAtTick(t); // once per tick
    
            while (remain > 0) {
                uint256 oid = lvl.head;
                if (oid == 0) break;
    
                Order storage m = orders[oid];
                uint256 f = m.lotsRemaining > remain ? remain : m.lotsRemaining;
    
                uint256 receiveAmt = f * price;
                got += receiveAmt;
    
                // Taker delivers TKN10K to maker (buyer)
                require(TKN10K.transferFrom(msg.sender, m.owner, f), "TKN10K pay failed");
    
                // Contract releases escrowed TETC to taker
                require(TETC.transfer(msg.sender, receiveAmt), "TETC deliver failed");
    
                m.lotsRemaining -= f;
                lvl.totalLots -= f;
                remain -= f;
    
                _emitTrade(oid, msg.sender, m.owner, false, t, f, price, receiveAmt, m.lotsRemaining);
    
                lastFilledTick = t;
    
                if (m.lotsRemaining == 0) {
                    _removeHead(true, t);
                    delete orders[oid];
                }
            }
    
            if (lvl.head == 0) {
                int256 nxt = lvl.next;
                _removeTick(true, t);
                if (nxt == NONE) break;
                t = nxt;
            }
        }
    
        require(remain == 0, "unfilled");
        require(got >= minQuoteOut, "slippage");
    
        lastTradeTick = lastFilledTick;
        lastTradeBlock = block.number;
    }

    /* -------------------- Full Book + Depth Views (single-pass, bounded) -------------------- */

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
            int256 tt = bestBuyTick;
            while (tt != NONE && n < maxOrders) {
                TickLevel storage lvl = buyLevels[tt];
                uint256 oid = lvl.head;
                while (oid != 0 && n < maxOrders) {
                    Order storage o = orders[oid];
                    out[n++] = BookOrder(oid, o.owner, o.tick, o.lotsRemaining);
                    oid = o.next;
                }
                tt = lvl.next;
            }
        } else {
            int256 tt = bestSellTick;
            while (tt != NONE && n < maxOrders) {
                TickLevel storage lvl = sellLevels[tt];
                uint256 oid = lvl.head;
                while (oid != 0 && n < maxOrders) {
                    Order storage o = orders[oid];
                    out[n++] = BookOrder(oid, o.owner, o.tick, o.lotsRemaining);
                    oid = o.next;
                }
                tt = lvl.next;
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
            int256 tt = bestBuyTick;
            while (tt != NONE && n < maxLevels) {
                TickLevel storage lvl = buyLevels[tt];
                if (lvl.totalLots > 0) out[n++] = BookLevel(tt, lvl.totalLots, lvl.orderCount);
                tt = lvl.next;
            }
        } else {
            int256 tt = bestSellTick;
            while (tt != NONE && n < maxLevels) {
                TickLevel storage lvl = sellLevels[tt];
                if (lvl.totalLots > 0) out[n++] = BookLevel(tt, lvl.totalLots, lvl.orderCount);
                tt = lvl.next;
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

    /* -------------------- Internals: Orders / Levels -------------------- */

    function _newOrder(bool isBuy, int256 tick, uint256 lots) internal returns (uint256 id) {
        id = nextOrderId++;
        orders[id] = Order(msg.sender, tick, lots, isBuy, 0, 0, true);
    }

    function _enqueue(bool isBuy, int256 tick, uint256 id) internal {
        TickLevel storage lvl = isBuy ? buyLevels[tick] : sellLevels[tick];

        if (!lvl.exists) {
            _insertTick(isBuy, tick);
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

    /* -------------------- Misc views -------------------- */

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
