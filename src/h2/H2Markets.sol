// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { H2Storage }    from "./H2Storage.sol";
import { IH2Oracle }    from "./IH2Oracle.sol";
import { ParamCatalog } from "../common/ParamCatalog.sol";
import { IAggregatorV3 } from "../common/IAggregatorV3.sol";
import { FundingIndex } from "../common/FundingIndex.sol";

/// @title H2Markets
/// @notice Market creation (the only "admin" the exchange has), parameter validation, and
/// the oracle-reading helpers every execution path shares.
abstract contract H2Markets is H2Storage {
    // ---- Market creation ----

    /// @notice Permissionless. `msg.sender` is recorded as the market's creator (identity
    /// only — the treasury is a role-less share vault); every parameter is validated once and
    /// then frozen. Changing anything means creating a successor market and letting this run off.
    function createMarket(
        address token,
        FeeParams calldata fees_,
        RiskParams calldata risk_,
        OracleParams calldata oracles_
    ) external override returns (uint256 marketId) {
        if (token == address(0)) revert BadMarketParams();
        FeeParams memory f = fees_;
        RiskParams memory r = risk_;
        OracleParams memory o = oracles_;

        // ---- fees ----
        if (f.openFlatPpm  > ParamCatalog.MAX_FEE_PPM ||
            f.closeFlatPpm > ParamCatalog.MAX_FEE_PPM) revert BadMarketParams();
        if (f.openLinearScale  > PPM || f.openQuadScale  > PPM ||
            f.closeLinearScale > PPM || f.closeQuadScale > PPM) revert BadMarketParams();
        if (f.maxCutPpm > ParamCatalog.MAX_HOUSE_CUT_PPM) revert BadMarketParams();

        // ---- risk ----
        if (r.priceTick == 0 || r.sizeTick == 0) revert BadMarketParams();
        uint256 product = uint256(r.priceTick) * uint256(r.sizeTick);
        if (product < _usdmDenom || product % _usdmDenom != 0) revert BadMarketParams();
        uint256 scale = product / _usdmDenom;
        if (scale > type(uint128).max) revert BadMarketParams();
        r.notionalScale = uint128(scale);
        if (r.minLeverage < ParamCatalog.MIN_LEVERAGE_FLOOR ||
            r.maxLeverage > ParamCatalog.MAX_LEVERAGE_CEIL ||
            r.minLeverage > r.maxLeverage) revert BadMarketParams();
        if (r.maxPositionDuration < ParamCatalog.MIN_DURATION_FLOOR ||
            r.maxPositionDuration > ParamCatalog.MAX_DURATION_CEIL) revert BadMarketParams();
        if (r.maxPositionNotional == 0) revert BadMarketParams(); // opens have no solvency gate
        if (r.maxOIGross == 0) r.maxOIGross = type(uint128).max;
        if (r.maxOISkew == 0)  r.maxOISkew  = type(uint128).max;
        if (r.liqWidthPpm > 100_000) revert BadMarketParams(); // early-trigger width ≤ 10%
        if (r.unstakeSecs > 30 days) revert BadMarketParams(); // 0 = no cooldown; ≤ 30 d
        // staleSpreadK is ppm per √ms; at the sentinel gap (√4095 ≈ 64) the bound below
        // keeps the max self-service spread ≤ ~20% (64 × 3125 ≈ 200_000 ppm). 0 disables
        // executeAtMark for the market.
        if (r.staleSpreadK > 3_125) revert BadMarketParams();

        // ---- oracles ----
        IH2Oracle.FeedView memory feed = _oracle.feedOf(o.primaryFeedId); // reverts UnknownFeed
        // The ring is recorded in the feed's tick; the walk-back replays it in the
        // market's units, so the two must be identical.
        if (feed.priceTick != r.priceTick) revert BadMarketParams();
        if (o.fallbackFeed == address(0)) revert BadMarketParams();
        if (o.fallbackDecimals > 18) revert BadMarketParams();
        // Decimals scale the fallback price to 1e18; a caller-supplied value that disagrees with
        // the aggregator would misprice every fallback fill and skew the deviation gate, so pin
        // it to the feed's own `decimals()` rather than trust the argument.
        if (IAggregatorV3(o.fallbackFeed).decimals() != o.fallbackDecimals) revert BadMarketParams();
        if (o.primaryStaleSecs == 0 || o.primaryStaleSecs > 1 days) revert BadMarketParams();
        if (o.fallbackMaxAge == 0 || o.fallbackMaxAge > 1 hours) revert BadMarketParams();
        if (o.fbOpenSpreadPpm > 200_000 || o.fbCloseSpreadPpm > 200_000) revert BadMarketParams();
        if (o.fbLiqSpreadPpm > o.fbCloseSpreadPpm) revert BadMarketParams();
        if (o.maxDeviationPpm == 0 || o.maxDeviationPpm > 200_000) revert BadMarketParams();
        if (r.maxSpreadPpm > 200_000) revert BadMarketParams();

        // THE ANTI-SANDWICH BOUND. Fills are formulaic, so a round trip's profit against
        // the treasury is bounded by how far the executing price can sit from truth —
        // which the deviation gate bounds. Require the MINIMUM round-trip cost (the flat
        // fee terms; neither size nor the spread oracle can lower them) to exceed it, so
        // a market whose treasury pays you to trade the oracle gap cannot exist.
        if (uint256(f.openFlatPpm) + uint256(f.closeFlatPpm) < uint256(o.maxDeviationPpm))
            revert BadMarketParams();

        // The coupled funding ceiling: funding accrued during the window users cannot
        // exit without the operator can never eat more than half of worst-case
        // collateral. The rate bound is the FEED's frozen cap (enforced at push — indices
        // integrate history, so no consumption-time cap could undo an accrual), and the
        // market's own cap field must dominate it.
        if (r.fundingRateCapPerSec == 0 || feed.maxRatePerSec > r.fundingRateCapPerSec)
            revert BadMarketParams();
        if (uint256(r.fundingRateCapPerSec) * uint256(o.primaryStaleSecs) * uint256(r.maxLeverage) * 2
            > uint256(FundingIndex.PCT_SCALE)) revert BadMarketParams();

        marketId = ++nextMarketId;
        if (marketId > type(uint64).max) revert BadMarketParams(); // Position packs it uint64
        _fees[marketId]      = f;
        _risk[marketId]      = r;
        _oracles[marketId]   = o;
        _creatorOf[marketId] = msg.sender;
        _tokenOf[marketId]   = token;
        // Cache the primary feed's rake — the operator's frozen cut of this market's earnings.
        _vault[marketId].rakePpm = uint32(feed.feeRakePpm);
        emit MarketCreated(marketId, msg.sender, token, f, r, o);
    }

    // ---- views ----

    function creatorOf(uint256 marketId) external view override returns (address) {
        return _creatorOf[marketId];
    }
    function feeParamsOf(uint256 marketId) external view override returns (FeeParams memory) {
        if (_creatorOf[marketId] == address(0)) revert UnknownMarket();
        return _fees[marketId];
    }
    function riskParamsOf(uint256 marketId) external view override returns (RiskParams memory) {
        if (_creatorOf[marketId] == address(0)) revert UnknownMarket();
        return _risk[marketId];
    }
    function oracleParamsOf(uint256 marketId) external view override returns (OracleParams memory) {
        if (_creatorOf[marketId] == address(0)) revert UnknownMarket();
        return _oracles[marketId];
    }
    function marketOf(uint256 marketId) external view override returns (MarketView memory) {
        if (_creatorOf[marketId] == address(0)) revert UnknownMarket();
        IH2Oracle.FeedView memory feed = _oracle.feedOf(_oracles[marketId].primaryFeedId);
        return MarketView({
            creator:           _creatorOf[marketId],
            token:             _tokenOf[marketId],
            primaryFeedId:     _oracles[marketId].primaryFeedId,
            mark:              feed.mark,
            lastPushMs:        feed.lastPushMs,
            openInterestLong:  openInterestLong[marketId],
            openInterestShort: openInterestShort[marketId]
        });
    }

    // ---- oracle-reading helpers ----

    function _feed(uint256 marketId) internal view returns (IH2Oracle.FeedView memory) {
        return _oracle.feedOf(_oracles[marketId].primaryFeedId);
    }

    /// @dev One side's funding index projected to now, computed locally from a FeedView
    /// (saves a second oracle call on paths that already fetched the feed).
    function _indexNow(IH2Oracle.FeedView memory feed, bool isLong) internal view returns (int128) {
        return FundingIndex.effectiveAtPctMs(
            isLong ? feed.fundingIndexLong : feed.fundingIndexShort,
            isLong ? feed.rateLong : feed.rateShort,
            feed.mark,
            feed.lastPushMs, uint64(_microTimestamp() / 1000)
        );
    }

    /// @dev The fallback feed's price (1e18) and freshness, per the market's params.
    /// Rejects non-positive and future-stamped answers outright.
    function _fallbackRead(OracleParams storage o)
        internal view returns (uint256 price1e18, bool fresh)
    {
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(o.fallbackFeed).latestRoundData();
        if (answer <= 0) revert OracleBadAnswer();
        uint256 upd = _updatedAtSecs(updatedAt);
        if (upd > block.timestamp + 60) revert OracleBadAnswer(); // future-stamped
        price1e18 = uint256(answer) * (10 ** (18 - uint256(o.fallbackDecimals)));
        fresh = block.timestamp <= upd + uint256(o.fallbackMaxAge);
    }

    /// @dev THE CONVERGENCE CHECK: require the primary mark and the fallback to agree
    /// within `maxDeviationPpm` — a fresh fallback that disagrees blocks the action rather
    /// than letting either price win. Publications are ungated (the oracle doesn't know
    /// markets exist), so the ring stays alive through a gated window and the walk-back can
    /// catch in-window crossings once the gate lifts.
    ///
    /// The two callers differ only in how they treat a STALE fallback:
    ///  - `requireFallback == false` (operator-attached `onMark`, authoritative fresh mark):
    ///    a stale fallback is simply no anchor to disagree with, so the check passes.
    ///  - `requireFallback == true` (self-service against a STALE mark): the mark is only
    ///    trustworthy if the fresh fallback vouches for it, so a missing anchor is fatal.
    function _assertConvergence(uint256 marketId, uint256 primaryMark1e18, bool requireFallback)
        internal view
    {
        OracleParams storage o = _oracles[marketId];
        (uint256 fb, bool fresh) = _fallbackRead(o);
        if (!fresh) {
            if (requireFallback) revert OracleTooOld();
            return;
        }
        uint256 diff = primaryMark1e18 > fb ? primaryMark1e18 - fb : fb - primaryMark1e18;
        if (diff * PPM > uint256(o.maxDeviationPpm) * fb) revert DeviationGate();
    }

    /// @dev Primary feed staleness on the HP clock — the fallback path's arming test.
    /// A never-published feed does NOT arm: no position can exist on it (both execution
    /// paths refuse), and arming it would let positions exist against a zero mark.
    function _primaryStale(uint256 marketId, IH2Oracle.FeedView memory feed)
        internal view returns (bool)
    {
        if (feed.lastPushMs == 0) return false;
        uint64 nowMs = uint64(_microTimestamp() / 1000);
        return nowMs - feed.lastPushMs > uint64(_oracles[marketId].primaryStaleSecs) * 1000;
    }
}
