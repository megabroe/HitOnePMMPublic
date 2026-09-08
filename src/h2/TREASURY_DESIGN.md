# H2 treasury — permissionless share vault

> **Implemented in `H2Treasury.sol`.**

Each market is backed by its own **share vault**. Lenders deposit USDM and
receive shares; a share is worth `poolAssets / totalShares`. All of the book's
trading P&L — open/close fees, the winnings cut, trader losses, liquidation
wipes, minus trader wins — flows through `poolAssets`, so the share price rises
with the book's earnings and falls with its losses. The lenders **are** the
counterparty to every trade: their capital is what winning traders are paid out
of, and they hold the aggregate position the traders don't.

There is **no rate, no cap, and no creator/treasurer role** — nobody governs the
vault, and nothing about it is mutable after the market is created. The only
compensation carve-out is the **oracle rake**: the market's feed operator earns a
frozen fraction of every pool gain. Choosing which market to fund is choosing
which operator you trust to run a profitable book, and accepting the variance of
being its house.

## Shares and NAV

The vault is standard ERC-4626-style share accounting with a virtual offset:

```
deposit:   shares = assets · (totalShares + 1) / (poolAssets + 1)
withdraw:  assets = burn   · (poolAssets  + 1) / (totalShares + 1)   // floored
sharePrice = (poolAssets + 1) · WAD / (totalShares + 1)              // vaultOf view
```

Both directions round in the vault's favor (mint floors shares in, redeem floors
assets out), and the **`+1 / +1` virtual offset** neutralizes the classic
first-depositor inflation attack: on an empty vault the first deposit mints
proportionally rather than one wei of shares that could then be revalued by a
donation. The floored redemption also means `assets ≤ poolAssets` for any single
withdrawal, so a redeem can never underflow the pool.

There is no separate accrual index. Because every share is a pro-rata claim on
`poolAssets`, earnings and losses are reflected the instant they hit the pool —
the NAV **is** the accumulator, so entry timing is fair by construction with no
per-deposit bookkeeping.

## Entry — immediate, at NAV

`deposit(marketId, assets)` mints against the up-to-the-instant NAV and pulls the
USDM in the same call. A mid-block joiner therefore buys in at the current price
and can never harvest earnings that accrued before it arrived.

Deposits require a **banded primary feed** (`refFeed != 0`); an unbanded deposit
reverts `UnbandedFeed`. This is load-bearing for senior money: an operator whose
feed is not checked against a reference could fabricate marks and drain the pool
through a single fake round trip or a retroactive walk-back wipe. Requiring the
band makes the mark stream trustworthy by construction before any lender capital
is exposed to it.

## Exit — unstake cooldown, redeem at current NAV

Exit is two steps, gated by the market's frozen `unstakeSecs`:

1. `requestUnstake(marketId, shares)` starts the cooldown clock. **The shares stay
   in the pool** — they keep earning fees and keep bearing P&L through the whole
   window. Re-requesting overwrites the prior request and resets the timer.
2. `withdraw(marketId)`, once `block.timestamp ≥ unlockAt`, burns the requested
   shares at the **current** NAV and transfers the USDM out. `CooldownActive`
   before the clock; `NothingStaked` with no request.

The cooldown is pure exit friction — it exists so a lender cannot pull capital
opportunistically the instant the book takes an adverse position, not to change
what a share is worth. Because redemption is always at the live NAV, waiting out
the cooldown confers no timing advantage or disadvantage beyond the P&L the
shares earn or lose while they wait. If the recorded request exceeds the holder's
current balance (they moved shares elsewhere in the meantime), the burn is
**clamped** to what they actually hold.

## The oracle rake

The feed operator's compensation is the rake, and it is the vault's only outflow
that is not a lender redemption:

```
_credit(marketId, amount):
    rake          = amount · rakePpm / PPM          // gross — off the top of every gain
    v.rakeOwed   += rake
    v.poolAssets += amount − rake                   // remainder lifts share price
```

- `rakePpm` is **frozen at market creation**, copied from the feed's `feeRakePpm`
  (which the oracle caps at 50%). It is never mutable.
- The rake is **gross**: it is taken off every pool *gain* and the operator shares
  in no *loss*. This is the deliberate asymmetry — the operator is paid for
  running the price feed and the book, and the lenders, not the operator, are the
  risk capital.
- `claimRake(marketId, to)` transfers the accrued `rakeOwed` and may be called
  **only by the current feed operator** (`NotFeedOperator` otherwise). The
  recipient is read live from the feed, so it tracks the operator, not a stored
  address.

## Builder codes

An order may name a **builder** (an address) and a **`builderFeePpm`** — both
inside the user's signed order, so the user consents to the referral and its
rate. The market freezes a cap (`maxBuilderFeePpm`); an order's rate must sit at
or under it. The builder is per-order, so a user can open through one builder and
close through another (never locked in). The winnings realized on a decrease or
an increase-crystallization pay the order's builder too, not just the flat fees.

Builder **eligibility lives in a separate contract**, not in the market: each
market freezes an `IBuilderRegistry` address at creation (`builderRegistryOf`;
`address(0)` disables builder codes for that market), and the market only ever
asks it `isBuilder(addr)`. So the criteria — what is staked, how much, any other
rule — are not frozen into the immutable market; changing them is deploying a new
registry and pointing new markets at it. The market reads the registry behind a
try/catch, so a reverting or hostile registry can never brick order execution —
it just forfeits the builder share to the vault (as does an order naming an
ineligible or zero builder; no revert either way). The reference `BuilderRegistry`
gates on a stake (native ETH, or an ERC-20 such as MEGA — configurable, since ETH,
not MEGA, is MegaETH's gas token) so naming yourself as builder is not a free
rebate; it costs the same locked stake as anyone else. Accrued fees live in the
market: builders `claimBuilderFees` there; they `register`/`unregister` in the
registry to gain/recover eligibility and their stake.

**Fee waterfall (oracle-senior):** on every order-driven fee/cut, the oracle rake
is skimmed FIRST and is untouched by the builder; the builder then takes its share
of the **vault residual** (`(amount − rake) · builderFeePpm`), and only the rest
lifts the share price. So builders are paid out of what would have gone to lenders,
never out of the operator's rake.

## Settlement hooks

The position paths settle against the vault through two internal credit calls
(`_credit` for non-order flows, `_creditWithBuilder` for order-driven fees/cut)
plus `_drainPool`:

- **`_credit` / `_creditWithBuilder`** — every trading earning enters here
  (open/close fees, the winnings cut, trader losses, liquidation wipes). It skims
  the rake, splits out any builder share (order-driven credits only), and adds the
  remainder to `poolAssets`, lifting the share price for lenders.
- **`_drainPool`** — a trader win leaves here. It reverts `Insolvent` if
  `poolAssets` cannot cover the payout, and otherwise subtracts it. **Opens are
  never solvency-gated** — only payouts are — so a market can always take new risk;
  it just cannot pay out more than it holds.

A loss is a **pure NAV markdown** borne pro-rata by every share. There is no
haircut mechanism, no first-loss tranche, and no waterfall: `poolAssets` simply
falls, and the share price with it.

## The risk this design accepts (state plainly to lenders)

Lenders are the **unhedged counterparty** to the market — the house. When traders
are net long, the vault is net short, and vice versa; the vault holds the
aggregate trader skew and marks it to the oracle every tick. The compensation for
that variance is the edge: open/close fees plus the winnings cut on trader
profits, net of the oracle rake. The exchange does **not** hedge on the lenders'
behalf and holds no buffer for them — a lender who wants to neutralize the
directional exposure must do it themselves, off-platform.

The contract's one structural bound on that variance is the market's frozen
**`maxOISkew`**: it caps how far net-long-minus-net-short the book can run, i.e.
the largest directional position the vault can ever be forced to hold. Unlike a
hedge it needs no trusted operator to enforce — it is a creation-time parameter
checked on every open. Sizing it is the difference between "bounded house" and
"unbounded directional bet."

Before depositing, and before each position they hold, lenders should read the
cheap views: `vaultOf` (NAV, share price, pool size, rake terms) and `stakeOf`
(their shares and any pending unstake). The share price is worth exactly what the
book backs it for.
