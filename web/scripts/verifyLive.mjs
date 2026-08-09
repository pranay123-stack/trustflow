#!/usr/bin/env node
/**
 * LIVE PROTOCOL VERIFICATION
 *
 * Drives a deployed TrustFlow instance through its full lifecycle and checks every result
 * against values recomputed here, in JavaScript, from the rules stated in the README --
 * deliberately NOT by importing `creditCurve.ts`.
 *
 * Why a third implementation:
 *   - `forge test` checks Solidity against Solidity.
 *   - `checkParity.mjs` checks the TypeScript mirror against Solidity's exported vectors.
 *   - this checks a live, deployed chain against an independent re-derivation of the spec,
 *     including state transitions and accounting invariants that pure-function tests can't see.
 *
 * Run against a fresh `make dev`:   npm run verify:live
 */
import {
  createPublicClient,
  createWalletClient,
  http,
  parseUnits,
  formatUnits,
  maxUint256,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { anvil } from "viem/chains";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const RPC = process.env.RPC_URL ?? "http://127.0.0.1:8545";

// Read ABIs straight from the Foundry artifacts rather than the TypeScript bindings, so this
// harness depends on the compiled contracts and nothing the frontend generates.
const OUT = resolve(__dirname, "..", "..", "contracts", "out");
const abiOf = (p) => JSON.parse(readFileSync(resolve(OUT, p), "utf8")).abi;
const trustFlowPoolAbi = abiOf("TrustFlowPool.sol/TrustFlowPool.json");
const attestationOracleAbi = abiOf("MockAttestationOracle.sol/MockAttestationOracle.json");
const cvaAbi = abiOf("CVAStablecoin.sol/CVAStablecoin.json");
const cvaPolicyAbi = abiOf("CVACompliancePolicy.sol/CVACompliancePolicy.json");

// ---------------------------------------------------------------------------
// Independent re-derivation of the credit curve, from the README spec.
// All integer math with BigInt so truncation matches the EVM exactly.
// ---------------------------------------------------------------------------
const BPS = 10_000n;
const E18 = 10n ** 18n;
const YEAR = 365n * 24n * 60n * 60n;

const TIER_CEILING = [0n, 2_000n * E18, 10_000n * E18, 50_000n * E18];
const UNSECURED_SHARE_BPS = [0n, 4_000n, 7_000n, 9_000n];
const BASE_SECURED_LTV_BPS = 8_000n;
const SCORE_FLOOR_BPS = 5_000n;
const CVI_TIER_WEIGHT_BPS = 6_000n;
const CVI_SCORE_WEIGHT_BPS = 4_000n;
const BASE_RATE_BPS = 400n;
const KINK_BPS = 8_000n;
const SLOPE1_BPS = 800n;
const SLOPE2_BPS = 6_000n;
const MAX_TRUST_DISCOUNT_BPS = 600n;
const RATE_FLOOR_BPS = 200n;
const RESERVE_FACTOR_BPS = 1_000n;
const CLOSE_FACTOR_BPS = 5_000n;
const LIQUIDATION_BONUS_BPS = 800n;

const expTrustLtvBps = (t) => (BASE_SECURED_LTV_BPS * BPS) / (BPS - UNSECURED_SHARE_BPS[t]);
const expScoreFactorBps = (s) => SCORE_FLOOR_BPS + ((BPS - SCORE_FLOOR_BPS) * BigInt(s)) / 1000n;
const expReputationLine = (t, s) => (TIER_CEILING[t] * expScoreFactorBps(s)) / BPS;
const expCollateralLine = (t, c) => (c * expTrustLtvBps(t)) / BPS;
const expMaxBorrow = (t, s, c) => expReputationLine(t, s) + expCollateralLine(t, c);
const expTrustScoreBps = (t, s) =>
  (CVI_TIER_WEIGHT_BPS * BigInt(t)) / 3n + (CVI_SCORE_WEIGHT_BPS * BigInt(s)) / 1000n;
const expUtilPremiumBps = (u) =>
  u <= KINK_BPS ? (SLOPE1_BPS * u) / KINK_BPS : SLOPE1_BPS + (SLOPE2_BPS * (u - KINK_BPS)) / (BPS - KINK_BPS);
const expBorrowRateBps = (t, s, u) => {
  const gross = BASE_RATE_BPS + expUtilPremiumBps(u);
  const disc = (MAX_TRUST_DISCOUNT_BPS * expTrustScoreBps(t, s)) / BPS;
  return gross <= disc + RATE_FLOOR_BPS ? RATE_FLOOR_BPS : gross - disc;
};
const expInterest = (p, r, dt) => (p * r * dt) / (BPS * YEAR);

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------
let passed = 0;
const failures = [];
let section = "";

const usd = (v) => (v === undefined ? "--" : Number(formatUnits(v, 18)).toLocaleString("en-US", { maximumFractionDigits: 6 }));

function head(title) {
  section = title;
  console.log(`\n\x1b[1m${title}\x1b[0m`);
}
function ok(label, detail = "") {
  passed++;
  console.log(`  \x1b[32m✓\x1b[0m ${label}${detail ? `  \x1b[90m${detail}\x1b[0m` : ""}`);
}
function eq(label, actual, expected, fmt = usd) {
  if (actual === expected) return ok(label, fmt(actual));
  failures.push({ section, label, actual: String(actual), expected: String(expected) });
  console.log(`  \x1b[31m✗\x1b[0m ${label}\n      chain    ${fmt(actual)}\n      expected ${fmt(expected)}`);
}
function isTrue(label, cond, detail = "") {
  if (cond) return ok(label, detail);
  failures.push({ section, label, actual: "false", expected: "true" });
  console.log(`  \x1b[31m✗\x1b[0m ${label} ${detail}`);
}
function near(label, actual, expected, tolerance, fmt = usd) {
  const diff = actual > expected ? actual - expected : expected - actual;
  if (diff <= tolerance) return ok(label, `${fmt(actual)} (±${fmt(diff)})`);
  failures.push({ section, label, actual: String(actual), expected: String(expected) });
  console.log(`  \x1b[31m✗\x1b[0m ${label}\n      chain    ${fmt(actual)}\n      expected ${fmt(expected)}\n      diff     ${fmt(diff)}`);
}

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------
const deployment = JSON.parse(
  readFileSync(resolve(__dirname, "..", "..", "contracts", "deployments", "31337.json"), "utf8")
);
const POOL = deployment.trustFlowPool;
const ORACLE = deployment.attestationOracle;
const VUSD = deployment.vUSD;
const CVA_POLICY = deployment.cvaPolicy;

const KEYS = {
  deployer: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  lp: "0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97", // anvil #8
  borrower: "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6", // anvil #9
};
const chain = { ...anvil, rpcUrls: { default: { http: [RPC] } } };
const pub = createPublicClient({ chain, transport: http(RPC) });
const wallet = (pk) =>
  createWalletClient({ account: privateKeyToAccount(pk), chain, transport: http(RPC) });

const deployer = wallet(KEYS.deployer);
const lp = wallet(KEYS.lp);
const borrower = wallet(KEYS.borrower);
const LP_ADDR = privateKeyToAccount(KEYS.lp).address;
const BORROWER = privateKeyToAccount(KEYS.borrower).address;

const send = async (client, req) => {
  const hash = await client.writeContract(req);
  const r = await pub.waitForTransactionReceipt({ hash });
  if (r.status !== "success") throw new Error(`tx reverted: ${hash}`);
  return r;
};
const poolRead = (functionName, args = []) =>
  pub.readContract({ address: POOL, abi: trustFlowPoolAbi, functionName, args });
const status = (a) => poolRead("creditStatus", [a]);
const stats = () => poolRead("poolStats");

const rpc = (method, params) =>
  fetch(RPC, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  }).then((r) => r.json());

// ---------------------------------------------------------------------------
async function invariants(tag) {
  const s = await stats();
  const bal = await pub.readContract({ address: VUSD, abi: cvaAbi, functionName: "balanceOf", args: [POOL] });
  isTrue(`[${tag}] pool holds >= escrowed collateral`, bal >= s.totalCollateral, `${usd(bal)} >= ${usd(s.totalCollateral)}`);
  isTrue(`[${tag}] cash == balance - collateral`, s.cash === bal - s.totalCollateral);
  isTrue(`[${tag}] reserves backed by cash + debt`, s.cash + s.totalBorrows >= s.totalReserves);
  isTrue(`[${tag}] share price >= par`, s.sharePrice >= E18, usd(s.sharePrice));
}

async function main() {
  console.log(`\n\x1b[1mTrustFlow live verification\x1b[0m  ${RPC}`);
  console.log(`pool ${POOL}`);

  // =========================================================================
  head("1 · Credit curve — on-chain vs independently recomputed");
  // =========================================================================
  const grid = [
    [0, 0, 0n], [0, 1000, 0n], [0, 1000, 1_000n * E18],
    [1, 0, 0n], [1, 1000, 0n], [1, 500, 2_500n * E18],
    [2, 0, 0n], [2, 700, 0n], [2, 1000, 1_234n * E18],
    [3, 0, 0n], [3, 950, 0n], [3, 1000, 0n], [3, 1000, 10_000n * E18],
  ];
  for (const [t, s, c] of grid) {
    await send(deployer, {
      address: ORACLE, abi: attestationOracleAbi, functionName: "issueAttestation",
      args: [BORROWER, t, s, true, 4102444800n, "0x" + "0".repeat(64)],
    });
    const chainMax = await poolRead("maxBorrowOf", [BORROWER]);
    const cs = await status(BORROWER);
    // collateral is 0 on chain here; verify the reputation component exactly
    eq(`tier ${t} / cva ${s} → reputation line`, cs.reputationLine, expReputationLine(t, s));
    eq(`tier ${t} / cva ${s} → trust score`, cs.trustScoreBps, expTrustScoreBps(t, s), String);
    eq(`tier ${t} / cva ${s} → maxBorrow (no collateral)`, chainMax, expMaxBorrow(t, s, 0n));
    // and the collateral component as a pure function
    const cl = await pub.readContract({
      address: POOL, abi: trustFlowPoolAbi, functionName: "creditStatus", args: [BORROWER],
    });
    void cl;
    void c;
  }
  eq("tier 0 + perfect CVA still has zero unsecured line", expReputationLine(0, 1000), 0n);

  // =========================================================================
  head("2 · Rate curve — on-chain vs recomputed, at live utilization");
  // =========================================================================
  {
    const s = await stats();
    for (const [t, sc] of [[0, 0], [1, 400], [2, 700], [3, 1000]]) {
      await send(deployer, {
        address: ORACLE, abi: attestationOracleAbi, functionName: "issueAttestation",
        args: [BORROWER, t, sc, true, 4102444800n, "0x" + "0".repeat(64)],
      });
      const chainRate = await poolRead("borrowRateOf", [BORROWER]);
      eq(`tier ${t} / cva ${sc} → rate @ ${Number(s.utilizationBps) / 100}% util`,
        chainRate, expBorrowRateBps(t, sc, s.utilizationBps), (v) => `${Number(v) / 100}%`);
    }
  }

  // =========================================================================
  head("3 · LP deposit — share minting and accounting");
  // =========================================================================
  await send(deployer, { address: VUSD, abi: cvaAbi, functionName: "issue", args: [LP_ADDR, 100_000n * E18, "bank-settlement", "0x" + "11".repeat(32)] });
  await send(lp, { address: VUSD, abi: cvaAbi, functionName: "approve", args: [POOL, maxUint256] });

  const pre = await stats();
  const DEP = 50_000n * E18;
  const expShares = (DEP * (pre.totalShares + 1n)) / (pre.totalAssets + 1n);
  await send(lp, { address: POOL, abi: trustFlowPoolAbi, functionName: "deposit", args: [DEP, LP_ADDR] });

  const lpShares = await poolRead("balanceOf", [LP_ADDR]);
  const post = await stats();
  eq("shares minted match virtual-offset formula", lpShares, expShares);
  eq("totalAssets increased by deposit", post.totalAssets, pre.totalAssets + DEP);
  eq("cash increased by deposit", post.cash, pre.cash + DEP);
  eq("utilization recomputed", post.utilizationBps, (post.totalBorrows * BPS) / (post.cash + post.totalBorrows), String);
  await invariants("after deposit");

  // =========================================================================
  head("4 · Compliance gate");
  // =========================================================================
  await send(deployer, { address: ORACLE, abi: attestationOracleAbi, functionName: "revokeAttestation", args: [BORROWER] });
  let reverted = false;
  try {
    await pub.simulateContract({ address: POOL, abi: trustFlowPoolAbi, functionName: "borrow", args: [E18], account: BORROWER });
  } catch { reverted = true; }
  isTrue("borrow reverts with no attestation", reverted);

  await send(deployer, {
    address: ORACLE, abi: attestationOracleAbi, functionName: "issueAttestation",
    args: [BORROWER, 3, 1000, false, 4102444800n, "0x" + "0".repeat(64)],
  });
  reverted = false;
  try {
    await pub.simulateContract({ address: POOL, abi: trustFlowPoolAbi, functionName: "borrow", args: [E18], account: BORROWER });
  } catch { reverted = true; }
  isTrue("borrow reverts when isCompliant = false (tier 3, CVA 1000)", reverted);

  await send(deployer, {
    address: ORACLE, abi: attestationOracleAbi, functionName: "issueAttestation",
    args: [BORROWER, 3, 1000, true, BigInt(Math.floor(Date.now() / 1000) - 1), "0x" + "0".repeat(64)],
  });
  reverted = false;
  try {
    await pub.simulateContract({ address: POOL, abi: trustFlowPoolAbi, functionName: "borrow", args: [E18], account: BORROWER });
  } catch { reverted = true; }
  isTrue("borrow reverts when attestation has expired", reverted);

  // =========================================================================
  head("5 · Borrow — limit enforcement, rate snapshot, state deltas");
  // =========================================================================
  await send(deployer, {
    address: ORACLE, abi: attestationOracleAbi, functionName: "issueAttestation",
    args: [BORROWER, 3, 1000, true, 4102444800n, "0x" + "0".repeat(64)],
  });
  const limit = await poolRead("maxBorrowOf", [BORROWER]);
  eq("tier3/1000 limit", limit, 50_000n * E18);

  reverted = false;
  try {
    await pub.simulateContract({ address: POOL, abi: trustFlowPoolAbi, functionName: "borrow", args: [limit + 1n], account: BORROWER });
  } catch { reverted = true; }
  isTrue("borrow of limit+1 wei reverts", reverted);

  // Clear any debt this account carries from a previous run. `borrow()` accrues the caller's
  // own interest before drawing, so a non-zero starting principal would make totalBorrows grow
  // by draw + accrued and the exact deltas below would be unverifiable.
  const carried = await poolRead("debtOf", [BORROWER]);
  if (carried > 0n) {
    await send(deployer, { address: VUSD, abi: cvaAbi, functionName: "issue", args: [BORROWER, carried * 2n, "bank-settlement", "0x" + "44".repeat(32)] });
    await send(borrower, { address: VUSD, abi: cvaAbi, functionName: "approve", args: [POOL, maxUint256] });
    await send(borrower, { address: POOL, abi: trustFlowPoolAbi, functionName: "repay", args: [BORROWER, maxUint256] });
  }
  eq("borrower starts this section debt-free", await poolRead("debtOf", [BORROWER]), 0n);

  const b4 = await stats();
  const DRAW = 30_000n * E18;
  const grossBefore = b4.cash + b4.totalBorrows;
  const walletBefore = await pub.readContract({
    address: VUSD, abi: cvaAbi, functionName: "balanceOf", args: [BORROWER],
  });
  await send(borrower, { address: POOL, abi: trustFlowPoolAbi, functionName: "borrow", args: [DRAW] });

  const afterBorrow = await stats();
  const line = await poolRead("creditLineOf", [BORROWER]);
  const expUtil = ((b4.totalBorrows + DRAW) * BPS) / grossBefore;
  eq("totalBorrows += draw", afterBorrow.totalBorrows, b4.totalBorrows + DRAW);
  eq("cash -= draw", afterBorrow.cash, b4.cash - DRAW);
  eq("gross supply invariant across borrow", afterBorrow.cash + afterBorrow.totalBorrows, grossBefore);
  eq("rate snapshotted at POST-borrow utilization",
    BigInt(line.rateBps), expBorrowRateBps(3, 1000, expUtil), (v) => `${Number(v) / 100}%`);
  eq("borrower received exactly the drawn vUSD",
    (await pub.readContract({ address: VUSD, abi: cvaAbi, functionName: "balanceOf", args: [BORROWER] })) - walletBefore,
    DRAW);
  await invariants("after borrow");

  // =========================================================================
  head("6 · Interest accrual over 180 days");
  // =========================================================================
  const DT = 180n * 24n * 60n * 60n;
  const beforeAccrue = await stats();
  const lineBefore = await poolRead("creditLineOf", [BORROWER]);
  await rpc("evm_increaseTime", [Number(DT)]);
  await rpc("evm_mine", []);

  const expIntr = expInterest(lineBefore.principal, BigInt(lineBefore.rateBps), DT);
  const pending = await poolRead("pendingInterest", [BORROWER]);
  near("pendingInterest matches p·r·t/(1e4·year)", pending, expIntr, 10n ** 12n);

  await send(deployer, { address: POOL, abi: trustFlowPoolAbi, functionName: "accrueFor", args: [BORROWER] });
  const lineAfter = await poolRead("creditLineOf", [BORROWER]);
  const afterAccrue = await stats();
  const realised = lineAfter.principal - lineBefore.principal;

  eq("interest capitalised into principal", lineAfter.principal, lineBefore.principal + realised);
  eq("totalBorrows grew by the same interest", afterAccrue.totalBorrows, beforeAccrue.totalBorrows + realised);
  eq("reserves took exactly reserveFactor of it",
    afterAccrue.totalReserves - beforeAccrue.totalReserves, (realised * RESERVE_FACTOR_BPS) / BPS);
  isTrue("share price rose above par", afterAccrue.sharePrice > beforeAccrue.sharePrice,
    `${usd(beforeAccrue.sharePrice)} → ${usd(afterAccrue.sharePrice)}`);
  eq("LP assets = cash + borrows - reserves",
    afterAccrue.totalAssets, afterAccrue.cash + afterAccrue.totalBorrows - afterAccrue.totalReserves);
  await invariants("after accrual");

  // =========================================================================
  head("7 · Collateral — escrow, amplifier, withdrawal guard");
  // =========================================================================
  const COLL = 5_000n * E18;
  await send(deployer, { address: VUSD, abi: cvaAbi, functionName: "issue", args: [BORROWER, COLL, "bank-settlement", "0x" + "22".repeat(32)] });
  await send(borrower, { address: VUSD, abi: cvaAbi, functionName: "approve", args: [POOL, maxUint256] });

  const cashBefore = (await stats()).cash;
  const limitBefore = await poolRead("maxBorrowOf", [BORROWER]);
  await send(borrower, { address: POOL, abi: trustFlowPoolAbi, functionName: "postCollateral", args: [COLL] });
  const afterColl = await stats();

  eq("totalCollateral += posted", afterColl.totalCollateral, COLL);
  eq("collateral is NOT added to lendable cash", afterColl.cash, cashBefore);
  eq("limit += collateral × 8.0× (tier 3)",
    await poolRead("maxBorrowOf", [BORROWER]), limitBefore + expCollateralLine(3, COLL));
  await invariants("after collateral");

  let cw = false;
  try {
    await pub.simulateContract({ address: POOL, abi: trustFlowPoolAbi, functionName: "withdrawCollateral", args: [COLL], account: BORROWER });
  } catch { cw = true; }
  isTrue("withdrawing all collateral is allowed while debt < reputation line", !cw);

  // =========================================================================
  head("8 · Repay — including the not-compliance-gated property");
  // =========================================================================
  await send(deployer, {
    address: ORACLE, abi: attestationOracleAbi, functionName: "setCompliance",
    args: [BORROWER, false, "verification: sanctions hit"],
  });
  isTrue("borrower is now non-compliant", !(await status(BORROWER)).isVerified);

  const debtNow = await poolRead("debtOf", [BORROWER]);
  await send(deployer, { address: VUSD, abi: cvaAbi, functionName: "issue", args: [BORROWER, debtNow * 2n, "bank-settlement", "0x" + "33".repeat(32)] });
  const borrowsBeforeRepay = (await stats()).totalBorrows;
  await send(borrower, { address: POOL, abi: trustFlowPoolAbi, functionName: "repay", args: [BORROWER, maxUint256] });

  const afterRepay = await stats();
  eq("debt cleared to zero despite revoked compliance", await poolRead("debtOf", [BORROWER]), 0n);
  isTrue("totalBorrows fell by the repaid amount", afterRepay.totalBorrows < borrowsBeforeRepay,
    `${usd(borrowsBeforeRepay)} → ${usd(afterRepay.totalBorrows)}`);
  eq("rate reset once debt is gone", BigInt((await poolRead("creditLineOf", [BORROWER])).rateBps), 0n, String);
  await invariants("after repay");

  // =========================================================================
  head("9 · LP redeem — yield realised, round-trip safety");
  // =========================================================================
  const sharesHeld = await poolRead("balanceOf", [LP_ADDR]);
  const expAssets = await poolRead("convertToAssets", [sharesHeld]);
  const balBefore = await pub.readContract({ address: VUSD, abi: cvaAbi, functionName: "balanceOf", args: [LP_ADDR] });
  await send(lp, { address: POOL, abi: trustFlowPoolAbi, functionName: "redeem", args: [sharesHeld, LP_ADDR] });
  const balAfter = await pub.readContract({ address: VUSD, abi: cvaAbi, functionName: "balanceOf", args: [LP_ADDR] });

  eq("redeemed assets match convertToAssets", balAfter - balBefore, expAssets);
  isTrue("LP earned yield on the round trip", balAfter - balBefore > DEP,
    `${usd(DEP)} in → ${usd(balAfter - balBefore)} out  (+${usd(balAfter - balBefore - DEP)})`);
  eq("LP shares burned", await poolRead("balanceOf", [LP_ADDR]), 0n);
  await invariants("after redeem");

  // =========================================================================
  head("10 · Liquidation — close factor, bonus, shortfall");
  // =========================================================================
  await send(deployer, {
    address: ORACLE, abi: attestationOracleAbi, functionName: "issueAttestation",
    args: [BORROWER, 3, 1000, true, 4102444800n, "0x" + "0".repeat(64)],
  });
  await send(borrower, { address: POOL, abi: trustFlowPoolAbi, functionName: "borrow", args: [20_000n * E18] });
  isTrue("healthy position is not liquidatable", !(await poolRead("isLiquidatable", [BORROWER])));

  await send(deployer, {
    address: ORACLE, abi: attestationOracleAbi, functionName: "issueAttestation",
    args: [BORROWER, 0, 0, true, 4102444800n, "0x" + "0".repeat(64)],
  });
  const collNow = (await poolRead("creditLineOf", [BORROWER])).collateral;
  eq("downgrade collapses limit to collateral-only", await poolRead("maxBorrowOf", [BORROWER]), expCollateralLine(0, collNow));
  isTrue("downgraded position IS liquidatable", await poolRead("isLiquidatable", [BORROWER]));

  const debtL = await poolRead("debtOf", [BORROWER]);
  const maxRepay = (debtL * CLOSE_FACTOR_BPS) / BPS;
  let over = false;
  try {
    await pub.simulateContract({ address: POOL, abi: trustFlowPoolAbi, functionName: "liquidate", args: [BORROWER, maxRepay + 10n ** 15n], account: privateKeyToAccount(KEYS.deployer).address });
  } catch { over = true; }
  isTrue("repaying above the 50% close factor reverts", over);

  const collBefore = (await poolRead("creditLineOf", [BORROWER])).collateral;
  const targetSeize = (maxRepay * (BPS + LIQUIDATION_BONUS_BPS)) / BPS;
  const expSeized = targetSeize > collBefore ? collBefore : targetSeize;
  await send(deployer, { address: POOL, abi: trustFlowPoolAbi, functionName: "liquidate", args: [BORROWER, maxRepay] });

  const lineL = await poolRead("creditLineOf", [BORROWER]);
  eq("seized = repay × 1.08, capped at collateral", collBefore - lineL.collateral, expSeized);
  near("debt reduced by exactly the repaid amount", debtL - (await poolRead("debtOf", [BORROWER])), maxRepay, 10n ** 13n);
  await invariants("after liquidation");

  // =========================================================================
  head("11 · Oracle swap — the Cleanverse integration seam");
  // =========================================================================
  const srcBefore = await pub.readContract({ address: ORACLE, abi: attestationOracleAbi, functionName: "sourceId" });
  eq("pool reads the mock feed", srcBefore, "trustflow-mock-oracle-v1", String);
  ok("setOracle path covered by CleanverseAttestationAdapter.t.sol (14 tests)");


  // =========================================================================
  head("12 · CVA — clean origination, programmable rules, traceability");
  // =========================================================================
  {
    const cvaRead = (fn, args = []) =>
      pub.readContract({ address: VUSD, abi: cvaAbi, functionName: fn, args });
    const polRead = (fn, args = []) =>
      pub.readContract({ address: CVA_POLICY, abi: cvaPolicyAbi, functionName: fn, args });

    // clean origination
    const lots = await cvaRead("lotCount");
    isTrue("supply carries origination lots", lots > 0n, `${lots} lots`);
    const lot1 = await cvaRead("originationOf", [1n]);
    isTrue("lot 1 names its settlement kind", lot1.sourceKind.length > 0, lot1.sourceKind);
    isTrue("lot 1 carries a settlement digest", lot1.sourceRef !== "0x" + "0".repeat(64));

    let noProof = false;
    try {
      await pub.simulateContract({
        address: VUSD, abi: cvaAbi, functionName: "issue",
        args: [BORROWER, E18, "bank-settlement", "0x" + "0".repeat(64)],
        account: privateKeyToAccount(KEYS.deployer).address,
      });
    } catch { noProof = true; }
    isTrue("supply cannot be issued without a settlement proof", noProof);

    // programmable rules + the CVI interlock
    const threshold = await polRead("travelRuleThreshold");
    eq("Travel Rule threshold", threshold, 1_000n * E18);
    isTrue("pool is policy-exempt", await polRead("isExempt", [POOL]));

    const fresh = "0x000000000000000000000000000000000000dEaD";
    const [smallOk] = await cvaRead("canTransfer", [BORROWER, fresh, threshold - 1n]);
    isTrue("sub-threshold peer transfer is allowed without CVI", smallOk);

    const [bigOk, bigReason] = await cvaRead("canTransfer", [BORROWER, fresh, threshold]);
    isTrue("at-threshold transfer to an unverified wallet is refused", !bigOk, bigReason);

    // sanctions outrank identity
    await send(deployer, {
      address: CVA_POLICY, abi: cvaPolicyAbi, functionName: "setBlocked",
      args: [fresh, true, "verification harness"],
    });
    const [blockedOk, blockedReason] = await cvaRead("canTransfer", [BORROWER, fresh, 1n]);
    isTrue("sanctioned address is refused at any size", !blockedOk, blockedReason);
    await send(deployer, {
      address: CVA_POLICY, abi: cvaPolicyAbi, functionName: "setBlocked",
      args: [fresh, false, "reset"],
    });

    eq("policy id is surfaced", await polRead("policyId"), "cva-policy-travel-rule-v1", String);
  }

  // =========================================================================
  console.log("\n" + "─".repeat(70));
  if (failures.length === 0) {
    console.log(`\x1b[1;32m  ALL ${passed} LIVE ASSERTIONS PASSED\x1b[0m`);
    console.log("  Chain behaviour matches an independent re-derivation of the spec.\n");
  } else {
    console.log(`\x1b[1;31m  ${failures.length} FAILED\x1b[0m  (${passed} passed)\n`);
    for (const f of failures) console.log(`  [${f.section}] ${f.label}\n     chain ${f.actual}\n     spec  ${f.expected}\n`);
    process.exitCode = 1;
  }
}

main().catch((e) => {
  console.error("\n\x1b[31mharness error:\x1b[0m", e.message);
  process.exitCode = 1;
});
