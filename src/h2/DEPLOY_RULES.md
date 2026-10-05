# H2 deployment configuration rules

The contracts freeze a market's parameters at creation. These rules are not enforced on-chain; they
are what a deployer must get right. Each one comes from the Zenith 2026-09 audit.

1. **Reference band ≤ deviation gate, same feed.** The feed's `refBandPpm` must be ≤ the market's
   `maxDeviationPpm`, and the feed's `refFeed` must be the market's `fallbackFeed`. The oracle bands
   every mark before it enters the history, so nothing the market would refuse to trade on can
   later be used to liquidate a position. (Zenith #35)
   Keep the band meaningful for the asset and `refMaxStale` finite and no longer than you would
   trust the reference for: a 100% band or a never-stale reference turns the check off. (Zenith #44)

2. **Seed every vault at creation and keep the seed until wind-down.** Deposit into the vault in
   the same run that creates the market, and leave that deposit in until the market has no open
   positions and is being retired. A pool that holds assets while no shares exist misprices the
   next depositor. (Zenith #26)

3. **Fallback feed with at most 12 decimals.** Above that, the fallback liquidation cushion can
   lose one tick of a position's protection at a boundary. (Zenith #8)

4. **Builder stake token: native or a standard ERC-20.** `stakeToken` must be `address(0)` (native)
   or an ERC-20 with no transfer fee and no rebasing. The registry credits the nominal stake, so a
   fee-on-transfer token would leave it under-collateralized. (Zenith #10)

5. **Monotonic winnings cut.** `cutSlopePpm × cutInterceptPpm ≤ 1e6 × (1e6 − 2 × maxCutPpm)`.
   Otherwise a larger win can pay out less than a smaller one. (Zenith #30)

6. **Funding budget against post-fee collateral.** `createMarket` bounds the funding that can accrue
   over `primaryStaleSecs` (the window in which a user cannot exit without the operator) against
   gross collateral, `1 / maxLeverage`. The open fee is taken from that collateral first and
   liquidation fires at `liqWidthPpm`, so hold the stricter bound by hand:
   `fundingRateCapPerSec × primaryStaleSecs / PCT_SCALE ≤ 1 / maxLeverage − open fee at maxPositionNotional − liqWidthPpm`.
   Keep `minAdjustGapBlocks` at 1; a longer gap extends the window in which a position cannot be
   closed. Otherwise funding at the cap can liquidate a max-leverage position before the fallback
   arms, with the price flat. (Zenith #12)

7. **Maintenance width within the fallback close spread.** `liqWidthPpm ≤ fbCloseSpreadPpm − fbLiqSpreadPpm`.
   A close or increase through `executeAtFallback` checks the stale primary ring, not the current
   fallback liquidation test, so a position `liquidateAtFallback` could wipe can still close at the
   fallback price. With the width inside the gap between the two spreads, such a close pays out
   nothing, the same as the wipe. A wider width would let it recover residual equity. (Zenith #14)

8. **Flat fee curves.** Keep the size-scaling fee terms (`openLinearScale`, `openQuadScale`,
   `closeLinearScale`, `closeQuadScale`) at 0. `createMarket` bounds each coefficient but not the
   curve's value, and a close-fee rate above 100% makes a long close of that size revert. If a term
   is ever enabled, the curve must stay at or below `MAX_FEE_PPM` (10%) at any close notional the
   market can see; close notional is priced at the fill, so it grows with price well past
   `maxPositionNotional`. (Zenith #16)

Reference deployment (MegaETH mainnet, BTC): reference band 1% and deviation gate 1%, both against
the same RedStone feed (8 decimals), reference max age 6 h; vault seeded at creation; native-ETH builder stake; cut
intercept 10%, slope 10%, max 5.5%; 1000x with a 50 ppm flat open fee and zero width, so post-fee
collateral is 950 ppm of notional against at most ≈ 488 ppm of funding over the 300 s window
(rate cap 1.5e15 per second); adjustment gap 1 block; fallback close spread 2,000 ppm and liquidation
cushion 1,000 ppm, so the zero width sits 1,000 ppm inside rule 7; flat 50 ppm open and close fees
with every size-scaling term at 0.
