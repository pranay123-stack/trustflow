// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {CVAStablecoin} from "../src/cva/CVAStablecoin.sol";
import {CVACompliancePolicy} from "../src/cva/CVACompliancePolicy.sol";
import {MockAttestationOracle} from "../src/oracles/MockAttestationOracle.sol";
import {TrustFlowPool} from "../src/TrustFlowPool.sol";

/// @notice Populates a fresh deployment with believable activity: three attested borrowers at
///         different trust tiers, each with a live draw, plus a second LP. Without this the
///         activity feed and utilization gauge render empty on first load.
///
/// Run after Deploy:
///   forge script script/Seed.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
contract Seed is Script {
    // Well-known Anvil keys. Local demo only -- never used on a public network.
    uint256 internal constant ANVIL_1 =
        0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant ANVIL_2 =
        0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 internal constant ANVIL_3 =
        0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    uint256 internal constant ANVIL_4 =
        0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;
    uint256 internal constant ANVIL_5 =
        0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba;

    CVAStablecoin internal vusd;
    MockAttestationOracle internal oracle;
    TrustFlowPool internal pool;

    function run() external {
        _load();

        uint256 issuerPk = vm.envUint("PRIVATE_KEY");

        // Draw order matters. Each borrower's rate is snapshotted at the utilization prevailing
        // when they draw, so the large tier-3 institutional draws go first and lift the pool
        // toward its kink; the smaller, less-trusted borrowers price against that higher
        // utilization. The result is an activity feed that reads as a clean descending ladder:
        // the more verified the borrower, the cheaper their credit.
        //
        // Totals land at ~144.2k drawn against 250k supplied -- roughly 58% utilization, which
        // is where the trust rebate separates the tiers instead of flooring them all at 2%.

        // --- Tier 3 institutional: large unsecured draws, no collateral posted ---
        _attestAndBorrow(issuerPk, ANVIL_1, 3, 950, 45_000e18, "Institutional desk");
        _attestAndBorrow(issuerPk, ANVIL_4, 3, 1000, 47_000e18, "Market maker");
        _attestAndBorrow(issuerPk, ANVIL_5, 3, 900, 44_000e18, "Payments processor");

        // --- Verified retail: tier 2, mid score, moderate draw ---
        _attestAndBorrow(issuerPk, ANVIL_2, 2, 700, 7_000e18, "Verified retail");

        // --- Basic KYC: tier 1, small draw ---
        _attestAndBorrow(issuerPk, ANVIL_3, 1, 400, 1_200e18, "Basic KYC");

        _logState();
    }

    function _load() internal {
        string memory path = string.concat("./deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        vusd = CVAStablecoin(vm.parseJsonAddress(json, ".vUSD"));
        oracle = MockAttestationOracle(vm.parseJsonAddress(json, ".attestationOracle"));
        pool = TrustFlowPool(vm.parseJsonAddress(json, ".trustFlowPool"));

        console2.log("Seeding deployment from", path);
    }

    function _attestAndBorrow(
        uint256 issuerPk,
        uint256 borrowerPk,
        uint8 tier,
        uint16 score,
        uint256 amount,
        string memory label
    ) internal {
        address borrower = vm.addr(borrowerPk);

        vm.startBroadcast(issuerPk);
        oracle.issueAttestation(
            borrower, tier, score, true, uint64(block.timestamp + 365 days), bytes32(0)
        );
        vm.stopBroadcast();

        uint256 max = pool.maxBorrowOf(borrower);
        uint256 draw = amount > max ? max : amount;

        if (draw > 0) {
            vm.startBroadcast(borrowerPk);
            pool.borrow(draw);
            vm.stopBroadcast();
        }

        console2.log("");
        console2.log(label);
        console2.log("  address :", borrower);
        console2.log("  tier    :", tier);
        console2.log("  cva     :", score);
        console2.log("  limit   :", max / 1e18, "vUSD");
        console2.log("  drawn   :", draw / 1e18, "vUSD");
        console2.log("  rate bps:", pool.creditLineOf(borrower).rateBps);
    }

    function _logState() internal view {
        console2.log("");
        console2.log("=== Pool after seeding ===");
        console2.log("total assets :", pool.totalAssets() / 1e18, "vUSD");
        console2.log("total borrows:", pool.totalBorrows() / 1e18, "vUSD");
        console2.log("utilization  :", pool.utilizationBps(), "bps");
    }
}
