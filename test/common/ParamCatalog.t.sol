// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Test }         from "forge-std/Test.sol";
import { ParamCatalog } from "../../src/common/ParamCatalog.sol";

contract ParamCatalogHarness {
    function validateStructural(ParamCatalog.Structural calldata p, uint256 usdmDenom) external pure {
        ParamCatalog.Structural memory pm = p;
        ParamCatalog.validateAndDeriveStructural(pm, usdmDenom);
    }
    function validateRisk(ParamCatalog.Risk calldata p) external pure {
        ParamCatalog.validateRisk(p);
    }
    function houseCut(uint256 effPnl, uint256 col, uint256 interceptPpm, uint256 slopePpm, uint256 maxPpm)
        external pure returns (uint256)
    {
        return ParamCatalog.houseCut(effPnl, col, interceptPpm, slopePpm, maxPpm);
    }
    function sizeFeePpm(uint256 notional, uint256 usdmDenom, uint256 openFeePpm, uint256 linearScale, uint256 quadScale)
        external pure returns (uint256)
    {
        return ParamCatalog.sizeFeePpm(notional, usdmDenom, openFeePpm, linearScale, quadScale);
    }
}

contract ParamCatalogTest is Test {
    ParamCatalogHarness internal h;
    uint256 internal constant USDM_18 = 1e18;
    uint256 internal constant PPM     = 1e6;

    function setUp() public { h = new ParamCatalogHarness(); }

    function _okStructural() internal pure returns (ParamCatalog.Structural memory) {
        return ParamCatalog.Structural({
            priceTick: 1e18, sizeTick: 1e10, notionalScale: 0,
            minLeverage: 100, maxLeverage: 1000,
            maxPositionDuration: 30 days,
            cutInterceptPpm: 0, cutSlopePpm: 55_000, maxCutPpm: 55_000
        });
    }

    function _okRisk() internal pure returns (ParamCatalog.Risk memory) {
        return ParamCatalog.Risk({
            openFeeBps: 10, linearScale: 1e30, quadScale: type(uint256).max,
            maxPositionNotional: 200_000e18,
            maxOIGross: type(uint256).max, maxOISkew: type(uint256).max,
            maxDevBps: 3
        });
    }

    // ---- structural ----

    function test_structuralOk() public view { h.validateStructural(_okStructural(), USDM_18); }

    function test_structuralPriceTickZero() public {
        ParamCatalog.Structural memory p = _okStructural(); p.priceTick = 0;
        vm.expectRevert(ParamCatalog.BadPriceTick.selector);
        h.validateStructural(p, USDM_18);
    }

    function test_structuralSizeTickZero() public {
        ParamCatalog.Structural memory p = _okStructural(); p.sizeTick = 0;
        vm.expectRevert(ParamCatalog.BadSizeTick.selector);
        h.validateStructural(p, USDM_18);
    }

    function test_structuralProductBelowUsdmDenom() public {
        // priceTick × sizeTick < usdmDenom — fails BadPriceTick
        ParamCatalog.Structural memory p = _okStructural();
        p.priceTick = 1; p.sizeTick = 1;       // product = 1 < 1e18
        vm.expectRevert(ParamCatalog.BadPriceTick.selector);
        h.validateStructural(p, USDM_18);
    }

    function test_structuralLeverageInverted() public {
        ParamCatalog.Structural memory p = _okStructural();
        p.minLeverage = 500; p.maxLeverage = 200;
        vm.expectRevert(ParamCatalog.BadLeverage.selector);
        h.validateStructural(p, USDM_18);
    }

    function test_structuralLeverageAboveCeil() public {
        ParamCatalog.Structural memory p = _okStructural(); p.maxLeverage = 20_000;
        vm.expectRevert(ParamCatalog.BadLeverage.selector);
        h.validateStructural(p, USDM_18);
    }

    function test_structuralLeverageBelowFloor() public {
        ParamCatalog.Structural memory p = _okStructural(); p.minLeverage = 0;
        vm.expectRevert(ParamCatalog.BadLeverage.selector);
        h.validateStructural(p, USDM_18);
    }

    function test_structuralDurationTooShort() public {
        ParamCatalog.Structural memory p = _okStructural(); p.maxPositionDuration = 1 minutes;
        vm.expectRevert(ParamCatalog.BadDuration.selector);
        h.validateStructural(p, USDM_18);
    }

    function test_structuralDurationTooLong() public {
        ParamCatalog.Structural memory p = _okStructural(); p.maxPositionDuration = 366 days;
        vm.expectRevert(ParamCatalog.BadDuration.selector);
        h.validateStructural(p, USDM_18);
    }

    function test_structuralHouseCutTooHigh() public {
        ParamCatalog.Structural memory p = _okStructural(); p.maxCutPpm = 500_001; // > 50%
        vm.expectRevert(ParamCatalog.BadHouseCut.selector);
        h.validateStructural(p, USDM_18);
    }

    // ---- risk (Iso's bps-denominated Risk — unchanged semantics) ----

    function test_riskOk() public view { h.validateRisk(_okRisk()); }

    function test_riskFeeTooHigh() public {
        ParamCatalog.Risk memory p = _okRisk(); p.openFeeBps = 1001;
        vm.expectRevert(ParamCatalog.BadFee.selector); h.validateRisk(p);
    }

    function test_riskLinearScaleZero() public {
        ParamCatalog.Risk memory p = _okRisk(); p.linearScale = 0;
        vm.expectRevert(ParamCatalog.BadSlippageScale.selector); h.validateRisk(p);
    }

    function test_riskQuadScaleZero() public {
        ParamCatalog.Risk memory p = _okRisk(); p.quadScale = 0;
        vm.expectRevert(ParamCatalog.BadSlippageScale.selector); h.validateRisk(p);
    }

    function test_riskDevBpsTooHigh() public {
        ParamCatalog.Risk memory p = _okRisk(); p.maxDevBps = 10_001;
        vm.expectRevert(ParamCatalog.BadDevBand.selector); h.validateRisk(p);
    }

    // ---- winnings cut: percent-return ramp -----------------------------------
    // rate = min(maxPpm, slopePpm × (returnPpm − interceptPpm)/1e6); cut = effPnl × rate/1e6.

    function test_houseCutBelowInterceptIsZero() public view {
        // +8% return on $1000 col, intercept +10% -> no cut
        assertEq(h.houseCut(80e18, 1000e18, 100_000, 55_000, 55_000), 0);
    }

    function test_houseCutAtInterceptIsZero() public view {
        // exactly +10% return, intercept +10% -> no cut (strict >)
        assertEq(h.houseCut(100e18, 1000e18, 100_000, 55_000, 55_000), 0);
    }

    function test_houseCutOnRamp() public view {
        // +60% return, intercept +10%, slope 5.5%/100% -> rate = 55_000×500_000/1e6 = 27_500 ppm
        // (2.75%); cut = 600e18 × 2.75% = 16.5e18
        assertEq(h.houseCut(600e18, 1000e18, 100_000, 55_000, 55_000), 16.5e18);
    }

    function test_houseCutSaturatesAtMax() public view {
        // +500% return: ramp says 55_000×4.9 = 269_500 ppm -> capped at 55_000 (5.5%);
        // cut = 5000e18 × 5.5% = 275e18
        assertEq(h.houseCut(5000e18, 1000e18, 100_000, 55_000, 55_000), 275e18);
    }

    /// The whole point of the percent intercept: splitting one bet across many
    /// positions/wallets must not dodge the cut. k slices with the same return
    /// pay exactly k × (slice cut) = the merged position's cut.
    function test_houseCutSplitInvariant() public view {
        // one position: $10k col, +60% return
        uint256 whole = h.houseCut(6000e18, 10_000e18, 100_000, 55_000, 55_000);
        // ten positions: $1k col each, +60% return each
        uint256 slice = h.houseCut(600e18, 1000e18, 100_000, 55_000, 55_000);
        assertEq(whole, slice * 10, "splitting must not change the total cut");
    }

    /// And the old nominal-intercept dodge is dead: a tiny position with a huge
    /// percent return pays the cut even though its nominal profit is small.
    function test_houseCutSmallNominalBigReturnStillPays() public view {
        // $1 col, +200% return = $2 profit — far below the old $100-style nominal
        // intercepts, but well past the +10% return intercept.
        uint256 cut = h.houseCut(2e18, 1e18, 100_000, 55_000, 55_000);
        assertEq(cut, 2e18 * 55_000 / PPM); // capped rate: 5.5% of $2
    }

    /// Decimal-bps rates are representable: max cut 12.75 bps = 1275 ppm.
    function test_houseCutDecimalBpsRate() public view {
        // +200% return with intercept 0 and a steep slope -> capped at 1275 ppm;
        // cut = 200e18 × 0.001275 = 0.255e18
        assertEq(h.houseCut(200e18, 100e18, 0, 1_000_000, 1275), 0.255e18);
    }

    function test_houseCutZeroSlopeDisables() public view {
        assertEq(h.houseCut(1000e18, 100e18, 0, 0, 55_000), 0);
    }

    function test_houseCutZeroColIsCappedNotReverting() public view {
        // Defensive: zero collateral = infinite return -> capped rate, never a revert
        // (houseCut sits on the close/liquidate path).
        assertEq(h.houseCut(100e18, 0, 100_000, 55_000, 55_000), 100e18 * 55_000 / PPM);
    }

    function test_houseCutExtremeExcessDoesNotOverflow() public view {
        // Absurd return (1 wei col, huge pnl) with a big slope: saturates at max, no revert.
        uint256 cut = h.houseCut(1e30, 1, 0, type(uint256).max / 2, 55_000);
        assertEq(cut, 1e30 * 55_000 / PPM);
    }

    // ---- size fee (HitOne spread): ppm base + REF-scaled slopes ----------------

    function test_sizeFeeDecimalBpsBase() public view {
        // 0.5 bps = 50 ppm on $10k notional -> $0.50. Unrepresentable in whole bps.
        assertEq(h.sizeFeePpm(10_000e18, USDM_18, 50, 0, 0), 50);
        assertEq(10_000e18 * 50 / PPM, 0.5e18);
    }

    function test_sizeFeeLinearSlopeRef() public view {
        // linearScale = 100 -> +100 ppm (1 bps) at $1M, so +50 ppm at $500k.
        assertEq(h.sizeFeePpm(500_000e18, USDM_18, 0, 100, 0), 50);
        assertEq(h.sizeFeePpm(1_000_000e18, USDM_18, 0, 100, 0), 100);
    }

    function test_sizeFeeQuadSlopeRef() public view {
        // quadScale = 400 -> +400 ppm at $1M; quadratic: +100 ppm at $500k (¼).
        assertEq(h.sizeFeePpm(500_000e18, USDM_18, 0, 0, 400), 100);
        assertEq(h.sizeFeePpm(1_000_000e18, USDM_18, 0, 0, 400), 400);
    }

    function test_sizeFeeAllTermsSum() public view {
        // base 25 ppm + linear 100@1M + quad 400@1M, at $1M -> 25 + 100 + 400 = 525 ppm
        assertEq(h.sizeFeePpm(1_000_000e18, USDM_18, 25, 100, 400), 525);
    }

    function test_sizeFeeZeroScalesAreOff() public view {
        assertEq(h.sizeFeePpm(1_000_000e18, USDM_18, 25, 0, 0), 25);
    }
}
