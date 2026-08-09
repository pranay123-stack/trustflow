// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CreditCurveHarness} from "./harness/CreditCurveHarness.sol";

/// @notice Exhaustive coverage of the credit curve: every tier boundary, every clamp, and
///         fuzzed monotonicity/bounds properties.
contract CreditCurveTest is Test {
    CreditCurveHarness internal curve;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant RATE_FLOOR = 200;
    uint256 internal constant RATE_CEIL = 7_200; // BASE 400 + SLOPE1 800 + SLOPE2 6000

    function setUp() public {
        curve = new CreditCurveHarness();
    }

    // =====================================================================
    // Clamping -- a misbehaving oracle must never brick the pool
    // =====================================================================

    function test_clampTier_passesThroughValidRange() public view {
        assertEq(curve.clampTier(0), 0);
        assertEq(curve.clampTier(1), 1);
        assertEq(curve.clampTier(2), 2);
        assertEq(curve.clampTier(3), 3);
    }

    function test_clampTier_clampsAboveMax() public view {
        assertEq(curve.clampTier(4), 3, "tier 4 must degrade to 3");
        assertEq(curve.clampTier(255), 3, "tier 255 must degrade to 3");
    }

    function test_clampScore_passesThroughValidRange() public view {
        assertEq(curve.clampScore(0), 0);
        assertEq(curve.clampScore(500), 500);
        assertEq(curve.clampScore(1000), 1000);
    }

    function test_clampScore_clampsAboveMax() public view {
        assertEq(curve.clampScore(1001), 1000);
        assertEq(curve.clampScore(type(uint16).max), 1000);
    }

    /// @dev The critical safety property: no tier/score an oracle can emit causes a revert.
    function testFuzz_curveNeverRevertsOnAnyOracleInput(uint8 tier, uint16 score, uint256 collateral)
        public
        view
    {
        collateral = bound(collateral, 0, 1e30);
        curve.maxBorrow(tier, score, collateral);
        curve.borrowRateBps(tier, score, 10_000);
        curve.trustScoreBps(tier, score);
    }

    // =====================================================================
    // Tier ceilings and unsecured shares
    // =====================================================================

    function test_tierCeilings() public view {
        assertEq(curve.tierCeiling(0), 0, "tier0 gets zero unsecured credit");
        assertEq(curve.tierCeiling(1), 2_000e18);
        assertEq(curve.tierCeiling(2), 10_000e18);
        assertEq(curve.tierCeiling(3), 50_000e18);
    }

    function test_unsecuredShares() public view {
        assertEq(curve.unsecuredShareBps(0), 0, "tier0 is fully collateralized");
        assertEq(curve.unsecuredShareBps(1), 4_000);
        assertEq(curve.unsecuredShareBps(2), 7_000);
        assertEq(curve.unsecuredShareBps(3), 9_000, "tier3 reaches 90% unsecured");
    }

    /// @dev trustLtv = BASE_SECURED_LTV / (1 - unsecuredShare), truncated toward the pool.
    function test_trustLtvBps_derivedFromUnsecuredShare() public view {
        assertEq(curve.trustLtvBps(0), 8_000, "tier0 = plain 80% LTV fallback");
        assertEq(curve.trustLtvBps(1), 13_333);
        assertEq(curve.trustLtvBps(2), 26_666);
        assertEq(curve.trustLtvBps(3), 80_000, "tier3 levers collateral 8x");
    }

    // =====================================================================
    // CVI score band
    // =====================================================================

    function test_scoreFactor_spansFloorToFull() public view {
        assertEq(curve.scoreFactorBps(0), 5_000, "zero CVA still earns half the tier band");
        assertEq(curve.scoreFactorBps(500), 7_500);
        assertEq(curve.scoreFactorBps(1000), 10_000, "perfect CVA earns the full band");
    }

    // =====================================================================
    // THE HEADLINE EDGE CASE: tier 0 gets no unsecured credit, ever
    // =====================================================================

    function test_tier0_hasZeroReputationLine_regardlessOfCva() public view {
        assertEq(curve.reputationLine(0, 0), 0);
        assertEq(curve.reputationLine(0, 500), 0);
        assertEq(curve.reputationLine(0, 1000), 0, "a perfect CVA cannot buy an unverified wallet credit");
    }

    function test_tier0_withNoCollateral_cannotBorrowAtAll() public view {
        assertEq(curve.maxBorrow(0, 1000, 0), 0, "tier0 + no collateral = no credit line");
    }

    function test_tier0_withCollateral_isExactly80PercentLtv() public view {
        assertEq(curve.maxBorrow(0, 0, 1_000e18), 800e18);
        assertEq(
            curve.maxBorrow(0, 1000, 1_000e18), 800e18, "CVA cannot lever a tier0 wallet past 80%"
        );
    }

    // =====================================================================
    // Reputation line at every tier x score corner
    // =====================================================================

    function test_reputationLine_tier1_corners() public view {
        assertEq(curve.reputationLine(1, 0), 1_000e18);
        assertEq(curve.reputationLine(1, 1000), 2_000e18);
    }

    function test_reputationLine_tier2_corners() public view {
        assertEq(curve.reputationLine(2, 0), 5_000e18);
        assertEq(curve.reputationLine(2, 1000), 10_000e18);
    }

    function test_reputationLine_tier3_corners() public view {
        assertEq(curve.reputationLine(3, 0), 25_000e18);
        assertEq(curve.reputationLine(3, 500), 37_500e18);
        assertEq(curve.reputationLine(3, 1000), 50_000e18, "max identity = 50k fully unsecured");
    }

    function test_reputationLine_clampedTierBehavesAsTier3() public view {
        assertEq(curve.reputationLine(9, 1000), 50_000e18);
    }

    // =====================================================================
    // Collateral line
    // =====================================================================

    function test_collateralLine_scalesWithTier() public view {
        uint256 c = 1_000e18;
        assertEq(curve.collateralLine(0, c), 800e18);
        assertEq(curve.collateralLine(1, c), 1_333.3e18);
        assertEq(curve.collateralLine(2, c), 2_666.6e18);
        assertEq(curve.collateralLine(3, c), 8_000e18);
    }

    function test_collateralLine_zeroCollateralIsZero() public view {
        assertEq(curve.collateralLine(3, 0), 0);
    }

    // =====================================================================
    // Composite max borrow
    // =====================================================================

    function test_maxBorrow_isReputationPlusCollateral() public view {
        // tier3 / CVA 1000 / 1_000 collateral = 50_000 unsecured + 8_000 secured.
        assertEq(curve.maxBorrow(3, 1000, 1_000e18), 58_000e18);
    }

    function test_maxBorrow_tier3_noCollateral_isFullyUnsecured() public view {
        assertEq(curve.maxBorrow(3, 1000, 0), 50_000e18);
    }

    /// @dev The protocol's core claim, stated as a test: at tier 3 the unsecured portion of a
    ///      drawn line clears 90%.
    function test_tier3_unsecuredShareOfLineExceeds90Percent() public view {
        uint256 collateral = 1_000e18;
        uint256 max = curve.maxBorrow(3, 1000, collateral);
        uint256 unsecured = max - collateral;
        assertGe((unsecured * BPS) / max, 9_000, "tier3 line must be >=90% unsecured");
    }

    function test_tier0_unsecuredShareOfLineIsZero() public view {
        uint256 collateral = 1_000e18;
        uint256 max = curve.maxBorrow(0, 1000, collateral);
        assertLt(max, collateral, "tier0 line must stay under its collateral: overcollateralized");
    }

    // =====================================================================
    // Trust score (drives the UI dial)
    // =====================================================================

    function test_trustScore_corners() public view {
        assertEq(curve.trustScoreBps(0, 0), 0, "dial starts empty");
        assertEq(curve.trustScoreBps(3, 1000), 10_000, "dial maxes at exactly 10_000");
    }

    function test_trustScore_weighting_60cvi_40cva() public view {
        assertEq(curve.trustScoreBps(3, 0), 6_000, "CVI alone contributes 60%");
        assertEq(curve.trustScoreBps(0, 1000), 4_000, "CVA alone contributes 40%");
        assertEq(curve.trustScoreBps(1, 250), 3_000);
        assertEq(curve.trustScoreBps(2, 750), 7_000);
    }

    // =====================================================================
    // Interest rate curve
    // =====================================================================

    function test_utilizationPremium_kinkShape() public view {
        assertEq(curve.utilizationPremiumBps(0), 0);
        assertEq(curve.utilizationPremiumBps(4_000), 400, "half way to the kink");
        assertEq(curve.utilizationPremiumBps(8_000), 800, "at the kink");
        assertEq(curve.utilizationPremiumBps(9_000), 3_800, "steep slope past the kink");
        assertEq(curve.utilizationPremiumBps(10_000), 6_800, "fully drawn");
    }

    function test_utilizationPremium_clampsAbove100Percent() public view {
        assertEq(curve.utilizationPremiumBps(20_000), 6_800);
    }

    function test_trustDiscount_maxIs600Bps() public view {
        assertEq(curve.trustDiscountBps(0, 0), 0);
        assertEq(curve.trustDiscountBps(3, 1000), 600, "perfect trust earns the full 6% rebate");
    }

    function test_borrowRate_untrustedPaysBase() public view {
        assertEq(curve.borrowRateBps(0, 0, 0), 400);
    }

    function test_borrowRate_trustReducesRate() public view {
        uint256 untrusted = curve.borrowRateBps(0, 0, 8_000);
        uint256 trusted = curve.borrowRateBps(3, 1000, 8_000);
        assertEq(untrusted, 1_200);
        assertEq(trusted, 600, "the same draw costs a tier3 borrower 600bps less");
        assertLt(trusted, untrusted);
    }

    function test_borrowRate_floorBindsInsteadOfUnderflowing() public view {
        // gross = 400, discount = 600. Naive subtraction would underflow.
        assertEq(curve.borrowRateBps(3, 1000, 0), RATE_FLOOR, "floor binds, no revert");
    }

    function test_borrowRate_ceilingAtFullUtilization() public view {
        assertEq(curve.borrowRateBps(0, 0, 10_000), RATE_CEIL);
        assertEq(curve.borrowRateBps(3, 1000, 10_000), RATE_CEIL - 600);
    }

    // =====================================================================
    // Interest accrual
    // =====================================================================

    function test_accruedInterest_oneYearAtTenPercent() public view {
        assertEq(curve.accruedInterest(1_000e18, 1_000, 365 days), 100e18);
    }

    function test_accruedInterest_zeroInputs() public view {
        assertEq(curve.accruedInterest(0, 1_000, 365 days), 0);
        assertEq(curve.accruedInterest(1_000e18, 0, 365 days), 0);
        assertEq(curve.accruedInterest(1_000e18, 1_000, 0), 0);
    }

    function test_accruedInterest_isLinearInTime() public view {
        uint256 half = curve.accruedInterest(1_000e18, 1_000, 182.5 days);
        assertEq(half, 50e18);
    }

    // =====================================================================
    // Fuzzed invariants
    // =====================================================================

    function testFuzz_maxBorrow_monotonicInTier(uint8 tier, uint16 score, uint256 collateral)
        public
        view
    {
        tier = uint8(bound(tier, 0, 2));
        score = uint16(bound(score, 0, 1000));
        collateral = bound(collateral, 0, 1e30);

        assertGe(
            curve.maxBorrow(tier + 1, score, collateral),
            curve.maxBorrow(tier, score, collateral),
            "a higher CVI tier must never reduce borrowing power"
        );
    }

    function testFuzz_maxBorrow_monotonicInScore(uint8 tier, uint16 score, uint256 collateral)
        public
        view
    {
        tier = uint8(bound(tier, 0, 3));
        score = uint16(bound(score, 0, 999));
        collateral = bound(collateral, 0, 1e30);

        assertGe(
            curve.maxBorrow(tier, score + 1, collateral),
            curve.maxBorrow(tier, score, collateral),
            "a higher CVI score must never reduce borrowing power"
        );
    }

    function testFuzz_maxBorrow_monotonicInCollateral(uint8 tier, uint16 score, uint256 collateral)
        public
        view
    {
        tier = uint8(bound(tier, 0, 3));
        score = uint16(bound(score, 0, 1000));
        collateral = bound(collateral, 0, 1e30);

        assertGe(
            curve.maxBorrow(tier, score, collateral + 1e18),
            curve.maxBorrow(tier, score, collateral),
            "more collateral must never reduce borrowing power"
        );
    }

    function testFuzz_borrowRate_alwaysWithinBounds(uint8 tier, uint16 score, uint256 util)
        public
        view
    {
        util = bound(util, 0, 20_000);
        uint256 rate = curve.borrowRateBps(tier, score, util);
        assertGe(rate, RATE_FLOOR, "rate must never dip below the floor");
        assertLe(rate, RATE_CEIL, "rate must never exceed base + both slopes");
    }

    /// @dev Justifies the unchecked `uint16(rate)` cast in TrustFlowPool.
    function testFuzz_borrowRate_alwaysFitsUint16(uint8 tier, uint16 score, uint256 util)
        public
        view
    {
        util = bound(util, 0, 20_000);
        assertLe(curve.borrowRateBps(tier, score, util), type(uint16).max);
    }

    function testFuzz_borrowRate_nonIncreasingInTrust(uint8 tier, uint16 score, uint256 util)
        public
        view
    {
        tier = uint8(bound(tier, 0, 2));
        score = uint16(bound(score, 0, 1000));
        util = bound(util, 0, 10_000);

        assertLe(
            curve.borrowRateBps(tier + 1, score, util),
            curve.borrowRateBps(tier, score, util),
            "more trust must never cost more"
        );
    }

    function testFuzz_borrowRate_nonDecreasingInUtilization(uint8 tier, uint16 score, uint256 util)
        public
        view
    {
        util = bound(util, 0, 9_999);
        assertLe(
            curve.borrowRateBps(tier, score, util),
            curve.borrowRateBps(tier, score, util + 1),
            "a more utilized pool must never charge less"
        );
    }

    /// @dev Truncation must always favour the pool, never the borrower.
    function testFuzz_collateralLine_neverExceedsExactMath(uint8 tier, uint256 collateral)
        public
        view
    {
        tier = uint8(bound(tier, 0, 3));
        collateral = bound(collateral, 0, 1e30);

        uint256 share = curve.unsecuredShareBps(tier);
        uint256 exact = (collateral * 8_000) / (BPS - share);
        assertLe(curve.collateralLine(tier, collateral), exact, "rounding must favour the pool");
    }
}
