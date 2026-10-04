// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { H2MarketTest } from "./H2Market.t.sol";
import { IH2Market }  from "../../src/h2/IH2Market.sol";

/// Zenith #4 — the size-weighted funding checkpoint blend on an increase floors toward -inf, so the
/// rounding always lands on the trader (a lower checkpoint owes more), never on the pool.
contract Zenith04 is H2MarketTest {
    /// Long 1 BTC opened after negative (long-receives) funding accrued, then +2 BTC after more.
    /// Returns the exact blend numerator, the new size, and the stored checkpoint.
    function _scenario() internal returns (int256 num, int256 newSize, int128 stored) {
        _adv(1); _pushMark(50_000e18, -int64(RATE_CAP), int64(RATE_CAP), 0); // longs receive
        uint256 id = _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        int128 ckptOld = h.positions(id).fundingCheckpoint;
        _adv(1); _pushMark(50_000e18, -int64(RATE_CAP), int64(RATE_CAP), 0);
        _adv(1);
        IH2Market.Order memory inc = _order(alicePk, true, true, 2e18, 100, 50_000e18, 200, 1);
        _pushOrder(50_000e18, inc, _sign(alicePk, inc), 0);
        assertEq(h.positions(id).size, 3e18, "increase executed");
        int128 idxNow = oracle.feedOf(feedId).fundingIndexLong;   // == fundingNow (same ms)
        num = int256(ckptOld) * 1e8 + int256(idxNow) * 2e8;        // size units: 1 BTC = 1e8
        newSize = 3e8;
        stored = h.positions(id).fundingCheckpoint;
    }

    function test_F04_negativeCheckpointBlendFloors() public {
        (int256 num, int256 n, int128 stored) = _scenario();
        assertLt(num, 0, "negative index regime");
        assertTrue(num % n != 0, "blend has a remainder");
        assertEq(int256(stored), num / n - 1, "floored toward -inf: rounding lands on the trader");
        emit log_named_int("exact blend x newSize", num);
        emit log_named_int("stored checkpoint", stored);
    }
}
