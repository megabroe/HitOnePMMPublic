// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { H2MarketTest } from "./H2Market.t.sol";
import { IH2Market }  from "../../src/h2/IH2Market.sol";
import { IH2Oracle }  from "../../src/h2/IH2Oracle.sol";

/// Zenith 2026-09 audit fixes — AFTER tests: each asserts the FIXED behaviour.
contract ZenithFixes is H2MarketTest {
    uint256 internal _nn = 1;

    function _ord(uint256 pk, uint256 m, bool isLong, bool isOpen, uint256 size, uint256 lev, uint256 target)
        internal returns (IH2Market.Order memory)
    {
        return IH2Market.Order({
            user: vm.addr(pk), marketId: m, isLong: isLong, isOpen: isOpen, size: size, leverage: lev,
            targetPrice: target, maxSlippageBps: 500, deadline: uint64(block.timestamp + 365 days),
            channel: 7, nonce: _nn++, builder: address(0), builderFeePpm: 0
        });
    }

    // ---------------------------------------------------------------- #42
    // Zenith's scenario: BTC market, 0.001 BTC min order, maxOISkew = maxPositionNotional = 200k,
    // liqWidth 0, UNBANDED primary feed (so LP deposits are disabled), vault funded only by trading.
    uint256 internal _f42Feed;
    uint256 internal _f42Mkt;

    function _f42Pk(uint256 i) internal pure returns (uint256) { return 0x4200 + i; }

    function _f42Mark(uint256 mark) internal {
        fallbackFeed.setAnswer(int256(mark / 1e10)); fallbackFeed.setUpdatedAt(block.timestamp);
        vm.prank(op);
        oracle.pushWithParams(_f42Feed, mark, 0, 0, 0, 0, new IH2Oracle.Call[](0));
    }

    function _f42Push(uint256 mark, IH2Market.Order memory o, uint256 pk) internal {
        fallbackFeed.setAnswer(int256(mark / 1e10)); fallbackFeed.setUpdatedAt(block.timestamp);
        IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
        calls[0] = IH2Oracle.Call({ target: address(h),
            data: abi.encode(_f42Mkt, uint8(IH2Market.ActionKind.Order_), abi.encode(o, _sign(pk, o))) });
        vm.prank(op);
        oracle.pushWithParams(_f42Feed, mark, 0, 0, 0, 0, calls);
    }

    function _f42Ord(uint256 i, bool isLong, bool isOpen, uint256 size, uint256 lev, uint256 target)
        internal returns (IH2Market.Order memory o)
    {
        o = _ord(_f42Pk(i), _f42Mkt, isLong, isOpen, size, lev, target);
    }

    function _f42Setup() internal {
        vm.prank(op);
        _f42Feed = oracle.createFeed(op, 1e18, RATE_CAP, RAKE_PPM, address(0), 0, 0, 0); // unbanded
        IH2Market.RiskParams memory r = _risk(0);
        r.minLeverage = 5;
        r.maxOISkew = 200_000e18;               // == maxPositionNotional (200k)
        IH2Market.OracleParams memory op_ = _oracleParams();
        op_.primaryFeedId = uint64(_f42Feed);
        vm.prank(op);
        _f42Mkt = h.createMarket(token, _fees(), r, op_, _spread(), address(reg));
        for (uint256 i = 1; i <= 8; i++) {
            address u = vm.addr(_f42Pk(i));
            usdm.mint(u, 1_000_000e18);
            vm.prank(u); usdm.approve(address(h), type(uint256).max);
        }
        _adv(1); _f42Mark(50_000e18);
    }

    function _f42Open(uint256 i, bool isLong, uint256 size, uint256 lev, uint256 mark) internal returns (uint256 id) {
        _adv(1);
        _f42Push(mark, _f42Ord(i, isLong, true, size, lev, mark), _f42Pk(i));
        id = h.activePositionId(vm.addr(_f42Pk(i)), _f42Mkt);
    }

    function _f42Close(uint256 i, bool isLong, uint256 size, uint256 mark) internal {
        _adv(1);
        _f42Push(mark, _f42Ord(i, isLong, false, size, 0, mark), _f42Pk(i));
    }


    /// Steps 1–2 of Zenith's scenario: 450k long / 0 short after both shorts close (cap 200k).
    function _f42OverCap() internal returns (uint256 m) {
        _f42Setup();
        m = _f42Mkt;
        _f42Open(1, true,  3e18,   5, 50_000e18);
        _f42Open(4, false, 3e18, 100, 50_000e18);
        _f42Open(2, true,  3e18,   5, 50_000e18);
        _f42Open(5, false, 3e18, 100, 50_000e18);
        _f42Open(3, true,  3e18,   5, 50_000e18);
        _f42Close(4, false, 3e18, 50_300e18);
        _f42Close(5, false, 3e18, 50_300e18);
        assertEq(h.marketOf(m).openInterestLong, 450_000e18);
        assertEq(h.marketOf(m).openInterestShort, 0);
    }

    function test_F42_minSizeSkewReducingOrderAccepted() public {
        uint256 m = _f42OverCap();
        uint256 id = _f42Open(6, false, 1e15, 100, 50_300e18);      // 0.001 BTC short
        assertTrue(id != 0, "AFTER: min short that reduces the skew is accepted");
        assertEq(h.marketOf(m).openInterestShort, 50.3e18);
    }

    function test_F42_skewIncreasingOrderStillRejectedOverCap() public {
        _f42OverCap();
        IH2Market.Order memory o = _f42Ord(7, true, true, 1e15, 100, 50_400e18);
        bytes memory sig = _sign(_f42Pk(7), o);
        _adv(1); _f42Mark(50_300e18);
        vm.expectRevert(IH2Market.OISkewCap.selector);
        h.executeAtMark(o, sig);
    }

    function test_F42_minoritySideWalksSkewBackUnderCap() public {
        uint256 m = _f42OverCap();
        // Two near-max (196k) shorts: skew 450k → 254k (still over the cap; allowed because it
        // shrinks) → 58k (under the cap).
        _f42Open(6, false, 3.9e18, 100, 50_300e18);
        IH2Market.MarketView memory mv = h.marketOf(m);
        assertGt(mv.openInterestLong - mv.openInterestShort, 200_000e18, "still over the cap");
        _f42Open(7, false, 3.9e18, 100, 50_300e18);
        mv = h.marketOf(m);
        assertLe(mv.openInterestLong - mv.openInterestShort, 200_000e18, "AFTER: back under the cap");
        // Once under the cap the ordinary post-trade check applies again: a long back to 254k fails.
        IH2Market.Order memory o = _f42Ord(8, true, true, 3.9e18, 100, 50_400e18);
        bytes memory sig = _sign(_f42Pk(8), o);
        _adv(1); _f42Mark(50_300e18);
        vm.expectRevert(IH2Market.OISkewCap.selector);
        h.executeAtMark(o, sig);
    }
}
