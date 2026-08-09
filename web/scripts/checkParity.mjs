#!/usr/bin/env node
/**
 * Proves `src/lib/creditCurve.ts` computes bit-identical results to
 * `contracts/src/libraries/CreditCurve.sol`.
 *
 * The UI quotes borrowing limits and rates locally so the trust dial responds instantly. If the
 * TypeScript mirror ever drifts from the Solidity, the app would promise a borrower a limit the
 * chain rejects. This replays every exported vector through the TS implementation and exits
 * non-zero on the first mismatch.
 *
 *   forge script script/ExportCurveVectors.s.sol   # in ../contracts, regenerates the fixture
 *   npm run test:parity                            # here
 */
import { readFileSync, existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { register } from "node:module";
import { pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE = resolve(__dirname, "..", "..", "contracts", "fixtures", "credit-curve-vectors.json");

if (!existsSync(FIXTURE)) {
  console.error(`\n  Fixture not found: ${FIXTURE}`);
  console.error("  Generate it first:  cd ../contracts && forge script script/ExportCurveVectors.s.sol\n");
  process.exit(1);
}

// The curve module is plain TS with no runtime deps, so strip the types and eval it directly
// rather than pulling in a bundler just for this check.
const curveSrc = readFileSync(resolve(__dirname, "..", "src", "lib", "creditCurve.ts"), "utf8");
const js = curveSrc
  .replace(/^import .*$/gm, "")
  .replace(/export const (\w+) = ([\s\S]*?) as const;/g, "const $1 = $2;")
  .replace(/: bigint\[\]/g, "")
  .replace(/: bigint/g, "")
  .replace(/: number\[\]/g, "")
  .replace(/: number/g, "")
  .replace(/: string/g, "")
  .replace(/\bexport /g, "");

const curve = new Function(`${js}; return { maxBorrow, reputationLine, collateralLine, trustScoreBps, borrowRateBps };`)();

const vectors = JSON.parse(readFileSync(FIXTURE, "utf8"));

let checked = 0;
const failures = [];

function check(label, actual, expected, ctx) {
  checked++;
  if (actual !== expected) {
    failures.push(`${label} ${ctx}\n    solidity: ${expected}\n    typescript: ${actual}`);
  }
}

// ---------------------------------------------------------------- borrowing power
const b = vectors.borrow;
for (let i = 0; i < b.maxBorrow.length; i++) {
  const tier = Number(b.tier[i]);
  const score = Number(b.score[i]);
  const collateral = BigInt(b.collateral[i]);
  const ctx = `(tier=${tier}, cva=${score}, collateral=${b.collateral[i]})`;

  check("maxBorrow", curve.maxBorrow(tier, score, collateral), BigInt(b.maxBorrow[i]), ctx);
  check("reputationLine", curve.reputationLine(tier, score), BigInt(b.reputationLine[i]), ctx);
  check("collateralLine", curve.collateralLine(tier, collateral), BigInt(b.collateralLine[i]), ctx);
  check("trustScoreBps", curve.trustScoreBps(tier, score), BigInt(b.trustScoreBps[i]), ctx);
}

// ---------------------------------------------------------------------- rates
const r = vectors.rate;
for (let i = 0; i < r.borrowRateBps.length; i++) {
  const tier = Number(r.tier[i]);
  const score = Number(r.score[i]);
  const util = BigInt(r.utilizationBps[i]);
  const ctx = `(tier=${tier}, cva=${score}, util=${r.utilizationBps[i]}bps)`;

  check("borrowRateBps", curve.borrowRateBps(tier, score, util), BigInt(r.borrowRateBps[i]), ctx);
}

// --------------------------------------------------------------------- report
if (failures.length > 0) {
  console.error(`\n  PARITY FAILED -- ${failures.length} of ${checked} assertions mismatched:\n`);
  for (const f of failures.slice(0, 10)) console.error(`  ${f}\n`);
  if (failures.length > 10) console.error(`  ...and ${failures.length - 10} more\n`);
  console.error("  The TypeScript credit curve has drifted from the Solidity. Fix src/lib/creditCurve.ts.\n");
  process.exit(1);
}

console.log(`\n  Credit-curve parity OK: ${checked} assertions across ${b.maxBorrow.length} borrow and ${r.borrowRateBps.length} rate vectors.`);
console.log("  TypeScript mirror matches the Solidity exactly.\n");
