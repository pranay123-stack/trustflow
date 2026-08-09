// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {TrustFlowPool} from "../../src/TrustFlowPool.sol";
import {CVAStablecoin} from "../../src/cva/CVAStablecoin.sol";
import {CVACompliancePolicy} from "../../src/cva/CVACompliancePolicy.sol";
import {MockAttestationOracle} from "../../src/oracles/MockAttestationOracle.sol";

/// @notice Drives randomised traffic against the pool for the invariant suite.
/// @dev Every action is bounded to a plausible range so the fuzzer spends its budget on real
///      state transitions rather than on reverts.
contract PoolHandler is CommonBase, StdCheats, StdUtils {
    TrustFlowPool public immutable pool;
    CVAStablecoin public immutable vusd;
    MockAttestationOracle public immutable oracle;
    address public immutable admin;

    address[] public actors;
    address internal currentActor;

    /// @dev Counters, printed by `forge test -vv`, confirming the fuzzer actually exercised
    ///      each path rather than reverting through all of them.
    uint256 public depositCalls;
    uint256 public borrowCalls;
    uint256 public repayCalls;
    uint256 public liquidateCalls;

    constructor(TrustFlowPool pool_, CVAStablecoin vusd_, MockAttestationOracle oracle_, address admin_) {
        pool = pool_;
        vusd = vusd_;
        oracle = oracle_;
        admin = admin_;

        for (uint256 i = 0; i < 5; i++) {
            address actor = address(uint160(uint256(keccak256(abi.encodePacked("actor", i)))));
            actors.push(actor);

            vm.prank(admin);
            vusd.issue(actor, 1_000_000e18, "test-settlement", bytes32(uint256(0x5EED)));

            vm.prank(actor);
            vusd.approve(address(pool), type(uint256).max);

            // Give every actor a live credit line from call #1. Without this the fuzzer has to
            // randomly stumble on reattest -> deposit -> borrow in order, and the borrow/repay/
            // liquidate paths stay almost entirely unexercised.
            vm.prank(admin);
            oracle.issueAttestation(
                actor,
                uint8(i % 4),
                uint16((i * 250) % 1001),
                true,
                uint64(block.timestamp + 365 days),
                bytes32(0)
            );
        }

        // Seed lendable liquidity so draws are possible immediately.
        vm.prank(admin);
        vusd.issue(address(this), 500_000e18, "test-settlement", bytes32(uint256(0x5EED)));
        vusd.approve(address(pool), type(uint256).max);
        pool.deposit(500_000e18, address(this));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    modifier useActor(uint256 seed) {
        currentActor = actors[bound(seed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------------

    function deposit(uint256 seed, uint256 amount) external useActor(seed) {
        amount = bound(amount, 1e18, 100_000e18);
        if (vusd.balanceOf(currentActor) < amount) return;
        pool.deposit(amount, currentActor);
        depositCalls++;
    }

    function redeem(uint256 seed, uint256 shares) external useActor(seed) {
        uint256 held = pool.balanceOf(currentActor);
        if (held == 0) return;
        shares = bound(shares, 1, held);
        if (pool.convertToAssets(shares) > pool.availableLiquidity()) return;
        pool.redeem(shares, currentActor);
    }

    function postCollateral(uint256 seed, uint256 amount) external useActor(seed) {
        amount = bound(amount, 1e18, 50_000e18);
        if (vusd.balanceOf(currentActor) < amount) return;
        pool.postCollateral(amount);
    }

    function withdrawCollateral(uint256 seed, uint256 amount) external useActor(seed) {
        uint256 posted = pool.creditLineOf(currentActor).collateral;
        if (posted == 0) return;
        amount = bound(amount, 1, posted);
        try pool.withdrawCollateral(amount) {} catch {}
    }

    function borrow(uint256 seed, uint256 amount) external useActor(seed) {
        uint256 headroom = pool.availableCreditOf(currentActor);
        uint256 liquid = pool.availableLiquidity();
        uint256 cap = headroom < liquid ? headroom : liquid;
        if (cap == 0) return;
        amount = bound(amount, 1, cap);
        try pool.borrow(amount) {
            borrowCalls++;
        } catch {}
    }

    /// @dev Repays the caller's own debt when they have any, otherwise falls back to whichever
    ///      actor does. Third-party repayment is a supported path, and without the fallback the
    ///      fuzzer almost never lands a repay on an indebted actor.
    function repay(uint256 seed, uint256 amount) external useActor(seed) {
        address target = currentActor;
        if (pool.debtOf(target) == 0) {
            target = address(0);
            for (uint256 i = 0; i < actors.length; i++) {
                if (pool.debtOf(actors[i]) > 0) {
                    target = actors[i];
                    break;
                }
            }
            if (target == address(0)) return;
        }

        uint256 debt = pool.debtOf(target);
        amount = bound(amount, 1, debt);
        if (vusd.balanceOf(currentActor) < amount) return;
        pool.repay(target, amount);
        repayCalls++;
    }

    function liquidate(uint256 seed, uint256 victimSeed, uint256 amount) external useActor(seed) {
        address victim = actors[bound(victimSeed, 0, actors.length - 1)];
        if (!pool.isLiquidatable(victim)) {
            // Fall back to any underwater position so the seize path gets exercised.
            victim = address(0);
            for (uint256 i = 0; i < actors.length; i++) {
                if (pool.isLiquidatable(actors[i])) {
                    victim = actors[i];
                    break;
                }
            }
            if (victim == address(0)) return;
        }

        uint256 maxRepay = (pool.debtOf(victim) * pool.CLOSE_FACTOR_BPS()) / 10_000;
        if (maxRepay == 0) return;
        amount = bound(amount, 1, maxRepay);
        if (vusd.balanceOf(currentActor) < amount) return;

        try pool.liquidate(victim, amount) {
            liquidateCalls++;
        } catch {}
    }

    /// @dev Randomly re-attest an actor, including downgrades -- this is what makes positions
    ///      go underwater in the first place.
    function reattest(uint256 seed, uint8 tier, uint16 score, bool compliant)
        external
        useActor(seed)
    {
        tier = uint8(bound(tier, 0, 3));
        score = uint16(bound(score, 0, 1000));

        vm.stopPrank();
        vm.prank(admin);
        oracle.issueAttestation(
            currentActor, tier, score, compliant, uint64(block.timestamp + 365 days), bytes32(0)
        );
        vm.startPrank(currentActor);
    }

    /// @dev Let interest actually accumulate between actions.
    function advanceTime(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1 hours, 90 days));
    }

    function pokeAccrual(uint256 seed) external {
        pool.accrueFor(actors[bound(seed, 0, actors.length - 1)]);
    }

    // ---------------------------------------------------------------------
    // Helpers for the invariant assertions
    // ---------------------------------------------------------------------

    function sumOfPrincipals() external view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            total += pool.creditLineOf(actors[i]).principal;
        }
    }

    function sumOfCollateral() external view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            total += pool.creditLineOf(actors[i]).collateral;
        }
    }
}
