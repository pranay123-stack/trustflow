// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ICVACompliancePolicy} from "../interfaces/ICVA.sol";
import {IAttestationOracle, Attestation} from "../interfaces/IAttestationOracle.sol";

/// @title CVACompliancePolicy
/// @notice The programmable rule set governing movement of a CVA asset.
///
/// @dev THIS CONTRACT IS WHERE THE TWO CLEANVERSE PRIMITIVES INTERLOCK.
///
///      Cleanverse describes itself as a "compliance-native rules layer that interlocks
///      verified identity and verified assets on every value transfer". CVI answers *who*;
///      CVA answers *what may move*. This policy is the join: it reads the CVI oracle to
///      decide whether a CVA transfer is permitted.
///
///      Rules, in evaluation order:
///
///        1. SANCTIONS      -- a blocked address can neither send nor receive. Absolute, and
///                             checked first so nothing below can override it.
///        2. PROTOCOL LEGS  -- transfers where one side is an exempt protocol contract (the
///                             lending pool) are permitted. The pool custodies value for many
///                             users at once, so it has no single meaningful CVI of its own;
///                             the identity check for those flows lives in TrustFlowPool's
///                             borrow gate instead, where it can be expressed properly.
///        3. TRAVEL RULE    -- peer-to-peer transfers at or above the threshold require BOTH
///                             counterparties to hold a live CVI. This is the on-chain analogue
///                             of FATF Recommendation 16 originator/beneficiary requirements.
///        4. BASELINE       -- below the threshold, an unverified wallet may still hold and move
///                             the asset. Deliberate: a CVA stablecoin that only verified users
///                             can touch is not a payment instrument, it is a walled garden.
///                             Each rule is independently switchable for stricter regimes.
///
///      Every rule is a config flag rather than hardcoded, because a different jurisdiction
///      wants a different policy against the same asset -- which is what "programmable
///      compliance rules" has to mean if it means anything.
contract CVACompliancePolicy is ICVACompliancePolicy, Ownable {
    /// @notice The CVI feed consulted for identity checks.
    IAttestationOracle public cviOracle;

    /// @notice Transfers at or above this size require Travel Rule data from both sides.
    uint256 public travelRuleThreshold = 1_000e18;

    /// @notice When true, peer-to-peer transfers above the threshold require sender CVI.
    bool public requireVerifiedSender = true;

    /// @notice When true, peer-to-peer transfers above the threshold require recipient CVI.
    bool public requireVerifiedRecipient = true;

    /// @notice Protocol contracts that custody value on behalf of many users.
    mapping(address => bool) public isExempt;

    /// @notice Sanctioned addresses. Denied unconditionally, in both directions.
    mapping(address => bool) public isBlocked;

    error ZeroAddress();

    event CviOracleUpdated(address indexed previous, address indexed current);
    event TravelRuleThresholdUpdated(uint256 previous, uint256 current);
    event VerificationRequirementsUpdated(bool sender, bool recipient);
    event ExemptionUpdated(address indexed account, bool exempt);
    event BlocklistUpdated(address indexed account, bool blocked, string reason);

    constructor(IAttestationOracle cviOracle_, address initialOwner) Ownable(initialOwner) {
        if (address(cviOracle_) == address(0)) revert ZeroAddress();
        cviOracle = cviOracle_;
        emit CviOracleUpdated(address(0), address(cviOracle_));
    }

    // ---------------------------------------------------------------------
    // ICVACompliancePolicy
    // ---------------------------------------------------------------------

    /// @inheritdoc ICVACompliancePolicy
    function checkTransfer(address from, address to, uint256 amount)
        public
        view
        returns (bool allowed, string memory reason)
    {
        // 1. Sanctions -- absolute.
        if (isBlocked[from]) return (false, "sender is sanctioned");
        if (isBlocked[to]) return (false, "recipient is sanctioned");

        // 2. Protocol legs -- identity is enforced at the pool's borrow gate instead.
        if (isExempt[from] || isExempt[to]) return (true, "");

        // 3. Travel Rule -- peer-to-peer, at or above threshold.
        if (amount >= travelRuleThreshold) {
            if (requireVerifiedSender && !cviOracle.isVerified(from)) {
                return (false, "sender lacks a live CVI for a Travel Rule transfer");
            }
            if (requireVerifiedRecipient && !cviOracle.isVerified(to)) {
                return (false, "recipient lacks a live CVI for a Travel Rule transfer");
            }
        }

        // 4. Baseline.
        return (true, "");
    }

    /// @inheritdoc ICVACompliancePolicy
    function requiresTravelRule(address from, address to, uint256 amount)
        external
        view
        returns (bool)
    {
        if (isExempt[from] || isExempt[to]) return false;
        return amount >= travelRuleThreshold;
    }

    /// @inheritdoc ICVACompliancePolicy
    function policyId() external pure returns (string memory) {
        return "cva-policy-travel-rule-v1";
    }

    // ---------------------------------------------------------------------
    // Administration
    // ---------------------------------------------------------------------

    function setCviOracle(IAttestationOracle newOracle) external onlyOwner {
        if (address(newOracle) == address(0)) revert ZeroAddress();
        emit CviOracleUpdated(address(cviOracle), address(newOracle));
        cviOracle = newOracle;
    }

    function setTravelRuleThreshold(uint256 newThreshold) external onlyOwner {
        emit TravelRuleThresholdUpdated(travelRuleThreshold, newThreshold);
        travelRuleThreshold = newThreshold;
    }

    function setVerificationRequirements(bool sender, bool recipient) external onlyOwner {
        requireVerifiedSender = sender;
        requireVerifiedRecipient = recipient;
        emit VerificationRequirementsUpdated(sender, recipient);
    }

    function setExempt(address account, bool exempt) external onlyOwner {
        isExempt[account] = exempt;
        emit ExemptionUpdated(account, exempt);
    }

    /// @notice Add or clear a sanctions block.
    /// @dev The mirror of `MockAttestationOracle.setCompliance` on the asset side: identity can
    ///      be revoked for a person, and movement can be frozen for an address. Both are needed --
    ///      revoking CVI stops new credit but does not by itself stop token movement.
    function setBlocked(address account, bool blocked, string calldata reason)
        external
        onlyOwner
    {
        isBlocked[account] = blocked;
        emit BlocklistUpdated(account, blocked, reason);
    }
}
