"use client";

import { useState } from "react";
import { formatUnits, maxUint256 } from "viem";

import { trustFlowPoolAbi, cvaStablecoinAbi } from "@/lib/abis";
import { fmtBps, fmtPct, fmtUsd, fmtUsdExact, toUnits } from "@/lib/format";
import { useTrustFlowAction, type PoolStats } from "@/hooks/useTrustFlow";
import { shortError } from "./AttestationPanel";

type Props = {
  pool?: `0x${string}`;
  vusd?: `0x${string}`;
  stats?: PoolStats;
  lpShares: bigint;
  vusdBalance: bigint;
  allowance: bigint;
  address?: `0x${string}`;
  isConnected: boolean;
  onConfirmed: () => void;
};

export function LpPanel({
  pool,
  vusd,
  stats,
  lpShares,
  vusdBalance,
  allowance,
  address,
  isConnected,
  onConfirmed,
}: Props) {
  const [mode, setMode] = useState<"deposit" | "withdraw">("deposit");
  const [amount, setAmount] = useState("0");
  const { writeContractAsync, isBusy, error } = useTrustFlowAction(onConfirmed);

  const amountWei = toUnits(amount);
  const cap = mode === "deposit" ? vusdBalance : lpShares;
  const needsApproval = mode === "deposit" && allowance < amountWei;

  // Share price above par is the yield LPs have earned so far.
  const sharePrice = stats?.sharePrice ?? 10n ** 18n;
  const yieldBps = ((sharePrice - 10n ** 18n) * 10_000n) / 10n ** 18n;
  const positionValue = (lpShares * sharePrice) / 10n ** 18n;

  const utilization = Number(stats?.utilizationBps ?? 0n) / 100;

  async function submit() {
    if (!pool || !vusd || !address || amountWei === 0n) return;
    try {
      if (needsApproval) {
        await writeContractAsync({
          address: vusd,
          abi: cvaStablecoinAbi,
          functionName: "approve",
          args: [pool, maxUint256],
        });
        return;
      }

      await writeContractAsync({
        address: pool,
        abi: trustFlowPoolAbi,
        functionName: mode === "deposit" ? "deposit" : "redeem",
        args: [amountWei, address],
      });
      setAmount("0");
    } catch {
      /* surfaced below */
    }
  }

  async function faucet() {
    if (!vusd) return;
    try {
      await writeContractAsync({
        address: vusd,
        abi: cvaStablecoinAbi,
        functionName: "faucet",
        args: [],
      });
    } catch {
      /* surfaced below */
    }
  }

  return (
    <section className="card">
      <header className="card-head">
        <div>
          <h2 className="card-title">Liquidity Pool</h2>
          <p className="card-sub">Fund the pool, earn borrower interest</p>
        </div>
        <div className="flex rounded-lg border border-white/[0.07] bg-ink-950/50 p-0.5">
          {(["deposit", "withdraw"] as const).map((m) => (
            <button
              key={m}
              onClick={() => {
                setMode(m);
                setAmount("0");
              }}
              className={`rounded-md px-2.5 py-1.5 text-xs font-medium capitalize transition ${
                mode === m ? "bg-white/[0.09] text-slate-100" : "text-slate-500 hover:text-slate-300"
              }`}
            >
              {m}
            </button>
          ))}
        </div>
      </header>

      <div className="space-y-4 p-5">
        {/* Utilization gauge */}
        <div>
          <div className="mb-1.5 flex items-baseline justify-between">
            <span className="stat-label">Pool utilization</span>
            <span className="tnum text-sm font-semibold text-slate-100">
              {utilization.toFixed(1)}%
            </span>
          </div>
          <div className="relative h-2 overflow-hidden rounded-full bg-white/[0.06]">
            <div
              className="h-full rounded-full bg-gradient-to-r from-iris-500 to-mint-500 transition-[width] duration-700 ease-out"
              style={{ width: `${Math.min(100, utilization)}%` }}
            />
            {/* Kink marker: the rate curve steepens sharply past 80%. */}
            <div
              className="absolute top-0 h-full w-px bg-amber-400/70"
              style={{ left: "80%" }}
              title="Rate curve kink at 80%"
            />
          </div>
          <div className="mt-1 flex justify-between text-[10px] text-slate-600">
            <span>{fmtUsd(stats?.totalBorrows)} borrowed</span>
            <span>{fmtUsd(stats?.totalAssets)} supplied</span>
          </div>
        </div>

        <div className="grid grid-cols-3 gap-2">
          <Stat label="Your position" value={`${fmtUsd(positionValue)}`} unit="vUSD" />
          <Stat label="Share price" value={fmtUsdExact(sharePrice, 5)} tone="mint" />
          <Stat label="Pool yield" value={fmtBps(yieldBps, 3)} tone="mint" />
        </div>

        <div>
          <div className="mb-2 flex items-baseline justify-between">
            <label className="stat-label">
              {mode === "deposit" ? "Deposit vUSD" : "Redeem shares"}
            </label>
            <button
              onClick={() => setAmount(formatUnits(cap, 18))}
              disabled={cap === 0n}
              className="text-[11px] font-medium text-mint-400 hover:text-mint-300 disabled:opacity-40"
            >
              Max {fmtUsd(cap)}
            </button>
          </div>
          <div className="relative">
            <input
              type="text"
              inputMode="decimal"
              value={amount}
              onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ""))}
              className="input pr-20 text-lg font-semibold tnum"
              placeholder="0.00"
            />
            <span className="absolute right-3.5 top-1/2 -translate-y-1/2 text-sm font-medium text-slate-500">
              {mode === "deposit" ? "vUSD" : "tfvUSD"}
            </span>
          </div>
        </div>

        <div className="flex gap-2">
          <button
            onClick={submit}
            disabled={!isConnected || isBusy || amountWei === 0n}
            className="btn-primary flex-1"
          >
            {isBusy
              ? "Confirming…"
              : needsApproval
                ? "Approve vUSD"
                : mode === "deposit"
                  ? "Supply liquidity"
                  : "Withdraw"}
          </button>
          <button
            onClick={faucet}
            disabled={!isConnected || isBusy}
            className="btn-secondary shrink-0"
            title="Mint 10,000 test vUSD"
          >
            Faucet
          </button>
        </div>

        <div className="flex items-center justify-between border-t border-white/[0.05] pt-3 text-xs text-slate-500">
          <span>
            Wallet: <span className="tnum text-slate-300">{fmtUsd(vusdBalance)} vUSD</span>
          </span>
          <span>
            Idle liquidity:{" "}
            <span className="tnum text-slate-300">{fmtUsd(stats?.availableLiquidity)} vUSD</span>
          </span>
        </div>

        {stats && stats.totalCollateral > 0n && (
          <p className="text-[11px] leading-relaxed text-slate-600">
            {fmtUsd(stats.totalCollateral)} vUSD of borrower collateral is escrowed separately and
            is never lent out, so it does not affect the share price or the{" "}
            {fmtPct(stats.utilizationBps, 1)} utilization above.
          </p>
        )}

        {error && (
          <p className="rounded-lg bg-rose-500/10 px-3 py-2 text-xs text-rose-400">
            {shortError(error.message)}
          </p>
        )}
      </div>
    </section>
  );
}

function Stat({
  label,
  value,
  unit,
  tone,
}: {
  label: string;
  value: string;
  unit?: string;
  tone?: "mint";
}) {
  return (
    <div className="rounded-xl border border-white/[0.06] bg-white/[0.02] px-3 py-2.5">
      <div className="stat-label">{label}</div>
      <div
        className={`tnum mt-0.5 text-sm font-semibold ${tone === "mint" ? "text-mint-400" : "text-slate-100"}`}
      >
        {value}
        {unit && <span className="ml-1 text-[10px] font-normal text-slate-600">{unit}</span>}
      </div>
    </div>
  );
}
