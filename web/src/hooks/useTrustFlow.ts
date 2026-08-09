"use client";

import { useCallback, useEffect, useMemo } from "react";
import {
  useAccount,
  useChainId,
  useReadContract,
  useReadContracts,
  useWaitForTransactionReceipt,
  useWriteContract,
} from "wagmi";
import { maxUint256, type Address } from "viem";

import { trustFlowPoolAbi, attestationOracleAbi, cvaStablecoinAbi } from "@/lib/abis";
import { getDeployment } from "@/lib/contracts";

const POLL_MS = 2_000;

export type CreditStatus = {
  cviTier: number;
  cviScore: number;
  isCompliant: boolean;
  isVerified: boolean;
  trustScoreBps: bigint;
  reputationLine: bigint;
  collateralLine: bigint;
  maxBorrow: bigint;
  debt: bigint;
  available: bigint;
  collateral: bigint;
  rateBps: bigint;
  unsecuredShareBps: bigint;
  healthBps: bigint;
};

export type PoolStats = {
  totalAssets: bigint;
  totalBorrows: bigint;
  cash: bigint;
  availableLiquidity: bigint;
  totalCollateral: bigint;
  totalReserves: bigint;
  utilizationBps: bigint;
  totalShares: bigint;
  sharePrice: bigint;
};

/**
 * Single source of on-chain state for the whole app.
 *
 * `creditStatus` and `poolStats` are struct-returning views, so the entire dashboard is two
 * RPC reads rather than a dozen. They poll on an interval so the dial reflects an attestation
 * the moment its transaction lands, without the page needing to know which action caused it.
 */
export function useTrustFlow() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const deployment = useMemo(() => getDeployment(chainId), [chainId]);

  const pool = deployment?.trustFlowPool;
  const oracle = deployment?.attestationOracle;
  const vusd = deployment?.vUSD;

  const enabled = Boolean(pool && address);

  const { data: status, refetch: refetchStatus } = useReadContract({
    address: pool,
    abi: trustFlowPoolAbi,
    functionName: "creditStatus",
    args: address ? [address] : undefined,
    query: { enabled, refetchInterval: POLL_MS },
  });

  const { data: stats, refetch: refetchStats } = useReadContract({
    address: pool,
    abi: trustFlowPoolAbi,
    functionName: "poolStats",
    query: { enabled: Boolean(pool), refetchInterval: POLL_MS },
  });

  const { data: bundle, refetch: refetchBundle } = useReadContracts({
    contracts: [
      {
        address: vusd,
        abi: cvaStablecoinAbi,
        functionName: "balanceOf",
        args: address ? [address] : undefined,
      },
      {
        address: vusd,
        abi: cvaStablecoinAbi,
        functionName: "allowance",
        args: address && pool ? [address, pool] : undefined,
      },
      {
        address: pool,
        abi: trustFlowPoolAbi,
        functionName: "balanceOf",
        args: address ? [address] : undefined,
      },
      {
        address: oracle,
        abi: attestationOracleAbi,
        functionName: "heldCredentials",
        args: address ? [address] : undefined,
      },
      {
        address: oracle,
        abi: attestationOracleAbi,
        functionName: "sourceId",
      },
    ],
    query: { enabled, refetchInterval: POLL_MS },
  });

  const refetchAll = useCallback(() => {
    void refetchStatus();
    void refetchStats();
    void refetchBundle();
  }, [refetchStatus, refetchStats, refetchBundle]);

  const vusdBalance = (bundle?.[0]?.result as bigint | undefined) ?? 0n;
  const allowance = (bundle?.[1]?.result as bigint | undefined) ?? 0n;
  const lpShares = (bundle?.[2]?.result as bigint | undefined) ?? 0n;
  const heldCredentials = (bundle?.[3]?.result as readonly boolean[] | undefined) ?? [
    false,
    false,
    false,
    false,
    false,
  ];
  const oracleSourceId = (bundle?.[4]?.result as string | undefined) ?? "unknown";

  return {
    address,
    isConnected,
    chainId,
    deployment,
    pool,
    oracle,
    vusd,
    status: status as CreditStatus | undefined,
    stats: stats as PoolStats | undefined,
    vusdBalance,
    allowance,
    lpShares,
    heldCredentials,
    oracleSourceId,
    refetchAll,
  };
}

/**
 * Wraps a write + receipt wait into one call, refetching state once the tx confirms.
 *
 * Every action in the UI needs the same three things: fire the tx, know when it is pending,
 * and refresh once it lands. Centralising that here keeps the panels declarative.
 */
export function useTrustFlowAction(onConfirmed?: () => void) {
  const { writeContractAsync, data: hash, isPending, error, reset } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({
    hash,
    query: { enabled: Boolean(hash) },
  });

  // Refresh as soon as the receipt lands.
  useEffect(() => {
    if (isSuccess) onConfirmed?.();
  }, [isSuccess, onConfirmed]);

  return {
    writeContractAsync,
    hash,
    isPending,
    isConfirming,
    isBusy: isPending || isConfirming,
    isSuccess,
    error,
    reset,
  };
}

/** Approve the pool for the max amount if the current allowance is short. */
export function buildApproval(vusd: Address, pool: Address) {
  return {
    address: vusd,
    abi: cvaStablecoinAbi,
    functionName: "approve" as const,
    args: [pool, maxUint256] as const,
  };
}
