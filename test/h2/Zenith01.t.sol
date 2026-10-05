// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Vm } from "forge-std/Vm.sol";
import { H2MarketTest } from "./H2Market.t.sol";
import { IH2Market }  from "../../src/h2/IH2Market.sol";

/// Zenith #1 — funding settlement rounds toward +inf: a debt's fractional wei is charged, a credit's
/// is dropped, so the rounding always favors the pool.
contract Zenith01 is H2MarketTest {
    /// 1-sat long at 50,000; longs pay at the rate cap for 1 s; close. Returns the exact funding
    /// numerator (x1e18) and the amount actually charged, read from `PositionClosed`.
    function _scenario() internal returns (int256 num, int256 fundingPaid) {
        uint256 id = _openLong(alicePk, 1e10, 100, 50_000e18, 0);
        int128 ckpt = h.positions(id).fundingCheckpoint;
        _adv(1); _pushMark(50_000e18, int64(RATE_CAP), 0, 0);
        _adv(1);
        vm.recordLogs();
        IH2Market.Order memory c = _order(alicePk, true, false, 1e10, 0, 50_000e18, 200, 1);
        _pushOrder(50_000e18, c, _sign(alicePk, c), 0);
        assertTrue(h.positions(id).closed);
        int128 idx = oracle.feedOf(feedId).fundingIndexLong;      // == fundingNow (same ms)
        num = (int256(idx) - int256(ckpt)) * int256(uint256(1) * 1e10);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("PositionClosed(uint256,uint256,uint256,int256,int256,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) (, , fundingPaid, , , ) =
                abi.decode(logs[i].data, (uint256, int256, int256, uint256, uint256, uint256));
        }
    }

    function test_F01_positiveFundingRoundsUpForThePool() public {
        (int256 num, int256 paid) = _scenario();
        assertGt(num, 0, "trader owes funding");
        assertTrue(num % 1e18 != 0, "exact funding has a fractional wei");
        assertEq(paid, num / 1e18 + 1, "the fractional wei is charged (ceil)");
        emit log_named_int("exact funding x1e18", num);
        emit log_named_int("charged (wei)", paid);
    }
}
