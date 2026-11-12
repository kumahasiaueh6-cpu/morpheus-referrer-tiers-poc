# Morpheus — Referrer Tiers Unreachable (PoC)

Proof-of-concept for a **Low-severity** bug-bounty finding in the Morpheus
protocol (mor.org/bug-bounty, program v2): referrer tier multipliers are
unreachable in the wBTC, USDC and USDT `DepositPool`s, so referrers earn
**0 MOR forever** in 3 of 5 pools.

## Root cause (one line)

`ReferrerLib.applyReferrerTier` tracks `amountStaked` in the token's **native**
decimals, but the owner-set tier thresholds are written as if amounts were
18-decimal (human amount x 1e18). For 18-decimal tokens (stETH, wETH) it
works; for wBTC (8 dec) and USDC/USDT (6 dec) the thresholds exceed the
entire token supply.

Live thresholds at ETH block 26400696 (pool 0):

| Pool | decimals | tier0 threshold | tier0 in whole tokens | pool deposits |
|------|----------|----------------|----------------------|---------------|
| stETH | 18 | 1e18 | 1 stETH | 4,712 stETH |
| wETH | 18 | 1e18 | 1 wETH | 10.91 wETH |
| wBTC | 8 | 3.5e16 | 350,000,000 wBTC | 0.103 wBTC |
| USDC | 6 | 4e21 | 4,000,000,000,000,000 USDC | 628,270 USDC |
| USDT | 6 | 4e21 | 4,000,000,000,000,000 USDT | 4,739 USDT |

wBTC tier0 (350M wBTC) exceeds the entire wBTC supply (~127k) by ~2,800x;
USDC/USDT tier0 (4 quadrillion) exceeds entire supplies by ~4-5 orders of
magnitude.

## Run it

```bash
forge test
```

Expected: **7 tests passed, 0 failed** (4 in `ReferrerTiersTest`, 3 in
`AaveProbeTest`).

- `testUSDCTiersUnreachable` — 300,000 USDC referred (above the intended
  $250k tier-3 threshold) -> referrer `virtualAmountStaked = 0`, reward
  **0 MOR**.
- `testWETHTiersReachable` — positive control: 100 wETH referred -> virtual
  15 wETH (tier 3, 15%), referrer reward **464.15 MOR**.
- `testSelfReferral` — self-referral double-dip: 100 wETH self-referred ->
  2,387.78 MOR vs 2,058.43 MOR control (+16.0%). Separate Low, not part of
  the main report.
- `AaveProbeTest` — documents the fork-harness limitation: the Aave V3 Pool
  implementation reverts `NotActivated` under foundry 1.8.5's REVM on this
  fork, so the tested pools' strategy was flipped to NONE via `vm.store`
  (does not touch Morpheus logic).

Fork: Ethereum mainnet block **26400696** via BlastAPI
(`https://eth-mainnet.public.blastapi.io`, public endpoint, no key).
No mainnet transactions are made; everything runs on a local fork.

## Contracts (Ethereum)

- DepositPool impl (shared by all 5 pools):
  `0xdB10dAEF167eA2233Ba6811457dD24D676FbD670`
- Distributor impl: `0x52f76e8be3dfabcc3b0ded02882a22be47dade03`
- Deployed code is byte-identical to the public repo (Sourcify v2:
  DepositPool partial match, Distributor exact match).

## Notes

- `forge-std` is vendored under `lib/forge-std/` (source:
  foundry-rs/forge-std) so the PoC runs with a single `forge test`.
- Build artifacts (`out/`, `cache/`) are intentionally not committed.
- Severity is honestly **Low**: rewards misallocation, no principal at risk;
  forgone referrer rewards are ~2 MOR/day (~$560/year) for a max-size USDC
  referrer at current pool sizes.
- Suggested fix: normalize referred amounts to 18 decimals inside
  `ReferrerLib` (or set per-pool tier thresholds in the token's native
  decimals).
