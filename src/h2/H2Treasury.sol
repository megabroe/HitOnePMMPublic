// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IERC20 }    from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { H2Storage } from "./H2Storage.sol";

/// @title H2Treasury
/// @notice Per-market index lending (see TREASURY_DESIGN.md). One pool per market holds
/// lender principal + retained trading P&L; there is no first-loss tranche. Lenders'
/// principal backs the book — winning traders are paid out of it — and earns a fixed rate
/// accrued through a single continuous index, so no deposit is ever "rolled". The creator
/// sets the rate (applied per term) and withdraws the pool's surplus above what lenders
/// are owed. Lenders bear the downside: a book that loses more than it has made haircuts
/// principal pro-rata at withdrawal.
///
/// The settlement hooks the position paths call (`_credit` / `_drainPool`) are plain
/// additions to / subtractions from `poolAssets`; the index accrues on TIME, independent of
/// P&L, so those hooks never touch it.
abstract contract H2Treasury is H2Storage {
    using SafeERC20 for IERC20;

    /// @dev Sanity ceiling on the annual rate (1000% = 1e7 ppm) — bounds index overflow and
    /// nonsense configs. Interest is worth what the pool backs it for regardless.
    uint256 internal constant MAX_RATE_PPM = 10_000_000;

    // ============================================================
    // creator side
    // ============================================================

    function setTreasurer(address creator, address treasurer_) external override onlyTreasurer(creator) {
        _treasurer[creator] = treasurer_;
        emit TreasurerSet(creator, treasurer_);
    }

    /// @notice Set the annual rate. While lenders are present it applies from the next term
    /// boundary (a running term keeps its rate); with none, immediately. 0 closes deposits.
    function setRate(uint256 marketId, uint256 ratePpm) external override onlyMarketTreasurer(marketId) {
        if (ratePpm > MAX_RATE_PPM) revert BadMarketParams();
        MarketTreasury storage t = _treasury[marketId];
        _accrue(marketId, t);
        bool immediate = t.totalPrincipal == 0 && t.frozenOwed == 0;
        if (immediate) {
            t.ratePpmAnnual = uint32(ratePpm);
            t.nextRatePpm   = uint32(ratePpm);
        } else {
            // Activates at nextBoundary(lastAccruedAt) — which _accrue just set to now —
            // so the current term keeps its rate. See _accrue for the boundary split.
            t.nextRatePpm = uint32(ratePpm);
        }
        emit RateSet(marketId, ratePpm, immediate);
    }

    /// @notice Withdraw the market's surplus (poolAssets - lenderObligation): the creator's
    /// profit for running the book. Cannot dip into lender-owed capital.
    function withdrawSurplus(uint256 marketId, uint256 amount, address to)
        external override nonReentrant onlyMarketTreasurer(marketId)
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        MarketTreasury storage t = _treasury[marketId];
        _accrue(marketId, t);
        uint256 obligation = uint256(t.totalPrincipal) + uint256(t.accInterest) + uint256(t.frozenOwed);
        uint256 surplus = uint256(t.poolAssets) > obligation ? uint256(t.poolAssets) - obligation : 0;
        if (amount > surplus) revert NoSurplus();
        unchecked { t.poolAssets -= uint128(amount); }
        emit SurplusWithdrawn(marketId, to, amount);
        usdm.safeTransfer(to, amount);
    }

    // ============================================================
    // lender side
    // ============================================================

    function depositFund(uint256 marketId, uint256 amount)
        external override nonReentrant returns (uint256 depositId)
    {
        if (_creatorOf[marketId] == address(0)) revert UnknownMarket();
        if (amount == 0) revert ZeroAmount();
        if (amount > type(uint128).max) revert BadSize();
        // Deposits require a banded primary feed: an unbanded operator could fabricate
        // marks and drain the pool through one fake round trip or a retroactive walk-back.
        if (_oracle.feedOf(_oracles[marketId].primaryFeedId).refFeed == address(0))
            revert UnbandedFeed();
        MarketTreasury storage t = _treasury[marketId];
        _accrue(marketId, t);
        if (t.ratePpmAnnual == 0) revert DepositsClosed();

        usdm.safeTransferFrom(msg.sender, address(this), amount);
        t.poolAssets     += uint128(amount);
        t.totalPrincipal += uint128(amount);

        depositId = ++_nextDepositId;
        _deposits[depositId] = Deposit({
            funder:      msg.sender,
            marketId:    uint64(marketId),
            optedOut:    false,
            principal:   uint128(amount),
            entryIndex:  t.fundingIndex,
            frozenIndex: 0
        });
        emit FundDeposited(depositId, marketId, msg.sender, amount);
    }

    /// @notice Opt out of the roll: freeze interest at the term-end index. The whole
    /// term-end interest is booked into `frozenOwed` now (so the creator can't withdraw the
    /// interest it committed to pay), and the principal leaves the active accrual.
    function stopRoll(uint256 depositId) external override {
        Deposit storage d = _deposits[depositId];
        if (d.funder == address(0)) revert UnknownDeposit();
        if (msg.sender != d.funder) revert NotFunder();
        if (d.optedOut) revert AlreadyOptedOut();
        uint256 marketId = d.marketId;
        MarketTreasury storage t = _treasury[marketId];
        _accrue(marketId, t);

        // The rate is constant from now to the next boundary (a pending change applies AT
        // the boundary, never before), so the term-end index is exact.
        uint256 B = _nextBoundary(block.timestamp, _risk[marketId].termSecs);
        uint256 termEndIndex = uint256(t.fundingIndex) + _deltaIndex(t.ratePpmAnnual, B - block.timestamp);

        uint256 principal   = uint256(d.principal);
        uint256 accruedNow  = principal * (uint256(t.fundingIndex) - uint256(d.entryIndex)) / WAD;
        uint256 owed        = principal + principal * (termEndIndex - uint256(d.entryIndex)) / WAD;

        t.totalPrincipal -= uint128(principal);
        t.accInterest    -= uint128(accruedNow);
        t.frozenOwed     += uint128(owed);

        d.optedOut    = true;
        d.frozenIndex = uint128(termEndIndex);
        emit FundOptedOut(depositId, owed, uint128(termEndIndex));
    }

    function withdrawFund(uint256 depositId, address to) external override nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        Deposit storage d = _deposits[depositId];
        if (d.funder == address(0)) revert UnknownDeposit();
        if (msg.sender != d.funder) revert NotFunder();
        if (!d.optedOut) revert NotOptedOut();
        uint256 marketId = d.marketId;
        MarketTreasury storage t = _treasury[marketId];
        _accrue(marketId, t);
        // The frozen index is the term-end value; the index reaches it exactly when the
        // boundary passes.
        if (uint256(t.fundingIndex) < uint256(d.frozenIndex)) revert TermNotEnded();

        uint256 owed = uint256(d.principal)
            + uint256(d.principal) * (uint256(d.frozenIndex) - uint256(d.entryIndex)) / WAD;

        uint256 obligation = uint256(t.totalPrincipal) + uint256(t.accInterest) + uint256(t.frozenOwed);
        uint256 pool = uint256(t.poolAssets);
        // Pro-rata haircut if the book lost more than it earned.
        uint256 pay = pool >= obligation ? owed : (obligation == 0 ? 0 : owed * pool / obligation);

        t.frozenOwed -= uint128(owed);
        t.poolAssets  = uint128(pool - pay);
        delete _deposits[depositId];

        emit FundWithdrawn(depositId, to, pay);
        if (pay > 0) usdm.safeTransfer(to, pay);
    }

    // ============================================================
    // views
    // ============================================================

    function treasuryOf(uint256 marketId) external view override returns (TreasuryView memory) {
        address creator = _creatorOf[marketId];
        if (creator == address(0)) revert UnknownMarket();
        (uint256 idx, uint256 accInt) = _previewAccrual(marketId);
        MarketTreasury storage t = _treasury[marketId];
        uint256 obligation = uint256(t.totalPrincipal) + accInt + uint256(t.frozenOwed);
        return TreasuryView({
            poolAssets:       t.poolAssets,
            totalPrincipal:   t.totalPrincipal,
            accInterest:      accInt,
            frozenOwed:       t.frozenOwed,
            lenderObligation: obligation,
            surplus:          uint256(t.poolAssets) > obligation ? uint256(t.poolAssets) - obligation : 0,
            fundingIndex:     idx,
            ratePpmAnnual:    t.ratePpmAnnual,
            nextRatePpm:      t.nextRatePpm,
            treasurer:        _effectiveTreasurer(creator)
        });
    }

    function grossOpenNotional(uint256 marketId) external view override returns (uint256) {
        return openInterestLong[marketId] + openInterestShort[marketId];
    }

    function deposits(uint256 depositId) external view override returns (DepositView memory) {
        Deposit storage d = _deposits[depositId];
        if (d.funder == address(0)) revert UnknownDeposit();
        (uint256 idx, ) = _previewAccrual(d.marketId);
        uint256 activeIdx = d.optedOut ? uint256(d.frozenIndex) : idx;
        uint256 value = uint256(d.principal)
            + uint256(d.principal) * (activeIdx - uint256(d.entryIndex)) / WAD;
        return DepositView({
            funder:       d.funder,
            marketId:     d.marketId,
            principal:    d.principal,
            entryIndex:   d.entryIndex,
            frozenIndex:  d.frozenIndex,
            optedOut:     d.optedOut,
            value:        value,
            withdrawable: d.optedOut && idx >= uint256(d.frozenIndex)
        });
    }

    // ============================================================
    // settlement hooks (position paths only) - plain pool moves
    // ============================================================

    /// @dev Trading earnings enter the pool: open/close fees, trader losses, liquidation
    /// wipes, the winnings cut. Grows the lenders' backing and the creator's surplus.
    function _credit(uint256 marketId, uint256 amount) internal {
        _treasury[marketId].poolAssets += uint128(amount);
    }

    /// @dev A user win leaves the pool. Reverts `Insolvent` when the pool - lender
    /// principal included - cannot cover it (opens are never solvency-gated).
    function _drainPool(uint256 marketId, uint256 amount) internal {
        MarketTreasury storage t = _treasury[marketId];
        if (uint256(t.poolAssets) < amount) revert Insolvent();
        unchecked { t.poolAssets -= uint128(amount); }
    }

    // ============================================================
    // index accrual
    // ============================================================

    /// @dev Advance the index (and the active-interest aggregate) to now, applying a
    /// pending rate change exactly at its boundary. `_accrue` runs on every treasury touch,
    /// so there is never an un-settled span; the pending change activates at
    /// nextBoundary(lastAccruedAt) because `setRate` pins lastAccruedAt to its own time.
    function _accrue(uint256 marketId, MarketTreasury storage t) internal {
        uint256 last = t.lastAccruedAt;
        uint256 nowT = block.timestamp;
        if (nowT <= last) return;

        if (t.nextRatePpm != t.ratePpmAnnual) {
            uint256 B = _nextBoundary(last, _risk[marketId].termSecs);
            if (nowT >= B) {
                _accrueSegment(t, last, B, t.ratePpmAnnual);
                t.ratePpmAnnual = t.nextRatePpm; // activate at the boundary
                _accrueSegment(t, B, nowT, t.ratePpmAnnual);
                t.lastAccruedAt = uint64(nowT);
                return;
            }
        }
        _accrueSegment(t, last, nowT, t.ratePpmAnnual);
        t.lastAccruedAt = uint64(nowT);
    }

    function _accrueSegment(MarketTreasury storage t, uint256 from, uint256 to, uint256 ratePpm) internal {
        if (to <= from || ratePpm == 0) return;
        uint256 d = _deltaIndex(ratePpm, to - from);
        if (d == 0) return;
        t.fundingIndex += uint128(d);
        t.accInterest  += uint128(uint256(t.totalPrincipal) * d / WAD);
    }

    /// @dev delta-index over `dt` seconds at an annual PPM rate, WAD-scaled.
    function _deltaIndex(uint256 ratePpm, uint256 dt) internal pure returns (uint256) {
        return ratePpm * WAD * dt / (PPM * YEAR);
    }

    /// @dev The first term boundary strictly after `t` (global epoch, per-market `termSecs`).
    function _nextBoundary(uint256 t, uint256 termSecs) internal pure returns (uint256) {
        return (t / termSecs + 1) * termSecs;
    }

    /// @dev View-side projection of (fundingIndex, accInterest) to now - mirrors `_accrue`
    /// without writing, including the pending-rate boundary split.
    function _previewAccrual(uint256 marketId) internal view returns (uint256 idx, uint256 accInt) {
        MarketTreasury storage t = _treasury[marketId];
        idx = t.fundingIndex;
        accInt = t.accInterest;
        uint256 last = t.lastAccruedAt;
        uint256 nowT = block.timestamp;
        if (nowT <= last) return (idx, accInt);
        uint256 tp = t.totalPrincipal;

        if (t.nextRatePpm != t.ratePpmAnnual) {
            uint256 B = _nextBoundary(last, _risk[marketId].termSecs);
            if (nowT >= B) {
                uint256 d1 = _deltaIndex(t.ratePpmAnnual, B - last);
                idx += d1; accInt += tp * d1 / WAD;
                uint256 d2 = _deltaIndex(t.nextRatePpm, nowT - B);
                idx += d2; accInt += tp * d2 / WAD;
                return (idx, accInt);
            }
        }
        uint256 d = _deltaIndex(t.ratePpmAnnual, nowT - last);
        idx += d; accInt += tp * d / WAD;
    }
}
