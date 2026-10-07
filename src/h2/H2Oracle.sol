// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IH2Oracle, IH2OracleCallback } from "./IH2Oracle.sol";
import { IAggregatorV3 } from "../common/IAggregatorV3.sol";
import { IHighPrecisionTimestamp } from "../common/IHighPrecisionTimestamp.sol";
import { MarkRing }     from "../common/MarkRing.sol";
import { FundingIndex } from "../common/FundingIndex.sol";

/// @title H2Oracle
/// @notice See IH2Oracle. Standalone, ownerless, immutable. Holds no funds and knows
/// nothing about markets — feeds are price/funding/spread streams plus a replayable ring,
/// and the pull path is an opinionless callback dispatcher.
contract H2Oracle is IH2Oracle, ReentrancyGuard {
    /// @dev MegaETH high-precision-timestamp system contract (µs since epoch).
    address internal constant HP_TIMESTAMP =
        0x6342000000000000000000000000000000000002;

    uint256 internal constant UNITS_CAP = 1 << 96;
    uint256 internal constant PPM = 1_000_000;

    /// @notice Packed to 6 slots.
    struct Feed {
        // Slot 0
        address operator;   // 20
        uint32  vol;        // 4 — operator vol estimate (PPM); market derives spread
        int32   skew;       // 4 — operator directional skew (signed PPM)
        // Slot 1
        uint128 priceTick;   // 1e18-scale quantum
        uint128 currentMark; // priceUnits (mark / priceTick)
        // Slot 2
        int128  fundingIndexLong;
        int64   rateLong;
        uint64  lastPushMs; // HP wall-clock — ring/staleness clock
        // Slot 3
        int128  fundingIndexShort;
        int64   rateShort;
        uint64  ringHead;
        // Slot 4
        address refFeed;       // 20; 0 = unbanded
        uint8   refDecimals;   // 1
        uint32  refBandPpm;    // 4
        uint32  refMaxStale;   // 4
        // Slot 5 (head of)
        uint64  maxRatePerSec; // frozen; enforced at push
        uint32  feeRakePpm;    // frozen; operator's rake on consuming markets' earnings
    }
    mapping(uint256 => Feed) internal _feeds;
    mapping(uint256 => uint256[25]) internal _rings; // 25 = MarkRing.MARK_SLOT_COUNT
    uint256 public override nextFeedId;

    modifier onlyOperator(uint256 feedId) {
        if (_feeds[feedId].operator == address(0)) revert UnknownFeed();
        if (msg.sender != _feeds[feedId].operator) revert NotOperator();
        _;
    }

    // ============================================================
    // feeds
    // ============================================================

    function createFeed(
        address operator,
        uint256 priceTick,
        uint64  maxRatePerSec,
        uint32  feeRakePpm,
        address refFeed,
        uint8   refDecimals,
        uint32  refBandPpm,
        uint32  refMaxStale
    ) external override returns (uint256 feedId) {
        if (operator == address(0)) revert BadFeedParams();
        if (priceTick == 0 || priceTick > type(uint128).max) revert BadFeedParams();
        if (maxRatePerSec == 0 || maxRatePerSec > uint64(uint256(int256(type(int64).max))))
            revert BadFeedParams();
        if (feeRakePpm > 500_000) revert BadFeedParams(); // rake ≤ 50%
        if (refFeed != address(0)) {
            // A banded feed's guarantee must be meaningful: nonzero band ≤ 100%, bounded
            // staleness, decodable decimals.
            if (refBandPpm == 0 || refBandPpm > PPM) revert BadFeedParams();
            if (refMaxStale == 0) revert BadFeedParams();
            if (refDecimals > 18) revert BadFeedParams();
            // Decimals scale the reference price in the band check; a caller-supplied value
            // that disagrees with the aggregator would misscale every comparison, so pin it to
            // the feed's own `decimals()` rather than trust the argument.
            if (IAggregatorV3(refFeed).decimals() != refDecimals) revert BadFeedParams();
        } else {
            if (refBandPpm != 0 || refMaxStale != 0 || refDecimals != 0) revert BadFeedParams();
        }
        feedId = ++nextFeedId;
        Feed storage f = _feeds[feedId];
        f.operator      = operator;
        f.priceTick     = uint128(priceTick);
        f.maxRatePerSec = maxRatePerSec;
        f.feeRakePpm    = feeRakePpm;
        f.refFeed     = refFeed;
        f.refDecimals = refDecimals;
        f.refBandPpm  = refBandPpm;
        f.refMaxStale = refMaxStale;
        emit FeedCreated(feedId, operator, priceTick, maxRatePerSec, feeRakePpm, refFeed, refBandPpm);
    }

    // ============================================================
    // publication
    // ============================================================

    function push(uint256 feedId, uint256 mark)
        external override nonReentrant onlyOperator(feedId)
    {
        Feed storage f = _feeds[feedId];
        _push(feedId, mark, f.rateLong, f.rateShort, f.vol, f.skew); // reuse sticky params
    }

    function pushAndCall(uint256 feedId, uint256 mark, Call[] calldata calls)
        external override nonReentrant onlyOperator(feedId)
    {
        Feed storage f = _feeds[feedId];
        _push(feedId, mark, f.rateLong, f.rateShort, f.vol, f.skew); // reuse sticky params
        _dispatch(feedId, calls);
    }

    function pushWithParams(
        uint256 feedId,
        uint256 mark,
        int64   rateLong,
        int64   rateShort,
        uint32  vol,
        int32   skew,
        Call[] calldata calls
    ) external override nonReentrant onlyOperator(feedId) {
        _push(feedId, mark, rateLong, rateShort, vol, skew);
        _dispatch(feedId, calls);
    }

    /// @dev Fire each pull-path callback. Each is isolated: an order whose nonce was
    /// cancelled mid-flight (a normal outcome) must not unwind the mark or its siblings.
    /// Failures surface via CallFailed; the callee authenticates msg.sender == this oracle.
    function _dispatch(uint256 feedId, Call[] calldata calls) internal {
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, ) = calls[i].target.call(
                abi.encodeCall(IH2OracleCallback.onMark, (feedId, calls[i].data))
            );
            if (!ok) emit CallFailed(feedId, i, calls[i].target);
        }
    }

    function _push(uint256 feedId, uint256 mark1e18, int64 rateLong, int64 rateShort, uint32 vol, int32 skew)
        internal
    {
        Feed storage f = _feeds[feedId];
        uint256 tick = f.priceTick;
        if (mark1e18 == 0 || mark1e18 % tick != 0) revert BadMark();
        uint256 units = mark1e18 / tick;
        if (units >= UNITS_CAP) revert BadMark();
        if (_absRate(rateLong) > f.maxRatePerSec || _absRate(rateShort) > f.maxRatePerSec)
            revert RateCapExceeded();
        // The pool must never be a net funding payer to a hedged long+short pair (#36).
        if (int256(rateLong) + int256(rateShort) < 0) revert NetNegativeFunding();

        _checkReferenceBand(f, mark1e18);

        uint256 microTs = _microTimestamp();
        uint64 nowMs = uint64(microTs / 1000);
        bool rateChanged = rateLong != f.rateLong || rateShort != f.rateShort;

        if (f.lastPushMs == 0) {
            f.currentMark = uint128(units);
            f.lastPushMs  = nowMs;
            f.rateLong    = rateLong;
            f.rateShort   = rateShort;
            f.vol         = vol;
            f.skew        = skew;
            emit MarkPushed(feedId, mark1e18, 0, 0, false, microTs, vol, skew);
            if (rateChanged) emit FundingRateChanged(feedId, rateLong, rateShort, uint64(block.timestamp));
            return;
        }

        uint64 elapsedMs = nowMs - f.lastPushMs;
        if (elapsedMs == 0) revert MarkSameSlot();

        // Accrue the elapsed interval on BOTH sides at the OLD rates and OLD mark (a step
        // function held until this publication overwrites it). Integrated on the ms clock:
        // marks arrive sub-second, so a whole-second clock floored most intervals to no accrual.
        uint256 oldMark1e18 = uint256(f.currentMark) * tick;
        f.fundingIndexLong  = FundingIndex.effectiveAtPctMs(f.fundingIndexLong,  f.rateLong,  oldMark1e18, f.lastPushMs, nowMs);
        f.fundingIndexShort = FundingIndex.effectiveAtPctMs(f.fundingIndexShort, f.rateShort, oldMark1e18, f.lastPushMs, nowMs);

        int256 priceDelta;
        unchecked {
            priceDelta = int256(units) - int256(uint256(f.currentMark));
        }
        uint64 head = f.ringHead;
        uint256 elapsedUnits = uint256(elapsedMs) / MarkRing.GAP_UNIT_MS;
        bool sentinel = elapsedUnits > MarkRing.GAP_MAX_UNITS;

        uint32 entry;
        if (sentinel) {
            entry = MarkRing.sentinelEntry();
            emit MarkPushed(feedId, mark1e18, priceDelta, 0, true, microTs, vol, skew);
        } else {
            entry = MarkRing.packEntry(priceDelta, elapsedUnits);
            emit MarkPushed(feedId, mark1e18, priceDelta, uint16(elapsedUnits), false, microTs, vol, skew);
        }
        MarkRing.writeMarkEntry(_rings[feedId], head, entry);

        f.ringHead    = head + 1;
        f.currentMark = uint128(units);
        f.lastPushMs  = nowMs;
        f.vol         = vol;
        f.skew        = skew;
        if (rateChanged) {
            f.rateLong  = rateLong;
            f.rateShort = rateShort;
            emit FundingRateChanged(feedId, rateLong, rateShort, uint64(block.timestamp));
        }
    }

    /// @dev A banded feed refuses any publication its reference can't vouch for. This is
    /// what makes RING HISTORY trustworthy by construction: consumers replaying it (the
    /// exchange's liquidation walk-back) need every recorded mark to have been sane at
    /// record time, which no action-time check can retroactively establish. A stale or
    /// broken reference therefore stops publication entirely (the feed goes stale and
    /// consumers fail over), rather than letting unchecked marks into the record.
    function _checkReferenceBand(Feed storage f, uint256 mark1e18) internal view {
        address ref = f.refFeed;
        if (ref == address(0)) return;
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(ref).latestRoundData();
        if (answer <= 0) revert RefBadAnswer();
        uint256 upd = _updatedAtSecs(updatedAt);
        if (upd > block.timestamp + 60) revert RefBadAnswer(); // future-stamped
        if (block.timestamp > upd + uint256(f.refMaxStale)) revert RefStale();
        uint256 refPx = uint256(answer) * (10 ** (18 - uint256(f.refDecimals)));
        uint256 diff = mark1e18 > refPx ? mark1e18 - refPx : refPx - mark1e18;
        if (diff * PPM > uint256(f.refBandPpm) * refPx) revert MarkOutOfBand();
    }

    // ============================================================
    // views
    // ============================================================

    function feedOf(uint256 feedId) external view override returns (FeedView memory) {
        Feed storage f = _feeds[feedId];
        if (f.operator == address(0)) revert UnknownFeed();
        return FeedView({
            operator:          f.operator,
            priceTick:         f.priceTick,
            maxRatePerSec:     f.maxRatePerSec,
            feeRakePpm:        f.feeRakePpm,
            refFeed:           f.refFeed,
            refDecimals:       f.refDecimals,
            refBandPpm:        f.refBandPpm,
            refMaxStale:       f.refMaxStale,
            mark:              uint256(f.currentMark) * uint256(f.priceTick),
            fundingIndexLong:  f.fundingIndexLong,
            fundingIndexShort: f.fundingIndexShort,
            rateLong:          f.rateLong,
            rateShort:         f.rateShort,
            vol:               f.vol,
            skew:              f.skew,
            lastPushMs:        f.lastPushMs,
            ringHead:          f.ringHead
        });
    }

    function indexNow(uint256 feedId, bool isLong) external view override returns (int128) {
        Feed storage f = _feeds[feedId];
        if (f.operator == address(0)) revert UnknownFeed();
        return FundingIndex.effectiveAtPctMs(
            isLong ? f.fundingIndexLong : f.fundingIndexShort,
            isLong ? f.rateLong : f.rateShort,
            uint256(f.currentMark) * uint256(f.priceTick),
            f.lastPushMs, uint64(_microTimestamp() / 1000)
        );
    }

    function ringEntry(uint256 feedId, uint256 idx) external view override returns (uint32) {
        if (_feeds[feedId].operator == address(0)) revert UnknownFeed();
        return MarkRing.readMarkEntry(_rings[feedId], idx);
    }

    function _absRate(int64 r) internal pure returns (uint64) {
        return r >= 0 ? uint64(r) : uint64(uint256(-int256(r)));
    }

    /// @dev µs wall-clock from MegaETH's system contract; block.timestamp fallback so a
    /// publication never bricks on the read (non-MegaETH chains, tests).
    function _microTimestamp() internal view returns (uint256) {
        (bool ok, bytes memory ret) = HP_TIMESTAMP.staticcall(
            abi.encodeWithSelector(IHighPrecisionTimestamp.timestamp.selector)
        );
        if (ok && ret.length >= 32) return abi.decode(ret, (uint256));
        return uint256(block.timestamp) * 1_000_000;
    }

    /// @dev Feed timestamps arrive in s / ms / µs depending on provider (MegaETH RedStone
    /// pushes µs); normalize by magnitude. Bands unambiguous until year ~5138.
    function _updatedAtSecs(uint256 t) internal pure returns (uint256) {
        if (t > 1e14) return t / 1_000_000;
        if (t > 1e11) return t / 1_000;
        return t;
    }
}
