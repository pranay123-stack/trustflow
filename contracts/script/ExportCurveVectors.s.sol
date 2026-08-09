// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {CreditCurve} from "../src/libraries/CreditCurve.sol";

/// @notice Exports a grid of credit-curve results to `fixtures/credit-curve-vectors.json`.
///
/// @dev The frontend reimplements this curve in TypeScript so the dial can respond without an
///      RPC round-trip. That duplication is a correctness risk: if the two ever disagree, the
///      UI quotes a limit the chain will reject. These vectors are the contract between them --
///      `web/scripts/checkParity.mjs` replays every one of them through the TS mirror and fails
///      loudly on any mismatch.
///
///      Values are written as decimal STRINGS, not JSON numbers: a 50_000e18 limit exceeds
///      JavaScript's safe integer range and would silently lose precision otherwise.
///
///      Accumulators live in storage rather than memory purely to stay under the EVM stack
///      limit -- this is a script, so the gas cost is irrelevant.
///
///      Regenerate with:  forge script script/ExportCurveVectors.s.sol
contract ExportCurveVectors is Script {
    string[] internal bTier;
    string[] internal bScore;
    string[] internal bCollateral;
    string[] internal bMaxBorrow;
    string[] internal bReputation;
    string[] internal bCollateralLine;
    string[] internal bTrustScore;

    string[] internal rTier;
    string[] internal rScore;
    string[] internal rUtil;
    string[] internal rRate;

    function run() external {
        _buildBorrowVectors();
        _buildRateVectors();
        _write();
    }

    function _buildBorrowVectors() internal {
        uint8[4] memory tiers = [0, 1, 2, 3];
        uint16[8] memory scores = [uint16(0), 1, 250, 499, 500, 750, 999, 1000];
        uint256[4] memory collaterals = [uint256(0), 1e18, 1_000e18, 12_345e18];

        for (uint256 t; t < 4; t++) {
            for (uint256 s; s < 8; s++) {
                for (uint256 c; c < 4; c++) {
                    bTier.push(vm.toString(uint256(tiers[t])));
                    bScore.push(vm.toString(uint256(scores[s])));
                    bCollateral.push(vm.toString(collaterals[c]));
                    bMaxBorrow.push(
                        vm.toString(CreditCurve.maxBorrow(tiers[t], scores[s], collaterals[c]))
                    );
                    bReputation.push(
                        vm.toString(CreditCurve.reputationLine(tiers[t], scores[s]))
                    );
                    bCollateralLine.push(
                        vm.toString(CreditCurve.collateralLine(tiers[t], collaterals[c]))
                    );
                    bTrustScore.push(
                        vm.toString(CreditCurve.trustScoreBps(tiers[t], scores[s]))
                    );
                }
            }
        }
    }

    function _buildRateVectors() internal {
        uint8[4] memory tiers = [0, 1, 2, 3];
        uint16[8] memory scores = [uint16(0), 1, 250, 499, 500, 750, 999, 1000];
        uint256[8] memory utils = [uint256(0), 1, 4_000, 7_999, 8_000, 8_001, 9_000, 10_000];

        for (uint256 t; t < 4; t++) {
            for (uint256 s; s < 8; s++) {
                for (uint256 u; u < 8; u++) {
                    rTier.push(vm.toString(uint256(tiers[t])));
                    rScore.push(vm.toString(uint256(scores[s])));
                    rUtil.push(vm.toString(utils[u]));
                    rRate.push(
                        vm.toString(CreditCurve.borrowRateBps(tiers[t], scores[s], utils[u]))
                    );
                }
            }
        }
    }

    function _write() internal {
        string memory borrowObj = "borrow";
        vm.serializeString(borrowObj, "tier", bTier);
        vm.serializeString(borrowObj, "score", bScore);
        vm.serializeString(borrowObj, "collateral", bCollateral);
        vm.serializeString(borrowObj, "reputationLine", bReputation);
        vm.serializeString(borrowObj, "collateralLine", bCollateralLine);
        vm.serializeString(borrowObj, "trustScoreBps", bTrustScore);
        string memory borrowJson = vm.serializeString(borrowObj, "maxBorrow", bMaxBorrow);

        string memory rateObj = "rate";
        vm.serializeString(rateObj, "tier", rTier);
        vm.serializeString(rateObj, "score", rScore);
        vm.serializeString(rateObj, "utilizationBps", rUtil);
        string memory rateJson = vm.serializeString(rateObj, "borrowRateBps", rRate);

        string memory root = "root";
        vm.serializeString(root, "borrow", borrowJson);
        string memory out = vm.serializeString(root, "rate", rateJson);

        vm.writeJson(out, "./fixtures/credit-curve-vectors.json");
    }
}
