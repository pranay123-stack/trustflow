"use client";

import { useMemo, useState } from "react";
import { formatUnits, maxUint256 } from "viem";

import { trustFlowPoolAbi, cvaStablecoinAbi } from "@/lib/abis";
import { borrowRateBps } from "@/lib/creditCurve";
import { fmtBps, fmtUsd, fmtUsdExact, fmtHealth, healthTone, toUnits } from "@/lib/format";
import { useTrustFlowAction, type CreditStatus, type PoolStats } from "@/hooks/useTrustFlow";
import { shortError } from "./AttestationPanel";

type Props = {
  pool?: `0x${string}`;
  vusd?: `0x${string}`;
  address?: `0x${string}`;
  status?: CreditStatus;
  stats?: PoolStats;
  allowance: bigint;
  vusdBalance: bigint;
  isConnected: boolean;
  onConfirmed: () => void;
};

type Tab = "borrow" | "repay" | "collateral";

export function BorrowPanel({
  pool,
  vusd,
  address,
  status,
  stats,
  allowance,
  vusdBalance,
  isConnected,
  onConfirmed,
}: Props) {
  const [tab, setTab] = useState<Tab>("borrow");
  const [amount, setAmount] = useState("0");
  const { writeContractAsync, isBusy, error } = useTrustFlowAction(onConfirmed);

  const available = status?.available ?? 0n;
  const liquidity = stats?.availableLiquidity ?? 0n;

  // The slider can never offer more than the protocol would actually allow: the borrower's
  // remaining headroom, capped by what the pool has on hand.
  const borrowCap = available < liquidity ? available : liquidity;
  const cap = tab === "borrow" ? borrowCap : tab === "repay" ? (status?.debt ?? 0n) : vusdBalance;

  const capFloat = Number(formatUnits(cap, 18));
  const amountNum = Number(amount) || 0;
  const amountWei = toUnits(amount);
  const progress = capFloat > 0 ? Math.min(100, (amountNum / capFloat) * 100) : 0;

  // Live preview: what the rate becomes at the utilization this draw would create.
  const projectedRate = useMemo(() => {
    if (!status || !stats) return 0n;
    const gross = stats.cash + stats.totalBorrows;
    if (gross === 0n) return status.rateBps;
    const newBorrows = stats.totalBorrows + (tab === "borrow" ? amountWei : 0n);
    const util = (newBorrows * 10_000n) / gross;
    return borrowRateBps(status.cviTier, status.cviScore, util);
  }, [status, stats, amountWei, tab]);

  const needsApproval = (tab === "repay" || tab === "collateral") && allowance < amountWei;

  // The slider is capped, but the text field accepts anything. Without this the user can type
  // past their limit, get an enabled button, and eat an on-chain revert.
  const exceedsCap = amountWei > cap;

  async function submit() {
    if (!pool || !vusd || amountWei === 0n) return;

    try {
      if (needsApproval) {
        await writeContractAsync({
          address: vusd,
          abi: cvaStablecoinAbi,
          functionName: "approve",
          args: [pool, maxUint256],
        });
        return; // Let the user confirm the action itself as a second, explicit step.
      }

      if (tab === "borrow") {
        await writeContractAsync({
          address: pool,
          abi: trustFlowPoolAbi,
          functionName: "borrow",
          args: [amountWei],
        });
      } else if (tab === "repay") {
        if (!address) return;
        await writeContractAsync({
          address: pool,
          abi: trustFlowPoolAbi,
          functionName: "repay",
          // Clearing the position uses max-uint so interest accruing in the pending block is
          // covered too; the contract caps the charge at the actual debt.
          args: [address, status?.debt === amountWei ? maxUint256 : amountWei],
        });
      } else {
        await writeContractAsync({
          address: pool,
          abi: trustFlowPoolAbi,
          functionName: "postCollateral",
          args: [amountWei],
        });
      }
      setAmount("0");
    } catch {
      /* surfaced below */
    }
  }

  const blocked = !status?.isVerified && tab === "borrow";

  return (
    <section className="card">
      <header className="card-head">
        <div>
          <h2 className="card-title">Credit Line</h2>
          <p className="card-sub">Draw against verified identity, not excess collateral</p>
        </div>
        <div className="flex rounded-lg border border-white/[0.07] bg-ink-950/50 p-0.5">
          {(["borrow", "repay", "collateral"] as Tab[]).map((t) => (
            <button
              key={t}
              onClick={() => {
                setTab(t);
                setAmount("0");
              }}
              className={`rounded-md px-2.5 py-1.5 text-xs font-medium capitalize transition ${
                tab === t ? "bg-white/[0.09] text-slate-100" : "text-slate-500 hover:text-slate-300"
              }`}
            >
              {t}
            </button>
          ))}
        </div>
      </header>

      <div className="space-y-4 p-5">
        {blocked && (
          <div className="flex items-start gap-2.5 rounded-xl border border-amber-500/25 bg-amber-500/[0.07] px-3.5 py-3">
            <span className="mt-0.5 text-amber-400">
              <LockIcon />
            </span>
            <div>
              <p className="text-sm font-medium text-amber-400">Compliance gate closed</p>
              <p className="mt-0.5 text-xs text-slate-400">
                Borrowing requires a live, unexpired, compliant attestation. Claim a credential to
                open your line. Repayment stays available regardless.
              </p>
            </div>
          </div>
        )}

        {/* Amount + slider */}
        <div>
          <div className="mb-2 flex items-baseline justify-between">
            <label className="stat-label">
              {tab === "borrow" ? "Borrow" : tab === "repay" ? "Repay" : "Post collateral"}
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
              className="input pr-16 text-lg font-semibold tnum"
              placeholder="0.00"
            />
            <span className="absolute right-3.5 top-1/2 -translate-y-1/2 text-sm font-medium text-slate-500">
              vUSD
            </span>
          </div>

          <input
            type="range"
            min={0}
            max={Math.max(capFloat, 0.000001)}
            step={capFloat / 200 || 0.01}
            value={Math.min(amountNum, capFloat)}
            onChange={(e) => setAmount(e.target.value)}
            disabled={cap === 0n}
            style={{ ["--range-progress" as string]: `${progress}%` }}
            className="mt-3 w-full"
            aria-label={`${tab} amount`}
          />
        </div>

        {/* Live terms */}
        <div className="grid grid-cols-2 gap-2">
          <Row
            label="Interest rate"
            // No wallet means no attestation to price against -- "0.00%" would read as a real
            // quote rather than an absent one.
            value={
              status ? fmtBps(tab === "borrow" ? projectedRate : status.rateBps) : "--"
            }
            tone="mint"
            hint={
              tab === "borrow" && status && status.trustScoreBps > 0n
                ? `−${fmtBps((status.trustScoreBps * 600n) / 10_000n)} trust rebate applied`
                : undefined
            }
          />
          <Row label="Credit limit" value={`${fmtUsd(status?.maxBorrow)} vUSD`} />
          <Row label="Current debt" value={`${fmtUsd(status?.debt)} vUSD`} />
          <Row
            label="Health factor"
            value={fmtHealth(status?.healthBps)}
            tone={healthTone(status?.healthBps)}
          />
        </div>

        {status && status.collateral > 0n && (
          <p className="text-xs text-slate-500">
            Collateral posted: <span className="tnum text-slate-300">{fmtUsdExact(status.collateral, 2)} vUSD</span>
            {" · "}
            Unsecured portion of your limit:{" "}
            <span className="tnum text-mint-400">
              {fmtUsd(status.maxBorrow > status.collateral ? status.maxBorrow - status.collateral : 0n)} vUSD
            </span>
          </p>
        )}

        {/* Explain the refusal rather than just greying the button out -- a disabled control
            with no reason reads as broken. */}
        {exceedsCap && !blocked && (
          <p className="rounded-lg bg-amber-500/10 px-3 py-2 text-xs text-amber-400">
            {tab === "borrow"
              ? available < liquidity
                ? `Exceeds your available credit of ${fmtUsd(cap)} vUSD. Claim another credential to raise it.`
                : `Exceeds the pool's idle liquidity of ${fmtUsd(cap)} vUSD.`
              : tab === "repay"
                ? `You only owe ${fmtUsd(cap)} vUSD.`
                : `Exceeds your wallet balance of ${fmtUsd(cap)} vUSD.`}
          </p>
        )}

        <button
          onClick={submit}
          disabled={
            !isConnected ||
            isBusy ||
            amountWei === 0n ||
            exceedsCap ||
            (tab === "borrow" && blocked)
          }
          className="btn-primary w-full"
        >
          {isBusy
            ? "Confirming…"
            : tab === "borrow" && blocked
              ? "Claim a credential to borrow"
              : needsApproval
                ? "Approve vUSD"
                : exceedsCap
                  ? "Amount exceeds limit"
                  : tab === "borrow"
                    ? `Borrow ${amountNum > 0 ? fmtUsd(amountWei) : ""} vUSD`
                    : tab === "repay"
                      ? "Repay"
                      : "Post collateral"}
        </button>

        {error && (
          <p className="rounded-lg bg-rose-500/10 px-3 py-2 text-xs text-rose-400">
            {shortError(error.message)}
          </p>
        )}
      </div>
    </section>
  );
}

function Row({
  label,
  value,
  tone,
  hint,
}: {
  label: string;
  value: string;
  tone?: "mint" | "safe" | "warn" | "danger";
  hint?: string;
}) {
  const toneClass =
    tone === "mint" || tone === "safe"
      ? "text-mint-400"
      : tone === "warn"
        ? "text-amber-400"
        : tone === "danger"
          ? "text-rose-400"
          : "text-slate-100";

  return (
    <div className="rounded-xl border border-white/[0.06] bg-white/[0.02] px-3 py-2.5">
      <div className="stat-label">{label}</div>
      <div className={`tnum mt-0.5 text-sm font-semibold ${toneClass}`}>{value}</div>
      {hint && <div className="mt-0.5 text-[10px] text-slate-600">{hint}</div>}
    </div>
  );
}

function LockIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 16 16" fill="none" aria-hidden>
      <rect x="3" y="7" width="10" height="7" rx="2" stroke="currentColor" strokeWidth="1.6" />
      <path d="M5.5 7V5a2.5 2.5 0 015 0v2" stroke="currentColor" strokeWidth="1.6" />
    </svg>
  );
}
