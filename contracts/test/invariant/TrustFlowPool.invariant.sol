// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PoolHandler} from "./PoolHandler.sol";
import {TrustFlowPool} from "../../src/TrustFlowPool.sol";
import {CVAStablecoin} from "../../src/cva/CVAStablecoin.sol";
import {CVACompliancePolicy} from "../../src/cva/CVACompliancePolicy.sol";
import {MockAttestationOracle} from "../../src/oracles/MockAttestationOracle.sol";
import {IAttestationOracle} from "../../src/interfaces/IAttestationOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Properties that must hold no matter what sequence of deposits, draws, repayments,
///         attestation changes, time jumps and liquidations the fuzzer throws at the pool.
contract TrustFlowPoolInvariantTest is Test {
    CVAStablecoin internal vusd;
    CVACompliancePolicy internal policy;
    MockAttestationOracle internal oracle;
    TrustFlowPool internal pool;
    PoolHandler internal handler;

    address internal admin = makeAddr("admin");

    function setUp() public {
        vm.warp(1_700_000_000);

        vm.startPrank(admin);
        oracle = new MockAttestationOracle(admin);
        policy = new CVACompliancePolicy(IAttestationOracle(address(oracle)), admin);
        vusd = new CVAStablecoin(policy, IAttestationOracle(address(oracle)), admin);
        pool = new TrustFlowPool(IERC20(address(vusd)), IAttestationOracle(address(oracle)), admin);
        policy.setExempt(address(pool), true);
        vm.stopPrank();

        handler = new PoolHandler(pool, vusd, oracle, admin);

        targetContract(address(handler));
    }

    /// @dev Borrower collateral is escrowed. The pool must always physically hold at least the
    ///      sum of what borrowers have posted -- otherwise someone's collateral was lent away.
    function invariant_collateralIsAlwaysFullyBacked() public view {
        assertGe(
            vusd.balanceOf(address(pool)),
            pool.totalCollateral(),
            "pool must hold at least every wei of posted collateral"
        );
    }

    /// @dev The aggregate debt counter must never drift from the per-account principals it is
    ///      supposed to summarise.
    function invariant_totalBorrowsEqualsSumOfPrincipals() public view {
        assertEq(
            pool.totalBorrows(),
            handler.sumOfPrincipals(),
            "totalBorrows must equal the sum of every credit line's principal"
        );
    }

    /// @dev Same, for the collateral counter.
    function invariant_totalCollateralEqualsSumOfLines() public view {
        assertEq(pool.totalCollateral(), handler.sumOfCollateral());
    }

    /// @dev No sequence may ever dilute existing LPs below par. Deposits and redemptions are
    ///      proportional, interest only adds, and losses are never socialised silently.
    function invariant_sharePriceNeverFallsBelowPar() public view {
        if (pool.totalSupply() == 0) return;
        assertGe(pool.sharePrice(), 1e18, "LP shares must never be worth less than they cost");
    }

    /// @dev LP-claimable assets are cash plus debt, net of reserves. Reserves must never be
    ///      counted as LP value.
    function invariant_totalAssetsExcludesReservesAndCollateral() public view {
        uint256 gross = pool.cash() + pool.totalBorrows();
        assertLe(pool.totalAssets(), gross, "reserves must never inflate LP assets");
        assertEq(
            pool.cash(),
            vusd.balanceOf(address(pool)) - pool.totalCollateral(),
            "cash must exclude escrowed collateral"
        );
    }

    /// @dev A wallet with no live attestation and no collateral can never hold debt that the
    ///      protocol considers within-limit.
    function invariant_unverifiedWalletsHaveNoCreditLine() public view {
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            address actor = handler.actors(i);
            if (pool.creditLineOf(actor).collateral == 0) {
                uint8 tier = oracle.getAttestation(actor).cviTier;
                if (tier == 0) {
                    assertEq(
                        pool.maxBorrowOf(actor),
                        0,
                        "tier0 with no collateral must have a zero credit line"
                    );
                }
            }
        }
    }

    /// @dev Solvency: the protocol's reserve claim is always backed by idle cash plus
    ///      outstanding debt.
    ///
    ///      Note what this deliberately does NOT assert: `balance >= totalCollateral +
    ///      totalReserves`. That is tempting but false, and the fuzzer proves it. Reserves
    ///      accrue the moment interest is capitalised, while the cash backing that interest
    ///      only arrives when the borrower repays. A heavily-utilised pool can therefore hold
    ///      less cash than it has booked in reserves -- reserves are a claim on future
    ///      repayments, not on present cash. `availableLiquidity()` saturates to zero for
    ///      exactly this case, so LPs are never paid out of the reserve claim.
    ///
    ///      The genuine invariant is the one below: every interest accrual adds at least as
    ///      much to (cash + borrows) as it does to reserves, and no other operation can break
    ///      the gap, because redemptions are bounded by `availableLiquidity`.
    function invariant_reservesAreBackedByCashPlusDebt() public view {
        assertGe(
            pool.cash() + pool.totalBorrows(),
            pool.totalReserves(),
            "reserves must always be backed by idle cash plus outstanding debt"
        );
    }

    /// @dev LPs can never redeem into the protocol's reserve claim.
    ///
    ///      Stated as two cases, because the single-expression version is wrong: when accrued
    ///      reserves exceed idle cash, withdrawable liquidity is simply zero and no arithmetic
    ///      relation to `cash` holds.
    function invariant_availableLiquidityNeverEatsReserves() public view {
        uint256 liquid = pool.availableLiquidity();
        uint256 c = pool.cash();

        assertLe(liquid, c, "withdrawable liquidity can never exceed idle cash");

        if (liquid > 0) {
            assertEq(
                liquid + pool.totalReserves(),
                c,
                "when liquidity is withdrawable, it must be cash net of the reserve claim"
            );
        }
    }

    function invariant_callSummary() public view {
        console2.log("deposits  :", handler.depositCalls());
        console2.log("borrows   :", handler.borrowCalls());
        console2.log("repays    :", handler.repayCalls());
        console2.log("liquidates:", handler.liquidateCalls());
    }
}
