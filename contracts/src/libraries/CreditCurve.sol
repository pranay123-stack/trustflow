// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title CreditCurve
/// @notice The transparent, deterministic map from identity -> borrowing power and price of credit.
/// @dev Every function is `pure`. Anyone can recompute a borrower's terms off-chain and get a
///      bit-identical answer -- that is the point. `web/src/lib/creditCurve.ts` is a line-for-line
///      TypeScript mirror of this file, and `test/CreditCurveParity.t.sol` pins the vectors both
///      implementations must agree on.
///
///      ------------------------------------------------------------------
///      THE CURVE, IN ONE PARAGRAPH
///      ------------------------------------------------------------------
///      A borrower's limit has two additive parts:
///
///        maxBorrow = reputationLine + collateralLine
///
///      1. reputationLine -- pure unsecured credit, requires NO collateral. Its ceiling is set
///         by the CVI tier (identity strength), and the CVI score scales it within that band
///         from 50% to 100% of the ceiling. Tier 0 has a ceiling of zero: an unverified wallet
///         gets no unsecured credit at all.
///
///      2. collateralLine -- posted collateral, amplified by trust. Tier 0 borrows at a
///         conservative 80% LTV (the "fully collateralized fallback"). Higher tiers lever the
///         same collateral further, because a larger share of their line is allowed to be
///         unsecured:
///
///             trustLtv(tier) = BASE_SECURED_LTV / (1 - unsecuredShare(tier))
///
///         With unsecuredShare = [0%, 40%, 70%, 90%] this yields LTVs of
///         [0.80x, 1.33x, 2.67x, 8.00x] against collateral.
///
///      Interest is a standard kinked utilization curve MINUS a trust rebate of up to 600bps,
///      so compliance is directly rewarded in the price the borrower pays.
library CreditCurve {
    // ---------------------------------------------------------------------
    // Units
    // ---------------------------------------------------------------------

    /// @notice Basis-point denominator. 10_000 bps == 100%.
    uint256 internal constant BPS = 10_000;

    /// @notice Highest CVI tier the curve recognises.
    uint8 internal constant MAX_CVI_TIER = 3;

    /// @notice Highest CVI score the curve recognises.
    uint16 internal constant MAX_CVI_SCORE = 1000;

    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    // ---------------------------------------------------------------------
    // Borrowing-power parameters
    // ---------------------------------------------------------------------

    /// @notice Unsecured ceiling per CVI tier, in vUSD (18 decimals), at a perfect CVI score.
    /// @dev tier0 = 0 by design: no identity, no unsecured credit. Ever.
    uint256 internal constant TIER0_CEILING = 0;
    uint256 internal constant TIER1_CEILING = 2_000e18;
    uint256 internal constant TIER2_CEILING = 10_000e18;
    uint256 internal constant TIER3_CEILING = 50_000e18;

    /// @notice Share of a tier's credit line permitted to be unsecured.
    uint256 internal constant TIER0_UNSECURED_BPS = 0; // fully collateralized fallback
    uint256 internal constant TIER1_UNSECURED_BPS = 4_000; // 40%
    uint256 internal constant TIER2_UNSECURED_BPS = 7_000; // 70%
    uint256 internal constant TIER3_UNSECURED_BPS = 9_000; // 90%

    /// @notice LTV applied to collateral before the trust amplifier. A tier-0 borrower sees
    ///         exactly this: a conventional 80%-LTV overcollateralized loan.
    uint256 internal constant BASE_SECURED_LTV_BPS = 8_000;

    /// @notice Floor of the CVI score band. A verified borrower with a zero CVI score still
    ///         receives half of their tier ceiling; a perfect score receives all of it.
    uint256 internal constant SCORE_FLOOR_BPS = 5_000;

    // ---------------------------------------------------------------------
    // Trust-score weights (drives the UI dial and the rate rebate)
    // ---------------------------------------------------------------------

    /// @notice CVI tier contributes 60% of the composite trust score...
    uint256 internal constant CVI_TIER_WEIGHT_BPS = 6_000;
    /// @notice ...and the CVI score the remaining 40%.
    uint256 internal constant CVI_SCORE_WEIGHT_BPS = 4_000;

    // ---------------------------------------------------------------------
    // Interest-rate parameters
    // ---------------------------------------------------------------------

    /// @notice Rate charged at zero utilization to a zero-trust borrower.
    uint256 internal constant BASE_RATE_BPS = 400; // 4.00%
    /// @notice Utilization at which the curve kinks steeply upward.
    uint256 internal constant KINK_BPS = 8_000; // 80%
    /// @notice Premium accumulated from 0% utilization up to the kink.
    uint256 internal constant SLOPE1_BPS = 800; // +8.00% at the kink
    /// @notice Premium accumulated from the kink up to 100% utilization.
    uint256 internal constant SLOPE2_BPS = 6_000; // +60.00% at full draw
    /// @notice Largest rebate a perfectly-trusted borrower can earn.
    uint256 internal constant MAX_TRUST_DISCOUNT_BPS = 600; // -6.00%
    /// @notice Rate can never be discounted below this.
    uint256 internal constant RATE_FLOOR_BPS = 200; // 2.00%

    // ---------------------------------------------------------------------
    // Normalisation
    // ---------------------------------------------------------------------

    /// @notice Clamp an oracle-supplied tier into the supported range.
    /// @dev Deliberately clamps rather than reverts. A misconfigured or upgraded oracle that
    ///      starts emitting tier 4 must not be able to brick every borrow in the pool; it
    ///      degrades to the most generous *known* tier instead of halting the protocol.
    function clampTier(uint8 cviTier) internal pure returns (uint256) {
        return cviTier > MAX_CVI_TIER ? MAX_CVI_TIER : cviTier;
    }

    /// @notice Clamp an oracle-supplied CVI score into the supported range.
    function clampScore(uint16 cviScore) internal pure returns (uint256) {
        return cviScore > MAX_CVI_SCORE ? MAX_CVI_SCORE : cviScore;
    }

    // ---------------------------------------------------------------------
    // Curve primitives
    // ---------------------------------------------------------------------

    /// @notice Maximum unsecured line for a tier, at a perfect CVI score, in vUSD.
    function tierCeiling(uint8 cviTier) internal pure returns (uint256) {
        uint256 t = clampTier(cviTier);
        if (t == 0) return TIER0_CEILING;
        if (t == 1) return TIER1_CEILING;
        if (t == 2) return TIER2_CEILING;
        return TIER3_CEILING;
    }

    /// @notice Share of the credit line this tier may leave uncollateralized, in bps.
    function unsecuredShareBps(uint8 cviTier) internal pure returns (uint256) {
        uint256 t = clampTier(cviTier);
        if (t == 0) return TIER0_UNSECURED_BPS;
        if (t == 1) return TIER1_UNSECURED_BPS;
        if (t == 2) return TIER2_UNSECURED_BPS;
        return TIER3_UNSECURED_BPS;
    }

    /// @notice Effective LTV applied to posted collateral, in bps.
    /// @dev trustLtv = BASE_SECURED_LTV / (1 - unsecuredShare). Integer division truncates,
    ///      which always rounds the borrower's power DOWN -- the safe direction for the pool.
    ///      Yields [8_000, 13_333, 26_666, 80_000] bps for tiers 0..3.
    function trustLtvBps(uint8 cviTier) internal pure returns (uint256) {
        uint256 share = unsecuredShareBps(cviTier);
        return (BASE_SECURED_LTV_BPS * BPS) / (BPS - share);
    }

    /// @notice CVA scaling factor within a tier band, in bps. Ranges 5_000..10_000.
    function scoreFactorBps(uint16 cviScore) internal pure returns (uint256) {
        uint256 s = clampScore(cviScore);
        return SCORE_FLOOR_BPS + ((BPS - SCORE_FLOOR_BPS) * s) / MAX_CVI_SCORE;
    }

    /// @notice Composite 0..10_000 trust score. This is the number the UI dial renders.
    /// @dev 60% weight on identity strength (CVI), 40% on live compliance quality (CVA).
    ///      A tier-3 wallet with a perfect CVI score scores exactly 10_000.
    function trustScoreBps(uint8 cviTier, uint16 cviScore) internal pure returns (uint256) {
        uint256 t = clampTier(cviTier);
        uint256 s = clampScore(cviScore);
        return (CVI_TIER_WEIGHT_BPS * t) / MAX_CVI_TIER + (CVI_SCORE_WEIGHT_BPS * s) / MAX_CVI_SCORE;
    }

    // ---------------------------------------------------------------------
    // Borrowing power
    // ---------------------------------------------------------------------

    /// @notice Unsecured credit available from reputation alone, requiring zero collateral.
    function reputationLine(uint8 cviTier, uint16 cviScore) internal pure returns (uint256) {
        return (tierCeiling(cviTier) * scoreFactorBps(cviScore)) / BPS;
    }

    /// @notice Credit unlocked by posted collateral, amplified by the borrower's tier.
    function collateralLine(uint8 cviTier, uint256 collateral) internal pure returns (uint256) {
        return (collateral * trustLtvBps(cviTier)) / BPS;
    }

    /// @notice Total borrowing power: the reputation line plus the collateral line.
    /// @dev The single source of truth for "how much can this wallet owe". Called by the pool
    ///      on borrow, on collateral withdrawal, and by the liquidation health check.
    function maxBorrow(uint8 cviTier, uint16 cviScore, uint256 collateral)
        internal
        pure
        returns (uint256)
    {
        return reputationLine(cviTier, cviScore) + collateralLine(cviTier, collateral);
    }

    // ---------------------------------------------------------------------
    // Price of credit
    // ---------------------------------------------------------------------

    /// @notice Utilization premium from the kinked curve, in bps.
    /// @param utilizationBps Pool utilization (borrows / total assets), 0..10_000.
    function utilizationPremiumBps(uint256 utilizationBps) internal pure returns (uint256) {
        uint256 u = utilizationBps > BPS ? BPS : utilizationBps;
        if (u <= KINK_BPS) {
            return (SLOPE1_BPS * u) / KINK_BPS;
        }
        return SLOPE1_BPS + (SLOPE2_BPS * (u - KINK_BPS)) / (BPS - KINK_BPS);
    }

    /// @notice Rebate earned by a trusted borrower, in bps. 0..600.
    function trustDiscountBps(uint8 cviTier, uint16 cviScore) internal pure returns (uint256) {
        return (MAX_TRUST_DISCOUNT_BPS * trustScoreBps(cviTier, cviScore)) / BPS;
    }

    /// @notice The borrower's annualised rate, in bps.
    /// @dev base + utilization premium - trust rebate, floored at RATE_FLOOR_BPS. Because the
    ///      floor binds before the subtraction can underflow, this never reverts.
    function borrowRateBps(uint8 cviTier, uint16 cviScore, uint256 utilizationBps)
        internal
        pure
        returns (uint256)
    {
        uint256 gross = BASE_RATE_BPS + utilizationPremiumBps(utilizationBps);
        uint256 discount = trustDiscountBps(cviTier, cviScore);
        if (gross <= discount + RATE_FLOOR_BPS) return RATE_FLOOR_BPS;
        return gross - discount;
    }

    /// @notice Simple (non-compounding) interest accrued on `principal` over `elapsed` seconds.
    /// @dev Interest is compounded implicitly by being folded back into principal at each
    ///      touch of the account -- see TrustFlowPool._accrue.
    function accruedInterest(uint256 principal, uint256 rateBps, uint256 elapsed)
        internal
        pure
        returns (uint256)
    {
        if (principal == 0 || rateBps == 0 || elapsed == 0) return 0;
        return (principal * rateBps * elapsed) / (BPS * SECONDS_PER_YEAR);
    }
}
