// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { H2Positions } from "./H2Positions.sol";
import { IH2Oracle }   from "./IH2Oracle.sol";

/// @title H2Fallback
/// @notice The two permissionless execution paths that let a user act without the feed
/// operator.
///
/// `executeAtMark` (self-service): while the primary mark is fresher than the ring's
/// sentinel gap, anyone executes against it, paying a staleness spread `staleSpreadK · √age`
/// that grows with the mark's age — gated by a fresh fallback within `maxDeviationPpm`, the
/// anchor that makes a stale-mark trade safe. This is the path that stops the operator from
/// being a gatekeeper: a user never depends on it to open or close.
///
/// `executeAtFallback` (deep failure): once the primary is stale past `primaryStaleSecs`,
/// anyone executes and liquidates against the market's fallback push feed at its price ±
/// the market's fallback spreads.
///
/// Neither publishes to the primary feed, so the operator's next publication resumes the
/// operator-attached path, and funding keeps accruing from the primary feed's indices. If
/// BOTH oracles fail, positions exit via `expirePosition` at the last primary mark.
abstract contract H2Fallback is H2Positions {
    /// @notice Primary-staleness check only; fallback freshness is enforced at execution.
    function fallbackArmed(uint256 marketId) public view override returns (bool) {
        if (_creatorOf[marketId] == address(0)) revert UnknownMarket();
        return _primaryStale(marketId, _feed(marketId));
    }

    // ============================================================
    // self-service against the (stale) primary mark
    // ============================================================

    function executeAtMark(Order calldata order, bytes calldata userSig)
        external override nonReentrant returns (uint256 id)
    {
        uint256 marketId = order.marketId;
        RiskParams storage r = _risk[marketId];
        if (_creatorOf[marketId] == address(0)) revert UnknownMarket();
        if (r.staleSpreadK == 0) revert SelfServiceDisabled();

        IH2Oracle.FeedView memory feed = _feed(marketId);
        if (feed.lastPushAt == 0) revert PrimaryNeverPushed();

        // Mark age must be under the sentinel gap: a mark older than that sits across a ring
        // discontinuity the walk-back cannot replay, so it is not a safe anchor for a new
        // position. Measured on the HP millisecond clock (the ring's clock).
        uint64 nowMs = uint64(_microTimestamp() / 1000);
        uint256 ageMs = uint256(nowMs - feed.lastPushMs);
        if (ageMs > MARK_RING_GAP_MAX_MS) revert MarkTooStale();

        // The stale mark is only trustworthy if the fresh fallback vouches for it, so the
        // fallback must be fresh (the anchor) AND within the deviation band — a missing
        // anchor is fatal here, unlike the operator-attached path.
        _assertConvergence(marketId, feed.mark, true);

        // staleSpread = staleSpreadK · √ageMs (ppm), on TOP of the feed's capped spread.
        uint256 spreadPpm = feed.spreadPpm;
        if (spreadPpm > r.maxSpreadPpm) spreadPpm = r.maxSpreadPpm;
        spreadPpm += uint256(r.staleSpreadK) * Math.sqrt(ageMs);

        uint256 fill = _adverseFill(order, feed.mark, spreadPpm, r.priceTick);
        _verifyAndConsumeOrder(order, userSig);
        id = _routeOrder(order, fill, feed);
        emit MarkExecuted(marketId, id, feed.mark, fill, ageMs);
    }

    function executeAtFallback(Order calldata order, bytes calldata userSig)
        external override nonReentrant returns (uint256 id)
    {
        uint256 marketId = order.marketId;
        if (!fallbackArmed(marketId)) revert FallbackNotArmed(); // also reverts UnknownMarket
        OracleParams storage o = _oracles[marketId];
        (uint256 price, bool fresh) = _fallbackRead(o);
        if (!fresh) revert OracleTooOld();

        uint256 spreadPpm = order.isOpen ? o.fbOpenSpreadPpm : o.fbCloseSpreadPpm;
        uint256 fill = _adverseFill(order, price, spreadPpm, _risk[marketId].priceTick);

        _verifyAndConsumeOrder(order, userSig);
        // Funding checkpoints/settlement still read the primary feed's indices.
        id = _routeOrder(order, fill, _feed(marketId));
        emit FallbackExecuted(marketId, id, price, fill);
    }

    function liquidateAtFallback(uint256 marketId, uint256[] calldata positionIds)
        external override nonReentrant
    {
        if (!fallbackArmed(marketId)) revert FallbackNotArmed();
        OracleParams storage o = _oracles[marketId];
        (uint256 price, bool fresh) = _fallbackRead(o);
        if (!fresh) revert OracleTooOld();

        // The liquidation cushion is applied in the POSITION's favor — it must be
        // liquidatable even after the benefit of the doubt, so fallback-feed noise cannot
        // cause a wrongful wipe. A long is hurt by low prices, so its test price shifts
        // (and tick-rounds) up; a short down.
        uint256 tick = _risk[marketId].priceTick;
        uint256 cushion = price * uint256(o.fbLiqSpreadPpm) / PPM;
        uint128 testLongUnits  = _toPriceUnits(_ceilToTick(price + cushion, tick), tick);
        uint128 testShortUnits = _toPriceUnits(_floorToTick(price - cushion, tick), tick);

        IH2Oracle.FeedView memory feed = _feed(marketId);
        int128 indexLongNow  = _indexNow(feed, true);
        int128 indexShortNow = _indexNow(feed, false);

        uint256 wipedCount = 0;
        for (uint256 i = 0; i < positionIds.length; i++) {
            uint256 id = positionIds[i];
            Position storage pos = _positions[id];
            if (pos.user == address(0) || pos.closed || pos.marketId != marketId) continue;
            uint128 testUnits = pos.isLong ? testLongUnits : testShortUnits;
            int128  indexNow_ = pos.isLong ? indexLongNow : indexShortNow;
            // Direct test at the fallback price — no walk-back: the primary ring is what
            // went stale. The widened threshold applies here too.
            if (!_isLiquidatable(pos, testUnits, indexNow_, _risk[marketId])) continue;
            _wipePosition(id, testUnits, 0);
            wipedCount++;
        }
        if (wipedCount == 0) revert NoneLiquidated();
        emit FallbackLiquidated(marketId, price, wipedCount);
    }
}
