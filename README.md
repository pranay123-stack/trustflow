# TrustFlow

**Undercollateralized lending built on both Cleanverse primitives.**

Cleanverse is a compliance-native rules layer that *interlocks verified identity and verified
assets on every value transfer*. TrustFlow is a credit market that uses both halves:

- **CVI — Cleanverse Verified Identity.** Identity tokens bound to wallets: bank-verified proofs,
  local-only PII, revocable credentials. In TrustFlow, CVI answers **who may borrow, how much,
  and at what rate** — replacing overcollateralization with verified reputation.
- **CVA — Cleanverse Verified Assets.** A verified stablecoin with clean origination, programmable
  compliance rules and full traceability. In TrustFlow, `vUSD` **is** a CVA asset: every unit
  traces to a recorded settlement, and every movement is checked against a swappable policy.

The two interlock. CVI decides how much credit a wallet gets; CVA decides whether the value may
move at all — and the CVA policy reads CVI to make that call.

Built for the Cleanverse *Verified Finance* hackathon, DeFi track.

---

## The problem

DeFi lending is stuck at overcollateralization. To borrow \$800 you must first lock \$1,000. That
is capital-destructive, and it excludes exactly the users traditional credit serves best:
verified businesses and individuals whose *identity* is the collateral.

The reason DeFi can't do unsecured credit is that a pseudonymous wallet has nothing at stake
beyond the collateral in the contract. Default costs it nothing.

**TrustFlow's answer:** make verified identity the thing at stake. A wallet's borrowing power is
a published, deterministic function of its CVI tier and credential score. Higher verified reputation →
higher loan-to-value → cheaper credit. Default, and the protocol emits a signal the attestation
authority consumes to downgrade the wallet's credentials — the consequence lands on the
reputation that made the credit possible in the first place.

This is credit *because of* compliance, not in spite of it.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                        FRONTEND  (Next.js · wagmi/viem)                       │
│                                                                               │
│   TrustDial          AttestationPanel      BorrowPanel        LpPanel         │
│   animated gauge     5 credential          slider capped      supply /        │
│   0–100 trust        buttons               at live limit      withdraw        │
│        │                    │                    │                 │          │
│        └────────────────────┴──────┬─────────────┴─────────────────┘          │
│                                    │                                          │
│                    creditCurve.ts  │  ← TypeScript mirror of the on-chain     │
│                    (instant quotes)│    curve, pinned by a 768-assertion      │
│                                    │    parity check. No RPC per keystroke.   │
└────────────────────────────────────┼──────────────────────────────────────────┘
                                     │ creditStatus() · poolStats() · events
┌────────────────────────────────────┼──────────────────────────────────────────┐
│                          MONAD     ▼                                          │
│                                                                               │
│   ┌─────────────────────────────────────────────────┐                         │
│   │              TrustFlowPool.sol                  │                         │
│   │                                                 │   ┌───────────────────┐ │
│   │  LP side          Borrower side                 │   │ CVAStablecoin     │ │
│   │  ─────────        ────────────                  │   │ (vUSD) — THE      │ │
│   │  deposit()        borrow()   ◄── CVI GATE       │◄─►│ CVA PRIMITIVE     │ │
│   │  redeem()         repay()                       │   │                   │ │
│   │                   postCollateral()              │   │ issue() records   │ │
│   │  ERC20 shares     withdrawCollateral()          │   │  clean origination│ │
│   │  (tfvUSD)         liquidate()                   │   │ _update() calls   │ │
│   │                   markDefault() ──► slash signal│   │  the policy       │ │
│   └───────────┬──────────────────────┬──────────────┘   │ emits traceability│ │
│               │                      │                  └─────────┬─────────┘ │
│               │ uses                 │ reads every               │ governed by│
│               ▼                      │ credit decision           ▼            │
│   ┌───────────────────────┐          │        ┌──────────────────────────────┐│
│   │  CreditCurve.sol      │          │        │ CVACompliancePolicy          ││
│   │  (pure library)       │          │        │ ── PROGRAMMABLE RULES ──     ││
│   │  maxBorrow()          │          │        │ 1 sanctions (absolute)       ││
│   │  borrowRateBps()      │          │        │ 2 protocol-leg exemption     ││
│   │  trustScoreBps()      │          │        │ 3 Travel Rule ≥ threshold    ││
│   │  reputationLine()     │          │        │ 4 baseline below it          ││
│   │  collateralLine()     │          │        └───────────┬──────────────────┘│
│   └───────────────────────┘          │                    │ reads CVI         │
│                                      ▼                    ▼   ◄── INTERLOCK   │
│                        ┌──────────────────────────────────────┐               │
│                        │   IAttestationOracle  (CVI)          │               │
│                        │   ── THE INTEGRATION SEAM ──         │               │
│                        │   getAttestation(addr) →             │               │
│                        │     { cviTier, cviScore, isCompliant,│               │
│                        │       issuedAt, expiresAt,           │               │
│                        │       credentialRef }                │               │
│                        │   isVerified(addr) · sourceId()      │               │
│                        └──────────────────┬───────────────────┘               │
│                                           │ implemented by                    │
│                        ┌──────────────────┴───────────────────┐               │
│                        ▼                                      ▼               │
│         ┌──────────────────────────┐         ┌──────────────────────────────┐ │
│         │ MockAttestationOracle    │         │ CleanverseAttestation        │ │
│         │ (demo — ships today)     │         │ Adapter (live — ships ready) │ │
│         │                          │         │                              │ │
│         │ attest(CredentialType)   │  swap   │ submitAttestation(           │ │
│         │  permissionless, so a    │ ──────► │   payload, EIP-712 sig)      │ │
│         │  live demo needs no      │  one    │  signed by Cleanverse,       │ │
│         │  issuer key              │  tx     │  relayed by the user         │ │
│         │ issueAttestation()       │         │ nonce + monotonic issuedAt   │ │
│         │  issuer-gated (prod path)│         │ replay & downgrade resistant │ │
│         └──────────────────────────┘         └──────────────────────────────┘ │
│                                                                               │
│         Switching feeds is ONE transaction: pool.setOracle(newOracle)          │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## The credit curve

Borrowing power has two additive parts. Both are pure functions — anyone can recompute a
borrower's terms off-chain and get a bit-identical answer.

```
maxBorrow = reputationLine + collateralLine
```

**1. Reputation line** — unsecured credit requiring *no collateral*. Ceiling set by CVI tier,
scaled within that band by the CVI credential score:

```
reputationLine = tierCeiling[cviTier] × scoreFactor(cviScore)
scoreFactor    = 50% + 50% × (cviScore / 1000)        // 0.50 … 1.00
```

**2. Collateral line** — posted collateral, amplified by trust:

```
collateralLine = collateral × trustLtv(cviTier)
trustLtv       = 80% / (1 − unsecuredShare(cviTier))
```

| CVI tier | Meaning | Unsecured share | Unsecured ceiling (CVI score 1000) | LTV on collateral |
|---|---|---|---|---|
| **0** | Unverified / pseudonymous | 0% | 0 vUSD | **0.80×** — plain overcollateralized fallback |
| **1** | Basic KYC | 40% | 2,000 vUSD | 1.33× |
| **2** | Enhanced (KYC + PoA + accreditation) | 70% | 10,000 vUSD | 2.67× |
| **3** | Institutional (KYB + UBO chain) | **90%** | **50,000 vUSD** | **8.00×** |

A tier-0 wallet gets **zero** unsecured credit no matter how high its credential score — identity is a
gate the score cannot buy past. A tier-3 wallet borrows 50,000 vUSD with no collateral at all.

**Interest** is a standard kinked utilization curve, minus a trust rebate — compliance is
rewarded in the price of credit, not just the size of the line:

```
APR = 4% base
    + utilization premium   (+8% at the 80% kink, +68% at full draw)
    − trust rebate          (up to −6%, scaled by the composite trust score)
    floored at 2%
```

**Trust score** (the 0–100 number on the dial) is `60% × CVI tier + 40% × CVI credential score`. Tier 3 with a perfect
credential score scores exactly 100.

---

## CVI · CVA integration points

Every place a Cleanverse primitive enters the protocol, and the exact code it maps to.

### CVI — Cleanverse Verified Identity → *who may borrow*

| # | Integration point | Interface member | Consumed by | Effect |
|---|---|---|---|---|
| 1 | **Verification tier** | `Attestation.cviTier` (0–3) | `CreditCurve.tierCeiling` / `.unsecuredShareBps` / `.trustLtvBps` | Sets the unsecured ceiling and the collateral amplifier |
| 2 | **Credential score** | `Attestation.cviScore` (0–1000) | `CreditCurve.scoreFactorBps` | Scales the line within the tier band (50%→100%) |
| 3 | **Compliance flag** | `Attestation.isCompliant` | `TrustFlowPool.borrow` → `oracle.isVerified()` | **Hard gate.** No live CVI, no new credit |
| 4 | **Revocability / expiry** | `Attestation.expiresAt` | `isVerified()` | A lapsed credential auto-closes the gate, no keeper needed |
| 5 | **Credential digest** | `Attestation.credentialRef` | stored + emitted | Audit trail; PII stays off-chain |
| 6 | **Composite trust** | derived | `CreditCurve.trustScoreBps` | Drives the rate rebate and the UI dial |
| 7 | **Feed provenance** | `sourceId()` | UI header badge | Shows at a glance whether the deployment reads mock or live data |
| 8 | **Downgrade** | re-issued attestation | read at call time, never cached | Collapses the line on the next block; position becomes liquidatable |
| 9 | **Default feedback** | `DefaultRecorded` event | `TrustFlowPool.markDefault` | Signal the authority consumes to slash the wallet's CVI |

### CVA — Cleanverse Verified Assets → *what may move*

| # | Integration point | Implementation | Effect |
|---|---|---|---|
| 10 | **Clean origination** | `CVAStablecoin.issue(to, amount, sourceKind, sourceRef)` | Supply cannot be created without naming the settlement that backed it and a digest of its proof. `issue` reverts on a zero `sourceRef` |
| 11 | **Origination ledger** | `originationOf(lotId)` → `Origination` | Every lot records issuer, timestamp, amount, settlement kind and proof digest |
| 12 | **Programmable rules** | `ICVACompliancePolicy` behind `setPolicy()` | The rule set is swappable per jurisdiction without redeploying the token or migrating holders |
| 13 | **Transfer gate** | `CVAStablecoin._update` → `policy.checkTransfer` | Every transfer is evaluated before it settles; refusals carry a human-readable reason |
| 14 | **Sanctions** | `CVACompliancePolicy.setBlocked` | Absolute, both directions, evaluated first — outranks even a tier-3 CVI |
| 15 | **Travel Rule** | `travelRuleThreshold` + `requiresTravelRule()` | Peer transfers at or above the threshold require a live CVI on both sides (FATF R.16 analogue) |
| 16 | **Full traceability** | `VerifiedValueTransferred` event | Every transfer logs both counterparties' CVI tiers and whether Travel Rule applied |
| 17 | **Non-reverting preflight** | `canTransfer()` | The UI can explain a refusal *before* asking for a signature |

### The interlock

| # | Where the two primitives meet | Mechanism |
|---|---|---|
| 18 | **CVA policy reads CVI** | `CVACompliancePolicy.checkTransfer` calls `cviOracle.isVerified()` — an asset rule enforced by an identity fact |
| 19 | **Revoking CVI freezes large transfers** | A sanctions hit on a CVI record blocks Travel-Rule-sized CVA movement on the next block |
| 20 | **Pool exemption is deliberate** | The pool custodies value for many users and has no meaningful CVI of its own, so identity for its flows is enforced by the borrow gate, not the transfer policy |
| 21 | **Two independent kill switches** | `setCompliance` (identity) stops new credit; `setBlocked` (asset) stops movement. Neither substitutes for the other |

### Swapping the mock for the live feed

The pool never imports a concrete oracle — only `IAttestationOracle`. Going live is one
transaction:

```solidity
pool.setOracle(IAttestationOracle(address(cleanverseAdapter)));
```

`CleanverseAttestationAdapter.sol` is written and tested against that path already
([`test_poolWorksAgainstLiveAdapterAfterOracleSwap`](contracts/test/CleanverseAttestationAdapter.t.sol)
stands up a pool on the mock, swaps to the adapter, submits a Cleanverse-signed attestation, and
borrows 50,000 vUSD — with zero changes to `TrustFlowPool`).

The adapter's flow:

1. User completes verification in Cleanverse; the service computes their CVI tier + credential score.
2. Cleanverse **signs** an EIP-712 `CleanverseAttestation` payload off-chain. No gas, no hot wallet.
3. The user (or a relayer) submits the signature on-chain.
4. The pool reads it through the same interface it used for the mock.

Enforced on submission: signature must come from the registered Cleanverse signer; each payload
carries a single-use nonce; `issuedAt` must strictly increase per subject, so a downgraded user
cannot replay an older, more favourable attestation; records carry a hard expiry.

**If the live API is REST rather than signed payloads**, only the adapter changes — write a
variant that ingests from your relayer or an on-chain publisher, keep `getAttestation` /
`isVerified` / `sourceId`, and call `setOracle`. Nothing else in the protocol moves.

---

## Why this is compliant, not evasive

- **Compliance is a gate, not a discount.** `borrow()` reverts unless the oracle reports a live,
  unexpired, compliant attestation. No admin override, no allowlist bypass — the check sits on
  the only path that reaches the transfer.
- **Repayment is never blocked.** If an attestation is revoked mid-loan the borrower can still
  repay. Freezing repayment would strand funds and leave a flagged wallet permanently indebted —
  worse for the lender, the borrower, and the regulator.
- **Credentials go on-chain, identities do not.** The chain stores a tier, a score, and a hash
  pointing at the off-chain bundle. No names, no documents, no PII.
- **Downgrades are immediate.** Borrowing power is read at call time, never cached at
  origination. A sanctions hit collapses the line on the next block.
- **Defaults have identity consequences.** When an unsecured line defaults there is no collateral
  to seize; `markDefault()` emits the signal the authority uses to downgrade the wallet.

---

## Quick start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`, `anvil`)
- Node.js 20+
- A browser wallet (MetaMask or similar)

### One command — local demo

```bash
make install     # first time only
make dev
```

That starts Anvil, deploys the full stack, seeds three demo borrowers at different trust tiers,
regenerates the frontend bindings, and opens the app on **http://localhost:3000**.

Add the local network to your wallet (RPC `http://127.0.0.1:8545`, chain ID `31337`), then either
import Anvil account #0 or just press **Faucet** in the app for 10,000 test vUSD.

### One command — Monad testnet

```bash
cp .env.example .env      # set PRIVATE_KEY to a funded throwaway key
make deploy-monad         # deploys + regenerates frontend bindings
make web                  # then switch your wallet to Monad Testnet
```

Monad testnet is chain ID `10143`; fund a key from the Monad faucet first.

### Everything CI would run

```bash
make verify   # build · 157 tests · curve parity · typecheck · production web build
```

---

## Demo script (90 seconds)

1. **Connect** — the dial reads 0. Available credit: 0 vUSD. The borrow panel shows the
   compliance gate closed.
2. **Try to borrow anyway** — reverts with `NotCompliant`. This is the point: the gate is real.
3. **Claim "Basic KYC"** — the dial sweeps to 28, tier 1 unlocks, and available credit animates
   from 0 to 1,200 vUSD. Note the APR appearing.
4. **Claim the remaining credentials** — watch the dial climb to 100 and the credit line reach
   **50,000 vUSD, fully unsecured, zero collateral posted**. The APR drops as trust rises.
5. **Borrow 30,000** — slider is capped at the live limit. The activity feed logs it instantly
   with tier and rate; pool utilization jumps.
6. **Show the credit curve chart** — borrowing power is a published function of identity, not a
   discretionary underwriting call.

---

## Testing

```bash
make test        # 157 tests
make parity      # 768 assertions: TypeScript curve == Solidity curve
make coverage
```

| Suite | Tests | What it covers |
|---|---|---|
| `CreditCurve.t.sol` | 42 | Every tier/score corner, clamping, monotonicity fuzz, rate bounds |
| `TrustFlowPool.t.sol` | 48 | Full lifecycle, compliance gate, interest, liquidation, oracle swap |
| `MockAttestationOracle.t.sol` | 21 | Credential ladder, one-shot claims, expiry, issuer control |
| `CVA.t.sol` | 23 | Clean origination, programmable rules, sanctions precedence, Travel Rule interlock, traceability events |
| `CleanverseAttestationAdapter.t.sol` | 14 | EIP-712 signing, replay, downgrade resistance, live swap |
| `invariant/` | 9 | Solvency and accounting properties over 12,800 randomised calls each |

Edge cases explicitly pinned, since the credit curve is where this protocol lives or dies:

- Tier 0 with a **perfect** credential score still gets **zero** unsecured credit
- Tier 0 with collateral is exactly an 80% LTV overcollateralized loan
- A tier above 3 or a score above 1000 **clamps** rather than reverting — a misconfigured oracle
  must never brick every borrow in the pool
- The rate floor binds *before* the trust rebate could underflow
- Collateral-line truncation always rounds toward the pool, never the borrower
- Interest accrual pushing a position underwater, then liquidating it
- An unsecured line downgraded to tier 0 mid-loan: liquidation reports the shortfall rather than
  hiding it, and `markDefault` fires

**Invariants held across 12,800 calls each:** collateral is always fully backed; `totalBorrows`
always equals the sum of every credit line's principal; the LP share price never falls below par;
reserves never inflate LP assets; withdrawable liquidity never eats into the reserve claim; a
tier-0 wallet with no collateral never has a credit line.

One of these was earned the hard way, and is worth stating because it is a real property of the
design rather than a curiosity. The obvious solvency assertion — *the pool's balance always
covers escrowed collateral plus accrued reserves* — is **false**, and the fuzzer produced the
counterexample. Reserves are booked the instant interest is capitalised, but the cash backing
that interest only arrives when the borrower repays. A heavily-drawn pool can therefore hold
less cash than it has booked in reserves. That is correct behaviour: reserves are a claim on
future repayments, and `availableLiquidity()` saturates to zero precisely so LPs are never paid
out of them. The invariant that *does* hold is `cash + totalBorrows >= totalReserves`.

---

## Scaling to a merchant & institutional pilot

The demo is a single pool with a single asset. Here is the path to a real pilot, and what each
step actually requires.

### Phase 1 — Pilot with a closed cohort (weeks)

Onboard 10–20 Cleanverse-verified merchants into a permissioned pool.

- Deploy `CleanverseAttestationAdapter` against the live CVI·CVA API and call `setOracle`.
- Raise `MockAttestationOracle`'s demo mode off; only issuer-signed attestations count.
- Cap the reputation line well below the curve's ceilings while loss data is thin — the tier
  ceilings are constants precisely so they can be tuned per deployment.
- LPs are a known set (the sponsor treasury, a partner fund). Utilization stays modest.

**What this proves:** default rates by CVI tier. That is the number the whole model rests on, and
nobody has it for undercollateralized on-chain credit yet.

### Phase 2 — Merchant receivables (months)

The natural first product is *working capital against verified revenue*.

- Extend the attestation struct with a revenue-attestation credential (a merchant processor
  signing "this entity settled \$X last quarter"). It slots in as another `CredentialType` and
  another input to `reputationLine` — the curve is a pure library, so this is an additive change.
- Add a term structure: fixed-duration draws rather than open lines, priced off the same curve.
- Introduce per-borrower caps as a fraction of attested revenue, so the line scales with the
  business rather than with the tier alone.

### Phase 3 — Institutional credit lines (quarters)

- **Tranching.** Split LP shares into senior/junior so risk-averse capital can fund the secured
  portion while junior capital absorbs unsecured first-loss. `TrustFlowPool` already segregates
  collateral from lendable cash, which is the accounting precondition.
- **Multi-asset.** The pool takes any ERC20 as `asset`; run parallel pools per currency rather
  than one pool with oracle-priced collateral, keeping the risk model legible.
- **Off-chain recourse.** For institutional borrowers, pair the on-chain line with a signed
  master agreement referenced by `credentialRef`. `markDefault` becomes the trigger for a
  real-world claim, not just a reputation slash.
- **Delegated underwriting.** Let whitelisted underwriters post junior capital against specific
  borrowers and earn the spread — the protocol supplies identity and accounting, underwriters
  supply judgment.

### What has to be built before real money

Stated plainly, because an MVP that pretends otherwise is not useful:

- **Interest accrues per borrower, on touch.** Each borrower pays a personalised rate, so there
  is no single global borrow index. `totalBorrows` lags real accrued interest until an account is
  poked, which makes the LP share price a slight *underestimate* — safe, but it needs a keeper
  sweeping `accrueForMany` before it is production accounting.
- **Liquidation cannot recover an unsecured line.** That is inherent, not a bug. Real deployment
  needs the off-chain recourse of Phase 3 to make the identity slash bite.
- **Oracle trust.** `setOracle` is owner-controlled. A real deployment puts it behind a timelock
  and a multisig — swapping the identity feed is the single most powerful action in the protocol.
- **Audit.** None of this has been audited.

---

## Repository layout

```
contracts/
  src/
    TrustFlowPool.sol                    the lending pool
    interfaces/IAttestationOracle.sol    THE INTEGRATION SEAM
    libraries/CreditCurve.sol            identity → borrowing power + price (pure)
    oracles/MockAttestationOracle.sol    demo feed, ships today
    oracles/CleanverseAttestationAdapter.sol   live feed, EIP-712 signed
    cva/CVAStablecoin.sol                vUSD — THE CVA PRIMITIVE
    cva/CVACompliancePolicy.sol          programmable rules; reads CVI
    interfaces/ICVA.sol                  CVA asset + policy interfaces
  test/                                  157 tests incl. fuzz + invariants
  script/
    Deploy.s.sol                         deploy + seed liquidity + write addresses
    Seed.s.sol                           demo borrowers at three trust tiers
    ExportCurveVectors.s.sol             parity fixtures for the TS mirror
web/
  src/lib/creditCurve.ts                 TypeScript mirror of CreditCurve.sol
  src/components/TrustDial.tsx           the animated gauge
  scripts/genabi.mjs                     regenerate ABIs + addresses from artifacts
  scripts/checkParity.mjs                prove the TS curve matches the Solidity
```

---

## Notes

Testnet only. vUSD has no value and the mock oracle hands out credentials to anyone who asks —
that is deliberate, so a judge can walk the full trust ladder without an issuer key. The
production path (`issueAttestation`, gated to registered issuers) is implemented alongside it,
and `disableDemoMode()` permanently closes the permissionless surface.

None of this is audited. Do not deploy it with real money.
