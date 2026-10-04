// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { H2MarketTest } from "./H2Market.t.sol";
import { IH2Market }  from "../../src/h2/IH2Market.sol";

/// Zenith #26 — assets credited while the vault has no shares go to the operator's rake, never
/// to the pool, so a first deposit always mints 1:1 and nothing is orphaned behind the virtual share.
contract Zenith26 is H2MarketTest {
    uint256 internal m; // a market nobody has deposited into

    function _emptyMarket() internal {
        m = h.createMarket(token, _fees(), _risk(0), _oracleParams(), _spread(), address(reg));
    }

    function _ordM(uint256 pk, bool isLong, bool isOpen, uint256 size, uint256 lev, uint256 px, uint256 nonce)
        internal view returns (IH2Market.Order memory)
    {
        return IH2Market.Order({
            user: vm.addr(pk), marketId: m, isLong: isLong, isOpen: isOpen, size: size, leverage: lev,
            targetPrice: px, maxSlippageBps: 200, deadline: uint64(block.timestamp + 1 hours),
            channel: 0, nonce: nonce, builder: address(0), builderFeePpm: 0
        });
    }

    function _trade(uint256 pk, bool isOpen, uint256 px, uint256 nonce) internal {
        _adv(1);
        IH2Market.Order memory o = _ordM(pk, true, isOpen, 1e18, 100, px, nonce);
        _pushOrderM(m, px, o, _sign(pk, o), 0, int32(0));
    }

    /// Fees earned before any LP exists (open + close, 25 each, 15% rake) used to orphan 42.5 in the
    /// pool; a 40 deposit then reverted and a 50 deposit bought one share worth 46.25. Now the 42.5
    /// goes to the rake, the pool stays empty, and a 40 deposit mints 40 shares that redeem to 40.
    function test_F26_feesBeforeAnyLpGoToRakeAndFirstDepositIsOneToOne() public {
        _emptyMarket();
        _trade(alicePk, true, 50_000e18, 0);
        _trade(alicePk, false, 50_000e18, 1);
        IH2Market.VaultView memory v = h.vaultOf(m);
        assertEq(v.poolAssets, 0, "nothing orphaned in the pool");
        assertEq(v.rakeOwed, 50e18, "7.5 rake + 42.5 that nobody owned");
        assertEq(v.totalShares, 0);

        vm.prank(bob); uint256 sh = h.deposit(m, 40e18);
        assertEq(sh, 40e18, "first deposit mints 1:1");
        vm.prank(bob); h.requestUnstake(m, sh);
        _adv(TERM);
        vm.prank(bob); uint256 out = h.withdraw(m);
        assertEq(out, 40e18, "and redeems in full");
    }

    /// A trader who loses against an EMPTY vault cannot buy the vault for dust and take the loss back.
    function test_F26_lossAgainstEmptyVaultCannotBeScoopedByDustDeposit() public {
        _emptyMarket();
        _trade(alicePk, true, 50_000e18, 0);                 // 1 BTC long, col 500 (less 25 fee)
        _adv(1); _pushMark(49_700e18, 0, 0, 0);              // −300
        _trade(alicePk, false, 49_700e18, 1);                // loss credited with no LPs
        IH2Market.VaultView memory v = h.vaultOf(m);
        assertEq(v.poolAssets, 0, "the loss did not land in an unowned pool");
        assertGt(v.rakeOwed, 300e18, "it went to the operator");
        vm.prank(bob); uint256 sh = h.deposit(m, 1);
        assertEq(sh, 1, "dust deposit mints dust");
        assertEq(h.vaultOf(m).poolAssets, 1, "and owns exactly its dust");
    }

    /// The last LP out leaves an empty pool: rounding dust is swept to the rake, not orphaned.
    function test_F26_lastLpExitLeavesEmptyPool() public {
        _openLong(alicePk, 1e18, 100, 50_000e18, 0);        // fees land in the seeded default market
        _adv(1);
        IH2Market.Order memory c = _order(alicePk, true, false, 1e18, 0, 50_000e18, 200, 1);
        _pushOrder(50_000e18, c, _sign(alicePk, c), 0);
        uint256 cs = h.stakeOf(mkt, carl).shares;
        vm.prank(carl); h.requestUnstake(mkt, cs);
        _adv(TERM);
        uint256 rakeBefore = h.vaultOf(mkt).rakeOwed;
        uint256 poolBefore = h.vaultOf(mkt).poolAssets;
        vm.prank(carl); uint256 out = h.withdraw(mkt);
        IH2Market.VaultView memory v = h.vaultOf(mkt);
        assertEq(v.totalShares, 0);
        assertEq(v.poolAssets, 0, "no dust left behind");
        assertEq(out + (v.rakeOwed - rakeBefore), poolBefore, "payout + swept dust = the whole pool");
    }

    /// Sole LP leaves while a position is still OPEN: nothing is swept (the remainder may back the
    /// trader), the trader's later loss goes to the rake, and the next depositor is priced fairly.
    function test_F26_lastLpExitWithOpenPositionSweepsNothing() public {
        uint256 cs = h.stakeOf(mkt, carl).shares;
        vm.prank(carl); h.requestUnstake(mkt, cs);
        _adv(TERM);
        _openLong(alicePk, 1e18, 100, 50_000e18, 0);
        uint256 rakeBefore = h.vaultOf(mkt).rakeOwed;
        vm.prank(carl); h.withdraw(mkt);
        IH2Market.VaultView memory v = h.vaultOf(mkt);
        assertEq(v.totalShares, 0);
        assertEq(v.rakeOwed, rakeBefore, "nothing swept while a position is open");
        uint256 dust = v.poolAssets;
        assertLt(dust, 10, "only rounding dust remains");

        _adv(1); _pushMark(49_700e18, 0, 0, 0);
        _adv(1);
        IH2Market.Order memory c = _order(alicePk, true, false, 1e18, 0, 49_700e18, 200, 1);
        c.deadline = uint64(_t + 1 hours);
        _pushOrder(49_700e18, c, _sign(alicePk, c), 0);
        v = h.vaultOf(mkt);
        assertEq(v.poolAssets, dust, "the loss did not land in the unowned pool");
        assertGt(v.rakeOwed, rakeBefore + 250e18, "it went to the operator");

        // A few wei of dust scales the share COUNT (1 wei ⇒ half as many shares) but not the value:
        // the next depositor still redeems what they put in.
        vm.prank(bob); uint256 sh = h.deposit(mkt, 1_000e18);
        assertGt(sh, 0);
        vm.prank(bob); h.requestUnstake(mkt, sh);
        _adv(TERM);
        vm.prank(bob); uint256 out = h.withdraw(mkt);
        assertApproxEqAbs(out, 1_000e18, 10, "next first deposit is priced fairly");
    }
}
