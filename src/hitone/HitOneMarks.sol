// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { HitOneStorage }     from "./HitOneStorage.sol";
import { ParamCatalog }      from "../common/ParamCatalog.sol";
import { IAggregatorV3 }     from "../common/IAggregatorV3.sol";
import { IHighPrecisionTimestamp } from "../common/IHighPrecisionTimestamp.sol";
import { MarkRing }          from "../common/MarkRing.sol";
import { FundingIndex }      from "../common/FundingIndex.sol";

/// @title HitOneMarks
/// @notice Mark + funding push logic and the mark-domain views.
abstract contract HitOneMarks is HitOneStorage {
    // ---- Mark + funding (admin) ----

    /// @notice Push a mark to the caller's OWN (msg.sender, token) book. Permissionless — anyone
    /// may quote their own market on a registered token.
    function setMark(address token, uint256 newMark) external override whenNotHalted {
        MarkState storage st = _markState[msg.sender][token];
        _pushMark(msg.sender, token, newMark, st.currentRateLong, st.currentRateShort, false);
    }
    // rateLong/rateShort are signed fixed-point funding FRACTIONS per second (real = rate / (100 *
    // 2**63)), NOT price-scaled amounts. The int64 range inherently caps each at ±1%/sec, so no
    // explicit bound check is needed. Each side is independent — see IHitOneMarket.setMarkAndRate.
    function setMarkAndRate(address token, uint256 newMark, int64 rateLong, int64 rateShort)
        external override whenNotHalted
    {
        _pushMark(msg.sender, token, newMark, rateLong, rateShort, true);
    }

    /// @dev Project one side's committed funding index forward to now, folding that side's live rate
    /// into the live mark. `priceTick` converts `currentMark` (price units) back to 1e18 USDM-wei.
    function _indexNow(MarkState storage st, uint256 priceTick, bool isLong) internal view returns (int128) {
        return FundingIndex.effectiveAtPct(
            isLong ? st.fundingIndexLong : st.fundingIndexShort,
            isLong ? st.currentRateLong  : st.currentRateShort,
            uint256(st.currentMark) * priceTick,
            st.lastPushAt, uint64(block.timestamp)
        );
    }

    function _pushMark(
        address maker, address token, uint256 newMark_1e18,
        int64 nextRateLong, int64 nextRateShort, bool isRateChange
    ) internal {
        ParamCatalog.Structural storage s = _params[token].structural;
        if (s.priceTick == 0) revert UnknownToken();
        uint128 newMarkUnits = _toPriceUnits(newMark_1e18, s.priceTick);

        _checkOracleBand(token, newMark_1e18);
        uint256 microTs = _microTimestamp();
        uint64 nowMs = uint64(microTs / 1000);

        MarkState storage st = _markState[maker][token];
        if (st.lastPushAt == 0) {
            st.currentMark = newMarkUnits;
            st.lastPushAt  = uint64(block.timestamp);
            st.lastPushMs  = nowMs;
            st.currentRateLong  = nextRateLong;
            st.currentRateShort = nextRateShort;
            emit MarkPushed(maker, token, newMark_1e18, 0, 0, false, microTs);
            if (isRateChange) emit FundingRateChanged(maker, token, nextRateLong, nextRateShort, uint64(block.timestamp));
            return;
        }

        // Liveness + ring gap run on the HP millisecond clock; funding stays second-based.
        uint64 elapsedMs = nowMs - st.lastPushMs;
        if (elapsedMs == 0) revert MarkSameSlot();

        int64 oldRateLong  = st.currentRateLong;
        int64 oldRateShort = st.currentRateShort;
        // Accrue the elapsed interval on BOTH sides at the OLD rate and OLD mark (both still live
        // here — the mark is a step function held until this push overwrites it below).
        uint256 mark1e18 = uint256(st.currentMark) * s.priceTick;
        st.fundingIndexLong  = FundingIndex.effectiveAtPct(st.fundingIndexLong,  oldRateLong,  mark1e18, st.lastPushAt, uint64(block.timestamp));
        st.fundingIndexShort = FundingIndex.effectiveAtPct(st.fundingIndexShort, oldRateShort, mark1e18, st.lastPushAt, uint64(block.timestamp));

        int256 priceDelta;
        unchecked {
            priceDelta = int256(uint256(newMarkUnits)) - int256(uint256(st.currentMark));
        }

        uint64 head = st.ringHead;
        uint256 elapsedUnits = uint256(elapsedMs) / MarkRing.GAP_UNIT_MS;
        bool sentinel = elapsedUnits > MarkRing.GAP_MAX_UNITS;

        uint32 markEntry;
        if (sentinel) {
            markEntry = MarkRing.sentinelEntry();
            emit MarkPushed(maker, token, newMark_1e18, priceDelta, 0, true, microTs);
        } else {
            markEntry = MarkRing.packEntry(priceDelta, elapsedUnits);
            emit MarkPushed(maker, token, newMark_1e18, priceDelta, uint16(elapsedUnits), false, microTs);
        }
        MarkRing.writeMarkEntry(_markRing[maker][token], head, markEntry);

        st.ringHead    = head + 1;
        st.currentMark = newMarkUnits;
        st.lastPushAt  = uint64(block.timestamp);
        st.lastPushMs  = nowMs;

        if (isRateChange) {
            st.currentRateLong  = nextRateLong;
            st.currentRateShort = nextRateShort;
            emit FundingRateChanged(maker, token, nextRateLong, nextRateShort, uint64(block.timestamp));
        }
    }

    /// @dev Microsecond wall-clock from MegaETH's system contract, for off-chain validation of
    /// mark timing. Falls back to `block.timestamp × 1e6` if the system contract is absent (e.g.
    /// non-MegaETH chains or tests) so a mark push never bricks on the read.
    function _microTimestamp() internal view returns (uint256) {
        (bool ok, bytes memory ret) = HP_TIMESTAMP.staticcall(
            abi.encodeWithSelector(IHighPrecisionTimestamp.timestamp.selector)
        );
        if (ok && ret.length >= 32) return abi.decode(ret, (uint256));
        return uint256(block.timestamp) * 1_000_000;
    }

    /// @dev Owner-set per-token band: every maker's marks on `token` are checked against the same
    /// oracle feed and `maxDevBps`, so a maker cannot loosen it. Skipped entirely when `feed == 0`.
    function _checkOracleBand(address token, uint256 newMark_1e18) internal view {
        OracleConfig storage oc = _oracleConfig[token];
        address feed = oc.feed;
        if (feed == address(0)) return;
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        if (answer <= 0)                                           revert OracleBadAnswer();
        if (block.timestamp > updatedAt + uint256(oc.maxStale))    revert OracleStale();
        uint256 oraclePx = uint256(answer) * (10 ** (18 - uint256(oc.decimals)));
        uint256 diff = newMark_1e18 > oraclePx ? newMark_1e18 - oraclePx : oraclePx - newMark_1e18;
        if (diff * ParamCatalog.BPS_DENOM > uint256(oc.maxDevBps) * oraclePx) revert MarkOutOfOracleBand();
    }

    // ---- Mark-domain views ----

    function marketOf(address maker, address token) external view override returns (MarketView memory) {
        MarkState storage st = _markState[maker][token];
        return MarketView({
            mark:              _priceOut(st.currentMark, _params[token].structural.priceTick),
            fundingIndexLong:  st.fundingIndexLong,
            fundingIndexShort: st.fundingIndexShort,
            currentRateLong:   st.currentRateLong,
            currentRateShort:  st.currentRateShort,
            ringHead:          st.ringHead,
            openInterestLong:  openInterestLong[maker][token],
            openInterestShort: openInterestShort[maker][token]
        });
    }

    // NOTE: `reconstructAt` (historical mark/funding walk-back view) was removed to fit the
    // EIP-170 contract-size limit. Off-chain consumers reconstruct the same values from the
    // `MarkPushed` (priceDelta + timeDeltaMs) and `FundingRateChanged` event streams.
}
