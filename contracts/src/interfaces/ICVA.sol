// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Provenance record for a minted lot of a CVA asset -- its "clean origination".
/// @dev Cleanverse defines CVA (Cleanverse Verified Assets) as "a digital representation of
///      verified stablecoins and assets, with clean origination, programmable compliance rules,
///      full traceability". This struct is the on-chain form of the first of those three.
struct Origination {
    /// @dev The authorised issuer that minted this lot.
    address issuer;
    /// @dev Unix seconds the lot was issued.
    uint64 issuedAt;
    /// @dev Units minted in this lot.
    uint256 amount;
    /// @dev What backed it, e.g. "bank-settlement", "verified-treasury", "merchant-receipt".
    string sourceKind;
    /// @dev Digest of the off-chain settlement proof (bank confirmation, custody attestation).
    ///      Lets an auditor tie these on-chain units back to a specific real-world settlement
    ///      without putting any of that document on-chain.
    bytes32 sourceRef;
}

/// @notice Programmable compliance rules evaluated on every CVA value transfer.
/// @dev This is the "programmable compliance rules" half of CVA. Keeping it behind an interface
///      means the policy can be replaced -- per jurisdiction, per asset, per regulatory regime --
///      without redeploying the token or anything that holds it.
interface ICVACompliancePolicy {
    /// @notice May `amount` move from `from` to `to`?
    /// @dev MUST be view and MUST NOT revert -- callers rely on the reason string to explain a
    ///      refusal to the user rather than surfacing an opaque failure.
    /// @return allowed True when the transfer satisfies every active rule.
    /// @return reason  Empty when allowed; a short human-readable cause otherwise.
    function checkTransfer(address from, address to, uint256 amount)
        external
        view
        returns (bool allowed, string memory reason);

    /// @notice True when this transfer must carry Travel Rule counterparty data.
    function requiresTravelRule(address from, address to, uint256 amount)
        external
        view
        returns (bool);

    /// @notice Human-readable identifier of the active policy, surfaced in the UI.
    function policyId() external view returns (string memory);
}

/// @notice A Cleanverse Verified Asset: an ERC20 whose movement is governed by a compliance
///         policy and whose supply carries auditable origination.
interface ICVAAsset {
    /// @notice Origination record for a given mint lot.
    function originationOf(uint256 lotId) external view returns (Origination memory);

    /// @notice Number of mint lots issued so far.
    function lotCount() external view returns (uint256);

    /// @notice The policy currently governing transfers of this asset.
    function compliancePolicy() external view returns (ICVACompliancePolicy);

    /// @notice Non-reverting preflight so a UI can explain a refusal before asking for a signature.
    function canTransfer(address from, address to, uint256 amount)
        external
        view
        returns (bool allowed, string memory reason);

    /// @notice Emitted on every transfer -- the "full traceability" half of CVA.
    /// @dev Carries both counterparties' CVI tiers alongside the movement, so the identity and
    ///      asset primitives are correlated in a single log line. An indexer can reconstruct the
    ///      complete flow of verified value without touching any PII.
    event VerifiedValueTransferred(
        address indexed from,
        address indexed to,
        uint256 amount,
        uint8 fromCviTier,
        uint8 toCviTier,
        bool travelRuleApplied
    );

    /// @notice Emitted when a new lot is minted against a real-world settlement.
    event OriginationRecorded(
        uint256 indexed lotId,
        address indexed issuer,
        address indexed to,
        uint256 amount,
        string sourceKind,
        bytes32 sourceRef
    );
}
