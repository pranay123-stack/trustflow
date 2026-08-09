import { generatedDeployments, type DeploymentAddresses } from "./deployments.generated";
import { localhost, monadTestnet } from "./chains";

/**
 * Address resolution order:
 *   1. NEXT_PUBLIC_* env overrides (useful for pointing the UI at someone else's deployment)
 *   2. contracts/deployments/<chainId>.json, baked in by `npm run genabi`
 */
function envOverride(): Partial<DeploymentAddresses> {
  return {
    vUSD: process.env.NEXT_PUBLIC_VUSD_ADDRESS as `0x${string}` | undefined,
    attestationOracle: process.env.NEXT_PUBLIC_ORACLE_ADDRESS as `0x${string}` | undefined,
    trustFlowPool: process.env.NEXT_PUBLIC_POOL_ADDRESS as `0x${string}` | undefined,
    cvaPolicy: process.env.NEXT_PUBLIC_CVA_POLICY_ADDRESS as `0x${string}` | undefined,
  };
}

export function getDeployment(chainId: number | undefined): DeploymentAddresses | null {
  const id = chainId ?? localhost.id;
  const base = generatedDeployments[id];
  const override = envOverride();

  // Typed explicitly rather than cast. An earlier version built this object with an
  // `as DeploymentAddresses` cast, which let a newly-added address (cvaPolicy) be silently
  // dropped here -- the CVA card then read `undefined` and rendered empty defaults with no
  // compiler complaint. Annotating the binding makes a missing field a build error.
  const merged: Partial<DeploymentAddresses> = {
    vUSD: override.vUSD ?? base?.vUSD,
    attestationOracle: override.attestationOracle ?? base?.attestationOracle,
    trustFlowPool: override.trustFlowPool ?? base?.trustFlowPool,
    cvaPolicy: override.cvaPolicy ?? base?.cvaPolicy,
    oracleMode: base?.oracleMode ?? "mock",
  };

  if (!merged.vUSD || !merged.attestationOracle || !merged.trustFlowPool || !merged.cvaPolicy) {
    return null;
  }
  return merged as DeploymentAddresses;
}

export const CHAIN_LABELS: Record<number, string> = {
  [localhost.id]: "Local Anvil",
  [monadTestnet.id]: "Monad Testnet",
};

/** Credential catalogue -- mirrors `MockAttestationOracle.CredentialType`. */
export const CREDENTIALS = [
  {
    id: 0,
    key: "KycBasic",
    name: "Basic KYC",
    detail: "Government ID + liveness check",
    minTier: 1,
    scoreDelta: 200,
  },
  {
    id: 1,
    key: "ProofOfAddress",
    name: "Proof of Address",
    detail: "Utility bill or bank statement",
    minTier: 1,
    scoreDelta: 150,
  },
  {
    id: 2,
    key: "SanctionsScreen",
    name: "Sanctions Screen",
    detail: "OFAC / EU / UN list clearance",
    minTier: 0,
    scoreDelta: 150,
  },
  {
    id: 3,
    key: "AccreditedInvestor",
    name: "Accredited Investor",
    detail: "Income & net-worth verification",
    minTier: 2,
    scoreDelta: 250,
  },
  {
    id: 4,
    key: "InstitutionalKyb",
    name: "Institutional KYB",
    detail: "Entity formation + UBO chain",
    minTier: 3,
    scoreDelta: 250,
  },
] as const;

export type Credential = (typeof CREDENTIALS)[number];
