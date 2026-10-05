// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { H2MarketTest } from "./H2Market.t.sol";
import { IH2Market }  from "../../src/h2/IH2Market.sol";

/// A fallback aggregator that is down (#15, dual failure).
contract RevertingAgg15 {
    function decimals() external pure returns (uint8) { return 8; }
    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) { revert("down"); }
}

/// Zenith #15 — expiry while the primary is stale settles at a fresh fallback price (with the
/// fallback close spread against the position), never at a primary mark that may predate the
/// position. Dual oracle failure keeps the last mark as the exit.
contract Zenith15 is H2MarketTest {
    uint256 internal _nn = 1000;

    function _ord(uint256 pk, uint256 m, bool isLong, bool isOpen, uint256 size, uint256 lev, uint256 target)
        internal returns (IH2Market.Order memory)
    {
        return IH2Market.Order({
            user: vm.addr(pk), marketId: m, isLong: isLong, isOpen: isOpen, size: size, leverage: lev,
            targetPrice: target, maxSlippageBps: 500, deadline: uint64(block.timestamp + 365 days),
            channel: 7, nonce: _nn++, builder: address(0), builderFeePpm: 0
        });
    }

    /// Primary last published 50,000 and goes dark; a 1-token position opens via the fallback at
    /// 45,000 ± 0.2% (the fallback open spread).
    function _openOnFallback(bool isLong) internal returns (uint256 id, uint256 col) {
        _adv(301);
        fallbackFeed.setAnswer(45_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        IH2Market.Order memory o = _ord(alicePk, mkt, isLong, true, 1e18, 100, isLong ? 45_090e18 : 44_910e18);
        id = h.executeAtFallback(o, _sign(alicePk, o));
        col = h.positions(id).col;
    }

    function _expire(uint256 id) internal returns (uint256 paid) {
        uint256 before = usdm.balanceOf(alice);
        h.expirePosition(id);
        paid = usdm.balanceOf(alice) - before;
    }

    // Zenith's scenario: the fallback price never moves, yet the audited code settled the long at
    // the obsolete 50,000 mark (+4,910 of "profit" from the pool).
    function test_F15_fallbackOpenedLongExpiresAtFreshFallback() public {
        (uint256 id, uint256 col) = _openOnFallback(true);
        _adv(30 days);
        fallbackFeed.setAnswer(45_000e8); fallbackFeed.setUpdatedAt(block.timestamp); // unchanged price
        // settles at floor(45,000 × 0.998) = 44,910 vs entry 45,090 ⇒ −180, no close fee
        assertEq(_expire(id), col - 180e18, "settled at the fresh fallback less the close spread");
    }

    function test_F15_fallbackOpenedShortExpiresAtFreshFallback() public {
        (uint256 id, uint256 col) = _openOnFallback(false);
        _adv(30 days);
        fallbackFeed.setAnswer(45_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        // settles at ceil(45,000 × 1.002) = 45,090 vs entry 44,910 ⇒ −180
        assertEq(_expire(id), col - 180e18, "short settled at the fresh fallback plus the close spread");
    }

    function test_F15_expiryProfitComesFromTheFallbackPrice() public {
        (uint256 id, uint256 col) = _openOnFallback(true);
        _adv(30 days);
        fallbackFeed.setAnswer(46_000e8); fallbackFeed.setUpdatedAt(block.timestamp);
        // settles at floor(46,000 × 0.998) = 45,908 vs entry 45,090 ⇒ +818, minus the 5.5% cut
        assertEq(_expire(id), col + 818e18 - 44.99e18, "profit measured against the fallback, not the stale mark");
    }

    function test_F15_dualFailureStillSettlesAtTheLastMark() public {
        (uint256 id, uint256 col) = _openOnFallback(true);
        _adv(30 days);                                   // fallback now stale too: dual failure
        // the documented exit: last mark 50,000 vs entry 45,090 ⇒ +4,910 minus the 5.5% cut
        assertEq(_expire(id), col + 4_910e18 - 270.05e18, "dual failure: last mark");
    }

    function test_F15_revertingFallbackDoesNotBlockExpiry() public {
        IH2Market.OracleParams memory o = _oracleParams();
        o.fallbackFeed = address(new RevertingAgg15());
        vm.prank(op);
        uint256 m = h.createMarket(token, _fees(), _risk(0), o, _spread(), address(reg));
        _seedTreasury(m, 1_000_000e18);
        _adv(1);
        IH2Market.Order memory ord = _ord(alicePk, m, true, true, 1e18, 100, 50_000e18);
        _pushOrderM(m, 50_000e18, ord, _sign(alicePk, ord), 0, 0);
        uint256 id = h.activePositionId(alice, m);
        uint256 col = h.positions(id).col;
        _adv(30 days + 1);                               // primary stale, fallback reverts
        assertEq(_expire(id), col, "settled flat at the last mark; the dead fallback is skipped");
    }

    function test_F15_freshPrimaryExpiryUnchanged() public {
        uint256 id = _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        uint256 col = h.positions(id).col;
        _adv(30 days + 1);
        _pushMark(50_500e18, 0, 0, 0);                   // fresh, agreeing primary
        assertEq(_expire(id), col + 500e18 - 27.5e18,
            "settles at the fresh mark: +500 pnl minus the 5.5% winnings cut (27.5)");
    }
}
