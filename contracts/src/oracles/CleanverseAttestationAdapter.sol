// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAttestationOracle, Attestation} from "../interfaces/IAttestationOracle.sol";

/// @title CleanverseAttestationAdapter
/// @notice Production-shaped `IAttestationOracle` backed by signed CVI-CVA results from the
///         real Cleanverse attestation service.
///
/// @dev THIS IS THE DROP-IN REPLACEMENT FOR `MockAttestationOracle`.
///
///      Integration flow, end to end:
///
///        1. A user completes verification in Cleanverse. The service computes their CVI tier
///           and CVI score.
///        2. The Cleanverse backend signs an EIP-712 `CleanverseAttestation` payload with
///           `attestationSigner`. No gas, no on-chain write by Cleanverse.
///        3. The user (or a relayer) calls `submitAttestation` with that signature. The
///           adapter verifies the signature and stores the record.
///        4. `TrustFlowPool` reads it through the identical `IAttestationOracle` interface it
///           already uses for the mock. Zero pool changes.
///
///      Going live is one transaction: `TrustFlowPool.setOracle(address(thisAdapter))`.
///
///      Security properties enforced here:
///        * Signature must come from the registered Cleanverse signer.
///        * Each attestation carries a nonce, consumed on use -- no replay.
///        * `issuedAt` must strictly increase per subject -- a user cannot resurrect an older,
///          more favourable attestation after being downgraded.
///        * Records carry a hard expiry; a stale record fails `isVerified` and therefore fails
///          the pool's borrow gate automatically.
contract CleanverseAttestationAdapter is IAttestationOracle, EIP712, Ownable {
    using ECDSA for bytes32;

    bytes32 public constant ATTESTATION_TYPEHASH = keccak256(
        "CleanverseAttestation(address subject,uint8 cviTier,uint16 cviScore,bool isCompliant,uint64 issuedAt,uint64 expiresAt,bytes32 credentialRef,uint256 nonce)"
    );

    uint16 internal constant MAX_CVI_SCORE = 1000;
    uint8 internal constant MAX_CVI_TIER = 3;

    /// @notice Public key of the Cleanverse attestation service.
    address public attestationSigner;

    /// @notice Reject attestations claiming to be issued further than this into the future,
    ///         guarding against clock skew or a mis-signed far-future record.
    uint64 public constant MAX_FUTURE_SKEW = 15 minutes;

    mapping(address => Attestation) internal _records;
    mapping(uint256 => bool) public nonceUsed;

    error InvalidSignature();
    error NonceAlreadyUsed(uint256 nonce);
    error StaleAttestation(uint64 issuedAt, uint64 storedIssuedAt);
    error AttestationExpired(uint64 expiresAt);
    error IssuedInFuture(uint64 issuedAt);
    error InvalidTier(uint8 tier);
    error InvalidScore(uint16 score);
    error ZeroAddress();

    event AttestationSubmitted(
        address indexed subject,
        uint8 cviTier,
        uint16 cviScore,
        bool isCompliant,
        uint64 issuedAt,
        uint64 expiresAt,
        uint256 nonce
    );
    event AttestationSignerUpdated(address indexed previous, address indexed current);

    constructor(address signer_, address initialOwner)
        EIP712("Cleanverse Attestation", "1")
        Ownable(initialOwner)
    {
        if (signer_ == address(0)) revert ZeroAddress();
        attestationSigner = signer_;
        emit AttestationSignerUpdated(address(0), signer_);
    }

    // ---------------------------------------------------------------------
    // IAttestationOracle
    // ---------------------------------------------------------------------

    /// @inheritdoc IAttestationOracle
    function getAttestation(address subject) external view returns (Attestation memory) {
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
        return "cleanverse-cvi-cva-v1";
    }

    // ---------------------------------------------------------------------
    // Submission
    // ---------------------------------------------------------------------

    /// @notice Publish a Cleanverse-signed attestation on-chain.
    /// @dev Callable by anyone holding a valid signature -- typically the subject themselves,
    ///      so the user bears the gas and Cleanverse never needs a funded hot wallet.
    function submitAttestation(
        address subject,
        uint8 cviTier,
        uint16 cviScore,
        bool isCompliant,
        uint64 issuedAt,
        uint64 expiresAt,
        bytes32 credentialRef,
        uint256 nonce,
        bytes calldata signature
    ) external {
        if (cviTier > MAX_CVI_TIER) revert InvalidTier(cviTier);
        if (cviScore > MAX_CVI_SCORE) revert InvalidScore(cviScore);
        if (nonceUsed[nonce]) revert NonceAlreadyUsed(nonce);
        if (issuedAt > block.timestamp + MAX_FUTURE_SKEW) revert IssuedInFuture(issuedAt);
        if (expiresAt != 0 && block.timestamp >= expiresAt) revert AttestationExpired(expiresAt);

        // Monotonicity: a downgraded user cannot replay their old, better attestation.
        uint64 storedIssuedAt = _records[subject].issuedAt;
        if (issuedAt <= storedIssuedAt) revert StaleAttestation(issuedAt, storedIssuedAt);

        bytes32 structHash = keccak256(
            abi.encode(
                ATTESTATION_TYPEHASH,
                subject,
                cviTier,
                cviScore,
                isCompliant,
                issuedAt,
                expiresAt,
                credentialRef,
                nonce
            )
        );
        address recovered = _hashTypedDataV4(structHash).recover(signature);
        if (recovered != attestationSigner) revert InvalidSignature();

        nonceUsed[nonce] = true;
        _records[subject] = Attestation({
            cviTier: cviTier,
            cviScore: cviScore,
            isCompliant: isCompliant,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            credentialRef: credentialRef
        });

        emit AttestationSubmitted(
            subject, cviTier, cviScore, isCompliant, issuedAt, expiresAt, nonce
        );
    }

    /// @notice Rotate the Cleanverse signing key.
    function setAttestationSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        emit AttestationSignerUpdated(attestationSigner, newSigner);
        attestationSigner = newSigner;
    }

    /// @notice EIP-712 domain separator, exposed so the Cleanverse backend can build payloads.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
