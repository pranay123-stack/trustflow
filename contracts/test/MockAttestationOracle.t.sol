// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockAttestationOracle} from "../src/oracles/MockAttestationOracle.sol";
import {Attestation} from "../src/interfaces/IAttestationOracle.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockAttestationOracleTest is Test {
    MockAttestationOracle internal oracle;

    address internal admin = makeAddr("admin");
    address internal user = makeAddr("user");

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.prank(admin);
        oracle = new MockAttestationOracle(admin);
    }

    // =====================================================================
    // Default state
    // =====================================================================

    function test_unknownSubjectReturnsZeroedRecord() public view {
        Attestation memory a = oracle.getAttestation(address(0xdead));
        assertEq(a.cviTier, 0);
        assertEq(a.cviScore, 0);
        assertFalse(a.isCompliant);
        assertFalse(oracle.isVerified(address(0xdead)));
    }

    function test_sourceIdIdentifiesTheMock() public view {
        assertEq(oracle.sourceId(), "trustflow-mock-oracle-v1");
    }

    // =====================================================================
    // The credential ladder that drives the demo
    // =====================================================================

    function test_credentialCatalogue_sumsToExactlyMaxScore() public view {
        uint16 total;
        for (uint8 i = 0; i < 5; i++) {
            total += oracle.credentialScoreDelta(MockAttestationOracle.CredentialType(i));
        }
        assertEq(total, 1000, "collecting all five credentials must land on exactly CVA 1000");
    }

    function test_fullLadder_reachesTier3AndPerfectScore() public {
        vm.startPrank(user);
        oracle.attest(MockAttestationOracle.CredentialType.KycBasic);
        oracle.attest(MockAttestationOracle.CredentialType.ProofOfAddress);
        oracle.attest(MockAttestationOracle.CredentialType.SanctionsScreen);
        oracle.attest(MockAttestationOracle.CredentialType.AccreditedInvestor);
        oracle.attest(MockAttestationOracle.CredentialType.InstitutionalKyb);
        vm.stopPrank();

        Attestation memory a = oracle.getAttestation(user);
        assertEq(a.cviTier, 3);
        assertEq(a.cviScore, 1000);
        assertTrue(a.isCompliant);
        assertTrue(oracle.isVerified(user));
    }

    function test_firstCredentialOpensTheComplianceGate() public {
        assertFalse(oracle.isVerified(user));

        vm.prank(user);
        oracle.attest(MockAttestationOracle.CredentialType.SanctionsScreen);

        assertTrue(oracle.isVerified(user));
        assertEq(oracle.getAttestation(user).cviScore, 150);
    }

    function test_tierOnlyRatchetsUpward() public {
        vm.startPrank(user);
        oracle.attest(MockAttestationOracle.CredentialType.InstitutionalKyb); // tier 3
        assertEq(oracle.getAttestation(user).cviTier, 3);

        oracle.attest(MockAttestationOracle.CredentialType.SanctionsScreen); // min tier 0
        assertEq(oracle.getAttestation(user).cviTier, 3, "a low-tier credential cannot demote");
        vm.stopPrank();
    }

    function test_credentialIsOneShot() public {
        vm.startPrank(user);
        oracle.attest(MockAttestationOracle.CredentialType.KycBasic);

        vm.expectRevert(
            abi.encodeWithSelector(
                MockAttestationOracle.CredentialAlreadyHeld.selector,
                user,
                MockAttestationOracle.CredentialType.KycBasic
            )
        );
        oracle.attest(MockAttestationOracle.CredentialType.KycBasic);
        vm.stopPrank();
    }

    function test_heldCredentials_reflectsTheMask() public {
        vm.startPrank(user);
        oracle.attest(MockAttestationOracle.CredentialType.KycBasic);
        oracle.attest(MockAttestationOracle.CredentialType.AccreditedInvestor);
        vm.stopPrank();

        bool[5] memory held = oracle.heldCredentials(user);
        assertTrue(held[uint8(MockAttestationOracle.CredentialType.KycBasic)]);
        assertFalse(held[uint8(MockAttestationOracle.CredentialType.ProofOfAddress)]);
        assertFalse(held[uint8(MockAttestationOracle.CredentialType.SanctionsScreen)]);
        assertTrue(held[uint8(MockAttestationOracle.CredentialType.AccreditedInvestor)]);
        assertFalse(held[uint8(MockAttestationOracle.CredentialType.InstitutionalKyb)]);
    }

    function test_scoreNeverExceedsMax() public {
        vm.startPrank(user);
        for (uint8 i = 0; i < 5; i++) {
            oracle.attest(MockAttestationOracle.CredentialType(i));
        }
        vm.stopPrank();
        assertLe(oracle.getAttestation(user).cviScore, 1000);
    }

    // =====================================================================
    // Demo mode
    // =====================================================================

    function test_disableDemoMode_closesThePermissionlessPath() public {
        vm.prank(admin);
        oracle.disableDemoMode();

        vm.prank(user);
        vm.expectRevert(MockAttestationOracle.DemoModeDisabled.selector);
        oracle.attest(MockAttestationOracle.CredentialType.KycBasic);
    }

    function test_disableDemoMode_leavesIssuerPathOpen() public {
        vm.startPrank(admin);
        oracle.disableDemoMode();
        oracle.attestFor(user, MockAttestationOracle.CredentialType.KycBasic);
        vm.stopPrank();

        assertEq(oracle.getAttestation(user).cviTier, 1);
    }

    function test_disableDemoMode_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        oracle.disableDemoMode();
    }

    function test_resetForDemo_onlyAffectsCaller() public {
        vm.prank(user);
        oracle.attest(MockAttestationOracle.CredentialType.InstitutionalKyb);
        assertEq(oracle.getAttestation(user).cviTier, 3);

        // A third party resetting themselves must not touch `user`.
        address griefer = makeAddr("griefer");
        vm.prank(griefer);
        oracle.resetForDemo();

        assertEq(oracle.getAttestation(user).cviTier, 3, "another wallet cannot wipe your identity");

        vm.prank(user);
        oracle.resetForDemo();
        assertEq(oracle.getAttestation(user).cviTier, 0);
        assertEq(oracle.credentialMask(user), 0, "mask clears so the demo can be re-run");
    }

    // =====================================================================
    // Issuer path
    // =====================================================================

    function test_issueAttestation_onlyIssuer() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(MockAttestationOracle.NotIssuer.selector, user));
        oracle.issueAttestation(user, 3, 1000, true, 0, bytes32(0));
    }

    function test_issueAttestation_validatesRanges() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(MockAttestationOracle.InvalidTier.selector, 4));
        oracle.issueAttestation(user, 4, 1000, true, 0, bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(MockAttestationOracle.InvalidScore.selector, 1001));
        oracle.issueAttestation(user, 3, 1001, true, 0, bytes32(0));
        vm.stopPrank();
    }

    function test_setIssuer_grantsAndRevokes() public {
        address newIssuer = makeAddr("newIssuer");

        vm.prank(admin);
        oracle.setIssuer(newIssuer, true);

        vm.prank(newIssuer);
        oracle.issueAttestation(user, 2, 500, true, 0, bytes32(0));
        assertEq(oracle.getAttestation(user).cviTier, 2);

        vm.prank(admin);
        oracle.setIssuer(newIssuer, false);

        vm.prank(newIssuer);
        vm.expectRevert(abi.encodeWithSelector(MockAttestationOracle.NotIssuer.selector, newIssuer));
        oracle.issueAttestation(user, 3, 1000, true, 0, bytes32(0));
    }

    function test_setCompliance_flipsTheGateWithoutTouchingScores() public {
        vm.startPrank(admin);
        oracle.issueAttestation(user, 3, 1000, true, 0, bytes32(0));
        oracle.setCompliance(user, false, "OFAC match");
        vm.stopPrank();

        Attestation memory a = oracle.getAttestation(user);
        assertEq(a.cviTier, 3, "scores survive; only the gate closes");
        assertEq(a.cviScore, 1000);
        assertFalse(oracle.isVerified(user));
    }

    function test_revokeAttestation_wipesEverything() public {
        vm.prank(user);
        oracle.attest(MockAttestationOracle.CredentialType.KycBasic);

        vm.prank(admin);
        oracle.revokeAttestation(user);

        assertEq(oracle.getAttestation(user).cviTier, 0);
        assertEq(oracle.credentialMask(user), 0);
    }

    // =====================================================================
    // Expiry
    // =====================================================================

    function test_expiry_failsVerificationOnceLapsed() public {
        vm.prank(admin);
        oracle.issueAttestation(user, 3, 1000, true, uint64(block.timestamp + 1 days), bytes32(0));

        assertTrue(oracle.isVerified(user));
        assertFalse(oracle.isExpired(user));

        vm.warp(block.timestamp + 1 days);

        assertTrue(oracle.isExpired(user));
        assertFalse(oracle.isVerified(user), "a lapsed review must fail the gate");
        assertEq(oracle.getAttestation(user).cviTier, 3, "but the record itself is still readable");
    }

    function test_zeroExpiryNeverLapses() public {
        vm.prank(admin);
        oracle.issueAttestation(user, 3, 1000, true, 0, bytes32(0));

        vm.warp(block.timestamp + 3650 days);
        assertTrue(oracle.isVerified(user));
    }

    function test_demoAttestationsCarryAOneYearWindow() public {
        vm.prank(user);
        oracle.attest(MockAttestationOracle.CredentialType.KycBasic);

        Attestation memory a = oracle.getAttestation(user);
        assertEq(a.expiresAt, uint64(block.timestamp) + 365 days);
        assertEq(a.issuedAt, uint64(block.timestamp));
        assertTrue(a.credentialRef != bytes32(0), "a credential digest is always recorded");
    }
}
