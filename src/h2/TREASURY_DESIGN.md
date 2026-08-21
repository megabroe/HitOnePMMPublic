# H2 treasury — index-based lending against the market's book

> **Implemented in `H2Treasury.sol`.** This replaced an earlier per-deposit
> design (prepaid interest + per-deposit rolls + a junior tranche).

A market is a book funded by lenders. There is no first-loss tranche, no
donations, no creator-posted capital: the market is assumed profitable, and its
trading winnings pay the lenders their rate. Lenders' principal *is* the
backing capital the book pays winning traders out of, so lenders carry the
market-making risk directly — compensated by a fixed rate, and bearing a
principal haircut if the book loses more than it has made. Choosing which
market to fund is choosing which operator you trust to run a profitable book.

## Roles and claims

- **Lenders** deposit USDM, locked until the next term boundary. Their principal
  backs the book; they earn a fixed rate accrued through a shared index. They
  are the senior claim on the pool (principal + accrued interest), but that
  claim is only as good as the pool backs it.
- **Creator** sets the rate (the one mutable market parameter) and is the
  residual claimant: it may withdraw the pool's surplus above what lenders are
  owed — the market's profit for running it. It posts no capital and holds no
  first-loss buffer.

## The index

Interest accrues **continuously** through one per-market accumulator, and
**withdrawal** is gated to fixed global term boundaries. The two are separate:
the index makes the yield fair to anyone regardless of when they enter, and the
boundaries give the market committed capital.

Per market: `fundingIndex` (WAD-scaled), `ratePpmAnnual` (the rate, in annual
PPM), `termSecs` (frozen — the expiry period, e.g. 30 days), `lastAccruedAt`.
The index is a cumulative-rate accumulator advanced lazily; over a span of `dt`
seconds it grows by the annual rate pro-rated to that span:

```
_accrue():  fundingIndex  += ratePpmAnnual × WAD × dt / (PPM × YEAR)   // dt = now − lastAccruedAt
            lastAccruedAt  = now
```

`_accrue()` runs on every deposit-touching call and on every rate change, so
there is never an un-settled span, and one update covers every deposit — no
per-deposit rolls. Accrual is per-second rather than per-term on purpose: a
term-stepped index would let a lender deposit just before a boundary, harvest a
whole term's interest, and leave — draining the pool at other lenders' expense.
Continuous accrual pays each deposit exactly for the time its capital was at
work.

A deposit stores `principal`, `entryIndex` (the index when it entered), and an
optional `frozenIndex`. Its accrued interest is:

```
interest    = principal × (activeIndex − entryIndex) / WAD
activeIndex = frozenIndex if the lender has opted out, else the live fundingIndex
```

### Terms, auto-roll, and opting out

Term boundaries fall at fixed multiples of `termSecs` from a global epoch, so
every deposit shares the same schedule (v1's "fixed expiration," not a
per-deposit clock). A deposit is locked until the next boundary; while
auto-roll is on (the default) it simply rolls into the next term at each
boundary, still earning through the live index — no roll transaction, no
re-lock action.

To exit, a lender calls `stopRoll(depositId)`: interest freezes at the index
value the deposit will hold at the **next term boundary** (`frozenIndex`), so it
earns through the current term and no further, and its principal + frozen
interest becomes withdrawable once that boundary passes — at any time
afterward, with nothing to crank.

### Updatable rate

`setRate(marketId, ratePpm)` (creator only, the one mutable market parameter)
calls `_accrue()` first — settling the index at the old rate, which is never
revalued — then schedules the new rate. While any lender is present it applies
from the **next term boundary**, so the running term keeps the rate it was
committed at (`_accrue` splits its span at the boundary and promotes
`nextRatePpm` there); with no lenders it applies immediately. Setting the rate
to 0 closes new deposits.

## Solvency and the waterfall

- `poolAssets` — the USDM the market holds: `Σ principal in + trading P&L
  (open/close fees, funding inflows, liquidation wipes, trader losses) − trader
  payouts − withdrawn principal − withdrawn interest − withdrawn surplus`. This
  is exactly the pool the position paths already settle against.
- `lenderObligation` — `totalPrincipal + accInterest + frozenOwed`, O(1) from
  three aggregates. `totalPrincipal` and `accInterest` cover the active
  (auto-rolling) deposits: `_accrue` advances `accInterest` by
  `totalPrincipal · Δindex / WAD` each segment, so it always equals the active
  deposits' interest to the second. `frozenOwed` holds opted-out deposits'
  settled claims (principal + term-end interest); a `stopRoll` moves a deposit's
  principal out of `totalPrincipal` and its full term-end obligation into
  `frozenOwed`, so it no longer accrues.

Rules:

- **Trader win** — paid from `poolAssets`; reverts `Insolvent` if it cannot be
  covered (unchanged from the current settlement path). Winning traders are
  paid ahead of lender withdrawals in time, first-come — a documented
  consequence, as today.
- **Lender withdrawal** (opted out, past the boundary) — pays `min(principal +
  interest, that deposit's pro-rata share of poolAssets)`. If the pool is short
  (the book lost more than it earned), principal is haircut pro-rata across
  lenders.
- **Creator withdrawal** — may take `poolAssets − lenderObligation` when
  positive, and no more: the residual (the market's profit above what lenders
  are owed), never lender-owed capital. Withdrawal is free and immediate; there
  is no mandated buffer or retention (the creator posts no capital and holds no
  cushion — see the risk note below).

## The risk this design accepts (state plainly to lenders)

Because the creator can withdraw all surplus and holds no buffer, lenders sit
directly on the book with no cushion: the first loss beyond the market's
accumulated winnings hits their principal, and a creator that has already
withdrawn its profit does not claw it back. A lender is underwriting the
operator's edge. The fixed rate is an accrual, not a guarantee — it is worth
what the pool backs it for. Mitigations are the lender's own: fund markets with
a demonstrated profitable history, and read `poolAssets` vs `lenderObligation`
(both cheap views) before depositing and before each term rolls.

## What the earlier design had that this drops

A junior `balance` seeded by the creator (`depositJuniorCapital` /
`withdrawJuniorCapital`), a restore-first `_credit` waterfall, per-deposit
prepaid-and-locked interest, and per-deposit `rollDeposit`. Here
`_credit`/`_drainPool` are plain additions to / subtractions from `poolAssets`,
and `funderOwed` / `funderAssets` are replaced by the index aggregates
(`totalPrincipal`, `accInterest`, `frozenOwed`).

## Settled

- Interest accrual is **continuous** (per-second index), for fairness across
  entry timing; terms are **fixed global expiries** every `termSecs`, shared
  by all deposits, governing withdrawal only.
- The creator withdraws surplus **freely, with no retention or cushion** — the
  market is assumed profitable and lenders bear the downside by choice.
