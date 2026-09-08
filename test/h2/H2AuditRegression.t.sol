// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { H2MarketTest } from "./H2Market.t.sol";
import { IH2Market }  from "../../src/h2/IH2Market.sol";
import { IH2Oracle }  from "../../src/h2/IH2Oracle.sol";
import { IBuilderRegistry } from "../../src/h2/IBuilderRegistry.sol";

// Registries exercising every failure mode of the `_builderEligible` gate.
contract GasBombReg is IBuilderRegistry { function isBuilder(address) external pure override returns (bool) { assembly { for {} 1 {} {} } } }
contract RevertReg  is IBuilderRegistry { function isBuilder(address) external pure override returns (bool) { revert("nope"); } }
contract GarbageReg is IBuilderRegistry { function isBuilder(address) external pure override returns (bool) { assembly { mstore(0, 2) return(0, 32) } } } // 32 bytes, value 2
contract BombReg    is IBuilderRegistry { function isBuilder(address) external pure override returns (bool) { assembly { return(0, 500000) } } }         // 500KB blob
contract ShortReg   is IBuilderRegistry { function isBuilder(address) external pure override returns (bool) { assembly { return(0, 16) } } }             // 16 bytes
contract OpenReg    is IBuilderRegistry { function isBuilder(address) external pure override returns (bool) { return true; } }                            // clean true

/// Tracked regression tests for the audit-fix batch (folds the auditors' PoCs):
///   MED-3  the builder-registry gate must never brick or gas-bomb an order;
///   FIX 2  the adjustment gap is a configurable, enforced per-market minimum;
///   the increase entry-blend rounds AGAINST the taker (no walk-toward-mark pool drain).
/// (HIGH-2 — the winnings cut is charged only at close, no crystallization — is covered by
///  test_increaseNeverChargesCutOrDrainsPool in H2Market.t.sol.)
contract H2AuditRegressionTest is H2MarketTest {
    uint256 internal _n; // unique-nonce cursor

    function _mkMarketReg(address registry) internal returns (uint256 id) {
        id = h.createMarket(token, _fees(), _risk(0), _oracleParams(), _spread(), registry);
        _seedTreasury(id, 1_000_000e18);
    }

    /// Operator-attach one order to a mark commit on the default feed, for an arbitrary market.
    function _pushOrderTo(uint256 marketId, uint256 mark, IH2Market.Order memory o, bytes memory sig) internal {
        _refresh(mark);
        bytes memory data = abi.encode(marketId, uint8(IH2Market.ActionKind.Order_), abi.encode(o, sig));
        IH2Oracle.Call[] memory calls = new IH2Oracle.Call[](1);
        calls[0] = IH2Oracle.Call({ target: address(h), data: data });
        vm.prank(op);
        oracle.pushWithParams(feedId, mark, 0, 0, 0, 0, calls);
    }

    function _orderOn(uint256 marketId, uint256 pk, bool isOpen, uint256 size, uint256 target,
                      address builder, uint256 builderFeePpm)
        internal returns (IH2Market.Order memory o)
    {
        o = IH2Market.Order({
            user: vm.addr(pk), marketId: marketId, isLong: true, isOpen: isOpen,
            size: size, leverage: 100, targetPrice: target, maxSlippageBps: 500,
            deadline: uint64(block.timestamp + 1 hours), channel: 9, nonce: _n++,
            builder: builder, builderFeePpm: builderFeePpm
        });
    }

    // ---- MED-3: a hostile/broken registry forfeits the builder share, never bricks the order ----
    function test_hostileRegistryNeverBricksOrder() public {
        address[6] memory regs = [
            address(new GasBombReg()), address(new RevertReg()), address(new GarbageReg()),
            address(new BombReg()), address(new ShortReg()), makeAddr("codelessRegistry")
        ];
        address builder = makeAddr("builder");
        for (uint256 i = 0; i < regs.length; i++) {
            uint256 m = _mkMarketReg(regs[i]);
            _adv(1);
            IH2Market.Order memory o = _orderOn(m, alicePk, true, 1e18, 50_500e18, builder, 100_000);
            _pushOrderTo(m, 50_000e18, o, _sign(alicePk, o));
            assertGt(h.activePositionId(alice, m), 0, "order landed despite a hostile registry");
            assertEq(h.builderOwed(builder), 0, "hostile/broken registry forfeits the builder share");
        }
        // Positive control: a clean registry returning `true` credits the builder.
        uint256 mOk = _mkMarketReg(address(new OpenReg()));
        _adv(1);
        IH2Market.Order memory ok_ = _orderOn(mOk, bobPk, true, 1e18, 50_500e18, builder, 100_000);
        _pushOrderTo(mOk, 50_000e18, ok_, _sign(bobPk, ok_));
        assertGt(h.activePositionId(bob, mOk), 0, "order landed");
        assertGt(h.builderOwed(builder), 0, "a clean `true` credits the builder");
    }

    /// A returndata bomb cannot inflate order gas: the 30k stipend can't fund the memory
    /// expansion to return a large blob, so the sub-call OOGs and the share is forfeited.
    function test_returndataBombDoesNotInflateGas() public {
        uint256 mBomb = _mkMarketReg(address(new BombReg()));
        uint256 mOpen = _mkMarketReg(address(new OpenReg()));
        address builder = makeAddr("builder");

        _adv(1);
        IH2Market.Order memory a = _orderOn(mOpen, alicePk, true, 1e18, 50_500e18, builder, 100_000);
        uint256 g0 = gasleft();
        _pushOrderTo(mOpen, 50_000e18, a, _sign(alicePk, a));
        uint256 benign = g0 - gasleft();

        _adv(1);
        IH2Market.Order memory b = _orderOn(mBomb, bobPk, true, 1e18, 50_500e18, builder, 100_000);
        g0 = gasleft();
        _pushOrderTo(mBomb, 50_000e18, b, _sign(bobPk, b));
        uint256 bombed = g0 - gasleft();

        assertLt(bombed, benign + 100_000, "returndata bomb gas is bounded by the 30k stipend");
    }

    // ---- increase entry-blend must round AGAINST the taker (no pool-draining entry walk) ----
    // An underwater long that dust-increases must NOT drift its entry toward the mark: the blended
    // entry ceils for a long, so a sub-priceUnit blend can't floor the entry down 1 unit per add
    // (which pre-fix let a position erase its unrealized loss straight out of the pool).
    function test_increaseBlendRoundsAgainstTaker() public {
        IH2Market.RiskParams memory r = _risk(0);
        r.minAdjustGapBlocks = 1;
        uint256 m = h.createMarket(token, _fees(), r, _oracleParams(), _spread(), address(reg)); // _spread() = zero derived spread
        _seedTreasury(m, 1_000_000e18);
        uint256 st = uint256(h.riskParamsOf(m).sizeTick);

        // Open a long at 50_000 (1000 size-ticks), then mark drops to 49_900 (underwater).
        _adv(1);
        IH2Market.Order memory oo = _orderOn(m, alicePk, true, st * 1000, 50_000e18, address(0), 0);
        _pushOrderTo(m, 50_000e18, oo, _sign(alicePk, oo));
        uint256 id = h.activePositionId(alice, m);
        uint256 entry0 = h.positions(id).entryPrice;

        // Dust-increase (1 size-tick) ten times at the lower mark.
        for (uint256 i; i < 10; i++) {
            _adv(1);
            IH2Market.Order memory oi = _orderOn(m, alicePk, true, st, 49_900e18, address(0), 0);
            _pushOrderTo(m, 49_900e18, oi, _sign(alicePk, oi));
        }
        // Round-against-taker: a long's entry never walks down toward the mark on dust adds.
        assertEq(h.positions(id).entryPrice, entry0, "long entry did not walk toward the mark");
    }

    // ---- FIX 2: configurable adjustment gap ----
    function test_minAdjustGapZeroRejected() public {
        IH2Market.RiskParams memory r = _risk(0);
        r.minAdjustGapBlocks = 0;
        vm.expectRevert(IH2Market.BadMarketParams.selector);
        h.createMarket(token, _fees(), r, _oracleParams(), _spread(), address(reg));
    }

    function test_adjustmentGapEnforcedAndConfigurable() public {
        IH2Market.RiskParams memory r = _risk(0);
        r.minAdjustGapBlocks = 2;
        uint256 m = h.createMarket(token, _fees(), r, _oracleParams(), _spread(), address(reg));
        _seedTreasury(m, 1_000_000e18);

        _adv(1); // open at block N
        IH2Market.Order memory o = _orderOn(m, alicePk, true, 1e18, 50_500e18, address(0), 0);
        _pushOrderTo(m, 50_000e18, o, _sign(alicePk, o));
        uint256 id = h.activePositionId(alice, m);
        assertGt(id, 0);
        uint256 sz0 = h.positions(id).size;

        // block N+1 (< N+2): the increase is isolated-rejected (AdjustmentTooSoon) → size unchanged
        _adv(1);
        IH2Market.Order memory inc1 = _orderOn(m, alicePk, true, 1e18, 50_600e18, address(0), 0);
        _pushOrderTo(m, 50_000e18, inc1, _sign(alicePk, inc1));
        assertEq(h.positions(id).size, sz0, "increase within the gap did not land");

        // block N+2 (== N + gap): the increase lands
        _adv(1);
        IH2Market.Order memory inc2 = _orderOn(m, alicePk, true, 1e18, 50_600e18, address(0), 0);
        _pushOrderTo(m, 50_000e18, inc2, _sign(alicePk, inc2));
        assertGt(h.positions(id).size, sz0, "increase after the gap landed");
    }
}
