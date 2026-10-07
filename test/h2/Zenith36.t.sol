// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { H2MarketTest } from "./H2Market.t.sol";
import { IH2Oracle }  from "../../src/h2/IH2Oracle.sol";

/// Zenith #36 — the oracle rejects funding rates whose sum is negative, so the pool can never be
/// a net funding payer to a price-neutral long + short pair.
contract Zenith36 is H2MarketTest {
    function _push(int64 rl, int64 rs) internal {
        _adv(1); _refresh(50_000e18);
        IH2Oracle.Call[] memory none = new IH2Oracle.Call[](0);
        vm.prank(op);
        oracle.pushWithParams(feedId, 50_000e18, rl, rs, 0, 0, none);
    }

    function test_F36_bothNegativeRejected() public {
        _adv(1); _refresh(50_000e18);
        IH2Oracle.Call[] memory none = new IH2Oracle.Call[](0);
        vm.prank(op);
        vm.expectRevert(IH2Oracle.NetNegativeFunding.selector);
        oracle.pushWithParams(feedId, 50_000e18, -int64(RATE_CAP), -int64(RATE_CAP), 0, 0, none);
        vm.prank(op);
        vm.expectRevert(IH2Oracle.NetNegativeFunding.selector);
        oracle.pushWithParams(feedId, 50_000e18, -2e12, 1e12, 0, 0, none);   // net -1e12
    }

    function test_F36_netNonNegativeAccepted() public {
        _push(0, 0);
        _push(int64(RATE_CAP), int64(RATE_CAP));        // both sides pay the pool
        _push(-1e12, 1e12);                              // one side paid, fully funded by the other
        _push(-1e12, 2e12);
        _push(int64(RATE_CAP), -int64(RATE_CAP));
    }
}
