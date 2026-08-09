// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice The canonical shape of a Cleanverse Verified Identity (CVI) record as TrustFlow
///         consumes it.
///
/// @dev CVI is one of Cleanverse's two primitives -- "identity tokens bound to wallets of
///      verified users: bank-verified identity proofs, local-only PII, revocable credentials".
///      It answers WHO a counterparty is.
///
///      The other primitive, CVA (Cleanverse Verified Assets), answers WHAT is moving, and is
///      modelled separately in `src/cva/` -- it is a property of the asset, not of the person,
///      so it does not belong in this struct. TrustFlow interlocks the two: CVI decides how
///      much a wallet may borrow, CVA decides whether the value may move at all.
///
///      This is the ONLY identity struct the lending pool understands. Every source -- the
///      local mock, a signed-feed relayer, or the live Cleanverse API adapter -- normalises
///      into this shape. See README: "CVI · CVA Integration Points".
struct Attestation {
    /// @dev CVI verification tier, 0..3 -- the DEPTH of verification performed.
    ///      0 = unverified / pseudonymous  -> no unsecured line, collateral-only fallback
    ///      1 = basic KYC (ID + liveness)  -> small unsecured line
    ///      2 = enhanced (KYC + PoA/PoI)   -> mid unsecured line
    ///      3 = institutional KYB + UBO    -> full unsecured line
    uint8 cviTier;
    /// @dev CVI credential score, 0..1000 -- the BREADTH and freshness of the credentials the
    ///      subject holds within their tier (screening recency, jurisdiction quality, number of
    ///      corroborating proofs). Scales the borrower's line WITHIN their CVI tier band.
    uint16 cviScore;
    /// @dev Hard compliance gate. False = sanctioned, jurisdiction-blocked, or lapsed review.
    ///      TrustFlow refuses to originate new credit when this is false. Never bypassable.
    bool isCompliant;
    /// @dev Unix seconds the record was issued by the attestation authority.
    uint64 issuedAt;
    /// @dev Unix seconds the record goes stale. 0 = never expires (mock/testing only).
    uint64 expiresAt;
    /// @dev Opaque pointer to the off-chain credential bundle (IPFS CID hash, VC digest).
    ///      Lets a verifier reconstruct exactly which documents backed this attestation.
    bytes32 credentialRef;
}

/// @title IAttestationOracle
/// @notice Swappable identity feed. TrustFlowPool holds a reference to ONE of these and
///         reads it on every credit-affecting action.
/// @dev THIS IS THE INTEGRATION SEAM. To go from mock -> live Cleanverse:
///      deploy a contract implementing this interface that sources real CVI/CVA data,
///      then call `TrustFlowPool.setOracle(newOracle)`. No pool logic changes.
interface IAttestationOracle {
    /// @notice Full identity record for `subject`.
    /// @dev MUST NOT revert for unknown subjects -- return a zeroed Attestation instead,
    ///      so an unverified wallet degrades to the collateral-only path rather than
    ///      bricking the pool.
    function getAttestation(address subject) external view returns (Attestation memory);

    /// @notice True when `subject` holds a live, unexpired, compliant attestation.
    /// @dev Convenience gate. Equivalent to: a.isCompliant && !expired(a).
    function isVerified(address subject) external view returns (bool);

    /// @notice Human-readable provenance of this feed, e.g. "cleanverse-cvi-cva-v1".
    /// @dev Surfaced in the UI so a judge/auditor can see at a glance whether the
    ///      deployment is running on mock or live attestation data.
    function sourceId() external view returns (string memory);
}
