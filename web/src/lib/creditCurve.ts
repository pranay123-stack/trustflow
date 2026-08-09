/**
 * TypeScript mirror of `contracts/src/libraries/CreditCurve.sol`.
 *
 * WHY THIS EXISTS: the UI needs to show a borrower what their limit and rate WOULD be before
 * they sign anything -- as they drag the borrow slider, and the instant an attestation lands.
 * Round-tripping every keystroke to an RPC would make the dial feel dead.
 *
 * Every constant and every operation below is a line-for-line copy of the Solidity, using
 * BigInt so integer truncation matches exactly. Drift here would mean the UI quotes a limit
 * the chain then rejects, so the duplication is pinned by a parity check:
 *
 *   cd ../contracts && forge script script/ExportCurveVectors.s.sol   # export 384 vectors
 *   npm run test:parity                                              # replay them through this file
 *
 * If you change the Solidity, change this file, then re-run the parity check.
 */

export const BPS = 10_000n;
export const MAX_CVI_TIER = 3;
export const MAX_CVI_SCORE = 1000;
const SECONDS_PER_YEAR = 365n * 24n * 60n * 60n;

const TIER_CEILINGS = [0n, 2_000n * 10n ** 18n, 10_000n * 10n ** 18n, 50_000n * 10n ** 18n];
const TIER_UNSECURED_BPS = [0n, 4_000n, 7_000n, 9_000n];

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

export function clampTier(tier: number): number {
  return tier > MAX_CVI_TIER ? MAX_CVI_TIER : Math.max(0, tier);
}

export function clampScore(score: number): bigint {
  return BigInt(score > MAX_CVI_SCORE ? MAX_CVI_SCORE : Math.max(0, score));
}

export function tierCeiling(tier: number): bigint {
  return TIER_CEILINGS[clampTier(tier)];
}

export function unsecuredShareBps(tier: number): bigint {
  return TIER_UNSECURED_BPS[clampTier(tier)];
}

export function trustLtvBps(tier: number): bigint {
  return (BASE_SECURED_LTV_BPS * BPS) / (BPS - unsecuredShareBps(tier));
}

export function scoreFactorBps(score: number): bigint {
  return SCORE_FLOOR_BPS + ((BPS - SCORE_FLOOR_BPS) * clampScore(score)) / BigInt(MAX_CVI_SCORE);
}

/** The 0..10_000 composite the hero dial renders. */
export function trustScoreBps(tier: number, score: number): bigint {
  return (
    (CVI_TIER_WEIGHT_BPS * BigInt(clampTier(tier))) / BigInt(MAX_CVI_TIER) +
    (CVI_SCORE_WEIGHT_BPS * clampScore(score)) / BigInt(MAX_CVI_SCORE)
  );
}

/** Unsecured credit from reputation alone -- no collateral required. */
export function reputationLine(tier: number, score: number): bigint {
  return (tierCeiling(tier) * scoreFactorBps(score)) / BPS;
}

/** Credit unlocked by posted collateral, amplified by tier. */
export function collateralLine(tier: number, collateral: bigint): bigint {
  return (collateral * trustLtvBps(tier)) / BPS;
}

export function maxBorrow(tier: number, score: number, collateral: bigint): bigint {
  return reputationLine(tier, score) + collateralLine(tier, collateral);
}

export function utilizationPremiumBps(utilBps: bigint): bigint {
  const u = utilBps > BPS ? BPS : utilBps < 0n ? 0n : utilBps;
  if (u <= KINK_BPS) return (SLOPE1_BPS * u) / KINK_BPS;
  return SLOPE1_BPS + (SLOPE2_BPS * (u - KINK_BPS)) / (BPS - KINK_BPS);
}

export function trustDiscountBps(tier: number, score: number): bigint {
  return (MAX_TRUST_DISCOUNT_BPS * trustScoreBps(tier, score)) / BPS;
}

export function borrowRateBps(tier: number, score: number, utilBps: bigint): bigint {
  const gross = BASE_RATE_BPS + utilizationPremiumBps(utilBps);
  const discount = trustDiscountBps(tier, score);
  if (gross <= discount + RATE_FLOOR_BPS) return RATE_FLOOR_BPS;
  return gross - discount;
}

export function accruedInterest(principal: bigint, rateBps: bigint, elapsedSecs: bigint): bigint {
  if (principal === 0n || rateBps === 0n || elapsedSecs === 0n) return 0n;
  return (principal * rateBps * elapsedSecs) / (BPS * SECONDS_PER_YEAR);
}

// ---------------------------------------------------------------------------
// Presentation helpers -- not part of the on-chain mirror
// ---------------------------------------------------------------------------

export const TIER_LABELS = [
  "Unverified",
  "Basic Verified",
  "Enhanced Verified",
  "Institutional",
] as const;

export const TIER_BLURBS = [
  "Pseudonymous wallet. Collateral-only lending, capped at 80% LTV.",
  "Government ID and liveness confirmed. Small unsecured line unlocked.",
  "Identity plus proof of address and accreditation. Majority-unsecured credit.",
  "Entity formation and UBO chain verified. Full unsecured credit line.",
] as const;

/** Points on the credit curve, for the chart that explains the model. */
export function creditCurvePoints(collateral: bigint) {
  return [0, 1, 2, 3].map((tier) => ({
    tier,
    label: TIER_LABELS[tier],
    unsecuredShareBps: Number(unsecuredShareBps(tier)),
    ltvBps: Number(trustLtvBps(tier)),
    minLine: maxBorrow(tier, 0, collateral),
    maxLine: maxBorrow(tier, MAX_CVI_SCORE, collateral),
  }));
}
