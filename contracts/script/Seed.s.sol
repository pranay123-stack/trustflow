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
    /// @dev secp256k1 curve order. Derived keys are reduced below it to stay valid.
    uint256 internal constant SECP256K1_N =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    /// @notice Deterministic demo-borrower key for slot `index`.
    ///
    /// @dev These used to be Anvil's published keys, which broke on a real network: Monad
    ///      testnet rejects transactions involving them with `reserve balance violation`,
    ///      because everyone knows those private keys and they would be a spam vector.
    ///
    ///      Deriving instead keeps the seed reproducible -- the same index always yields the
    ///      same borrower, so a demo looks identical on every run -- without colliding with
    ///      any well-known account. These addresses only ever hold a small gas stipend and
    ///      testnet vUSD, so publishing the derivation is harmless.
    function _demoKey(uint256 index) internal pure returns (uint256) {
        return (uint256(keccak256(abi.encodePacked("trustflow/demo-borrower/v1", index)))
            % (SECP256K1_N - 1)) + 1;
    }

    CVAStablecoin internal vusd;
    MockAttestationOracle internal oracle;
    TrustFlowPool internal pool;

    /// @notice Native-token top-up each demo borrower receives so they can pay for their own
    ///         `borrow()`. Ignored where accounts are already funded (e.g. Anvil).
    /// @dev Sized against a real network, not a local one. A `borrow()` costs ~324k gas on Monad
    ///      testnet, which at ~102 gwei is ~0.033 native tokens -- roughly 4x what the same call
    ///      costs locally. 0.15 leaves room for a retry and for gas-price drift.
    uint256 internal constant GAS_STIPEND = 0.15 ether;

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
        _attestAndBorrow(issuerPk, _demoKey(1), 3, 950, 45_000e18, "Institutional desk");
        _attestAndBorrow(issuerPk, _demoKey(4), 3, 1000, 47_000e18, "Market maker");
        _attestAndBorrow(issuerPk, _demoKey(5), 3, 900, 44_000e18, "Payments processor");

        // --- Verified retail: tier 2, mid score, moderate draw ---
        _attestAndBorrow(issuerPk, _demoKey(2), 2, 700, 7_000e18, "Verified retail");

        // --- Basic KYC: tier 1, small draw ---
        _attestAndBorrow(issuerPk, _demoKey(3), 1, 400, 1_200e18, "Basic KYC");

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

        // Each demo borrower signs their own `borrow()`, so they need native gas. On Anvil these
        // accounts are pre-funded and this is a no-op; on a real testnet they start empty and the
        // whole seed fails at broadcast with an opaque "failed to estimate gas". Topping them up
        // from the issuer makes the script chain-agnostic.
        if (borrower.balance < GAS_STIPEND) {
            (bool sent,) = borrower.call{value: GAS_STIPEND - borrower.balance}("");
            require(sent, "gas stipend transfer failed");
        }
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
