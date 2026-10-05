# H2 oracle architecture — the exchange consumes oracles, operators publish them

H2 is a decentralized exchange where users open leveraged positions priced by
oracles. To match MegaETH's speed it is built around a specific division of
labor: **price publishers push marks; the exchange market-makes by formula.**
Nobody quotes a fill a formula didn't derive, so the party operating the price
stream — however sophisticated its off-chain machinery — is an oracle
operator, not a counterparty.

Two contracts:

| Contract | Role |
|---|---|
| `H2Oracle` | Permissionless registry of operator-published feeds: marks, two-sided funding rates, an optional spread, the mark-history ring, and the pull path (commit a mark and execute callbacks against it in one transaction). |
| `H2Market` | The exchange. Consumes one `H2Oracle` feed (primary) and one external push feed (fallback) per market; derives every fill, funding charge and liquidation from them plus frozen market parameters; owns positions and the market treasury. |

An operator's entire on-chain footprint is `H2Oracle` transactions.

---

## 1. The primary oracle (`H2Oracle`)

A **feed** is created permissionlessly and is defined by two frozen values: its
`operator` (the only address that may publish to it) and its `priceTick` (the
quantum its ring history is recorded in). One feed can serve many markets.

The operator gate is load-bearing, not ceremonial: the exchange's liquidation
walk-back replays ring history, so an open ring would let anyone print a
within-band dip that retroactively liquidates every leveraged position.
"Anyone can operate an oracle" means anyone can create a feed and markets on
it — not that anyone can write to an existing feed.

### Feed contents

Each publication carries:

- `mark` — the price, 1e18 scale, a multiple of the feed's `priceTick`.
- `rateLong`, `rateShort` — two-sided funding rates (signed fixed-point
  fraction/sec, real = rate / (100·2⁶³)). Funding rates are published market
  data, like marks; the exchange bounds them per market (§3). Each side's
  funding **index** integrates `rate × mark` over time and lives in the feed —
  indices are pure functions of feed history.
- `vol`, `skew` — a volatility estimate and a directional-skew estimate (both
  PPM of price, 10_000 = 1%). The operator publishes these; the CONSUMING
  MARKET derives its own spread from them via frozen coefficients — per side
  and per action — `spread = volK·vol²/VOL_REF ± skewK·skew/SKEW_REF`, clamped
  to `[0, maxSpreadPpm]` (see ParamCatalog.derivedSpread). The `vol²` term
  prices variance; the linear skew term makes the spread asymmetric (skew>0 ⇒
  longs pay more). Zeroing the close coefficients gives zero close spread (the
  winnings rake prices closes). The derived spread can only ever worsen a fill
  within the user's signed slippage band, so it adds vol-adaptivity without
  giving the operator fill discretion.

Publication rules: two publications in the same HP millisecond revert; a gap
above 4.095 s writes a ring sentinel (walk-backs stop there); ring entries are
tick-quantized deltas, 200 deep.

### Push and pull

Funding rates and the vol/skew estimate are **sticky feed state** — they rarely
move, while the mark moves every block — so the hot path carries only the price
and reuses the stored parameters. (Funding still accrues on every push; the index
integrates rate × mark over time regardless of whether the rate value changed.)

- **Push** — `push(feedId, mark)`: the per-block publication, reusing the
  stored rates and vol/skew.
- **Pull** — `pushAndCall(feedId, mark, Call[] calls)`: the same, plus a
  synchronous callback to each listed target
  (`IH2OracleCallback.onMark(feedId, data)`). This is how a user's order
  executes at minimal latency without MEV exposure: the user signs an order
  with slippage restrictions and sends it to the operator off-chain; the
  operator attaches it to the next mark commit, and the order executes against
  exactly that mark, in that transaction. Nothing observable exists to
  front-run.
- **Update** — `pushWithParams(feedId, mark, rateLong, rateShort, vol, skew,
  Call[] calls)`: the cold path for the rare occasions rates or the vol/skew
  estimate move. `calls` may be empty (a pure parameter change) or carry the usual
  callbacks. All three entrypoints run the same accrual, so funding is always
  computed at a publication boundary.

Callbacks are the oracle's only opinionless feature: the oracle does not know
or care what `data` means — the exchange authenticates that `msg.sender` is
the oracle and that the feed matches the market, and interprets `data` as
orders or liquidation batches itself.

## 2. Execution availability — the operator is a cost optimizer, not a gatekeeper

A user must be able to open and close *without* the operator's cooperation —
otherwise the operator gates execution, which is the centralization the whole
design exists to remove. So execution is a spectrum keyed on how fresh the
primary mark is, priced so that the staler the mark a trade uses, the more it
pays for the risk that the mark is wrong. There are three tiers.

### 2.1 Operator-attached (freshest)

The operator commits a new mark and attaches the order in the same
`pushAndCall` (§1). Mark age ≈ 0, so the only spread is the market's derived
spread from the feed's vol/skew. This is the cheapest fill and the normal path — the operator's
service is keeping marks fresh so its users pay the least — but it is not the
*only* path.

### 2.2 Self-service against the last mark (`executeAtMark`)

Anyone may execute a signed order against the **current primary mark** without
the operator, paying a **staleness spread** that grows with the mark's age:

```
staleSpreadPpm(age) = staleSpreadK · √ageMs      (ageMs = mark age, milliseconds)
```

The √age shape is the price of a stale quote: over a random-walk horizon the
adverse move scales like σ√age, so a linear-in-age spread would be too cheap at
milliseconds and too dear at seconds. `staleSpreadK` (a frozen per-market param,
ppm per √millisecond, sized ≈ 2σ; `0` disables self-service for the market) is
the treasury's compensation for adverse selection by a trader who can pick the
moment. It is charged on top of the feed's capped spread and folded, with the
fee curve, into the user's signed band.

Two guards make it safe:

- **Deviation gate (§2.4).** The stale primary mark is checked against the
  *fresh* fallback feed; if they have diverged past `maxDeviationPpm` the trade
  is refused. This is what stops a patient actor from executing exactly when
  the stale mark is maximally wrong — the fallback is the freshness anchor.
- **Sentinel bound.** `executeAtMark` is available only while the mark is
  fresher than the ring's sentinel gap (`MarkRing.GAP_MAX`, 4.095 s). A mark
  older than that sits across a ring discontinuity the walk-back cannot replay,
  so it is not a safe anchor for a new position; beyond the sentinel age,
  self-service closes and execution waits for a fresh mark or the fallback.

Between the sentinel age and `primaryStaleSecs` there is a **dead window**: the
mark is too stale for self-service but the primary is not yet "dark" enough to
open the fallback. In it, only the operator can act (it can always resume
pushing). Keep `primaryStaleSecs` close to the sentinel gap to make this window
small — a longer setting just means a longer glitch before the fallback opens.

An adverse price move that occurs and recovers entirely between two marks — a
gap during which the primary publishes nothing and the fallback has not yet
armed — is a liquidation blind spot: the crossing is never live-liquidated, and
once a sentinel closes the gap the walk-back cannot reach back across it. This
bounds treasury exposure to the largest move that can round-trip within one
such gap, which is why `primaryStaleSecs` should be short and the maintenance
width (`liqWidthPpm`) should carry enough margin to absorb it.

### 2.3 Fully dark → the fallback feed (`executeAtFallback`)

Once the primary has been silent past `primaryStaleSecs`, anyone may open,
close and liquidate against the **fallback push feed** (Chainlink-shaped;
RedStone Bolt on MegaETH) at its price ± the market's fallback spreads. This is
the deep-failure tier: the primary ring
is unusable, so trades price against an independent feed rather than a stale
mark. If *both* oracles fail, positions are stuck until `maxPositionDuration`,
at which point permissionless expiry settles them at the last primary mark.
Timestamps from either feed are normalized by magnitude (µs / ms / s). A
timestamp more than 60 s ahead of block time is rejected; up to 60 s is tolerated as
clock skew, so a round can count as fresh for up to its max age + 60 s.

### 2.4 The deviation gate

Whenever both a primary price (a fresh mark, or the stale mark a self-service
trade would use) and a fresh fallback exist, every position action requires
`|primary − fallback| ≤ maxDeviationPpm`. A discrepancy blocks opens, closes
and liquidations — but **not publications**: marks keep recording through a
gated window so the ring stays alive, and the walk-back can catch in-window
liquidation crossings once the gate lifts.

The gate is symmetric: it protects users from a hostile primary and the
treasury from a wedged fallback, turning "the two price sources disagree" into
a halt rather than a choice.

## 3. The exchange as market maker

A market's economics are entirely frozen parameters, grouped into three
sub-structs (each ≤ 24 fields, so standard tooling can bind them):

- **`FeeParams`** — opening fee curve (flat + linear + quadratic ppm of
  notional), closing fee curve (same shape), winnings-cut ramp (min, max,
  scale ppm on percent return).
- **`RiskParams`** — `priceTick`/`sizeTick`, min/max leverage,
  `maxPositionNotional`, `maxOIGross`/`maxOISkew`, `maxPositionDuration`,
  `liqWidthPpm`, `maxFundingRatePerSec`, `maxSpreadPpm`, `termSecs`, and
  (DESIGN, §2.2) `staleSpreadK` — the self-service staleness-spread coefficient
  (ppm per √millisecond, ≈ 2σ; 0 disables self-service).
- **`OracleParams`** — primary `feedId`, fallback feed + decimals,
  `primaryStaleSecs`, `fallbackMaxAge`, fallback open/close/liquidation
  spreads (ppm), `maxDeviationPpm`.

With those, the contract quotes:

- **Fills**: `mark ± (feeCurve(notional) + oracleSpread + staleSpread(age))`,
  direction against the taker, folded into the user's signed band — the all-in
  price can never exceed what the user consented to. Opening and closing each
  have their own curve; the notional-scaled terms price size; the
  age-dependent `staleSpread` term (§2.2) is zero on the operator-attached path
  and grows on self-service.
- **Funding**: accrued from the feed's two-sided indices, checkpointed per
  position, settled at close, with the market enforcing `|rate| ≤
  maxFundingRatePerSec` at consumption.
- **Liquidation**: a position is liquidatable when the oracle price is within
  `liqWidthPpm` of its liquidation price — an early trigger, so the full
  knockout (all collateral to the treasury) lands *before* bankruptcy and the
  treasury keeps a gap-risk margin. The walk-back tests ring history against
  the same widened threshold. On the fallback path the liquidation spread
  shifts the test price in the position's favor.

### On sandwiching the treasury (no fee-floor bound)

Because fills are formulaic, a round trip could in principle extract up to
`2 · maxDeviationPpm · notional` — but only if the operator parks the mark at
opposite gate edges (open cheap, close dear) across the two legs. That requires a
**dishonest feed**: an honest operator's mark tracks truth, so both legs execute
at ~truth and the gap is ~0. And a dishonest operator that *can* place marks
`maxDeviationPpm` off truth can already do far worse (arbitrary marks within the
gate, forced liquidations) — the vault trusts its price feed by construction. So
the exchange does **not** impose a fee-floor tying `openFlat`/`closeFlat` to
`maxDeviationPpm`; guarding one narrow extraction while trusting the operator for
everything else buys nothing. The deviation gate (§2.4) remains, as a
staleness/sanity check against a *stale or diverged* fallback — not as protection
against the operator itself. The remaining creation-time bounds carry over: band and
spread caps, `termSecs ∈ [1 h, 365 d]`, and the coupled funding ceiling
(`maxFundingRatePerSec × primaryStaleSecs × maxLeverage ≤ ½·PCT_SCALE` — the
funding accrued during the window users cannot exit without the operator can
never eat more than half of worst-case collateral).

## 4. Treasury — index lending (full spec in TREASURY_DESIGN.md)

One lending pool per market. `poolAssets` holds lender principal plus retained
trading P&L; there is no junior tranche and no creator-posted capital. The
**creator** (typically the same party as the feed operator, but the roles are
distinct — the operator publishes prices, the creator owns the money) has two
powers: `setRate(marketId, ratePpm)` and `withdrawSurplus`. Everything else is
frozen.

**Lenders** call `depositFund`, which requires a nonzero rate (0 = deposits
closed, the creator's off switch) and a **banded primary feed** (`UnbandedFeed`
otherwise): senior money requires ring integrity, since an unbanded operator
could fabricate history and drain the pool through one fake round trip or a
retroactive walk-back wipe. Principal earns a fixed rate accrued through a
single continuous per-market index (`fundingIndex`), so no deposit is ever
individually rolled — one `_accrue` advances every deposit's interest at once.
A deposit records `principal` and `entryIndex`; its interest is `principal ·
(index − entryIndex)`.

Terms are **fixed global expiries** every `termSecs`, shared by all deposits
and governing withdrawal only. Auto-roll is the default (a deposit simply keeps
earning through the index across each boundary). To exit, a lender calls
`stopRoll`, which freezes its interest at the index the deposit will hold at the
**next boundary** (`frozenIndex`); once the live index reaches that value the
principal + frozen interest is withdrawable via `withdrawFund`, at any time
after, with nothing to crank. A rate change while lenders are present applies at
the next boundary (the running term keeps its rate); with none present it
applies immediately.

Settlement collapses to plain pool moves: `_credit` adds trading earnings
(open/close fees, user losses, liquidation wipes, the winnings cut) to
`poolAssets`; `_drainPool` pays user winnings from it and reverts `Insolvent`
past what the pool — lender principal included — can cover. The creator may
withdraw `poolAssets − lenderObligation` (where `lenderObligation =
totalPrincipal + accInterest + frozenOwed`) as surplus, never lender-owed
capital.

The risk this accepts, stated plainly to lenders: the creator holds no buffer
and withdraws all surplus, so lenders sit directly on the book. A book that
loses more than it has earned haircuts withdrawing principal pro-rata (`pay =
owed · poolAssets / obligation`); the fixed rate is an accrual, not a guarantee,
worth what the pool backs it for. **There is no solvency check on open** — the
onus is on the opener to compare `grossOpenNotional(marketId)` against
`treasuryOf(marketId)` (two cheap reads); insolvency bites only at payout
(`Insolvent`, first-come-first-served — a win that cannot be covered leaves the
position open until the pool is replenished) and at lender withdrawal (the
haircut ratio).

## 5. Order lifecycle

1. User signs an EIP-712 `Order` (11 fields, naming the `marketId`;
   domain `H2Market`/`1`) with target price and slippage bound, and sends it
   to the feed operator off-chain.
2. The operator attaches it (with any others, and any liquidation batch) to
   its next `pushAndCall`.
3. The oracle records the mark and invokes the exchange's `onMark`; the
   exchange verifies the signature/nonce/deadline, derives the fill from the
   just-committed mark and the market's curves, checks the band, OI caps and
   the deviation gate, and settles against the treasury.
4. If the operator does not attach it, the same signed order is executable by
   anyone: against the last primary mark while it is fresher than the sentinel
   gap (self-service, §2.2), or against the fallback feed once the primary is
   dark past `primaryStaleSecs` (§2.3).
5. `cancelNonce` retires an unspent order at any time; a cancel racing an
   in-flight commit reverts the commit's execution of that order —
   a normal outcome, not an anomaly.

The signing domain is `name="H2Market", version="1"`, with `verifyingContract`
the exchange address. That address moves on any redeploy while the domain
string does not, so a client left on a stale address produces a *valid-looking*
signature over the wrong digest — clients must track the deployed address as
configuration.

## 6. Implementation status

All three execution tiers are implemented: operator-attached (§2.1),
self-service `executeAtMark` with the √age staleness spread (§2.2), and the
fully-dark fallback (§2.3), along with the deviation gate (§2.4), the
market-maker fee/funding/liquidation model (§3), and the treasury (§4).
