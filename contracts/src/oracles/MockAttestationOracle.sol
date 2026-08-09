// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAttestationOracle, Attestation} from "../interfaces/IAttestationOracle.sol";

/// @title MockAttestationOracle
/// @notice Stand-in for the live Cleanverse CVI-CVA attestation feed.
/// @dev Two distinct surfaces, on purpose:
///
///      1. THE PRODUCTION SHAPE -- `issueAttestation` is restricted to authorised issuers,
///         exactly as a real attestation authority would be. This is the code path the live
///         Cleanverse adapter replaces.
///
///      2. THE DEMO SHAPE -- `attest(CredentialType)` is permissionless so anyone can walk
///         the full trust ladder in a live demo without us holding an issuer key. The five
///         credentials sum to precisely CVA 1000 / CVI tier 3, so collecting all of them
///         lands the wallet on a perfect 10_000 trust score.
///
///      The demo surface is guarded by `demoMode`, which the owner can switch OFF permanently.
///      A production deployment ships with it off and only the issuer path live.
contract MockAttestationOracle is IAttestationOracle, Ownable {
    // ---------------------------------------------------------------------
    // Credential catalogue
    // ---------------------------------------------------------------------

    /// @notice The credential types a subject can hold. Each maps to a real-world check.
    enum CredentialType {
        KycBasic, //           government ID + liveness       -> tier >= 1, +200 CVA
        ProofOfAddress, //     utility bill / bank statement   -> tier >= 1, +150 CVA
        SanctionsScreen, //    OFAC/EU/UN list screening       -> tier >= 0, +150 CVA
        AccreditedInvestor, // income / net-worth verification -> tier >= 2, +250 CVA
        InstitutionalKyb //    entity formation + UBO chain    -> tier >= 3, +250 CVA
    }

    uint8 internal constant CREDENTIAL_COUNT = 5;
    uint16 internal constant MAX_CVI_SCORE = 1000;
    uint8 internal constant MAX_CVI_TIER = 3;

    /// @notice Minimum CVI tier each credential unlocks.
    function credentialMinTier(CredentialType c) public pure returns (uint8) {
        if (c == CredentialType.KycBasic) return 1;
        if (c == CredentialType.ProofOfAddress) return 1;
        if (c == CredentialType.SanctionsScreen) return 0;
        if (c == CredentialType.AccreditedInvestor) return 2;
        return 3; // InstitutionalKyb
    }

    /// @notice CVA points each credential contributes. Sums to exactly 1000 across all five.
    function credentialScoreDelta(CredentialType c) public pure returns (uint16) {
        if (c == CredentialType.KycBasic) return 200;
        if (c == CredentialType.ProofOfAddress) return 150;
        if (c == CredentialType.SanctionsScreen) return 150;
        if (c == CredentialType.AccreditedInvestor) return 250;
        return 250; // InstitutionalKyb
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    mapping(address => Attestation) internal _records;

    /// @notice Bitmask of credentials held, indexed by CredentialType. Prevents double-counting.
    mapping(address => uint8) public credentialMask;

    /// @notice Addresses permitted to issue attestations through the production path.
    mapping(address => bool) public isIssuer;

    /// @notice When true, the permissionless demo path is live.
    bool public demoMode = true;

    /// @notice Default validity window applied to demo-issued attestations.
    uint64 public constant DEMO_VALIDITY = 365 days;

    // ---------------------------------------------------------------------
    // Errors + events
    // ---------------------------------------------------------------------

    error NotIssuer(address caller);
    error DemoModeDisabled();
    error CredentialAlreadyHeld(address subject, CredentialType credential);
    error InvalidTier(uint8 tier);
    error InvalidScore(uint16 score);

    event AttestationIssued(
        address indexed subject,
        uint8 cviTier,
        uint16 cviScore,
        bool isCompliant,
        uint64 expiresAt,
        bytes32 credentialRef
    );
    event CredentialAdded(
        address indexed subject, CredentialType indexed credential, uint8 newTier, uint16 newScore
    );
    event ComplianceUpdated(address indexed subject, bool isCompliant, string reason);
    event AttestationRevoked(address indexed subject);
    event IssuerUpdated(address indexed issuer, bool allowed);
    event DemoModeDisabledForever();

    constructor(address initialOwner) Ownable(initialOwner) {
        isIssuer[initialOwner] = true;
        emit IssuerUpdated(initialOwner, true);
    }

    modifier onlyIssuer() {
        if (!isIssuer[msg.sender]) revert NotIssuer(msg.sender);
        _;
    }

    // ---------------------------------------------------------------------
    // IAttestationOracle
    // ---------------------------------------------------------------------

    /// @inheritdoc IAttestationOracle
    function getAttestation(address subject) external view returns (Attestation memory) {
        // Unknown subjects return a zeroed record rather than reverting: an unverified wallet
        // must degrade to the collateral-only path, never brick the pool.
        return _records[subject];
    }

    /// @inheritdoc IAttestationOracle
    function isVerified(address subject) public view returns (bool) {
        Attestation memory a = _records[subject];
        if (!a.isCompliant) return false;
        if (a.expiresAt != 0 && block.timestamp >= a.expiresAt) return false;
        return true;
    }

    /// @inheritdoc IAttestationOracle
    function sourceId() external pure returns (string memory) {
        return "trustflow-mock-oracle-v1";
    }

    /// @notice True once the record has aged past its validity window.
    function isExpired(address subject) external view returns (bool) {
        Attestation memory a = _records[subject];
        return a.expiresAt != 0 && block.timestamp >= a.expiresAt;
    }

    /// @notice Which credentials `subject` currently holds, as a fixed-length flag array.
    function heldCredentials(address subject) external view returns (bool[5] memory held) {
        uint8 mask = credentialMask[subject];
        for (uint8 i = 0; i < CREDENTIAL_COUNT; i++) {
            held[i] = mask & (uint8(1) << i) != 0;
        }
    }

    // ---------------------------------------------------------------------
    // Production path -- what the live Cleanverse adapter replaces
    // ---------------------------------------------------------------------

    /// @notice Write a full attestation record. Mirrors an authority pushing a signed CVI-CVA
    ///         result on-chain.
    function issueAttestation(
        address subject,
        uint8 cviTier,
        uint16 cviScore,
        bool compliant,
        uint64 expiresAt,
        bytes32 credentialRef
    ) external onlyIssuer {
        if (cviTier > MAX_CVI_TIER) revert InvalidTier(cviTier);
        if (cviScore > MAX_CVI_SCORE) revert InvalidScore(cviScore);

        _records[subject] = Attestation({
            cviTier: cviTier,
            cviScore: cviScore,
            isCompliant: compliant,
            issuedAt: uint64(block.timestamp),
            expiresAt: expiresAt,
            credentialRef: credentialRef
        });

        emit AttestationIssued(subject, cviTier, cviScore, compliant, expiresAt, credentialRef);
    }

    /// @notice Flip the hard compliance gate, e.g. on a new sanctions hit.
    /// @dev This is the lever that makes the demo's "compliance revoked" moment real: existing
    ///      debt stays repayable, but no new credit can be drawn.
    function setCompliance(address subject, bool compliant, string calldata reason)
        external
        onlyIssuer
    {
        _records[subject].isCompliant = compliant;
        emit ComplianceUpdated(subject, compliant, reason);
    }

    /// @notice Wipe a subject's record entirely.
    function revokeAttestation(address subject) external onlyIssuer {
        delete _records[subject];
        delete credentialMask[subject];
        emit AttestationRevoked(subject);
    }

    function setIssuer(address issuer, bool allowed) external onlyOwner {
        isIssuer[issuer] = allowed;
        emit IssuerUpdated(issuer, allowed);
    }

    /// @notice Permanently close the permissionless demo path. One-way.
    function disableDemoMode() external onlyOwner {
        demoMode = false;
        emit DemoModeDisabledForever();
    }

    // ---------------------------------------------------------------------
    // Demo path -- drives the "Add Attestation" buttons in the UI
    // ---------------------------------------------------------------------

    /// @notice Claim a credential for `msg.sender`, raising their CVI tier and CVI score.
    /// @dev Permissionless by design so a live demo needs no issuer key. Each credential is
    ///      one-shot per address. Holding a credential implies a passed compliance review, so
    ///      the first credential also opens the compliance gate.
    function attest(CredentialType credential) external {
        _attest(msg.sender, credential);
    }

    /// @notice Same as `attest`, but an issuer may grant on someone's behalf (seeding demos).
    function attestFor(address subject, CredentialType credential) external onlyIssuer {
        _attest(subject, credential);
    }

    function _attest(address subject, CredentialType credential) internal {
        if (!demoMode && !isIssuer[msg.sender]) revert DemoModeDisabled();

        uint8 bit = uint8(1) << uint8(credential);
        if (credentialMask[subject] & bit != 0) {
            revert CredentialAlreadyHeld(subject, credential);
        }
        credentialMask[subject] |= bit;

        Attestation storage a = _records[subject];

        uint8 minTier = credentialMinTier(credential);
        if (a.cviTier < minTier) a.cviTier = minTier;

        uint16 newScore = a.cviScore + credentialScoreDelta(credential);
        a.cviScore = newScore > MAX_CVI_SCORE ? MAX_CVI_SCORE : newScore;

        a.isCompliant = true;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp) + DEMO_VALIDITY;
        // Deterministic stand-in for the off-chain credential bundle digest.
        a.credentialRef = keccak256(abi.encodePacked(subject, uint8(credential), block.timestamp));

        emit CredentialAdded(subject, credential, a.cviTier, a.cviScore);
        emit AttestationIssued(
            subject, a.cviTier, a.cviScore, true, a.expiresAt, a.credentialRef
        );
    }

    /// @notice Reset your OWN wallet so the demo can be run again from zero.
    /// @dev Scoped to `msg.sender` deliberately -- a permissionless "reset anyone" would let a
    ///      griefer wipe a live borrower's attestations and force them into liquidation.
    function resetForDemo() external {
        if (!demoMode) revert DemoModeDisabled();
        delete _records[msg.sender];
        delete credentialMask[msg.sender];
        emit AttestationRevoked(msg.sender);
    }
}
