// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { H2MarketTest } from "./H2Market.t.sol";
import { H2Market }     from "../../src/h2/H2Market.sol";
import { IH2Market }    from "../../src/h2/IH2Market.sol";
import { IH2Oracle }    from "../../src/h2/IH2Oracle.sol";
import { ParamCatalog } from "../../src/common/ParamCatalog.sol";

/// Exposes the internal tick helpers (#46).
contract H2StorageProbe is H2Market {
    constructor(address usdm_, address oracle_) H2Market(usdm_, oracle_) {}
    function toSize(uint256 input, uint256 tick)  external pure returns (uint128) { return _toSizeUnits(input, tick); }
    function toPrice(uint256 input, uint256 tick) external pure returns (uint128) { return _toPriceUnits(input, tick); }
}

/// Zenith Informationals with a code change: #40 named limits, #46 zero-tick guard,
/// #49 `ringEntry` range check, #52 `grossOpenNotional` on an unknown market.
contract ZenithInfos is H2MarketTest {
    // ---------------------------------------------------------------- #40
    function test_I40_namedLimitsMatchTheFormerLiterals() public {
        assertEq(ParamCatalog.MAX_BUILDER_FEE_PPM, 500_000);
        assertEq(ParamCatalog.MAX_LIQ_WIDTH_PPM,   100_000);
        assertEq(ParamCatalog.MAX_FEE_RAKE_PPM,    500_000);
        // ...and are what createMarket / createFeed enforce.
        IH2Market.FeeParams memory f = _fees(); f.maxBuilderFeePpm = 500_001;
        vm.prank(op); vm.expectRevert(IH2Market.BadMarketParams.selector);
        h.createMarket(token, f, _risk(0), _oracleParams(), _spread(), address(0));
        vm.prank(op); vm.expectRevert(IH2Market.BadMarketParams.selector);
        h.createMarket(token, _fees(), _risk(100_001), _oracleParams(), _spread(), address(0));
        vm.expectRevert(IH2Oracle.BadFeedParams.selector);
        oracle.createFeed(op, 1e18, RATE_CAP, 500_001, address(0), 0, 0, 0);
    }

    // ---------------------------------------------------------------- #46
    function test_I46_zeroTickRevertsBadSizeNotPanic() public {
        H2StorageProbe p = new H2StorageProbe(address(usdm), address(oracle));
        vm.expectRevert(IH2Market.BadSize.selector);
        p.toSize(1e18, 0);
        vm.expectRevert(IH2Market.BadMark.selector);
        p.toPrice(1e18, 0);
        assertEq(p.toSize(3e18, 1e18), 3, "valid input unchanged");
    }

    // ---------------------------------------------------------------- #49
    function test_I49_ringEntryRejectsIndicesOutsideTheRetainedWindow() public {
        _adv(1); _pushMark(50_000e18, 0, 0, 0);
        _adv(1); _pushMark(50_100e18, 0, 0, 0);
        uint256 head = oracle.feedOf(feedId).ringHead;
        assertGe(head, 2);
        // In range: the newest written entry and the oldest retained one read fine.
        oracle.ringEntry(feedId, head - 1);
        oracle.ringEntry(feedId, head < 200 ? 0 : head - 200);
        // Out of range: at/after the head (unwritten), and older than RING_LEN (overwritten).
        vm.expectRevert(IH2Oracle.RingEntryOutOfRange.selector);
        oracle.ringEntry(feedId, head);
        if (head > 200) {
            vm.expectRevert(IH2Oracle.RingEntryOutOfRange.selector);
            oracle.ringEntry(feedId, head - 201);
        }
    }

    function test_I49_walkBackStillReadsTheWholeRing() public {
        // Fill the ring past its length so every in-window index the market walks is exercised.
        uint256 id = _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        for (uint256 i = 0; i < 205; i++) { _adv(1); _pushMark(50_000e18 + (i % 7) * 1e18, 0, 0, 0); }
        assertGt(oracle.feedOf(feedId).ringHead, 200);
        // A close walks the full retained window through ringEntry without reverting.
        _adv(1);
        IH2Market.Order memory c = _order(alicePk, true, false, 1e18, 100, 50_000e18, 500, 1);
        _pushOrder(50_000e18, c, _sign(alicePk, c), 0);
        assertTrue(h.positions(id).closed, "close settled through a full-ring walk");
    }

    // ---------------------------------------------------------------- #52
    function test_I52_grossOpenNotionalRevertsOnUnknownMarket() public {
        assertEq(h.grossOpenNotional(mkt), 0);
        vm.expectRevert(IH2Market.UnknownMarket.selector);
        h.grossOpenNotional(999_999);
    }
}
