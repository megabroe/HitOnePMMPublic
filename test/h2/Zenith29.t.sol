// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { H2MarketTest } from "./H2Market.t.sol";
import { IH2Market }  from "../../src/h2/IH2Market.sol";

/// Zenith #29 — createMarket requires an LP unstake cooldown of at least 1 day.
contract Zenith29 is H2MarketTest {
    function _create(uint32 unstakeSecs) internal returns (bool ok) {
        IH2Market.RiskParams memory r = _risk(0);
        r.unstakeSecs = unstakeSecs;
        try h.createMarket(token, _fees(), r, _oracleParams(), _spread(), address(reg)) { ok = true; } catch {}
    }

    function test_F29_zeroCooldownRejected() public {
        assertFalse(_create(0), "zero cooldown rejected");
        assertFalse(_create(1 days - 1), "under a day rejected");
    }

    function test_F29_oneDayAndAboveAccepted() public {
        assertTrue(_create(1 days), "1 day accepted");
        assertTrue(_create(7 days), "7 days accepted");
        assertTrue(_create(30 days), "30 days accepted");
        assertFalse(_create(30 days + 1), "over 30 days still rejected");
    }
}
