// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Test } from "forge-std/Test.sol";

import { H2Market }  from "../../src/h2/H2Market.sol";
import { H2Oracle }  from "../../src/h2/H2Oracle.sol";
import { IH2Market } from "../../src/h2/IH2Market.sol";
import { IH2Oracle } from "../../src/h2/IH2Oracle.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockAggregatorV3 } from "../mocks/MockAggregatorV3.sol";

contract H2MarketTest is Test {
    H2Market  internal h;
    H2Oracle  internal oracle;
    MockERC20 internal usdm;
    MockAggregatorV3 internal ref;      // primary feed's reference band
    MockAggregatorV3 internal fallbackFeed;

    address internal op     = makeAddr("operator"); // feed operator + market creator
    address internal keeper = makeAddr("keeper");
    address internal carl   = makeAddr("carl");     // funder

    uint256 internal alicePk = 0xA11CE;
    address internal alice;
    uint256 internal bobPk = 0xB0B;
    address internal bob;

    address internal token;
    uint256 internal feedId;
    uint256 internal mkt;

    uint64  internal constant RATE_CAP = 1_500_000_000_000_000; // passes coupled ceiling
    uint256 internal constant RATE_10PCT = 100_000;
    uint256 internal constant TERM = 30 days;

    bytes32 internal DOMAIN_SEPARATOR;
    bytes32 internal constant ORDER_TYPEHASH = keccak256(
        "Order(address user,uint256 marketId,bool isLong,bool isOpen,uint256 size,uint256 leverage,"
        "uint256 targetPrice,uint256 maxSlippageBps,uint64 deadline,uint256 channel,uint256 nonce)"
    );

    uint256 internal _t;
    function _adv(uint256 dt) internal { _t += dt; vm.warp(_t); }

    /// @dev Open a market's deposits (creator sets the rate) and back its pool with lender
    /// capital from carl — the index-lending replacement for the old junior seed.
    function _seedTreasury(uint256 marketId, uint256 amount) internal {
        vm.prank(h.creatorOf(marketId));
        h.setRate(marketId, RATE_10PCT);
        usdm.mint(carl, amount);
        vm.startPrank(carl);
        usdm.approve(address(h), type(uint256).max);
        h.depositFund(marketId, amount);
        vm.stopPrank();
    }

    function _fees() internal pure returns (IH2Market.FeeParams memory) {
        return IH2Market.FeeParams({
            openFlatPpm: 500, openLinearScale: 0, openQuadScale: 0,   // 5 bps open
            closeFlatPpm: 500, closeLinearScale: 0, closeQuadScale: 0, // 5 bps close (> 100ppm dev)
            cutInterceptPpm: 100_000, cutSlopePpm: 100_000, maxCutPpm: 55_000
        });
    }
    function _risk(uint32 liqWidthPpm) internal pure returns (IH2Market.RiskParams memory) {
        return IH2Market.RiskParams({
            priceTick: 1e18, sizeTick: 1e10, notionalScale: 0,
            minLeverage: 100, maxLeverage: 1000,
            maxPositionDuration: 30 days,
            maxPositionNotional: 200_000e18,
            maxOIGross: 0, maxOISkew: 0,
            liqWidthPpm: liqWidthPpm,
            fundingRateCapPerSec: RATE_CAP,
            maxSpreadPpm: 5_000, // ≤ 0.5% operator spread
            termSecs: uint32(TERM),
            staleSpreadK: 6 // ppm per √ms ≈ 2σ for BTC (≈356 ppm at the 4s sentinel)
        });
    }
    function _oracleParams() internal view returns (IH2Market.OracleParams memory) {
        return IH2Market.OracleParams({
            primaryFeedId: uint64(feedId),
            primaryStaleSecs: 300,
            fallbackFeed: address(fallbackFeed),
            fallbackDecimals: 8,
            fallbackMaxAge: 60,
            fbOpenSpreadPpm: 2_000, fbCloseSpreadPpm: 2_000, fbLiqSpreadPpm: 1_000,
            maxDeviationPpm: 100 // 1 bp; open+close flat = 1000 ppm ≥ this
        });
    }

    function setUp() public {
        _t = 1_786_986_000;
        vm.warp(_t);
        alice = vm.addr(alicePk);
        bob   = vm.addr(bobPk);

        usdm  = new MockERC20();
        oracle = new H2Oracle();
        ref = new MockAggregatorV3(8, 50_000e8, block.timestamp);
        fallbackFeed = new MockAggregatorV3(8, 50_000e8, block.timestamp);
        h = new H2Market(address(usdm), address(oracle));
        token = makeAddr("btc");

        vm.prank(op);
        feedId = oracle.createFeed(op, 1e18, RATE_CAP, address(ref), 8, 100_000, 1 hours);

        vm.prank(op);
        mkt = h.createMarket(token, _fees(), _risk(0), _oracleParams());

        // Open deposits, back the pool with lender capital; publish an initial mark.
        _seedTreasury(mkt, 5_000_000e18);
        _pushMark(50_000e18, 0, 0, 0);

        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("H2Market")),
            keccak256(bytes("1")),
            block.chainid,
            address(h)
        ));

        usdm.mint(alice, 1_000_000e18);
        usdm.mint(bob,   1_000_000e18);
        vm.prank(alice); usdm.approve(address(h), type(uint256).max);
        vm.prank(bob);   usdm.approve(address(h), type(uint256).max);
    }

    // ---- helpers ----

    function _refresh(uint256 px1e18) internal {
        ref.setAnswer(int256(px1e18 / 1e10));
        ref.setUpdatedAt(block.timestamp);
        fallbackFeed.setAnswer(int256(px1e18 / 1e10));
        fallbackFeed.setUpdatedAt(block.timestamp);
    }

    /// @dev Plain operator mark push (no orders).
    function _pushMark(uint256 mark, int64 rl, int64 rs, uint32 spread) internal {
        _refresh(mark);
        IH2Oracle.Call[] memory none = new IH2Oracle.Call[](0);
        vm.prank(op);
        oracle.pushWithParams(feedId, mark, rl, rs, spread, none);
    }

    function _sign(uint256 pk, IH2Market.Order memory o) internal view returns (bytes memory) {
        bytes32 sh = keccak256(abi.encode(
            ORDER_TYPEHASH, o.user, o.marketId, o.isLong, o.isOpen, o.size, o.leverage,
            o.targetPrice, o.maxSlippageBps, o.deadline, o.channel, o.nonce));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, sh)));
        return abi.encodePacked(r, s, v);
    }

    function _order(uint256 pk, bool isLong, bool isOpen, uint256 size, uint256 lev,
                    uint256 target, uint256 slip, uint256 nonce)
        internal view returns (IH2Market.Order memory)
    {
        return IH2Market.Order({
            user: vm.addr(pk), marketId: mkt, isLong: isLong, isOpen: isOpen,
            size: size, leverage: lev, targetPrice: target, maxSlippageBps: slip,
            deadline: uint64(block.timestamp + 1 hours), channel: 0, nonce: nonce
        });
    }

    /// @dev Operator commits a mark and attaches one order — the primary pull path.
    function _pushOrder(uint256 mark, IH2Market.Order memory o, bytes memory sig, uint32 spread)
        internal
    {
        _refresh(mark);
        bytes memory payload = abi.encode(o, sig);
        bytes memory data = abi.encode(mkt, uint8(IH2Market.ActionKind.Order_), payload);
        IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
        calls[0] = IH2Oracle.Call({ target: address(h), data: data });
        vm.prank(op);
        oracle.pushWithParams(feedId, mark, 0, 0, spread, calls);
    }

    function _pushLiquidate(uint256 mark, uint256[] memory ids) internal {
        _refresh(mark);
        bytes memory data = abi.encode(mkt, uint8(IH2Market.ActionKind.Liquidate), abi.encode(ids));
        IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
        calls[0] = IH2Oracle.Call({ target: address(h), data: data });
        vm.prank(op);
        oracle.pushAndCall(feedId, mark, calls);
    }

    function _openLong(uint256 pk, uint256 size, uint256 lev, uint256 mark, uint256 nonce)
        internal returns (uint256 id)
    {
        _adv(1);
        IH2Market.Order memory o = _order(pk, true, true, size, lev, mark, 200, nonce);
        _pushOrder(mark, o, _sign(pk, o), 0);
        id = h.activePositionId(vm.addr(pk), mkt);
    }

    // ============================================================
    // market creation + validation
    // ============================================================

    function test_createMarketFreezesAndDerives() public view {
        IH2Market.RiskParams memory r = h.riskParamsOf(mkt);
        assertEq(r.notionalScale, 1e10);
        assertEq(uint256(r.maxOIGross), type(uint128).max);
        assertEq(h.creatorOf(mkt), op);
        assertEq(h.marketOf(mkt).mark, 50_000e18);
    }

    function test_createRejectsAntiSandwichViolation() public {
        IH2Market.FeeParams memory f = _fees();
        f.openFlatPpm = 40; f.closeFlatPpm = 40; // 80 < 100 dev
        vm.prank(op);
        vm.expectRevert(IH2Market.BadMarketParams.selector);
        h.createMarket(token, f, _risk(0), _oracleParams());
    }

    function test_createRejectsTickMismatch() public {
        IH2Market.RiskParams memory r = _risk(0);
        r.priceTick = 1e17; // feed tick is 1e18
        vm.prank(op);
        vm.expectRevert(IH2Market.BadMarketParams.selector);
        h.createMarket(token, _fees(), r, _oracleParams());
    }

    // ============================================================
    // primary path: open / close with formulaic fills
    // ============================================================

    function test_openViaPullPathAppliesSpreadAndFee() public {
        _adv(1);
        // Operator spread 2000 ppm (0.2%); long open pays up: 50_000 × 1.002 = 50_100.
        IH2Market.Order memory o = _order(alicePk, true, true, 1e18, 100, 50_200e18, 200, 0);
        _pushOrder(50_000e18, o, _sign(alicePk, o), 2_000);
        uint256 id = h.activePositionId(alice, mkt);
        assertEq(h.positions(id).entryPrice, 50_100e18);
        // collateral = 500e18 notional/lev minus 5bps open fee on 50_100 notional.
        assertApproxEqAbs(h.positions(id).col, 501e18 - (uint256(50_100e18) * 500 / 1_000_000), 1e12);
    }

    function test_onMarkOnlyFromOracle() public {
        _adv(1);
        IH2Market.Order memory o = _order(alicePk, true, true, 1e18, 100, 50_000e18, 200, 0);
        bytes memory data = abi.encode(mkt, uint8(IH2Market.ActionKind.Order_), abi.encode(o, _sign(alicePk, o)));
        vm.prank(op); // not the oracle
        vm.expectRevert(IH2Market.NotOracle.selector);
        h.onMark(feedId, data);
    }

    function test_openCloseRoundTrip() public {
        uint256 id = _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        uint256 balBefore = usdm.balanceOf(alice);
        // Close at a higher mark; long close receives down 0.2%? spread 0 here.
        _adv(1);
        IH2Market.Order memory o = _order(alicePk, true, false, 1e18, 0, 50_500e18, 200, 1);
        _pushOrder(50_500e18, o, _sign(alicePk, o), 0);
        assertTrue(h.positions(id).closed);
        assertGt(usdm.balanceOf(alice), balBefore); // profited
        assertEq(h.activePositionId(alice, mkt), 0);
    }

    function test_closeRejectsFlippedSide() public {
        _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        _adv(1);
        IH2Market.Order memory o = _order(alicePk, false, false, 1e18, 0, 50_000e18, 200, 1);
        bytes memory sig = _sign(alicePk, o);
        _refresh(50_000e18);
        bytes memory data = abi.encode(mkt, uint8(IH2Market.ActionKind.Order_), abi.encode(o, sig));
        IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
        calls[0] = IH2Oracle.Call({ target: address(h), data: data });
        vm.prank(op);
        // The callback reverts BadUserSig internally, isolated as CallFailed — the mark commits.
        vm.expectEmit(true, false, false, false);
        emit IH2Oracle.CallFailed(feedId, 0, address(h));
        oracle.pushAndCall(feedId, 50_000e18, calls);
        assertFalse(h.positions(h.activePositionId(alice, mkt)).closed);
    }

    // ============================================================
    // deviation gate
    // ============================================================

    function test_deviationGateBlocksOnDisagreement() public {
        _adv(1);
        IH2Market.Order memory o = _order(alicePk, true, true, 1e18, 100, 50_200e18, 200, 0);
        bytes memory sig = _sign(alicePk, o);
        // Primary 50_000, fallback 50_100 → 20 bp apart > 1 bp gate.
        ref.setAnswer(50_000e8); ref.setUpdatedAt(block.timestamp);
        fallbackFeed.setAnswer(50_100e8); fallbackFeed.setUpdatedAt(block.timestamp);
        bytes memory data = abi.encode(mkt, uint8(IH2Market.ActionKind.Order_), abi.encode(o, sig));
        IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
        calls[0] = IH2Oracle.Call({ target: address(h), data: data });
        vm.prank(op);
        vm.expectEmit(true, false, false, false);
        emit IH2Oracle.CallFailed(feedId, 0, address(h)); // DeviationGate inside, isolated
        oracle.pushAndCall(feedId, 50_000e18, calls);
        assertEq(h.activePositionId(alice, mkt), 0);
    }

    function test_marksRecordDuringGatedWindow() public {
        // A disagreeing fallback blocks actions but must NOT block publication.
        _adv(1);
        fallbackFeed.setAnswer(51_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        ref.setAnswer(50_000e8); ref.setUpdatedAt(block.timestamp);
        vm.prank(op);
        oracle.push(feedId, 50_000e18); // succeeds — the ring stays alive
        assertEq(oracle.feedOf(feedId).mark, 50_000e18);
    }

    // ============================================================
    // liquidation: widened threshold + walk-back
    // ============================================================

    function test_liqWidthTriggersEarly() public {
        // Market with a 1% maintenance width.
        vm.prank(op);
        uint256 wmkt = h.createMarket(token, _fees(), _risk(10_000), _oracleParams());
        _seedTreasury(wmkt, 1_000_000e18);
        _adv(1);
        _pushMark(50_000e18, 0, 0, 0);

        // open a 1000x long on wmkt (col ~50e18 on 50_000 notional)
        _adv(1);
        IH2Market.Order memory o = IH2Market.Order({
            user: alice, marketId: wmkt, isLong: true, isOpen: true, size: 1e18, leverage: 1000,
            targetPrice: 50_100e18, maxSlippageBps: 200, deadline: uint64(block.timestamp + 1 hours),
            channel: 0, nonce: 0 });
        bytes memory sig = _sign(alicePk, o);
        _refresh(50_000e18);
        bytes memory data = abi.encode(wmkt, uint8(IH2Market.ActionKind.Order_), abi.encode(o, sig));
        IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
        calls[0] = IH2Oracle.Call({ target: address(h), data: data });
        vm.prank(op); oracle.pushAndCall(feedId, 50_000e18, calls);
        uint256 id = h.activePositionId(alice, wmkt);
        assertFalse(h.positions(id).closed);

        // A dip that leaves the position solvent but inside the 1% maintenance width wipes it.
        _adv(1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        _refresh(49_951e18);
        bytes memory ld = abi.encode(wmkt, uint8(IH2Market.ActionKind.Liquidate), abi.encode(ids));
        IH2Oracle.Call[] memory lc = new IH2Oracle.Call[](1);
        lc[0] = IH2Oracle.Call({ target: address(h), data: ld });
        vm.prank(op); oracle.pushAndCall(feedId, 49_951e18, lc);
        assertTrue(h.positions(id).closed);
    }

    function test_expireForceCloses() public {
        uint256 id = _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        _adv(30 days + 1);
        _pushMark(50_000e18, 0, 0, 0); // keep the feed fresh
        vm.prank(keeper);
        h.expirePosition(id);
        assertTrue(h.positions(id).closed);
    }

    // ============================================================
    // fallback path
    // ============================================================

    // ============================================================
    // self-service: executeAtMark
    // ============================================================

    function test_executeAtMarkOpensAgainstStaleMark() public {
        _openLong(alicePk, 1e18, 100, 50_000e18, 0); // seed nothing special; just advance clock
        // Bob self-service opens 2s after the last mark, no operator involvement.
        _adv(2);
        fallbackFeed.setAnswer(50_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        IH2Market.Order memory o = _order(bobPk, true, true, 1e18, 100, 50_100e18, 200, 0);
        vm.prank(keeper);
        uint256 id = h.executeAtMark(o, _sign(bobPk, o));
        assertEq(h.positions(id).user, bob);
        // entry = mark 50_000 up by (feed spread 0 + staleSpread 6·√2000ms≈268 ppm) → ~50_013,
        // ceil-to-tick ($1) → 50_014.
        assertGe(h.positions(id).entryPrice, 50_013e18);
        assertLe(h.positions(id).entryPrice, 50_015e18);
    }

    function test_executeAtMarkRejectsWhenMarkTooStale() public {
        _adv(5); // last mark now 5s old > 4.095s sentinel gap
        fallbackFeed.setAnswer(50_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        IH2Market.Order memory o = _order(alicePk, true, true, 1e18, 100, 50_200e18, 200, 0);
        vm.expectRevert(IH2Market.MarkTooStale.selector);
        h.executeAtMark(o, _sign(alicePk, o));
    }

    function test_executeAtMarkRejectsWhenFallbackStale() public {
        _adv(2);
        // primary mark 2s old (usable) but fallback not refreshed → no anchor.
        fallbackFeed.setUpdatedAt(block.timestamp - 100);
        IH2Market.Order memory o = _order(alicePk, true, true, 1e18, 100, 50_200e18, 200, 0);
        vm.expectRevert(IH2Market.OracleTooOld.selector);
        h.executeAtMark(o, _sign(alicePk, o));
    }

    function test_executeAtMarkRejectsOnDeviation() public {
        _adv(2);
        // fresh fallback but far from the stale primary mark → gate.
        fallbackFeed.setAnswer(51_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        IH2Market.Order memory o = _order(alicePk, true, true, 1e18, 100, 50_200e18, 200, 0);
        vm.expectRevert(IH2Market.DeviationGate.selector);
        h.executeAtMark(o, _sign(alicePk, o));
    }

    function test_executeAtMarkDisabledWhenKZero() public {
        IH2Market.RiskParams memory r = _risk(0);
        r.staleSpreadK = 0;
        vm.prank(op);
        uint256 dmkt = h.createMarket(token, _fees(), r, _oracleParams());
        _seedTreasury(dmkt, 1_000_000e18);
        _adv(1);
        _refresh(50_000e18);
        vm.prank(op);
        oracle.push(feedId, 50_000e18);
        _adv(2);
        fallbackFeed.setAnswer(50_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        IH2Market.Order memory o = IH2Market.Order({
            user: alice, marketId: dmkt, isLong: true, isOpen: true, size: 1e18, leverage: 100,
            targetPrice: 50_200e18, maxSlippageBps: 200, deadline: uint64(block.timestamp + 1 hours),
            channel: 0, nonce: 0 });
        vm.expectRevert(IH2Market.SelfServiceDisabled.selector);
        h.executeAtMark(o, _sign(alicePk, o));
    }

    function test_staleSpreadGrowsWithAge() public {
        // Bob opens at 1s, Alice-equivalent (via bob nonce) can't reuse; use two markets or
        // compare entry prices at two ages on fresh positions in fresh markets.
        _adv(1);
        fallbackFeed.setAnswer(50_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        IH2Market.Order memory o1 = _order(bobPk, true, true, 1e18, 100, 50_100e18, 200, 0);
        vm.prank(keeper);
        uint256 id1 = h.executeAtMark(o1, _sign(bobPk, o1));
        uint256 e1 = h.positions(id1).entryPrice;

        // A second market, mark refreshed, then aged 4s (near the sentinel) → larger spread.
        vm.prank(op);
        uint256 m2 = h.createMarket(token, _fees(), _risk(0), _oracleParams());
        _seedTreasury(m2, 1_000_000e18);
        _adv(1); _refresh(50_000e18); vm.prank(op); oracle.push(feedId, 50_000e18);
        _adv(4);
        fallbackFeed.setAnswer(50_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        IH2Market.Order memory o2 = IH2Market.Order({
            user: alice, marketId: m2, isLong: true, isOpen: true, size: 1e18, leverage: 100,
            targetPrice: 50_300e18, maxSlippageBps: 200, deadline: uint64(block.timestamp + 1 hours),
            channel: 0, nonce: 0 });
        vm.prank(keeper);
        uint256 id2 = h.executeAtMark(o2, _sign(alicePk, o2));
        // 4s old pays a strictly wider spread than 1s old → higher entry.
        assertGt(h.positions(id2).entryPrice, e1);
    }

    function test_fallbackArmsWhenPrimaryStale() public {
        _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        assertFalse(h.fallbackArmed(mkt));
        _adv(301); // primary now stale
        assertTrue(h.fallbackArmed(mkt));
    }

    function test_fallbackCloseWorksWhenPrimaryDark() public {
        uint256 id = _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        _adv(301);
        fallbackFeed.setAnswer(50_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        IH2Market.Order memory o = _order(alicePk, true, false, 1e18, 0, 49_800e18, 200, 1);
        vm.prank(keeper);
        h.executeAtFallback(o, _sign(alicePk, o));
        assertTrue(h.positions(id).closed);
    }

    function test_fallbackRejectsWhenPrimaryFresh() public {
        _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        _adv(1);
        _refresh(50_000e18);
        IH2Market.Order memory o = _order(alicePk, true, false, 1e18, 0, 49_800e18, 200, 1);
        vm.expectRevert(IH2Market.FallbackNotArmed.selector);
        h.executeAtFallback(o, _sign(alicePk, o));
    }

    // ============================================================
    // treasury (interim) — unbanded-feed deposit gate + waterfall
    // ============================================================

    function test_depositFundRequiresBandedFeed() public {
        // Stand up an unbanded feed + market.
        vm.prank(op);
        uint256 ufeed = oracle.createFeed(op, 1e18, RATE_CAP, address(0), 0, 0, 0);
        IH2Market.OracleParams memory op_ = _oracleParams();
        op_.primaryFeedId = uint64(ufeed);
        vm.prank(op);
        uint256 umkt = h.createMarket(token, _fees(), _risk(0), op_);
        // The banding gate precedes the rate/deposits-open check, so an unbanded market
        // rejects deposits whether or not the creator has set a rate.
        vm.prank(op);
        h.setRate(umkt, RATE_10PCT);
        usdm.mint(carl, 100e18);
        vm.startPrank(carl);
        usdm.approve(address(h), type(uint256).max);
        vm.expectRevert(IH2Market.UnbandedFeed.selector);
        h.depositFund(umkt, 100e18);
        vm.stopPrank();
    }

    function test_fundDepositAndInvariant() public {
        // setUp already seeded 5M of lender principal into mkt; add another deposit.
        IH2Market.TreasuryView memory t0 = h.treasuryOf(mkt);
        usdm.mint(carl, 100_000e18);
        vm.prank(carl);
        h.depositFund(mkt, 100_000e18);

        IH2Market.TreasuryView memory t = h.treasuryOf(mkt);
        // No time has passed, so nothing has accrued: obligation is exactly principal, and
        // the pool backs it to the wei with zero surplus.
        assertEq(t.totalPrincipal, t0.totalPrincipal + 100_000e18);
        assertEq(t.accInterest, 0);
        assertEq(t.lenderObligation, t.totalPrincipal);
        assertEq(t.poolAssets, t.lenderObligation);
        assertEq(t.surplus, 0);
    }

    // ---- walk-back time floor under sub-second (production) mark cadence ----

    function _mockHp(uint256 micros) internal {
        vm.mockCall(
            0x6342000000000000000000000000000000000002,
            abi.encodeWithSignature("timestamp()"),
            abi.encode(micros)
        );
    }

    /// @dev Operator mark push on an arbitrary feed at a mocked µs clock, ref pinned = mark.
    function _pushAtFeed(uint256 fid, uint256 micros, uint256 mark) internal {
        _mockHp(micros);
        ref.setAnswer(int256(mark / 1e10));
        ref.setUpdatedAt(block.timestamp);
        vm.prank(op);
        oracle.push(fid, mark);
    }

    /// @dev Regression for the ring-walk time floor: with marks pushed sub-second apart (the
    /// MegaETH regime), the walk must still rewind its clock exactly and NOT test marks that
    /// predate the position. A pre-open dip must not wipe a position that never once breached
    /// after it opened.
    function test_walkBackExcludesPreOpenMarksUnderSubSecondCadence() public {
        vm.prank(op);
        uint256 fid = oracle.createFeed(op, 1e18, RATE_CAP, address(ref), 8, 100_000, 1 hours);
        IH2Market.OracleParams memory op_ = _oracleParams();
        op_.primaryFeedId = uint64(fid);
        vm.prank(op);
        uint256 m = h.createMarket(token, _fees(), _risk(0), op_);
        _seedTreasury(m, 1_000_000e18);

        // µs clock, 100 ms apart; block.timestamp never advances.
        uint256 b = (_t + 1) * 1_000_000;
        _pushAtFeed(fid, b,           50_000e18); // first push: initializes, no ring entry
        _pushAtFeed(fid, b + 100_000, 49_000e18); // PRE-OPEN dip: a 100x long @50k is bust here
        _pushAtFeed(fid, b + 200_000, 50_000e18); // recover

        // Open a 100x long @ 50_000 AFTER the dip — never liquidatable at any post-open mark.
        _mockHp(b + 300_000);
        ref.setAnswer(50_000e8); ref.setUpdatedAt(block.timestamp);
        fallbackFeed.setAnswer(50_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        IH2Market.Order memory o = IH2Market.Order({
            user: alice, marketId: m, isLong: true, isOpen: true, size: 1e18, leverage: 100,
            targetPrice: 50_100e18, maxSlippageBps: 200, deadline: uint64(block.timestamp + 1 hours),
            channel: 0, nonce: 0 });
        {
            bytes memory data = abi.encode(m, uint8(IH2Market.ActionKind.Order_), abi.encode(o, _sign(alicePk, o)));
            IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
            calls[0] = IH2Oracle.Call({ target: address(h), data: data });
            vm.prank(op); oracle.pushAndCall(fid, 50_000e18, calls);
        }
        uint256 id = h.activePositionId(alice, m);
        assertFalse(h.positions(id).closed);

        // Fresh mark @ 50_000 carrying a liquidation batch. The pre-open dip must be excluded,
        // so nothing liquidates: the batch reverts internally (NoneLiquidated → CallFailed) and
        // the position stays open.
        _mockHp(b + 400_000);
        ref.setAnswer(50_000e8); ref.setUpdatedAt(block.timestamp);
        fallbackFeed.setAnswer(50_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        {
            bytes memory data = abi.encode(m, uint8(IH2Market.ActionKind.Liquidate), abi.encode(ids));
            IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
            calls[0] = IH2Oracle.Call({ target: address(h), data: data });
            vm.prank(op); oracle.pushAndCall(fid, 50_000e18, calls);
        }
        assertFalse(h.positions(id).closed, "pre-open dip must not wipe the position");
    }

    /// @dev Companion: a genuine POST-open breach in the ring still liquidates (the fix must
    /// not over-correct into never liquidating from history).
    function test_walkBackStillLiquidatesPostOpenBreach() public {
        vm.prank(op);
        uint256 fid = oracle.createFeed(op, 1e18, RATE_CAP, address(ref), 8, 100_000, 1 hours);
        IH2Market.OracleParams memory op_ = _oracleParams();
        op_.primaryFeedId = uint64(fid);
        vm.prank(op);
        uint256 m = h.createMarket(token, _fees(), _risk(0), op_);
        _seedTreasury(m, 1_000_000e18);

        uint256 b = (_t + 1) * 1_000_000;
        _pushAtFeed(fid, b, 50_000e18);

        // Open a 100x long @ 50_000.
        _mockHp(b + 100_000);
        ref.setAnswer(50_000e8); ref.setUpdatedAt(block.timestamp);
        fallbackFeed.setAnswer(50_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        IH2Market.Order memory o = IH2Market.Order({
            user: alice, marketId: m, isLong: true, isOpen: true, size: 1e18, leverage: 100,
            targetPrice: 50_100e18, maxSlippageBps: 200, deadline: uint64(block.timestamp + 1 hours),
            channel: 0, nonce: 0 });
        {
            bytes memory data = abi.encode(m, uint8(IH2Market.ActionKind.Order_), abi.encode(o, _sign(alicePk, o)));
            IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
            calls[0] = IH2Oracle.Call({ target: address(h), data: data });
            vm.prank(op); oracle.pushAndCall(fid, 50_000e18, calls);
        }
        uint256 id = h.activePositionId(alice, m);

        // POST-open dip to 49_000 (bust), then recover — a keeper walks the ring back to it.
        _pushAtFeed(fid, b + 200_000, 49_000e18);
        _pushAtFeed(fid, b + 300_000, 50_000e18);

        _mockHp(b + 400_000);
        ref.setAnswer(50_000e8); ref.setUpdatedAt(block.timestamp);
        fallbackFeed.setAnswer(50_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        {
            bytes memory data = abi.encode(m, uint8(IH2Market.ActionKind.Liquidate), abi.encode(ids));
            IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
            calls[0] = IH2Oracle.Call({ target: address(h), data: data });
            vm.prank(op); oracle.pushAndCall(fid, 50_000e18, calls);
        }
        assertTrue(h.positions(id).closed, "post-open breach must still liquidate");
    }

    function test_setRateDefersWhileFunded() public {
        // mkt carries 5M of principal (setUp), so a rate change waits for the term boundary.
        IH2Market.TreasuryView memory t0 = h.treasuryOf(mkt);
        assertEq(t0.ratePpmAnnual, RATE_10PCT);
        assertEq(t0.nextRatePpm, RATE_10PCT);

        vm.prank(op);
        h.setRate(mkt, 200_000); // 20%
        IH2Market.TreasuryView memory t1 = h.treasuryOf(mkt);
        assertEq(t1.ratePpmAnnual, RATE_10PCT); // current term keeps its rate
        assertEq(t1.nextRatePpm, 200_000);      // pending until the boundary

        // Cross the boundary and touch the treasury: _accrue promotes the pending rate.
        _adv(TERM);
        usdm.mint(carl, 1e18);
        vm.prank(carl);
        h.depositFund(mkt, 1e18);
        IH2Market.TreasuryView memory t2 = h.treasuryOf(mkt);
        assertEq(t2.ratePpmAnnual, 200_000);
        assertEq(t2.nextRatePpm, 200_000);
    }

    function test_stopRollWithdrawHaircutsUnfundedInterest() public {
        // carl's setUp deposit is id 1. Opt out mid-term.
        _adv(2 days);
        vm.prank(carl);
        h.stopRoll(1);

        // Withdrawal is refused until the term boundary the freeze targeted has passed.
        vm.prank(carl);
        vm.expectRevert(IH2Market.TermNotEnded.selector);
        h.withdrawFund(1, carl);

        _adv(TERM); // safely past the next global boundary
        vm.prank(carl);
        h.withdrawFund(1, carl);
        // The pool earned no trading P&L, so the promised interest is unfunded: carl
        // recovers principal exactly and the pool is drained to zero.
        assertEq(usdm.balanceOf(carl), 5_000_000e18);
        assertEq(h.treasuryOf(mkt).poolAssets, 0);
        vm.expectRevert(IH2Market.UnknownDeposit.selector);
        h.deposits(1);
    }

    function test_withdrawSurplusTakesProfitOnly() public {
        // A flat round trip leaves alice's fees + spread in the pool as surplus.
        uint256 id = _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        _adv(1);
        IH2Market.Order memory c = _order(alicePk, true, false, 1e18, 0, 49_800e18, 200, 1);
        _pushOrder(50_000e18, c, _sign(alicePk, c), 0);
        assertTrue(h.positions(id).closed);

        IH2Market.TreasuryView memory t = h.treasuryOf(mkt);
        assertGt(t.surplus, 0);
        assertEq(t.surplus, t.poolAssets - t.lenderObligation);

        uint256 before = usdm.balanceOf(op);
        vm.prank(op);
        h.withdrawSurplus(mkt, t.surplus, op);
        assertEq(usdm.balanceOf(op), before + t.surplus);

        // Nothing left above the lender obligation.
        vm.prank(op);
        vm.expectRevert(IH2Market.NoSurplus.selector);
        h.withdrawSurplus(mkt, 1, op);
    }

    function test_cancelNonceRetiresOrder() public {
        vm.prank(alice);
        h.cancelNonce(0, 7);
        _adv(1);
        IH2Market.Order memory o = _order(alicePk, true, true, 1e18, 100, 50_000e18, 200, 7);
        bytes memory sig = _sign(alicePk, o);
        _refresh(50_000e18);
        bytes memory data = abi.encode(mkt, uint8(IH2Market.ActionKind.Order_), abi.encode(o, sig));
        IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
        calls[0] = IH2Oracle.Call({ target: address(h), data: data });
        vm.prank(op);
        vm.expectEmit(true, false, false, false);
        emit IH2Oracle.CallFailed(feedId, 0, address(h)); // NonceAlreadyUsed, isolated
        oracle.pushAndCall(feedId, 50_000e18, calls);
        assertEq(h.activePositionId(alice, mkt), 0);
    }

    function test_grossOpenNotionalIsPerMarket() public {
        _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        assertEq(h.grossOpenNotional(mkt), 50_000e18);
    }
}
