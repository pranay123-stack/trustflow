// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {CVAStablecoin} from "../src/cva/CVAStablecoin.sol";
import {CVACompliancePolicy} from "../src/cva/CVACompliancePolicy.sol";
import {MockAttestationOracle} from "../src/oracles/MockAttestationOracle.sol";
import {IAttestationOracle} from "../src/interfaces/IAttestationOracle.sol";
import {ICVAAsset, ICVACompliancePolicy, Origination} from "../src/interfaces/ICVA.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Coverage for the CVA (Cleanverse Verified Assets) primitive: clean origination,
///         programmable compliance rules, and full traceability -- plus the interlock with CVI.
contract CVATest is Test {
    CVAStablecoin internal vusd;
    CVACompliancePolicy internal policy;
    MockAttestationOracle internal cvi;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal poolLike = makeAddr("poolLike");

    bytes32 internal constant REF = keccak256("bank-settlement-0001");

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.startPrank(admin);
        cvi = new MockAttestationOracle(admin);
        policy = new CVACompliancePolicy(IAttestationOracle(address(cvi)), admin);
        vusd = new CVAStablecoin(policy, IAttestationOracle(address(cvi)), admin);
        vm.stopPrank();
    }

    function _verify(address who, uint8 tier, uint16 score) internal {
        vm.prank(admin);
        cvi.issueAttestation(who, tier, score, true, uint64(block.timestamp + 365 days), bytes32(0));
    }

    function _issue(address to, uint256 amount) internal {
        vm.prank(admin);
        vusd.issue(to, amount, "bank-settlement", REF);
    }

    // =====================================================================
    // Clean origination
    // =====================================================================

    function test_issue_recordsOrigination() public {
        vm.prank(admin);
        uint256 lotId = vusd.issue(alice, 10_000e18, "bank-settlement", REF);

        Origination memory o = vusd.originationOf(lotId);
        assertEq(o.issuer, admin);
        assertEq(o.amount, 10_000e18);
        assertEq(o.sourceKind, "bank-settlement");
        assertEq(o.sourceRef, REF);
        assertEq(o.issuedAt, uint64(block.timestamp));
        assertEq(vusd.balanceOf(alice), 10_000e18);
    }

    /// @dev The core claim of "clean origination": supply cannot exist without provenance.
    function test_issue_revertsWithoutSettlementProof() public {
        vm.startPrank(admin);
        vm.expectRevert(CVAStablecoin.MissingOriginationProof.selector);
        vusd.issue(alice, 1e18, "bank-settlement", bytes32(0));

        vm.expectRevert(CVAStablecoin.MissingOriginationProof.selector);
        vusd.issue(alice, 1e18, "", REF);
        vm.stopPrank();
    }

    function test_issue_onlyIssuer() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CVAStablecoin.NotIssuer.selector, alice));
        vusd.issue(alice, 1e18, "bank-settlement", REF);
    }

    function test_lotsAreSequentialAndIndependent() public {
        _issue(alice, 1_000e18);
        _issue(bob, 2_500e18);
        assertEq(vusd.lotCount(), 2);
        assertEq(vusd.originationOf(1).amount, 1_000e18);
        assertEq(vusd.originationOf(2).amount, 2_500e18);
    }

    function test_faucetSupplyAlsoCarriesProvenance() public {
        vm.prank(alice);
        vusd.faucet();

        Origination memory o = vusd.originationOf(vusd.lotCount());
        assertEq(o.sourceKind, "testnet-faucet", "even demo supply is traceable");
        assertTrue(o.sourceRef != bytes32(0));
    }

    // =====================================================================
    // Programmable compliance rules
    // =====================================================================

    function test_smallPeerTransferIsAllowedWithoutCvi() public {
        _issue(alice, 10_000e18);
        vm.prank(alice);
        vusd.transfer(bob, 999e18); // below the 1_000 Travel Rule threshold
        assertEq(vusd.balanceOf(bob), 999e18);
    }

    /// @dev THE INTERLOCK: a CVA transfer above the Travel Rule threshold is refused because of
    ///      a CVI fact about the counterparties. Neither primitive can express this alone.
    function test_travelRuleTransferRequiresCviOnBothSides() public {
        _issue(alice, 10_000e18);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CVAStablecoin.TransferBlocked.selector,
                alice,
                bob,
                "sender lacks a live CVI for a Travel Rule transfer"
            )
        );
        vusd.transfer(bob, 1_000e18);

        _verify(alice, 2, 700);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CVAStablecoin.TransferBlocked.selector,
                alice,
                bob,
                "recipient lacks a live CVI for a Travel Rule transfer"
            )
        );
        vusd.transfer(bob, 1_000e18);

        _verify(bob, 1, 200);
        vm.prank(alice);
        vusd.transfer(bob, 1_000e18);
        assertEq(vusd.balanceOf(bob), 1_000e18, "allowed once both hold a live CVI");
    }

    function test_revokedCviBlocksTravelRuleTransfers() public {
        _issue(alice, 10_000e18);
        _verify(alice, 3, 1000);
        _verify(bob, 3, 1000);

        vm.prank(alice);
        vusd.transfer(bob, 2_000e18);

        vm.prank(admin);
        cvi.setCompliance(bob, false, "sanctions hit");

        vm.prank(alice);
        vm.expectRevert();
        vusd.transfer(bob, 2_000e18);
    }

    function test_sanctionedAddressIsBlockedInBothDirections() public {
        _issue(alice, 10_000e18);
        _issue(bob, 10_000e18);

        vm.prank(admin);
        policy.setBlocked(bob, true, "OFAC SDN");

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CVAStablecoin.TransferBlocked.selector, alice, bob, "recipient is sanctioned"
            )
        );
        vusd.transfer(bob, 1e18);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                CVAStablecoin.TransferBlocked.selector, bob, alice, "sender is sanctioned"
            )
        );
        vusd.transfer(alice, 1e18);
    }

    /// @dev Sanctions outrank everything, including a perfect CVI.
    function test_sanctionsOverrideEvenTier3Identity() public {
        _issue(alice, 10_000e18);
        _verify(alice, 3, 1000);
        _verify(bob, 3, 1000);

        vm.prank(admin);
        policy.setBlocked(bob, true, "OFAC SDN");

        vm.prank(alice);
        vm.expectRevert();
        vusd.transfer(bob, 1e18);
    }

    function test_exemptProtocolContractsBypassTravelRule() public {
        _issue(alice, 10_000e18);
        vm.prank(admin);
        policy.setExempt(poolLike, true);

        vm.prank(alice);
        vusd.transfer(poolLike, 5_000e18);
        assertEq(vusd.balanceOf(poolLike), 5_000e18, "unverified user may still supply a pool");
    }

    function test_exemptionDoesNotOverrideSanctions() public {
        _issue(alice, 10_000e18);
        vm.startPrank(admin);
        policy.setExempt(poolLike, true);
        policy.setBlocked(alice, true, "OFAC SDN");
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert();
        vusd.transfer(poolLike, 1e18);
    }

    function test_policyIsProgrammable_thresholdAndRequirements() public {
        _issue(alice, 10_000e18);

        vm.prank(admin);
        policy.setTravelRuleThreshold(100e18);
        vm.prank(alice);
        vm.expectRevert();
        vusd.transfer(bob, 100e18);

        // A looser regime: only the sender must be verified.
        vm.startPrank(admin);
        policy.setVerificationRequirements(true, false);
        vm.stopPrank();
        _verify(alice, 1, 200);

        vm.prank(alice);
        vusd.transfer(bob, 100e18);
        assertEq(vusd.balanceOf(bob), 100e18);
    }

    function test_policyCanBeSwappedWholesale() public {
        vm.startPrank(admin);
        CVACompliancePolicy permissive =
            new CVACompliancePolicy(IAttestationOracle(address(cvi)), admin);
        permissive.setVerificationRequirements(false, false);
        vusd.setPolicy(permissive);
        vm.stopPrank();

        _issue(alice, 10_000e18);
        vm.prank(alice);
        vusd.transfer(bob, 5_000e18); // would have failed under the original policy
        assertEq(vusd.balanceOf(bob), 5_000e18);
    }

    function test_setPolicy_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vusd.setPolicy(policy);
    }

    function test_canTransfer_previewsRefusalWithoutReverting() public {
        _issue(alice, 10_000e18);
        (bool allowed, string memory reason) = vusd.canTransfer(alice, bob, 5_000e18);
        assertFalse(allowed);
        assertEq(reason, "sender lacks a live CVI for a Travel Rule transfer");

        (bool small,) = vusd.canTransfer(alice, bob, 1e18);
        assertTrue(small, "below threshold is fine");
    }

    // =====================================================================
    // Full traceability
    // =====================================================================

    function test_everyTransferEmitsTraceabilityWithBothCviTiers() public {
        _issue(alice, 10_000e18);
        _verify(alice, 3, 1000);
        _verify(bob, 1, 200);

        vm.expectEmit(true, true, false, true, address(vusd));
        emit ICVAAsset.VerifiedValueTransferred(alice, bob, 2_000e18, 3, 1, true);

        vm.prank(alice);
        vusd.transfer(bob, 2_000e18);
    }

    function test_subThresholdTransferMarksTravelRuleFalse() public {
        _issue(alice, 10_000e18);

        vm.expectEmit(true, true, false, true, address(vusd));
        emit ICVAAsset.VerifiedValueTransferred(alice, bob, 10e18, 0, 0, false);

        vm.prank(alice);
        vusd.transfer(bob, 10e18);
    }

    function test_requiresTravelRule_matchesThreshold() public view {
        assertFalse(vusd.compliancePolicy().requiresTravelRule(alice, bob, 999e18));
        assertTrue(vusd.compliancePolicy().requiresTravelRule(alice, bob, 1_000e18));
    }

    function test_policyIdIsSurfaced() public view {
        assertEq(policy.policyId(), "cva-policy-travel-rule-v1");
    }

    // =====================================================================
    // Fuzz
    // =====================================================================

    function testFuzz_sanctionedAddressCanNeverMove(uint256 amount) public {
        amount = bound(amount, 1, 10_000e18);
        _issue(alice, 10_000e18);
        _verify(alice, 3, 1000);
        _verify(bob, 3, 1000);

        vm.prank(admin);
        policy.setBlocked(bob, true, "OFAC SDN");

        (bool allowed,) = vusd.canTransfer(alice, bob, amount);
        assertFalse(allowed, "no amount, however small, reaches a sanctioned address");
    }

    function testFuzz_belowThresholdAlwaysAllowedWhenUnsanctioned(uint256 amount) public view {
        amount = bound(amount, 1, policy.travelRuleThreshold() - 1);
        (bool allowed,) = vusd.canTransfer(alice, bob, amount);
        assertTrue(allowed);
    }

    function testFuzz_issuedSupplyAlwaysMatchesLotRecord(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e18);
        vm.prank(admin);
        uint256 lotId = vusd.issue(alice, amount, "bank-settlement", REF);
        assertEq(vusd.originationOf(lotId).amount, amount);
        assertEq(vusd.totalSupply(), amount);
    }
}
