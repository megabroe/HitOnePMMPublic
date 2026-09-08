// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title ParamCatalog
/// @notice Per-token configuration shared by every venue. Two cadences:
///   - `Structural` — infrequent. Tick granularity (price + size), leverage range,
///     position lifetime, house cut.
///   - `Risk` — frequent. Fee, slippage scales (in sizeUnits), OI caps, oracle deviation band.
///
/// **Internal-vs-external scale.** External API takes price/size in 1e18-scaled USDM-wei and
/// asset-wei (unchanged from prior versions). Internally, every venue stores priceUnits and
/// sizeUnits compressed by `priceTick` and `sizeTick` — fitting easily in uint128 each.
/// Math is overflow-safe in tick-space because realistic priceUnits/sizeUnits are far below
/// 2^96. The conversion is transparent: outputs (events, views) emit 1e18-scaled values.
library ParamCatalog {
    uint256 internal constant SCALE                = 1e18;
    uint256 internal constant BPS_DENOM            = 10_000;
    /// @notice Fee / winnings-cut rates are denominated in PPM (parts per million)
    /// of the base amount: **1 ppm = 0.01 bps**, so "2.5 bps" = 250 ppm. This is
    /// what makes decimal-bps configs representable — bps-denominated rates can
    /// only step in whole bps. (`maxSlippageBps` in the signed Order stays bps:
    /// it's inside the frozen EIP-712 typehash and user tolerances don't need
    /// sub-bps resolution.)
    uint256 internal constant RATE_DENOM           = 1_000_000;
    uint256 internal constant MAX_FEE_BPS          = 1_000;    // open-fee cap for bps-denominated venues
    uint256 internal constant MAX_FEE_PPM          = 100_000;  // 10% — open-fee cap for ppm-denominated venues
    uint256 internal constant MAX_HOUSE_CUT_PPM    = 500_000;  // 50% ceiling on the cut rate
    uint256 internal constant MIN_LEVERAGE_FLOOR   = 1;
    uint256 internal constant MAX_LEVERAGE_CEIL    = 10_000;
    uint256 internal constant MIN_DURATION_FLOOR   = 1 hours;
    uint256 internal constant MAX_DURATION_CEIL    = 365 days;
    uint256 internal constant MAX_DEV_BPS          = 10_000;

    /// @notice Skew is measured in PPM (parts per million). 1 PPM = 0.0001%.
    /// fillPrice = mark × (SKEW_SCALE ± skew) / SKEW_SCALE.
    uint256 internal constant SKEW_SCALE           = 1_000_000;
    uint256 internal constant SKEW_SCALE_SQRT      = 1_000;

    error BadPriceTick();
    error BadSizeTick();
    error BadSlippageScale();
    error BadFee();
    error BadLeverage();
    error BadDuration();
    error BadHouseCut();
    error BadDevBand();

    /// @notice Infrequent-cadence params.
    ///
    /// **Winnings cut.** The house rake on positive effective PnL is a per-token linear ramp on
    /// the position's PERCENT RETURN (`effPnl / collateral`), not on nominal profit — a nominal
    /// threshold/ramp is dodged by splitting one bet across many positions or wallets, while a
    /// percent-return measure is split-invariant (each slice keeps the same return). No cut
    /// applies until the return clears `cutInterceptPpm`. Above it, the cut *rate* ramps by
    /// `cutSlopePpm` per 1e6 ppm (i.e. per +100%) of excess return, capped at `maxCutPpm`. The
    /// cut is then that rate applied to the *whole* effective PnL. All three are PPM
    /// (1 ppm = 0.01 bps), so decimal-bps configs are representable. See `houseCut`.
    struct Structural {
        uint256 priceTick;          // min price step in 1e18 USDM-wei (e.g., 1e18 = $1 step)
        uint256 sizeTick;           // min size step in 1e18 asset-wei (e.g., 1e10 = 1 sat for BTC)
        uint256 notionalScale;      // derived = (priceTick × sizeTick) / 1e18; USDM-wei per (priceUnit × sizeUnit)
        uint256 minLeverage;
        uint256 maxLeverage;
        uint256 maxPositionDuration;
        uint256 cutInterceptPpm;    // return (effPnl/col, ppm) below which no winnings cut is taken; 100_000 = +10%
        uint256 cutSlopePpm;        // cut-rate ppm added per 1e6 ppm (+100%) of return above the intercept
        uint256 maxCutPpm;          // ceiling on the winnings-cut rate, ppm (≤ MAX_HOUSE_CUT_PPM)
    }

    /// @notice Frequent-cadence params. Slippage scales are in `sizeUnits`, not 1e18.
    struct Risk {
        uint256 openFeeBps;
        uint256 linearScale;        // larger ⇒ less linear slippage; type(uint256).max ⇒ off
        uint256 quadScale;          // larger ⇒ less quadratic slippage; type(uint256).max ⇒ off
        uint256 maxPositionNotional;// USDM-wei (1e18 scale) — unchanged convention
        uint256 maxOIGross;         // USDM-wei
        uint256 maxOISkew;          // USDM-wei
        uint256 maxDevBps;
    }

    struct TokenParams {
        Structural structural;
        Risk       risk;
    }

    /// @notice Validate `structural` AND compute the derived `notionalScale` field.
    /// `usdmDenom = 10 ** usdm.decimals()` is passed by the venue (cached in its constructor).
    /// `notionalScale = priceTick × sizeTick / usdmDenom` — must be a positive integer.
    function validateAndDeriveStructural(Structural memory p, uint256 usdmDenom) internal pure {
        if (p.priceTick == 0)                                                revert BadPriceTick();
        if (p.sizeTick == 0)                                                 revert BadSizeTick();
        uint256 product = p.priceTick * p.sizeTick;
        if (product < usdmDenom || product % usdmDenom != 0)                 revert BadPriceTick();
        p.notionalScale = product / usdmDenom;
        if (p.minLeverage < MIN_LEVERAGE_FLOOR ||
            p.maxLeverage > MAX_LEVERAGE_CEIL ||
            p.minLeverage > p.maxLeverage)                                   revert BadLeverage();
        if (p.maxPositionDuration < MIN_DURATION_FLOOR ||
            p.maxPositionDuration > MAX_DURATION_CEIL)                       revert BadDuration();
        if (p.maxCutPpm > MAX_HOUSE_CUT_PPM)                                 revert BadHouseCut();
    }

    /// @notice Winnings cut on positive effective PnL, ramping on PERCENT RETURN.
    ///
    /// `returnPpm = effPnl × 1e6 / col`; below/at `interceptPpm` there is no cut. Above it,
    /// `rate = min(maxPpm, slopePpm × (returnPpm − interceptPpm) / 1e6)` and the returned cut is
    /// `effPnl × rate / 1e6`. Split-invariant: k positions with the same leverage and the same
    /// price move have the same `returnPpm` as the single merged position, so they pay the same
    /// total cut — opening many small positions (or many wallets) doesn't dodge the rake.
    ///
    /// Never reverts (it sits on the close/liquidate path): the ramp saturates at `maxPpm` before
    /// `slopePpm × excess` could overflow, and a zero-collateral edge (can't happen for a real
    /// position) is treated as infinite return → capped rate.
    function houseCut(
        uint256 effPnl,
        uint256 col,
        uint256 interceptPpm,
        uint256 slopePpm,
        uint256 maxPpm
    ) internal pure returns (uint256) {
        if (effPnl == 0 || slopePpm == 0 || maxPpm == 0) return 0;
        uint256 ratePpm;
        if (col == 0) {
            ratePpm = maxPpm; // defensive: infinite return
        } else {
            uint256 returnPpm = effPnl * RATE_DENOM / col;
            if (returnPpm <= interceptPpm) return 0;
            uint256 excess = returnPpm - interceptPpm;
            if (excess > type(uint256).max / slopePpm) {
                ratePpm = maxPpm; // would overflow ⇒ far past the cap anyway
            } else {
                ratePpm = slopePpm * excess / RATE_DENOM;
                if (ratePpm > maxPpm) ratePpm = maxPpm;
            }
        }
        return effPnl * ratePpm / RATE_DENOM;
    }

    /// @notice Size-scaled open-fee rate (PPM). `N = notional / usdmDenom` (whole USDM):
    ///   ppm = openFeePpm + linearScale·N / 1e6 + quadScale·N² / 1e12
    /// `linearScale`/`quadScale` read as "extra ppm at $1M notional" (linear ∝ N, quad ∝ N²) —
    /// the REF divisors are how fractional slopes are encoded: `linearScale = 100` is
    /// +100 ppm (= 1 bps) at $1M, i.e. 0.0001 ppm per whole USDM. `0` disables a term.
    /// Checked arithmetic reverts on absurd configs (too-large scales) — acceptable here
    /// because this runs at OPEN, never on the close path.
    uint256 internal constant SIZE_FEE_LINEAR_REF = 1e6;   // $1M in whole USDM
    uint256 internal constant SIZE_FEE_QUAD_REF   = 1e12;  // ($1M)²
    function sizeFeePpm(
        uint256 notional,
        uint256 usdmDenom,
        uint256 openFeePpm,
        uint256 linearScale,
        uint256 quadScale
    ) internal pure returns (uint256 ppm) {
        uint256 n = notional / usdmDenom;
        ppm = openFeePpm;
        if (linearScale != 0) ppm += linearScale * n / SIZE_FEE_LINEAR_REF;
        if (quadScale   != 0) ppm += quadScale * n * n / SIZE_FEE_QUAD_REF;
    }

    /// @notice Vol/skew → spread. The feed operator publishes a `(vol, skew)` estimate, both
    /// in PPM of price (`10_000` = 1%); the market's frozen `(volK, skewK)` coefficients derive
    /// the per-side spread, capped:
    ///   spread = volK·vol²/VOL_REF ± skewK·skew/SKEW_REF   (clamped to [0, maxSpreadPpm])
    /// The `vol²` term prices variance (a doubling of vol quadruples the spread, below the cap);
    /// the linear skew term is added on the taker's BUY side and subtracted on the SELL side —
    /// the caller passes `up = (isLong == isOpen)` (true when the taker is buying: opening a long
    /// or closing a short), so `skew > 0` charges buyers more and rebates sellers (standard
    /// inventory/drift quote-skew, applied by fill direction, not by position side). `VOL_REF`
    /// pins `volK` as "ppm of spread at 1% vol" (vol=10_000 ⇒ base=volK); `SKEW_REF` pins `skewK`
    /// as "ppm per 1% skew". The favored side floors at 0 (never a rebate). Never reverts: the
    /// intermediate `volK·vol²` fits uint256 (volK ≤ 1e9, vol ≤ 2³²), and the result caps.
    uint256 internal constant VOL_REF  = 1e8;   // (1% vol)² in ppm² = 10_000² = 1e8
    uint256 internal constant SKEW_REF = 1e4;   // 1% skew in ppm
    function derivedSpread(
        uint32  vol,
        int32   skew,
        uint32  volK,
        uint32  skewK,
        bool    up,
        uint256 maxSpreadPpm
    ) internal pure returns (uint256) {
        // base = volK · vol² / VOL_REF  (variance-like, unsigned)
        uint256 base = uint256(volK) * uint256(vol) * uint256(vol) / VOL_REF;
        // skewTerm = skewK · skew / SKEW_REF  (signed, linear). skew>0 disfavors buyers (up-fills).
        int256 skewTerm = (int256(uint256(skewK)) * int256(skew)) / int256(SKEW_REF);
        int256 sided = int256(base) + (up ? skewTerm : -skewTerm);
        if (sided <= 0) return 0; // clamp ≥ 0: the favored side never gets a rebate
        uint256 s = uint256(sided);
        return s > maxSpreadPpm ? maxSpreadPpm : s;
    }

    /// @notice Validate `risk`. `linearScale` and `quadScale` are interpreted in sizeUnits.
    function validateRisk(Risk memory p) internal pure {
        if (p.openFeeBps > MAX_FEE_BPS)                                      revert BadFee();
        if (p.linearScale == 0 || p.quadScale == 0)                          revert BadSlippageScale();
        if (p.maxDevBps > MAX_DEV_BPS)                                       revert BadDevBand();
    }
}
