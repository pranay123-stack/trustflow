// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CreditCurve} from "../../src/libraries/CreditCurve.sol";

/// @notice Thin external wrapper so the `internal` CreditCurve library can be exercised
///         directly (including revert/fuzz paths) from tests.
contract CreditCurveHarness {
    function clampTier(uint8 t) external pure returns (uint256) {
        return CreditCurve.clampTier(t);
    }

    function clampScore(uint16 s) external pure returns (uint256) {
        return CreditCurve.clampScore(s);
    }

    function tierCeiling(uint8 t) external pure returns (uint256) {
        return CreditCurve.tierCeiling(t);
    }

    function unsecuredShareBps(uint8 t) external pure returns (uint256) {
        return CreditCurve.unsecuredShareBps(t);
    }

    function trustLtvBps(uint8 t) external pure returns (uint256) {
        return CreditCurve.trustLtvBps(t);
    }

    function scoreFactorBps(uint16 s) external pure returns (uint256) {
        return CreditCurve.scoreFactorBps(s);
    }

    function trustScoreBps(uint8 t, uint16 s) external pure returns (uint256) {
        return CreditCurve.trustScoreBps(t, s);
    }

    function reputationLine(uint8 t, uint16 s) external pure returns (uint256) {
        return CreditCurve.reputationLine(t, s);
    }

    function collateralLine(uint8 t, uint256 c) external pure returns (uint256) {
        return CreditCurve.collateralLine(t, c);
    }

    function maxBorrow(uint8 t, uint16 s, uint256 c) external pure returns (uint256) {
        return CreditCurve.maxBorrow(t, s, c);
    }

    function utilizationPremiumBps(uint256 u) external pure returns (uint256) {
        return CreditCurve.utilizationPremiumBps(u);
    }

    function trustDiscountBps(uint8 t, uint16 s) external pure returns (uint256) {
        return CreditCurve.trustDiscountBps(t, s);
    }

    function borrowRateBps(uint8 t, uint16 s, uint256 u) external pure returns (uint256) {
        return CreditCurve.borrowRateBps(t, s, u);
    }

    function accruedInterest(uint256 p, uint256 r, uint256 e) external pure returns (uint256) {
        return CreditCurve.accruedInterest(p, r, e);
    }
}
