// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ICVAAsset, ICVACompliancePolicy, Origination} from "../interfaces/ICVA.sol";
import {IAttestationOracle} from "../interfaces/IAttestationOracle.sol";

/// @title CVAStablecoin (vUSD)
/// @notice A Cleanverse Verified Asset: a stablecoin with clean origination, programmable
///         compliance rules, and full traceability.
///
/// @dev Cleanverse's CVA primitive is "a digital representation of verified stablecoins and
///      assets, with clean origination, programmable compliance rules, full traceability".
///      This contract implements all three:
///
///      CLEAN ORIGINATION
///        Every mint creates a *lot* carrying the issuer, the settlement kind, and a digest of
///        the off-chain proof that backed it. Supply is never conjured: `mint` requires a
///        `sourceRef`, so each unit traces to a specific real-world settlement.
///
///      PROGRAMMABLE COMPLIANCE RULES
///        Every transfer is checked against a swappable `ICVACompliancePolicy` before it
///        settles. The policy -- not this token -- decides the rules, so the same asset can be
///        governed differently per jurisdiction without redeploying it or migrating holders.
///
///      FULL TRACEABILITY
///        Every transfer emits `VerifiedValueTransferred` carrying both counterparties' CVI
///        tiers and whether Travel Rule data applied. That single log line correlates the
///        identity primitive with the asset primitive, which is what makes an indexer able to
///        reconstruct verified value flow without ever touching PII.
///
///      A NOTE ON LOT TRACKING, stated plainly because it is a real limitation: lots record
///      the provenance of *supply*, not of individual balances. Tracking per-unit lineage
///      through every transfer would make each transfer unbounded in gas. Full per-unit
///      lineage is reconstructible off-chain from `OriginationRecorded` plus the transfer log;
///      the on-chain record is the anchor, not the whole graph.
contract CVAStablecoin is ERC20, Ownable, ICVAAsset {
    /// @notice The policy consulted on every transfer.
    ICVACompliancePolicy public policy;

    /// @notice The CVI feed, read only to annotate transfer logs with counterparty tiers.
    IAttestationOracle public cviOracle;

    /// @notice Addresses permitted to mint against a settlement proof.
    mapping(address => bool) public isIssuer;

    mapping(uint256 => Origination) internal _originations;
    uint256 public lotCount;

    /// @notice Largest amount a single faucet call hands out.
    uint256 public constant FAUCET_AMOUNT = 10_000e18;

    /// @notice Cooldown between faucet claims per address.
    uint256 public constant FAUCET_COOLDOWN = 1 hours;

    mapping(address => uint256) public lastFaucetClaim;

    error TransferBlocked(address from, address to, string reason);
    error NotIssuer(address caller);
    error ZeroAddress();
    error MissingOriginationProof();
    error FaucetCooldownActive(uint256 availableAt);

    event PolicyUpdated(address indexed previous, address indexed current, string policyId);
    event IssuerUpdated(address indexed issuer, bool allowed);
    event FaucetClaimed(address indexed to, uint256 amount);

    constructor(ICVACompliancePolicy policy_, IAttestationOracle cviOracle_, address initialOwner)
        ERC20("Verified USD", "vUSD")
        Ownable(initialOwner)
    {
        if (address(policy_) == address(0) || address(cviOracle_) == address(0)) {
            revert ZeroAddress();
        }
        policy = policy_;
        cviOracle = cviOracle_;
        isIssuer[initialOwner] = true;
        emit PolicyUpdated(address(0), address(policy_), policy_.policyId());
        emit IssuerUpdated(initialOwner, true);
    }

    // ---------------------------------------------------------------------
    // ICVAAsset
    // ---------------------------------------------------------------------

    /// @inheritdoc ICVAAsset
    function originationOf(uint256 lotId) external view returns (Origination memory) {
        return _originations[lotId];
    }

    /// @inheritdoc ICVAAsset
    function compliancePolicy() external view returns (ICVACompliancePolicy) {
        return policy;
    }

    /// @inheritdoc ICVAAsset
    function canTransfer(address from, address to, uint256 amount)
        external
        view
        returns (bool allowed, string memory reason)
    {
        return policy.checkTransfer(from, to, amount);
    }

    // ---------------------------------------------------------------------
    // Issuance against a settlement proof
    // ---------------------------------------------------------------------

    /// @notice Mint a lot of vUSD backed by a recorded real-world settlement.
    /// @param sourceKind What backed it, e.g. "bank-settlement".
    /// @param sourceRef  Digest of the off-chain proof. Required -- supply cannot be created
    ///                   without provenance, which is what "clean origination" means.
    function issue(address to, uint256 amount, string calldata sourceKind, bytes32 sourceRef)
        external
        returns (uint256 lotId)
    {
        if (!isIssuer[msg.sender]) revert NotIssuer(msg.sender);
        if (to == address(0)) revert ZeroAddress();
        if (sourceRef == bytes32(0) || bytes(sourceKind).length == 0) {
            revert MissingOriginationProof();
        }

        lotId = ++lotCount;
        _originations[lotId] = Origination({
            issuer: msg.sender,
            issuedAt: uint64(block.timestamp),
            amount: amount,
            sourceKind: sourceKind,
            sourceRef: sourceRef
        });

        _mint(to, amount);
        emit OriginationRecorded(lotId, msg.sender, to, amount, sourceKind, sourceRef);
    }

    /// @notice Testnet faucet. Issues against a synthetic origination so even demo supply
    ///         carries a provenance record rather than appearing from nowhere.
    function faucet() external {
        uint256 nextAllowed = lastFaucetClaim[msg.sender] + FAUCET_COOLDOWN;
        if (lastFaucetClaim[msg.sender] != 0 && block.timestamp < nextAllowed) {
            revert FaucetCooldownActive(nextAllowed);
        }
        lastFaucetClaim[msg.sender] = block.timestamp;

        uint256 lotId = ++lotCount;
        bytes32 ref = keccak256(abi.encodePacked("testnet-faucet", msg.sender, block.timestamp));
        _originations[lotId] = Origination({
            issuer: address(this),
            issuedAt: uint64(block.timestamp),
            amount: FAUCET_AMOUNT,
            sourceKind: "testnet-faucet",
            sourceRef: ref
        });

        _mint(msg.sender, FAUCET_AMOUNT);
        emit OriginationRecorded(lotId, address(this), msg.sender, FAUCET_AMOUNT, "testnet-faucet", ref);
        emit FaucetClaimed(msg.sender, FAUCET_AMOUNT);
    }

    // ---------------------------------------------------------------------
    // The compliance hook
    // ---------------------------------------------------------------------

    /// @dev Every balance change routes through here. Mints and burns bypass the policy -- they
    ///      are issuance and redemption, gated by `isIssuer` above rather than by transfer rules.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            (bool allowed, string memory reason) = policy.checkTransfer(from, to, value);
            if (!allowed) revert TransferBlocked(from, to, reason);

            emit VerifiedValueTransferred(
                from,
                to,
                value,
                cviOracle.getAttestation(from).cviTier,
                cviOracle.getAttestation(to).cviTier,
                policy.requiresTravelRule(from, to, value)
            );
        }
        super._update(from, to, value);
    }

    // ---------------------------------------------------------------------
    // Administration
    // ---------------------------------------------------------------------

    /// @notice Swap the rule set governing this asset. Holders and balances are untouched.
    function setPolicy(ICVACompliancePolicy newPolicy) external onlyOwner {
        if (address(newPolicy) == address(0)) revert ZeroAddress();
        emit PolicyUpdated(address(policy), address(newPolicy), newPolicy.policyId());
        policy = newPolicy;
    }

    function setCviOracle(IAttestationOracle newOracle) external onlyOwner {
        if (address(newOracle) == address(0)) revert ZeroAddress();
        cviOracle = newOracle;
    }

    function setIssuer(address issuer, bool allowed) external onlyOwner {
        isIssuer[issuer] = allowed;
        emit IssuerUpdated(issuer, allowed);
    }
}
