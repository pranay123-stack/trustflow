// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "./Base.t.sol";
import {TrustFlowPool, CreditLine, CreditStatus, PoolStats} from "../src/TrustFlowPool.sol";
import {MockAttestationOracle} from "../src/oracles/MockAttestationOracle.sol";
import {IAttestationOracle} from "../src/interfaces/IAttestationOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract TrustFlowPoolTest is BaseTest {
    // =====================================================================
    // LP side
    // =====================================================================

    function test_deposit_firstDepositorMintsOneToOne() public {
        vm.prank(alice);
        uint256 shares = pool.deposit(100_000e18, alice);

        assertEq(shares, 100_000e18);
        assertEq(pool.balanceOf(alice), 100_000e18);
        assertEq(pool.totalAssets(), 100_000e18);
        assertEq(pool.cash(), 100_000e18);
    }

    function test_deposit_secondDepositorPricedFairly() public {
        _fundPool(100_000e18);

        vm.prank(carol);
        uint256 shares = pool.deposit(50_000e18, carol);

        assertEq(shares, 50_000e18, "no yield accrued yet, so 1:1 still holds");
        assertEq(pool.totalAssets(), 150_000e18);
    }

    function test_deposit_revertsOnZero() public {
        vm.prank(alice);
        vm.expectRevert(TrustFlowPool.ZeroAmount.selector);
        pool.deposit(0, alice);
    }

    function test_deposit_revertsOnZeroReceiver() public {
        vm.prank(alice);
        vm.expectRevert(TrustFlowPool.ZeroAddress.selector);
        pool.deposit(1e18, address(0));
    }

    function test_redeem_returnsUnderlying() public {
        _fundPool(100_000e18);
        uint256 before = vusd.balanceOf(alice);

        vm.prank(alice);
        uint256 assets = pool.redeem(40_000e18, alice);

        assertEq(assets, 40_000e18);
        assertEq(vusd.balanceOf(alice), before + 40_000e18);
        assertEq(pool.balanceOf(alice), 60_000e18);
    }

    function test_redeem_revertsWhenLiquidityIsLentOut() public {
        _fundPool(100_000e18);
        _attestMax(bob);

        vm.prank(bob);
        pool.borrow(50_000e18);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrustFlowPool.InsufficientLiquidity.selector, 100_000e18, 50_000e18
            )
        );
        pool.redeem(100_000e18, alice);
    }

    // =====================================================================
    // THE COMPLIANCE GATE
    // =====================================================================

    function test_borrow_revertsForWalletWithNoAttestation() public {
        _fundPool(100_000e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TrustFlowPool.NotCompliant.selector, bob));
        pool.borrow(1e18);
    }

    function test_borrow_revertsWhenComplianceRevoked() public {
        _fundPool(100_000e18);
        _attestMax(bob);

        vm.prank(bob);
        pool.borrow(1_000e18); // works while compliant

        vm.prank(admin);
        oracle.setCompliance(bob, false, "sanctions list hit");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TrustFlowPool.NotCompliant.selector, bob));
        pool.borrow(1e18);
    }

    function test_borrow_revertsWhenAttestationExpired() public {
        _fundPool(100_000e18);

        vm.prank(admin);
        oracle.issueAttestation(bob, 3, 1000, true, uint64(block.timestamp + 1 days), bytes32(0));

        vm.prank(bob);
        pool.borrow(1_000e18);

        vm.warp(block.timestamp + 2 days);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TrustFlowPool.NotCompliant.selector, bob));
        pool.borrow(1e18);
    }

    /// @dev Repayment must survive a compliance revocation -- blocking it would strand funds.
    function test_repay_isNotComplianceGated() public {
        _fundPool(100_000e18);
        _attestMax(bob);

        vm.prank(bob);
        pool.borrow(5_000e18);

        vm.prank(admin);
        oracle.setCompliance(bob, false, "sanctions list hit");

        vm.prank(bob);
        uint256 repaid = pool.repay(bob, 5_000e18);

        assertEq(repaid, 5_000e18);
        assertEq(pool.debtOf(bob), 0, "a flagged borrower must still be able to clear their debt");
    }

    // =====================================================================
    // Borrowing power
    // =====================================================================

    function test_borrow_tier0_withoutCollateral_hasNoCreditLine() public {
        _fundPool(100_000e18);
        _attest(bob, 0, 1000, true); // compliant, but unverified identity

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TrustFlowPool.ExceedsCreditLimit.selector, 1e18, 0));
        pool.borrow(1e18);
    }

    function test_borrow_tier0_withCollateral_isOvercollateralized() public {
        _fundPool(100_000e18);
        _attest(bob, 0, 0, true);

        vm.startPrank(bob);
        pool.postCollateral(10_000e18);
        assertEq(pool.maxBorrowOf(bob), 8_000e18, "80% LTV fallback");

        pool.borrow(8_000e18);
        vm.stopPrank();

        assertEq(pool.debtOf(bob), 8_000e18);
        assertLt(pool.debtOf(bob), 10_000e18, "debt stays below collateral");
    }

    function test_borrow_tier3_fullyUnsecured() public {
        _fundPool(100_000e18);
        _attestMax(bob);

        assertEq(pool.maxBorrowOf(bob), 50_000e18);

        vm.prank(bob);
        pool.borrow(50_000e18);

        assertEq(pool.debtOf(bob), 50_000e18);
        assertEq(pool.creditLineOf(bob).collateral, 0, "not one wei of collateral was posted");
    }

    function test_borrow_revertsAboveCreditLimit() public {
        _fundPool(100_000e18);
        _attestMax(bob);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrustFlowPool.ExceedsCreditLimit.selector, 50_000e18 + 1, 50_000e18
            )
        );
        pool.borrow(50_000e18 + 1);
    }

    function test_borrow_revertsWhenPoolIsDry() public {
        _fundPool(1_000e18);
        _attestMax(bob);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(TrustFlowPool.InsufficientLiquidity.selector, 5_000e18, 1_000e18)
        );
        pool.borrow(5_000e18);
    }

    function test_borrow_creditGrowsAsAttestationsAccumulate() public {
        _fundPool(200_000e18);

        _attest(bob, 0, 0, true);
        assertEq(pool.availableCreditOf(bob), 0);

        _attest(bob, 1, 200, true);
        assertEq(pool.availableCreditOf(bob), 1_200e18);

        _attest(bob, 2, 500, true);
        assertEq(pool.availableCreditOf(bob), 7_500e18);

        _attest(bob, 3, 1000, true);
        assertEq(pool.availableCreditOf(bob), 50_000e18, "the demo's wow moment, as an assertion");
    }

    // =====================================================================
    // Rates
    // =====================================================================

    function test_borrowRate_trustedBorrowerPaysLess() public {
        _fundPool(100_000e18);

        // Push utilization to 50% with an unrelated borrower so neither rate hits the floor.
        _attestMax(carol);
        vm.prank(carol);
        pool.borrow(50_000e18);

        assertEq(pool.utilizationBps(), 5_000);

        _attest(bob, 0, 0, true);
        uint256 untrusted = pool.borrowRateOf(bob);

        _attest(bob, 3, 1000, true);
        uint256 trusted = pool.borrowRateOf(bob);

        assertEq(untrusted, 900, "4% base + 5% utilization premium");
        assertEq(trusted, 300, "same pool, 600bps cheaper for a fully attested borrower");
    }

    function test_borrow_snapshotsRateOnTheLine() public {
        _fundPool(100_000e18);
        _attest(bob, 0, 0, true);

        vm.startPrank(bob);
        pool.postCollateral(10_000e18);
        pool.borrow(8_000e18);
        vm.stopPrank();

        // util = 8_000 / 100_000 = 800bps -> premium 80bps -> 480bps total, no trust discount.
        assertEq(pool.creditLineOf(bob).rateBps, 480);
    }

    // =====================================================================
    // Interest + LP yield
    // =====================================================================

    function test_interest_accruesAndCompoundsIntoPrincipal() public {
        _fundPool(100_000e18);
        _attest(bob, 0, 0, true);

        vm.startPrank(bob);
        pool.postCollateral(10_000e18);
        pool.borrow(8_000e18);
        vm.stopPrank();

        assertEq(pool.pendingInterest(bob), 0);

        vm.warp(block.timestamp + 365 days);

        // 8_000 * 4.80% = 384
        assertEq(pool.pendingInterest(bob), 384e18);
        assertEq(pool.debtOf(bob), 8_384e18);

        pool.accrueFor(bob);
        assertEq(pool.creditLineOf(bob).principal, 8_384e18, "interest folded into principal");
        assertEq(pool.totalBorrows(), 8_384e18);
    }

    function test_interest_raisesLpSharePrice() public {
        _fundPool(100_000e18);
        _attest(bob, 0, 0, true);

        vm.startPrank(bob);
        pool.postCollateral(10_000e18);
        pool.borrow(8_000e18);
        vm.stopPrank();

        assertEq(pool.sharePrice(), 1e18);

        vm.warp(block.timestamp + 365 days);
        pool.accrueFor(bob);

        // 384 interest, 10% to reserves -> 345.6 to LPs on a 100_000 base.
        assertEq(pool.totalReserves(), 38.4e18);
        assertEq(pool.totalAssets(), 100_345.6e18);
        assertGt(pool.sharePrice(), 1e18, "LPs earn yield from borrower interest");
    }

    function test_accrue_isIdempotentWithinSameBlock() public {
        _fundPool(100_000e18);
        _attestMax(bob);

        vm.prank(bob);
        pool.borrow(10_000e18);

        vm.warp(block.timestamp + 30 days);
        pool.accrueFor(bob);
        uint256 afterFirst = pool.creditLineOf(bob).principal;

        pool.accrueFor(bob);
        assertEq(pool.creditLineOf(bob).principal, afterFirst, "double-poke must be a no-op");
    }

    function test_accrueForMany_sweepsTheBook() public {
        _fundPool(200_000e18);
        _attestMax(bob);
        _attestMax(carol);

        vm.prank(bob);
        pool.borrow(10_000e18);
        vm.prank(carol);
        pool.borrow(20_000e18);

        vm.warp(block.timestamp + 365 days);

        address[] memory borrowers = new address[](2);
        borrowers[0] = bob;
        borrowers[1] = carol;
        pool.accrueForMany(borrowers);

        assertGt(pool.creditLineOf(bob).principal, 10_000e18);
        assertGt(pool.creditLineOf(carol).principal, 20_000e18);
    }

    // =====================================================================
    // Repayment
    // =====================================================================

    function test_repay_partial() public {
        _fundPool(100_000e18);
        _attestMax(bob);

        vm.startPrank(bob);
        pool.borrow(10_000e18);
        pool.repay(bob, 4_000e18);
        vm.stopPrank();

        assertEq(pool.debtOf(bob), 6_000e18);
        assertEq(pool.totalBorrows(), 6_000e18);
    }

    function test_repay_maxUintClearsExactly() public {
        _fundPool(100_000e18);
        _attestMax(bob);

        vm.prank(bob);
        pool.borrow(10_000e18);

        vm.warp(block.timestamp + 100 days);

        uint256 balBefore = vusd.balanceOf(bob);
        vm.prank(bob);
        uint256 repaid = pool.repay(bob, type(uint256).max);

        assertEq(pool.debtOf(bob), 0, "position fully cleared");
        assertEq(pool.creditLineOf(bob).rateBps, 0, "rate resets once debt is gone");
        assertEq(balBefore - vusd.balanceOf(bob), repaid, "charged exactly what was owed");
    }

    function test_repay_byThirdParty() public {
        _fundPool(100_000e18);
        _attestMax(bob);

        vm.prank(bob);
        pool.borrow(10_000e18);

        vm.prank(carol);
        pool.repay(bob, 10_000e18);

        assertEq(pool.debtOf(bob), 0);
    }

    function test_repay_revertsWithNoDebt() public {
        _fundPool(100_000e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TrustFlowPool.NoDebt.selector, bob));
        pool.repay(bob, 1e18);
    }

    // =====================================================================
    // Collateral
    // =====================================================================

    function test_postCollateral_isExcludedFromLendableCash() public {
        _fundPool(100_000e18);

        vm.prank(bob);
        pool.postCollateral(10_000e18);

        assertEq(pool.totalCollateral(), 10_000e18);
        assertEq(pool.cash(), 100_000e18, "borrower collateral is escrowed, not lent out");
        assertEq(pool.totalAssets(), 100_000e18, "and never inflates the LP share price");
    }

    function test_withdrawCollateral_whenDebtFree() public {
        vm.prank(bob);
        pool.postCollateral(10_000e18);

        uint256 before = vusd.balanceOf(bob);
        vm.prank(bob);
        pool.withdrawCollateral(10_000e18);

        assertEq(vusd.balanceOf(bob), before + 10_000e18);
        assertEq(pool.totalCollateral(), 0);
    }

    function test_withdrawCollateral_revertsIfItWouldBreakTheLine() public {
        _fundPool(100_000e18);
        _attest(bob, 0, 0, true);

        vm.startPrank(bob);
        pool.postCollateral(10_000e18);
        pool.borrow(8_000e18); // exactly at the 80% limit

        vm.expectRevert(
            abi.encodeWithSelector(TrustFlowPool.ExceedsCreditLimit.selector, 8_000e18, 7_920e18)
        );
        pool.withdrawCollateral(100e18);
        vm.stopPrank();
    }

    function test_withdrawCollateral_revertsAboveBalance() public {
        vm.startPrank(bob);
        pool.postCollateral(1_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrustFlowPool.InsufficientCollateral.selector, 2_000e18, 1_000e18
            )
        );
        pool.withdrawCollateral(2_000e18);
        vm.stopPrank();
    }

    // =====================================================================
    // Liquidation
    // =====================================================================

    function test_liquidate_revertsOnHealthyPosition() public {
        _fundPool(100_000e18);
        _attestMax(bob);

        vm.prank(bob);
        pool.borrow(10_000e18);

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(TrustFlowPool.PositionHealthy.selector, bob));
        pool.liquidate(bob, 1_000e18);
    }

    function test_liquidate_collateralizedPositionPushedUnderByInterest() public {
        _fundPool(100_000e18);
        _attest(bob, 0, 0, true);

        vm.startPrank(bob);
        pool.postCollateral(10_000e18);
        pool.borrow(8_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        pool.accrueFor(bob);

        assertTrue(pool.isLiquidatable(bob), "8_384 debt against an 8_000 line");

        uint256 maxRepay = (8_384e18 * 5_000) / BPS; // 50% close factor
        uint256 balBefore = vusd.balanceOf(liquidator);

        vm.prank(liquidator);
        uint256 seized = pool.liquidate(bob, maxRepay);

        assertEq(seized, (maxRepay * 10_800) / BPS, "liquidator earns the 8% bonus");
        assertEq(vusd.balanceOf(liquidator), balBefore - maxRepay + seized);
        assertFalse(pool.isLiquidatable(bob), "position is healthy again after the partial close");
    }

    function test_liquidate_revertsAboveCloseFactor() public {
        _fundPool(100_000e18);
        _attest(bob, 0, 0, true);

        vm.startPrank(bob);
        pool.postCollateral(10_000e18);
        pool.borrow(8_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        pool.accrueFor(bob);

        uint256 maxRepay = (8_384e18 * 5_000) / BPS;
        vm.prank(liquidator);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrustFlowPool.RepayExceedsCloseFactor.selector, maxRepay + 1, maxRepay
            )
        );
        pool.liquidate(bob, maxRepay + 1);
    }

    /// @dev An attestation downgrade instantly collapses an unsecured line. There is no
    ///      collateral to seize -- the shortfall is reported, not hidden.
    function test_liquidate_unsecuredLineAfterAttestationDowngrade() public {
        _fundPool(100_000e18);
        _attestMax(bob);

        vm.prank(bob);
        pool.borrow(10_000e18);

        _attest(bob, 0, 0, true); // identity revoked down to tier 0
        assertEq(pool.maxBorrowOf(bob), 0);
        assertTrue(pool.isLiquidatable(bob));

        vm.prank(liquidator);
        uint256 seized = pool.liquidate(bob, 5_000e18);

        assertEq(seized, 0, "nothing to seize on a purely unsecured line");
        assertEq(pool.debtOf(bob), 5_000e18);
    }

    function test_markDefault_emitsSlashSignalForUnsecuredLoss() public {
        _fundPool(100_000e18);
        _attestMax(bob);

        vm.prank(bob);
        pool.borrow(10_000e18);

        _attest(bob, 0, 0, true);

        vm.expectEmit(true, false, false, true, address(pool));
        emit TrustFlowPool.DefaultRecorded(bob, 10_000e18, 0);
        pool.markDefault(bob);
    }

    function test_markDefault_revertsWhileCollateralRemains() public {
        _fundPool(100_000e18);
        _attest(bob, 0, 0, true);

        vm.startPrank(bob);
        pool.postCollateral(10_000e18);
        pool.borrow(8_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        vm.expectRevert(abi.encodeWithSelector(TrustFlowPool.PositionHealthy.selector, bob));
        pool.markDefault(bob);
    }

    // =====================================================================
    // The oracle swap -- the Cleanverse integration seam
    // =====================================================================

    function test_setOracle_swapsTheIdentityFeedWithNoOtherChanges() public {
        _fundPool(100_000e18);
        _attestMax(bob);
        assertEq(pool.maxBorrowOf(bob), 50_000e18);

        // A second feed that knows nothing about bob.
        vm.startPrank(admin);
        MockAttestationOracle fresh = new MockAttestationOracle(admin);
        pool.setOracle(IAttestationOracle(address(fresh)));
        vm.stopPrank();

        assertEq(pool.maxBorrowOf(bob), 0, "credit now follows the new feed");

        vm.prank(admin);
        fresh.issueAttestation(bob, 2, 1000, true, uint64(block.timestamp + 365 days), bytes32(0));
        assertEq(pool.maxBorrowOf(bob), 10_000e18);
    }

    function test_setOracle_onlyOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        pool.setOracle(IAttestationOracle(address(oracle)));
    }

    function test_setOracle_rejectsZero() public {
        vm.prank(admin);
        vm.expectRevert(TrustFlowPool.ZeroAddress.selector);
        pool.setOracle(IAttestationOracle(address(0)));
    }

    // =====================================================================
    // Reserves
    // =====================================================================

    function test_setReserveFactor_enforcesCap() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TrustFlowPool.ReserveFactorTooHigh.selector, 3_001));
        pool.setReserveFactor(3_001);

        vm.prank(admin);
        pool.setReserveFactor(3_000);
        assertEq(pool.reserveFactorBps(), 3_000);
    }

    function test_withdrawReserves() public {
        _fundPool(100_000e18);
        _attest(bob, 0, 0, true);

        vm.startPrank(bob);
        pool.postCollateral(10_000e18);
        pool.borrow(8_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        pool.accrueFor(bob);

        uint256 reserves = pool.totalReserves();
        assertEq(reserves, 38.4e18);

        vm.prank(admin);
        pool.withdrawReserves(admin, reserves);

        assertEq(vusd.balanceOf(admin), reserves);
        assertEq(pool.totalReserves(), 0);
    }

    // =====================================================================
    // Aggregate views used by the frontend
    // =====================================================================

    function test_creditStatus_matchesIndividualViews() public {
        _fundPool(100_000e18);
        _attest(bob, 2, 750, true);

        vm.startPrank(bob);
        pool.postCollateral(1_000e18);
        pool.borrow(4_000e18);
        vm.stopPrank();

        CreditStatus memory s = pool.creditStatus(bob);

        assertEq(s.cviTier, 2);
        assertEq(s.cviScore, 750);
        assertTrue(s.isCompliant);
        assertTrue(s.isVerified);
        assertEq(s.trustScoreBps, 7_000);
        assertEq(s.maxBorrow, pool.maxBorrowOf(bob));
        assertEq(s.debt, pool.debtOf(bob));
        assertEq(s.available, pool.availableCreditOf(bob));
        assertEq(s.collateral, 1_000e18);
        assertEq(s.unsecuredShareBps, 7_000);
        assertEq(s.reputationLine + s.collateralLine, s.maxBorrow);
    }

    function test_creditStatus_healthIsMaxWhenDebtFree() public {
        _attestMax(bob);
        assertEq(pool.creditStatus(bob).healthBps, type(uint256).max);
    }

    function test_poolStats_matchesIndividualViews() public {
        _fundPool(100_000e18);
        _attestMax(bob);
        vm.prank(bob);
        pool.borrow(30_000e18);

        PoolStats memory p = pool.poolStats();
        assertEq(p.totalAssets, pool.totalAssets());
        assertEq(p.totalBorrows, 30_000e18);
        assertEq(p.cash, 70_000e18);
        assertEq(p.utilizationBps, 3_000);
        assertEq(p.totalShares, 100_000e18);
    }

    // =====================================================================
    // Events -- the UI activity feed depends on these exact shapes
    // =====================================================================

    function test_borrow_emitsRichEvent() public {
        _fundPool(100_000e18);
        _attestMax(bob);

        vm.expectEmit(true, false, false, true, address(pool));
        emit TrustFlowPool.Borrowed(bob, 10_000e18, 10_000e18, 200, 3, 1000, 50_000e18, 1_000);

        vm.prank(bob);
        pool.borrow(10_000e18);
    }

    function test_repay_emitsEvent() public {
        _fundPool(100_000e18);
        _attestMax(bob);

        vm.startPrank(bob);
        pool.borrow(10_000e18);

        vm.expectEmit(true, true, false, true, address(pool));
        emit TrustFlowPool.Repaid(bob, bob, 4_000e18, 6_000e18);
        pool.repay(bob, 4_000e18);
        vm.stopPrank();
    }

    // =====================================================================
    // Fuzz
    // =====================================================================

    function testFuzz_borrowNeverExceedsCreditLine(uint8 tier, uint16 score, uint256 amount)
        public
    {
        tier = uint8(bound(tier, 0, 3));
        score = uint16(bound(score, 0, 1000));
        amount = bound(amount, 1, 100_000e18);

        _fundPool(500_000e18);
        _attest(bob, tier, score, true);

        uint256 max = pool.maxBorrowOf(bob);

        vm.prank(bob);
        if (amount > max) {
            vm.expectRevert();
            pool.borrow(amount);
        } else {
            pool.borrow(amount);
            assertLe(pool.debtOf(bob), max, "debt can never exceed the credit line at draw time");
        }
    }

    function testFuzz_depositThenRedeemIsLossless(uint256 amount) public {
        amount = bound(amount, 1e18, 500_000e18);

        uint256 before = vusd.balanceOf(alice);

        vm.startPrank(alice);
        uint256 shares = pool.deposit(amount, alice);
        uint256 assets = pool.redeem(shares, alice);
        vm.stopPrank();

        assertLe(assets, amount, "round-trip must never mint value out of thin air");
        assertLe(before - vusd.balanceOf(alice), 1, "and must lose at most 1 wei to rounding");
    }
}
