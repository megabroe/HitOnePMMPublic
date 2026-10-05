// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IH2OracleCallback
/// @notice A pull-path target. The oracle invokes this synchronously inside `pushAndCall`,
/// AFTER recording the mark — so the callee observes the just-committed price. The oracle
/// attaches no meaning to `data`; the callee must authenticate `msg.sender` as the oracle
/// and interpret `data` itself.
interface IH2OracleCallback {
    function onMark(uint256 feedId, bytes calldata data) external;
}

/// @title IH2Oracle
/// @notice Permissionless registry of operator-published price feeds: marks, two-sided
/// funding rates, a volatility + skew estimate (the consuming market derives its spread from
/// them), and a packed mark-history ring. Ownerless and immutable, like the exchange that
/// consumes it.
///
/// A feed is frozen at creation: its `operator` (the only address that may publish),
/// its `priceTick` (the quantum ring history is recorded in), and optionally a REFERENCE
/// band (`refFeed`/`refBandPpm`/`refMaxStale`) every publication is checked against. The
/// band is what makes ring history trustworthy BY CONSTRUCTION — consumers that replay
/// history (liquidation walk-backs) need every recorded mark to have been sane at record
/// time, not merely the current one. A feed without a reference (refFeed == 0) records
/// unchecked marks and is unsuitable for third-party funds.
///
/// The operator gate is load-bearing: an open ring would let anyone print a within-band
/// dip that retroactively liquidates leveraged positions in any consumer replaying it.
/// "Anyone can operate an oracle" means anyone can CREATE a feed — not write to one.
interface IH2Oracle {
    // ============================================================
    // structs
    // ============================================================

    /// @notice A pull-path callback. Each call is isolated: a reverting target does not
    /// unwind the mark or its sibling calls (the failure is surfaced via `CallFailed`).
    struct Call {
        address target; // an IH2OracleCallback
        bytes   data;
    }

    struct FeedView {
        address operator;
        uint256 priceTick;         // 1e18-scale quantum; marks must be multiples
        uint64  maxRatePerSec;     // frozen magnitude cap on both funding rates — enforced
                                   // at PUSH, because indices integrate history and no
                                   // consumer can retroactively cap what already accrued
        uint32  feeRakePpm;        // the operator's cut of consuming markets' earnings (PPM)
        address refFeed;           // AggregatorV3-shaped reference; 0 = unbanded feed
        uint8   refDecimals;
        uint32  refBandPpm;        // |mark − ref| ≤ band (PPM of ref)
        uint32  refMaxStale;       // max reference age (seconds) for a push to be accepted
        uint256 mark;              // last published mark, 1e18
        int128  fundingIndexLong;  // integrates rate × mark over time, 1e18 price scale
        int128  fundingIndexShort;
        int64   rateLong;          // signed fixed-point fraction/sec, real = rate/(100·2⁶³)
        int64   rateShort;
        uint32  vol;               // operator-published volatility estimate, PPM (10_000 = 1%);
                                   // the consuming market derives its spread from vol+skew
        int32   skew;              // operator-published directional skew, signed PPM; shifts the
                                   // derived spread by FILL DIRECTION (skew>0 ⇒ buyers pay more:
                                   // opening a long or closing a short)
        uint64  lastPushMs;        // HP wall-clock ms — the single push clock (funding,
                                   // ring, staleness); 0 iff the feed has never been pushed
        uint64  ringHead;
    }

    // ============================================================
    // events
    // ============================================================

    event FeedCreated(
        uint256 indexed feedId,
        address indexed operator,
        uint256 priceTick,
        uint64  maxRatePerSec,
        uint32  feeRakePpm,
        address refFeed,
        uint32  refBandPpm
    );
    event MarkPushed(
        uint256 indexed feedId,
        uint256 mark,
        int256  priceDelta,
        uint16  timeDeltaMs,
        bool    isSentinel,
        uint256 microTimestamp,
        uint32  vol,
        int32   skew
    );
    event FundingRateChanged(uint256 indexed feedId, int64 rateLong, int64 rateShort, uint64 startTime);
    /// @notice A pull-path callback reverted; the mark and sibling calls stand.
    event CallFailed(uint256 indexed feedId, uint256 indexed callIndex, address target);

    // ============================================================
    // errors
    // ============================================================

    error UnknownFeed();
    error NotOperator();
    error BadFeedParams();
    error BadMark();          // zero, not a tick multiple, or overflows units
    error MarkSameSlot();     // two publications in one HP millisecond
    error RateCapExceeded();  // |rate| above the feed's frozen maxRatePerSec
    error RefStale();         // reference feed older than refMaxStale (push refused)
    error RefBadAnswer();     // reference answer ≤ 0 or stamped > 60 s ahead of block time
    error MarkOutOfBand();    // |mark − ref| beyond refBandPpm

    // ============================================================
    // feeds
    // ============================================================

    /// @notice Create a feed. Permissionless; every argument is frozen forever. Pass
    /// `refFeed = 0` for an unbanded feed (ring history then carries no sanity guarantee —
    /// consumers should require a banded feed before accepting third-party funds).
    /// `feeRakePpm` (≤ 500_000) is the operator's cut of the earnings of every market that
    /// consumes this feed — the operator's compensation, paid to `operator`.
    function createFeed(
        address operator,
        uint256 priceTick,
        uint64  maxRatePerSec,
        uint32  feeRakePpm,
        address refFeed,
        uint8   refDecimals,
        uint32  refBandPpm,
        uint32  refMaxStale
    ) external returns (uint256 feedId);

    /// @notice Publish a mark, REUSING the feed's stored funding rates and spread (operator
    /// only). This is the hot path: rates and spread are sticky feed state that rarely
    /// moves, so the per-block push carries only the price. Rules: mark is a nonzero
    /// multiple of the feed's tick; publications in the same HP millisecond revert; a gap
    /// over 4.095 s records a ring sentinel; banded feeds check the reference (fresh,
    /// positive, within 60 s of block time, within band). Funding still accrues on every push.
    function push(uint256 feedId, uint256 mark) external;

    /// @notice `push`, then synchronously invoke each callback with the mark committed —
    /// the PULL path. A user-signed order rides the operator's next mark commit in one
    /// transaction: nothing observable exists to front-run, and the order executes against
    /// exactly the price it was attached to. Each call is isolated (`CallFailed`). Also
    /// reuses the stored rates and spread.
    function pushAndCall(uint256 feedId, uint256 mark, Call[] calldata calls) external;

    /// @notice Publish a mark AND update the feed's funding rates and vol/skew estimate — the
    /// cold path, for the rare occasions those move. `calls` may be empty (a pure rate/vol/skew
    /// update) or carry the usual pull-path callbacks. Same publication rules as `push`; the new
    /// rates apply from this publication forward (funding up to here accrued at the old rates).
    /// `vol`/`skew` are the operator's volatility + directional-skew estimates (PPM); consuming
    /// markets derive their spread from them.
    function pushWithParams(
        uint256 feedId,
        uint256 mark,
        int64   rateLong,
        int64   rateShort,
        uint32  vol,
        int32   skew,
        Call[] calldata calls
    ) external;

    // ============================================================
    // views
    // ============================================================

    function nextFeedId() external view returns (uint256);
    function feedOf(uint256 feedId) external view returns (FeedView memory);
    /// @notice One side's funding index projected to now at the live rate and mark.
    function indexNow(uint256 feedId, bool isLong) external view returns (int128);
    /// @notice Raw packed ring entry at logical index `idx` (see MarkRing for the encoding).
    /// Exposed so consumers can replay history (walk-back liquidation) themselves.
    function ringEntry(uint256 feedId, uint256 idx) external view returns (uint32);
}
