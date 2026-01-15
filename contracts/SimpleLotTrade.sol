// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/*
  SimpleLotrade v0.6.3 (Design / Testnet)
  By PseudoDeterminist
  See README at https://github.com/PseudoDeterminist/SimpleLotTrade for details.
*/

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/* ===================== Lot CLOB ===================== */

contract SimpleLotrade {
    using SafeERC20 for IERC20;
    // Tick range: -464 .. +1855 (5 decades * 464 ticks/decade)
    int256 private constant MIN_TICK = -464; // 0.1 TETC per lot; 0.00001 TETC per TKN
    int256 private constant MAX_TICK =  1855; // 9950 TETC per lot; 0.995 TETC per TKN
    uint256 private constant MAX_LOTS = 100000;

    int256 private constant NONE = type(int256).min;

    IERC20 public immutable TETC;    // quote token (18 decimals)
    IERC20 public immutable TKN10K;  // base token (0 decimals, integer lots)

    // Event integrity chain (increments once per emitted event)
    uint256 public historySeq;
    bytes32 public historyHash;

    // Oracle
    int256 public lastTradeTick;
    uint256 public lastTradePrice;
    uint256 public lastTradeBlock;
    int256 public bestBuyTick;
    int256 public bestSellTick;

    // Running escrow totals (resting maker escrows)
    uint256 public bookEscrowTETC;     // total TETC Escrowed in buy orders
    uint256 public bookEscrowTKN10K;   // total TKN10K Escrowed in sell orders
    uint256 public bookAskTKN10K;      // total TKN10K asked in buy orders
    uint256 public bookAskTETC;        // total TETC asked in sell orders

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
        uint256 lots,                   // if isBuy: TKN10K Ask placed; else TKN10K Escrowed
        uint256 value                   // if isBuy: TETC Escrowed; else TETC Ask placed
    );

    event OrderCanceled(
        uint256 indexed seq,
        bytes32 indexed newHash,
        uint256 indexed orderId,
        address owner,
        bool isBuy,
        int256 tick,
        uint256 lotsCanceled,           // if isBuy: TKN10K Ask canceled; else TKN10K Escrow refunded
        uint256 valueCanceled           // if isBuy: TETC Escrow refunded; else TETC Ask canceled
    );

    // One Trade event per maker fill (FOK taker may generate multiple)
    event Trade(
        uint256 indexed seq,
        bytes32 indexed newHash,
        uint256 indexed orderId,
        address taker,
        address maker,
        bool takerIsBuy,
        int256 tick,
        uint256 pricePerLot,
        uint256 lotsFilled,
        uint256 valueFilled,
        uint256 lotsRemainingAfter,      // if maker.isBuy: TKN10K Ask remaining; else TKN10K Escrow remaining
        uint256 valueRemainingAfter      // if maker.isBuy: TETC Escrow remaining; else TETC Ask remaining
    );

    /* -------------------- Order book data -------------------- */

    struct Order {
        bool exists;
        address owner;
        int256 tick;
        uint256 lotsRemaining;           // if isBuy: TKN10K Ask remaining; else TKN10K Escrow remaining
        uint256 valueRemaining;          // if isBuy: TETC Escrow remaining; else TETC Ask remaining
        bool isBuy;
        uint256 prev;
        uint256 next;
    }

    struct TickLevel {
        bool exists;
        uint256 price;
        int256 prev;
        int256 next;
        uint256 head;
        uint256 tail;
        uint256 orderCount;
        uint256 totalLots;               // if buyLevel: TKN10K Ask total; else TKN10K Escrow total
        uint256 totalValue;              // if buyLevel: TETC Escrow total; else TETC Ask total
    }

    uint256 public nextOrderId = 1;

    mapping(uint256 => Order) public orders;
    mapping(int256 => TickLevel) public buyLevels;
    mapping(int256 => TickLevel) public sellLevels;

    // Book return structs
    struct BookLevel {
        int256 tick;
        uint256 price;
        uint256 totalLots;               // if buyLevel: TKN10K Ask total; else TKN10K Escrow total
        uint256 totalValue;              // if buyLevel: TETC Escrow total; else TETC Ask total
        uint256 orderCount;
    }

    struct BookOrder {
        uint256 id;
        address owner;
        int256 tick;
        uint256 price;
        uint256 lotsRemaining;
        uint256 valueRemaining;
    }

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
        // historySeq defaults to 0, historyHash defaults to 0x00..00
    }

    /* -------------------- Price -------------------- */

    function priceAtTick(int256 tick) public pure returns (uint256 result) {
        require(tick >= MIN_TICK && tick <= MAX_TICK, "tick out of range");

        uint256 t = uint256(tick - MIN_TICK); // safe because of require above
        uint256 d = t / 464;                  // decade index (0..4)
        uint256 r = t % 464;                  // mantissa index (0..463)

        uint256 i = r * 2;
        uint256 m = (uint256(uint8(MANT[i])) << 8) | uint256(uint8(MANT[i + 1]));

        uint256 factor;
        if (d == 0) factor = 1e14;       //    0.1 to      0.995 TETC per lot = 0.00001 to  0.0000995 TETC per Base TKN
        else if (d == 1) factor = 1e15;  //      1 to      9.95  TETC per lot = 0.0001  to  0.000995  TETC per Base TKN
        else if (d == 2) factor = 1e16;  //     10 to     99.5   TETC per lot = 0.001   to  0.00995   TETC per Base TKN
        else if (d == 3) factor = 1e17;  //    100 to    995     TETC per lot = 0.01    to  0.0995    TETC per Base TKN
        else factor = 1e18;              //   1000 to   9950     TETC per lot = 0.1     to  0.995     TETC per Base TKN

        result = factor * m;
    }

    /* -------------------- Hash chain helpers -------------------- */

    function _chainHash(bytes32 recordHash) internal returns (bytes32) {
        return historyHash = keccak256(abi.encodePacked(historyHash, recordHash));
    }

    function _emitPlaced(
        uint256 orderId,
        address owner,
        bool isBuy,
        int256 tick,
        uint256 lots,
        uint256 value
    ) internal {
        ++historySeq;
        bytes32 rec = keccak256(abi.encode(EVT_PLACE, historySeq, orderId, owner, isBuy, tick, lots, value));
        emit OrderPlaced(historySeq, _chainHash(rec), orderId, owner, isBuy, tick, lots, value);
    }

    function _emitCanceled(
        uint256 orderId,
        address owner,
        bool isBuy,
        int256 tick,
        uint256 lotsCanceled,
        uint256 valueCanceled
    ) internal {
        ++historySeq;
        bytes32 rec = keccak256(abi.encode(EVT_CANCEL, historySeq, orderId, owner, isBuy, tick, lotsCanceled, valueCanceled));
        emit OrderCanceled(historySeq, _chainHash(rec), orderId, owner, isBuy, tick, lotsCanceled, valueCanceled);
    }

    function _emitTrade(
        uint256 orderId,
        address taker,
        address maker,
        bool takerIsBuy,
        int256 tick,
        uint256 pricePerLot,
        uint256 lotsFilled,
        uint256 valueFilled,
        uint256 lotsRemainingAfter,
        uint256 valueRemainingAfter
    ) internal {
        ++historySeq;
        bytes32 rec = keccak256(
            abi.encode(
                EVT_TRADE,
                historySeq,
                orderId,
                taker,
                maker,
                takerIsBuy,
                tick,
                pricePerLot,
                lotsFilled,
                valueFilled,
                lotsRemainingAfter,
                valueRemainingAfter
            )
        );
        emit Trade(
            historySeq,
            _chainHash(rec),
            orderId,
            taker,
            maker,
            takerIsBuy,
            tick,
            pricePerLot,
            lotsFilled,
            valueFilled,
            lotsRemainingAfter,
            valueRemainingAfter
        );
    }

    /* -------------------- Maker Orders (escrow on placement) -------------------- */

    function placeBuy(int256 tick, uint256 lots) external nonReentrant returns (uint256 id) {
        require(lots > 0 && lots < MAX_LOTS, "invalid lots");
        require(bestSellTick == NONE || bestSellTick > tick, "crossing sell book -- consider takeBuyFOK");
        require(tick >= MIN_TICK && tick <= MAX_TICK, "tick out of range");

        uint256 price = priceAtTick(tick);
        uint256 cost = lots * price;

        // Escrow TETC in this contract
        TETC.safeTransferFrom(msg.sender, address(this), cost); // reverts on insufficient balance/allowance

        id = _newOrder(true, tick, lots, cost);
        _enqueue(true, tick, price, lots, cost, id);

        // Track buy escrow (global)
        bookEscrowTETC += cost;
        bookAskTKN10K += lots;

        _emitPlaced(id, msg.sender, true, tick, lots, cost);
    }

    function placeSell(int256 tick, uint256 lots) external nonReentrant returns (uint256 id) {
        require(lots > 0 && lots < MAX_LOTS, "invalid lots");
        require(bestBuyTick == NONE || bestBuyTick < tick, "crossing buy book -- consider takeSellFOK");
        require(tick >= MIN_TICK && tick <= MAX_TICK, "tick out of range");

        // Escrow TKN10K lots in this contract
        TKN10K.safeTransferFrom(msg.sender, address(this), uint256(lots));  // reverts on insufficient balance/allowance

        uint256 price = priceAtTick(tick);
        uint256 value = lots * price;

        id = _newOrder(false, tick, lots, value);
        _enqueue(false, tick, price, lots, value, id);

        // Track sell escrow (global). Per-level is already totalLots.
        bookEscrowTKN10K += lots;
        bookAskTETC += value;

        _emitPlaced(id, msg.sender, false, tick, lots, value);
    }

    function cancel(uint256 id) external nonReentrant {
        Order storage o = orders[id];
        require(o.exists && o.owner == msg.sender, "not owner");

        uint256 lotsRemaining = o.lotsRemaining;
        uint256 valueRemaining = o.valueRemaining;

        // Refund remaining escrow
        if (o.isBuy) {
            buyLevels[o.tick].totalLots -= lotsRemaining;
            buyLevels[o.tick].totalValue -= valueRemaining;
            bookEscrowTETC -= valueRemaining;
            bookAskTKN10K -= lotsRemaining;

            TETC.safeTransfer(msg.sender, valueRemaining);   // only after state updates
        } else {
            sellLevels[o.tick].totalLots -= lotsRemaining;
            sellLevels[o.tick].totalValue -= valueRemaining;
            bookAskTETC -= valueRemaining;
            bookEscrowTKN10K -= lotsRemaining;

            TKN10K.safeTransfer(msg.sender, lotsRemaining);   // only after state updates
        }

        _unlinkOrder(o.isBuy, o.tick, id);
        _emitCanceled(id, msg.sender, o.isBuy, o.tick, lotsRemaining, valueRemaining);

        delete orders[id];
    }

    /* -------------------- Taker FOK -------------------- */

    function takeBuyFOK(int256 limitTick, uint256 lots, uint256 maxTetcIn) external nonReentrant {
        require(lots > 0, "You requested zero lots");
        require(bestSellTick != NONE, "There are no sell orders on book");
        require(lots <= bookEscrowTKN10K, "insufficient sell orders on book");

        TETC.safeTransferFrom(msg.sender, address(this), maxTetcIn); // escrow maxTetcIn. reverts on insufficient balance/allowance

        uint256 remain = lots;
        uint256 spent = 0;

        int256 t = bestSellTick;
        int256 lastFilledTick;    // internal tracking, see lastTradeTick for global

        while (remain > 0) {
            require(t <= limitTick, "FOK");
            TickLevel storage lvl = sellLevels[t];

            uint256 price = priceAtTick(t);

            while (remain > 0) {
                uint256 oid = lvl.head;
                if (oid == 0) break;

                Order storage m = orders[oid];
                uint256 f = m.lotsRemaining > remain ? remain : m.lotsRemaining;

                uint256 pay = f * price;

                // Slippage guard: total quote spent cannot exceed maxTetcIn
                spent += pay;
                require(spent <= maxTetcIn, "slippage");

                // Update balances
                m.lotsRemaining -= f;
                m.valueRemaining -= pay;

                lvl.totalLots -= f;
                bookEscrowTKN10K -= f;
                lvl.totalValue -= pay;
                bookAskTETC -= pay;

                remain -= f;

                // Contract delivers TETC to maker (seller) after state updates
                TETC.safeTransfer(m.owner, pay);

                // Contract releases escrowed TKN10K to taker (buyer) after state updates
                TKN10K.safeTransfer(msg.sender, f);

                _emitTrade(oid, msg.sender, m.owner, true, t, price, f, pay, m.lotsRemaining, m.valueRemaining);

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
        lastTradePrice = priceAtTick(lastFilledTick);
        lastTradeBlock = block.number;
    }

    function takeSellFOK(int256 limitTick, uint256 lots, uint256 minTetcOut) external nonReentrant {
        require(lots > 0, "You requested zero lots");
        require(bestBuyTick != NONE, "There are no buy orders on book");
        require(minTetcOut <= bookEscrowTETC, "insufficient buy orders on book");

        TKN10K.safeTransferFrom(msg.sender, address(this), lots); // escrow TKN10K. reverts on insufficient balance/allowance

        uint256 remain = lots;
        uint256 got = 0;

        int256 t = bestBuyTick;
        int256 lastFilledTick;     // internal tracking, see lastTradeTick for global

        while (remain > 0) {
            require(t >= limitTick, "FOK");
            TickLevel storage lvl = buyLevels[t];

            uint256 price = priceAtTick(t);

            while (remain > 0) {
                uint256 oid = lvl.head;
                if (oid == 0) break;

                Order storage m = orders[oid];
                uint256 f = m.lotsRemaining > remain ? remain : m.lotsRemaining;

                uint256 receiveAmt = f * price;
                got += receiveAmt;

                // Update balances
                m.lotsRemaining -= f;
                m.valueRemaining -= receiveAmt;

                lvl.totalLots -= f;
                bookAskTKN10K -= f;
                lvl.totalValue -= receiveAmt;
                bookEscrowTETC -= receiveAmt;

                remain -= f;

                // Contract delivers TKN10K to maker (buyer) after state updates
                TKN10K.safeTransfer(m.owner, f);

                // Contract releases escrowed TETC to taker (seller) after state updates
                TETC.safeTransfer(msg.sender, receiveAmt);
                

                _emitTrade(oid, msg.sender, m.owner, false, t, price, f, receiveAmt, m.lotsRemaining, m.valueRemaining);

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

        // Slippage guard: total quote received cannot be less than minTetcOut
        require(got >= minTetcOut, "slippage");

        lastTradeTick = lastFilledTick;
        lastTradePrice = priceAtTick(lastFilledTick);
        lastTradeBlock = block.number;
    }

    /* -------------------- Internals: Orders / Levels -------------------- */

    function _newOrder(bool isBuy, int256 tick, uint256 lots, uint256 value) internal returns (uint256 id) {
        id = nextOrderId++;
        orders[id] = Order(true, msg.sender, tick, lots, value, isBuy, 0, 0);
    }

    function _enqueue(bool isBuy, int256 tick, uint256 price,uint256 lots, uint256 value, uint256 id) internal {
        TickLevel storage lvl = isBuy ? buyLevels[tick] : sellLevels[tick];

        if (!lvl.exists) {
            _insertTick(isBuy, tick, price);
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
        lvl.totalValue += value;
        lvl.totalLots += lots;
    }

    function _insertTick(bool isBuy, int256 tick, uint256 price) internal {
        TickLevel storage lvl = isBuy ? buyLevels[tick] : sellLevels[tick];
        lvl.exists = true;
        lvl.price = price;
        lvl.prev = NONE;
        lvl.next = NONE;

        if (isBuy) {
            if (bestBuyTick == NONE) {
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
            if (bestSellTick == NONE) {
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
        lvl.totalLots -= o.lotsRemaining;
        lvl.totalValue -= o.valueRemaining;
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
            delete buyLevels[tick];
        } else {
            if (p == NONE) bestSellTick = n;
            else sellLevels[p].next = n;
            if (n != NONE) sellLevels[n].prev = p;
            delete sellLevels[tick];
        }
    }

    /* -------------------- Misc views -------------------- */

    function getBuyBook(uint256 maxLevels) external view returns (BookLevel[] memory out, uint256 n)
    {
        return getBook(true, maxLevels);
    }

    function getSellBook(uint256 maxLevels) external view returns (BookLevel[] memory out, uint256 n)
    {
        return getBook(false, maxLevels);
    }

    function getBuyOrders(uint256 maxOrders) external view returns (BookOrder[] memory out, uint256 n)
    {
        return getOrders(true, maxOrders);
    }

    function getSellOrders(uint256 maxOrders) external view returns (BookOrder[] memory out, uint256 n)
    {
        return getOrders(false, maxOrders);
    }

    function getBook(bool isBuy, uint256 maxLevels)
        internal
        view
        returns (BookLevel[] memory out, uint256 n)
    {
        if (maxLevels == 0) return (new BookLevel[](0), 0);

        if (isBuy) {
            if (bestBuyTick == NONE) return (new BookLevel[](0), 0);
        } else {
            if (bestSellTick == NONE) return (new BookLevel[](0), 0);
        }

        out = new BookLevel[](maxLevels);
        n = 0;

        if (isBuy) {
            int256 t = bestBuyTick;
            while (t != NONE && n < maxLevels) {
                TickLevel storage lvl = buyLevels[t];
                if (lvl.totalLots > 0) out[n++] = BookLevel(t, lvl.price,lvl.totalLots, lvl.totalValue, lvl.orderCount);
                t = lvl.next;
            }
        } else {
            int256 t = bestSellTick;
            while (t != NONE && n < maxLevels) {
                TickLevel storage lvl = sellLevels[t];
                if (lvl.totalLots > 0) out[n++] = BookLevel(t, lvl.price, lvl.totalLots, lvl.totalValue, lvl.orderCount);
                t = lvl.next;
            }
        }
    }

    function getOrders(bool isBuy, uint256 maxOrders)
        internal
        view
        returns (BookOrder[] memory out, uint256 n)
    {
        if (maxOrders == 0) return (new BookOrder[](0), 0);

        int256 t = isBuy ? bestBuyTick : bestSellTick;
        if (t == NONE) return (new BookOrder[](0), 0);

        out = new BookOrder[](maxOrders);
        n = 0;

        while (t != NONE && n < maxOrders) {
            TickLevel storage lvl = isBuy ? buyLevels[t] : sellLevels[t];
            uint256 id = lvl.head;
            uint256 price = lvl.price;

            while (id != 0 && n < maxOrders) {
                Order storage o = orders[id];
                if (o.lotsRemaining > 0) {
                    out[n++] = BookOrder(id, o.owner, t, price, o.lotsRemaining, o.valueRemaining);
                }
                id = o.next;
            }

            t = lvl.next;
        }
    }

    function getTopOfBook() external view returns (
        int256, uint256, uint256,
        int256, uint256, uint256
    ) {
        uint256 buyLots;
        uint256 buyOrders;
        uint256 sellLots;
        uint256 sellOrders;

        if (bestBuyTick != NONE) {
            TickLevel storage b = buyLevels[bestBuyTick];
            buyLots = b.totalLots;
            buyOrders = b.orderCount;
        }

        if (bestSellTick != NONE) {
            TickLevel storage s = sellLevels[bestSellTick];
            sellLots = s.totalLots;
            sellOrders = s.orderCount;
        }

        return (bestBuyTick, buyLots, buyOrders, bestSellTick, sellLots, sellOrders);
    }

    function getOracle() external view returns (int256, int256, int256, uint256, uint256) {
        return (bestBuyTick, bestSellTick, lastTradeTick, lastTradeBlock, lastTradePrice);
    }

    function getEscrowTotals() external view returns (uint256 buyTETC, uint256 sellTKN10K) {
        return (bookEscrowTETC, bookEscrowTKN10K);
    }
}
