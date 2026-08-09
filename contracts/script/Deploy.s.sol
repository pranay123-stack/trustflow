// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {CVAStablecoin} from "../src/cva/CVAStablecoin.sol";
import {CVACompliancePolicy} from "../src/cva/CVACompliancePolicy.sol";
import {MockAttestationOracle} from "../src/oracles/MockAttestationOracle.sol";
import {TrustFlowPool} from "../src/TrustFlowPool.sol";
import {IAttestationOracle} from "../src/interfaces/IAttestationOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deploys the full TrustFlow stack and writes the addresses to
///         `deployments/<chainId>.json`, which the frontend reads directly.
///
/// Local:  forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
/// Monad:  forge script script/Deploy.s.sol --rpc-url $MONAD_RPC_URL --broadcast
contract Deploy is Script {
    /// @notice vUSD minted to the deployer to seed the pool and the faucet.
    uint256 public constant DEPLOYER_MINT = 10_000_000e18;

    /// @notice Initial LP liquidity supplied by the deployer so borrowers can draw immediately.
    /// @dev Sized against what `Seed.s.sol` draws (~144k) to land the pool near 58% utilization.
    ///      That matters: the trust rebate is up to 600bps, so on a near-empty pool every tier
    ///      above 1 bottoms out at the 200bps rate floor and the "higher trust costs less"
    ///      relationship becomes invisible. At ~58% the tiers separate cleanly, and ~106k stays
    ///      idle -- enough for a fresh wallet to draw a full 50k tier-3 line during a demo.
    uint256 public constant INITIAL_LIQUIDITY = 250_000e18;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console2.log("Deployer:", deployer);
        console2.log("Chain id:", block.chainid);

        vm.startBroadcast(pk);

        MockAttestationOracle oracle = new MockAttestationOracle(deployer);
        CVACompliancePolicy policy = new CVACompliancePolicy(IAttestationOracle(address(oracle)), deployer);
        CVAStablecoin vusd = new CVAStablecoin(policy, IAttestationOracle(address(oracle)), deployer);
        TrustFlowPool pool =
            new TrustFlowPool(IERC20(address(vusd)), IAttestationOracle(address(oracle)), deployer);

        // CVA supply is never conjured -- each lot names what settled it and carries a digest
        // of the off-chain proof. On a real deployment these come from the issuing bank.
        vusd.issue(
            deployer,
            DEPLOYER_MINT,
            "bank-settlement",
            keccak256("trustflow/testnet/treasury-settlement-001")
        );
        policy.setExempt(address(pool), true);
        vusd.approve(address(pool), type(uint256).max);
        pool.deposit(INITIAL_LIQUIDITY, deployer);

        // Fund an optional demo wallet so a judge can borrow without hunting for the faucet.
        address demoWallet = vm.envOr("DEMO_WALLET", address(0));
        if (demoWallet != address(0)) {
            vusd.issue(
                demoWallet,
                50_000e18,
                "bank-settlement",
                keccak256("trustflow/testnet/demo-wallet-funding")
            );
            console2.log("Funded demo wallet:", demoWallet);
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== TrustFlow deployed ===");
        console2.log("vUSD           :", address(vusd));
        console2.log("Oracle (CVI)   :", address(oracle));
        console2.log("CVA policy     :", address(policy));
        console2.log("TrustFlowPool  :", address(pool));
        console2.log("Pool liquidity :", INITIAL_LIQUIDITY / 1e18, "vUSD");

        _writeDeployment(address(vusd), address(oracle), address(pool), address(policy), deployer);
    }

    function _writeDeployment(
        address vusd,
        address oracle,
        address pool,
        address cvaPolicy,
        address deployer
    )
        internal
    {
        string memory key = "trustflow";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "vUSD", vusd);
        vm.serializeAddress(key, "attestationOracle", oracle);
        vm.serializeAddress(key, "trustFlowPool", pool);
        vm.serializeAddress(key, "cvaPolicy", cvaPolicy);
        vm.serializeString(key, "oracleMode", "mock");
        string memory out = vm.serializeAddress(key, "deployer", deployer);

        string memory path =
            string.concat("./deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(out, path);

        console2.log("Wrote", path);
    }
}
