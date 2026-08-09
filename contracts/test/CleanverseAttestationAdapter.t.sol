// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CleanverseAttestationAdapter} from "../src/oracles/CleanverseAttestationAdapter.sol";
import {IAttestationOracle, Attestation} from "../src/interfaces/IAttestationOracle.sol";
import {TrustFlowPool} from "../src/TrustFlowPool.sol";
import {CVAStablecoin} from "../src/cva/CVAStablecoin.sol";
import {CVACompliancePolicy} from "../src/cva/CVACompliancePolicy.sol";
import {MockAttestationOracle} from "../src/oracles/MockAttestationOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Proves the live-Cleanverse path works end to end: a signed attestation is submitted
///         on-chain, the pool is repointed at the adapter, and credit flows -- with no changes
///         to TrustFlowPool itself.
contract CleanverseAttestationAdapterTest is Test {
    CleanverseAttestationAdapter internal adapter;

    address internal admin = makeAddr("admin");
    address internal user = makeAddr("user");

    uint256 internal signerKey = 0xC1EA5;
    address internal signer;

    function setUp() public {
        vm.warp(1_700_000_000);
        signer = vm.addr(signerKey);
        vm.prank(admin);
        adapter = new CleanverseAttestationAdapter(signer, admin);
    }

    // ---------------------------------------------------------------------
    // EIP-712 helpers -- mirrors what the Cleanverse backend would produce
    // ---------------------------------------------------------------------

    function _digest(
        address subject,
        uint8 tier,
        uint16 score,
        bool compliant,
        uint64 issuedAt,
        uint64 expiresAt,
        bytes32 credentialRef,
        uint256 nonce
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                adapter.ATTESTATION_TYPEHASH(),
                subject,
                tier,
                score,
                compliant,
                issuedAt,
                expiresAt,
                credentialRef,
                nonce
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", adapter.domainSeparator(), structHash));
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Build the signature. Kept separate from `_send` because this performs external view
    ///      calls on the adapter -- folding it into a submit helper would swallow any
    ///      `vm.expectRevert` armed by the caller.
    function _sig(
        uint256 key,
        address subject,
        uint8 tier,
        uint16 score,
        bool compliant,
        uint64 issuedAt,
        uint64 expiresAt,
        uint256 nonce
    ) internal view returns (bytes memory) {
        return _sign(
            key, _digest(subject, tier, score, compliant, issuedAt, expiresAt, bytes32(0), nonce)
        );
    }

    /// @dev The single external call under test.
    function _send(
        address subject,
        uint8 tier,
        uint16 score,
        bool compliant,
        uint64 issuedAt,
        uint64 expiresAt,
        uint256 nonce,
        bytes memory sig
    ) internal {
        adapter.submitAttestation(
            subject, tier, score, compliant, issuedAt, expiresAt, bytes32(0), nonce, sig
        );
    }

    function _submit(
        uint256 key,
        address subject,
        uint8 tier,
        uint16 score,
        bool compliant,
        uint64 issuedAt,
        uint64 expiresAt,
        uint256 nonce
    ) internal {
        bytes memory sig = _sig(key, subject, tier, score, compliant, issuedAt, expiresAt, nonce);
        _send(subject, tier, score, compliant, issuedAt, expiresAt, nonce, sig);
    }

    // ---------------------------------------------------------------------
    // Happy path
    // ---------------------------------------------------------------------

    function test_sourceIdIdentifiesTheLiveFeed() public view {
        assertEq(adapter.sourceId(), "cleanverse-cvi-cva-v1");
    }

    function test_submitAttestation_storesSignedRecord() public {
        uint64 issuedAt = uint64(block.timestamp);
        uint64 expiresAt = uint64(block.timestamp + 90 days);

        _submit(signerKey, user, 3, 950, true, issuedAt, expiresAt, 1);

        Attestation memory a = adapter.getAttestation(user);
        assertEq(a.cviTier, 3);
        assertEq(a.cviScore, 950);
        assertTrue(a.isCompliant);
        assertEq(a.issuedAt, issuedAt);
        assertEq(a.expiresAt, expiresAt);
        assertTrue(adapter.isVerified(user));
    }

    /// @dev The user submits their own attestation, so Cleanverse never needs a funded wallet.
    function test_anyoneCanRelayAValidSignature() public {
        bytes memory sig = _sign(
            signerKey,
            _digest(user, 2, 600, true, uint64(block.timestamp), 0, bytes32(0), 7)
        );

        vm.prank(user);
        adapter.submitAttestation(
            user, 2, 600, true, uint64(block.timestamp), 0, bytes32(0), 7, sig
        );

        assertEq(adapter.getAttestation(user).cviTier, 2);
    }

    // ---------------------------------------------------------------------
    // Signature + replay protection
    // ---------------------------------------------------------------------

    function test_rejectsSignatureFromWrongKey() public {
        uint256 attackerKey = 0xBAD;
        uint64 issuedAt = uint64(block.timestamp);
        bytes memory sig = _sig(attackerKey, user, 3, 1000, true, issuedAt, 0, 1);

        vm.expectRevert(CleanverseAttestationAdapter.InvalidSignature.selector);
        _send(user, 3, 1000, true, issuedAt, 0, 1, sig);
    }

    function test_rejectsTamperedPayload() public {
        // Sign for tier 1, then try to submit as tier 3.
        bytes memory sig = _sign(
            signerKey, _digest(user, 1, 100, true, uint64(block.timestamp), 0, bytes32(0), 1)
        );

        vm.expectRevert(CleanverseAttestationAdapter.InvalidSignature.selector);
        adapter.submitAttestation(
            user, 3, 100, true, uint64(block.timestamp), 0, bytes32(0), 1, sig
        );
    }

    function test_rejectsNonceReplay() public {
        _submit(signerKey, user, 1, 100, true, uint64(block.timestamp), 0, 42);

        vm.warp(block.timestamp + 1 days);

        uint64 issuedAt = uint64(block.timestamp);
        bytes memory sig = _sig(signerKey, user, 3, 1000, true, issuedAt, 0, 42);

        vm.expectRevert(
            abi.encodeWithSelector(CleanverseAttestationAdapter.NonceAlreadyUsed.selector, 42)
        );
        _send(user, 3, 1000, true, issuedAt, 0, 42, sig);
    }

    /// @dev The key downgrade-resistance property: a user who has been demoted cannot replay an
    ///      older, more favourable attestation to restore their credit line.
    function test_rejectsStaleAttestationAfterDowngrade() public {
        uint64 goodIssuedAt = uint64(block.timestamp);
        _submit(signerKey, user, 3, 1000, true, goodIssuedAt, 0, 1);

        vm.warp(block.timestamp + 30 days);
        uint64 downgradeIssuedAt = uint64(block.timestamp);
        _submit(signerKey, user, 0, 0, false, downgradeIssuedAt, 0, 2);

        assertFalse(adapter.isVerified(user));

        // Re-signing the ORIGINAL good record with a fresh nonce must still fail.
        bytes memory staleSig = _sig(signerKey, user, 3, 1000, true, goodIssuedAt, 0, 3);

        vm.expectRevert(
            abi.encodeWithSelector(
                CleanverseAttestationAdapter.StaleAttestation.selector,
                goodIssuedAt,
                downgradeIssuedAt
            )
        );
        _send(user, 3, 1000, true, goodIssuedAt, 0, 3, staleSig);
    }

    function test_rejectsAttestationIssuedTooFarInFuture() public {
        uint64 future = uint64(block.timestamp + 1 hours);
        bytes memory sig = _sig(signerKey, user, 3, 1000, true, future, 0, 1);

        vm.expectRevert(
            abi.encodeWithSelector(CleanverseAttestationAdapter.IssuedInFuture.selector, future)
        );
        _send(user, 3, 1000, true, future, 0, 1, sig);
    }

    function test_acceptsSmallClockSkew() public {
        uint64 slightlyAhead = uint64(block.timestamp + 5 minutes);
        _submit(signerKey, user, 3, 1000, true, slightlyAhead, 0, 1);
        assertEq(adapter.getAttestation(user).cviTier, 3);
    }

    function test_rejectsAlreadyExpiredAttestation() public {
        uint64 issuedAt = uint64(block.timestamp);
        uint64 expiresAt = uint64(block.timestamp - 1);
        bytes memory sig = _sig(signerKey, user, 3, 1000, true, issuedAt, expiresAt, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                CleanverseAttestationAdapter.AttestationExpired.selector, expiresAt
            )
        );
        _send(user, 3, 1000, true, issuedAt, expiresAt, 1, sig);
    }

    function test_rejectsOutOfRangeValues() public {
        uint64 issuedAt = uint64(block.timestamp);
        bytes memory tierSig = _sig(signerKey, user, 4, 1000, true, issuedAt, 0, 1);
        bytes memory scoreSig = _sig(signerKey, user, 3, 1001, true, issuedAt, 0, 2);

        vm.expectRevert(abi.encodeWithSelector(CleanverseAttestationAdapter.InvalidTier.selector, 4));
        _send(user, 4, 1000, true, issuedAt, 0, 1, tierSig);

        vm.expectRevert(
            abi.encodeWithSelector(CleanverseAttestationAdapter.InvalidScore.selector, 1001)
        );
        _send(user, 3, 1001, true, issuedAt, 0, 2, scoreSig);
    }

    function test_expiredRecordFailsVerification() public {
        uint64 expiresAt = uint64(block.timestamp + 1 days);
        _submit(signerKey, user, 3, 1000, true, uint64(block.timestamp), expiresAt, 1);
        assertTrue(adapter.isVerified(user));

        vm.warp(block.timestamp + 2 days);
        assertFalse(adapter.isVerified(user), "stale attestations auto-close the borrow gate");
    }

    function test_rotateSigner() public {
        uint256 newKey = 0xABCDEF;
        address newSigner = vm.addr(newKey);

        vm.prank(admin);
        adapter.setAttestationSigner(newSigner);

        uint64 issuedAt = uint64(block.timestamp);
        bytes memory oldSig = _sig(signerKey, user, 3, 1000, true, issuedAt, 0, 1);

        vm.expectRevert(CleanverseAttestationAdapter.InvalidSignature.selector);
        _send(user, 3, 1000, true, issuedAt, 0, 1, oldSig);

        _submit(newKey, user, 3, 1000, true, issuedAt, 0, 2);
        assertEq(adapter.getAttestation(user).cviTier, 3);
    }

    // ---------------------------------------------------------------------
    // THE SWAP: mock -> live, with zero pool changes
    // ---------------------------------------------------------------------

    function test_poolWorksAgainstLiveAdapterAfterOracleSwap() public {
        // Stand up a pool on the mock oracle, exactly as the demo deployment does.
        vm.startPrank(admin);
        MockAttestationOracle mock = new MockAttestationOracle(admin);
        CVACompliancePolicy pol = new CVACompliancePolicy(IAttestationOracle(address(mock)), admin);
        CVAStablecoin vusd = new CVAStablecoin(pol, IAttestationOracle(address(mock)), admin);
        TrustFlowPool pool =
            new TrustFlowPool(IERC20(address(vusd)), IAttestationOracle(address(mock)), admin);
        vusd.issue(admin, 500_000e18, "test-settlement", bytes32(uint256(0x5EED)));
        pol.setExempt(address(pool), true);
        vusd.approve(address(pool), type(uint256).max);
        pool.deposit(200_000e18, admin);
        vm.stopPrank();

        assertEq(pool.maxBorrowOf(user), 0);

        // Flip to the live Cleanverse feed. One transaction, no redeploy.
        vm.prank(admin);
        pool.setOracle(IAttestationOracle(address(adapter)));

        // Cleanverse signs off-chain; the user relays it on-chain.
        _submit(signerKey, user, 3, 1000, true, uint64(block.timestamp), 0, 1);

        assertEq(pool.maxBorrowOf(user), 50_000e18, "real attestations drive real credit");

        vm.prank(user);
        pool.borrow(50_000e18);
        assertEq(vusd.balanceOf(user), 50_000e18);
    }
}
