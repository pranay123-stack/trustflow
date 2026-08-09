// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {CVAStablecoin} from "../src/cva/CVAStablecoin.sol";
import {CVACompliancePolicy} from "../src/cva/CVACompliancePolicy.sol";
import {MockAttestationOracle} from "../src/oracles/MockAttestationOracle.sol";
import {TrustFlowPool} from "../src/TrustFlowPool.sol";
import {IAttestationOracle} from "../src/interfaces/IAttestationOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Shared fixture: a funded pool, a mock oracle, and named actors.
abstract contract BaseTest is Test {
    CVAStablecoin internal vusd;
    CVACompliancePolicy internal policy;
    MockAttestationOracle internal oracle;
    TrustFlowPool internal pool;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice"); // LP
    address internal bob = makeAddr("bob"); // borrower
    address internal carol = makeAddr("carol"); // second borrower
    address internal liquidator = makeAddr("liquidator");

    uint256 internal constant BPS = 10_000;

    function setUp() public virtual {
        vm.startPrank(admin);
        // CVI first -- the CVA policy reads it, and the token reads the policy.
        oracle = new MockAttestationOracle(admin);
        policy = new CVACompliancePolicy(IAttestationOracle(address(oracle)), admin);
        vusd = new CVAStablecoin(policy, IAttestationOracle(address(oracle)), admin);
        pool = new TrustFlowPool(IERC20(address(vusd)), IAttestationOracle(address(oracle)), admin);

        // The pool custodies value for many users, so it has no meaningful CVI of its own.
        // Identity for its flows is enforced by the borrow gate, not by the transfer policy.
        policy.setExempt(address(pool), true);

        vusd.issue(alice, 1_000_000e18, "test-settlement", bytes32(uint256(0x5EED)));
        vusd.issue(bob, 1_000_000e18, "test-settlement", bytes32(uint256(0x5EED)));
        vusd.issue(carol, 1_000_000e18, "test-settlement", bytes32(uint256(0x5EED)));
        vusd.issue(liquidator, 1_000_000e18, "test-settlement", bytes32(uint256(0x5EED)));
        vm.stopPrank();

        _approveAll(alice);
        _approveAll(bob);
        _approveAll(carol);
        _approveAll(liquidator);
    }

    function _approveAll(address who) internal {
        vm.prank(who);
        vusd.approve(address(pool), type(uint256).max);
    }

    /// @dev Seed the pool with LP liquidity from alice.
    function _fundPool(uint256 amount) internal {
        vm.prank(alice);
        pool.deposit(amount, alice);
    }

    /// @dev Write an attestation straight through the issuer path.
    function _attest(address who, uint8 tier, uint16 score, bool compliant) internal {
        vm.prank(admin);
        oracle.issueAttestation(
            who, tier, score, compliant, uint64(block.timestamp + 365 days), bytes32(0)
        );
    }

    /// @dev Give `who` a maxed-out identity: tier 3, CVA 1000, compliant.
    function _attestMax(address who) internal {
        _attest(who, 3, 1000, true);
    }
}
