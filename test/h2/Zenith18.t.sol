// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { H2MarketTest } from "./H2Market.t.sol";
import { IH2Market }  from "../../src/h2/IH2Market.sol";

/// Zenith #18 — a winning settlement's solvency check runs against the pool's NET debit (gross
/// profit less the pool's share of the winnings cut), so a fundable close no longer reverts
/// `Insolvent` when the pool is within one cut of the gross profit.
contract Zenith18 is H2MarketTest {
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

    /// 1 BTC 100x long 50,000 → 51,000 on a fresh market seeded with `seed`. At the close: effPnl
    /// 1,000, winnings cut 55 (46.75 to the pool after the 15% rake), close fee 25.5 (21.675 to the
    /// pool). The open fee credited 21.25 to the pool at the open.
    function _closeOn(uint256 seed) internal returns (uint256 m, uint256 id) {
        vm.prank(op);
        m = h.createMarket(token, _fees(), _risk(0), _oracleParams(), _spread(), address(reg));
        _seedTreasury(m, seed);
        _adv(1);
        IH2Market.Order memory o = _ord(alicePk, m, true, true, 1e18, 100, 50_000e18);
        _pushOrderM(m, 50_000e18, o, _sign(alicePk, o), 0, 0);
        id = h.activePositionId(alice, m);
        _adv(1);
        IH2Market.Order memory c = _ord(alicePk, m, true, false, 1e18, 0, 51_000e18);
        _pushOrderM(m, 51_000e18, c, _sign(alicePk, c), 0, 0);
    }

    // Zenith's scenario: pool 960 at the close (938.75 seed + 21.25 open fee) is below the gross
    // 1,000 profit but covers the net debit of 953.25. The audited code reverted `Insolvent`.
    function test_F18_fundableCloseSettlesOnNetDebit() public {
        (uint256 m, uint256 id) = _closeOn(938.75e18);
        assertTrue(h.positions(id).closed, "fundable close settles");
        // 960 + 21.675 (close fee, net of rake) + 46.75 (cut, net of rake) − 1,000
        assertEq(h.vaultOf(m).poolAssets, 28.425e18, "pool ends at the exact net");
    }

    function test_F18_unfundableCloseStillRevertsInsolvent() public {
        // pool 921.25 at the close: 921.25 + 21.675 + 46.75 = 989.675 < 1,000 ⇒ still Insolvent
        (uint256 m, uint256 id) = _closeOn(900e18);
        assertFalse(h.positions(id).closed, "a genuinely unfundable win still waits");
        assertEq(h.vaultOf(m).poolAssets, 921.25e18, "pool untouched by the reverted close");
    }

    function test_F18_finalBalancesUnchangedWhenAmplyFunded() public {
        (uint256 m, uint256 id) = _closeOn(10_000e18);
        assertTrue(h.positions(id).closed);
        // 10,000 + 21.25 + 21.675 + 46.75 − 1,000: the reorder moves the check, not the money
        assertEq(h.vaultOf(m).poolAssets, 9_089.675e18, "same final pool as before the reorder");
    }
}
