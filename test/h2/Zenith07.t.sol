// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { H2MarketTest } from "./H2Market.t.sol";
import { IH2Market }  from "../../src/h2/IH2Market.sol";
import { IH2Oracle }  from "../../src/h2/IH2Oracle.sol";

/// Zenith #7 — a market's price tick (and so its minimum mark) is floored at $0.000001, which keeps
/// per-push funding-index truncation (< 1 USDM-wei per whole token) at dust for any listable asset.
contract Zenith07 is H2MarketTest {
    /// Micro-priced feed ($1e-8 tick = mark), rate ~1e-9/s. Feed A is pushed every 100 ms for 10 s;
    /// feed B once at the start and once after 10 s. Same price, same rate: shows the truncation.
    function _accrual() internal returns (int128 frequent, int128 single) {
        int64 rate = 922_337_203_685; // ~PCT_SCALE * 1e-9
        vm.startPrank(op);
        uint256 fa = oracle.createFeed(op, 1e10, RATE_CAP, 0, address(0), 0, 0, 0);
        uint256 fb = oracle.createFeed(op, 1e10, RATE_CAP, 0, address(0), 0, 0, 0);
        vm.stopPrank();
        IH2Oracle.Call[] memory none = new IH2Oracle.Call[](0);
        uint256 t0 = 1_800_000_000_000_000; // us
        _mockHp(t0);
        vm.startPrank(op);
        oracle.pushWithParams(fa, 1e10, rate, rate, 0, 0, none);
        oracle.pushWithParams(fb, 1e10, rate, rate, 0, 0, none);
        for (uint256 i = 1; i <= 100; i++) {
            vm.stopPrank(); _mockHp(t0 + i * 100_000); vm.startPrank(op);
            oracle.push(fa, 1e10);
        }
        oracle.push(fb, 1e10);
        vm.stopPrank();
        frequent = oracle.feedOf(fa).fundingIndexLong;
        single   = oracle.feedOf(fb).fundingIndexLong;
    }

    function _microTickMarket() internal returns (bool created) {
        vm.prank(op);
        uint256 fid = oracle.createFeed(op, 1e10, RATE_CAP, 0, address(0), 0, 0, 0);
        IH2Market.RiskParams memory r = _risk(0);
        r.priceTick = 1e10; r.sizeTick = 1e8;          // $1e-8 tick; product = 1e18
        IH2Market.OracleParams memory o = _oracleParams();
        o.primaryFeedId = uint64(fid);
        vm.prank(op);
        try h.createMarket(token, _fees(), r, o, _spread(), address(reg)) { created = true; } catch { }
    }

    function test_F07_microTickMarketIsRejected() public {
        assertFalse(_microTickMarket(), "createMarket rejects a tick below $0.000001");
        // The oracle-level truncation itself is unchanged; it just cannot reach a market:
        (int128 frequent, int128 single) = _accrual();
        assertEq(frequent, 0, "100 x 100 ms pushes commit nothing");
        assertGt(single, 90, "one 10 s push commits ~99 units");
    }

    function test_F07_tickAtFloorIsAccepted() public {
        vm.prank(op);
        uint256 fid = oracle.createFeed(op, 1e12, RATE_CAP, 0, address(0), 0, 0, 0);
        IH2Market.RiskParams memory r = _risk(0);
        r.priceTick = 1e12; r.sizeTick = 1e6;
        IH2Market.OracleParams memory o = _oracleParams();
        o.primaryFeedId = uint64(fid);
        vm.prank(op);
        h.createMarket(token, _fees(), r, o, _spread(), address(reg));
    }
}
