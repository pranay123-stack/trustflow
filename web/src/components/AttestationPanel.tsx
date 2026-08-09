"use client";

import { useState } from "react";
import { attestationOracleAbi } from "@/lib/abis";
import { CREDENTIALS } from "@/lib/contracts";
import { maxBorrow, reputationLine, trustScoreBps } from "@/lib/creditCurve";
import { fmtUsd } from "@/lib/format";
import { useTrustFlowAction } from "@/hooks/useTrustFlow";

type Props = {
  oracle?: `0x${string}`;
  held: readonly boolean[];
  cviTier: number;
  cviScore: number;
  collateral: bigint;
  isConnected: boolean;
  isVerified: boolean;
  onConfirmed: () => void;
};

/**
 * Each button is a real credential from the Cleanverse catalogue. Claiming one raises the CVI
 * tier and credential score on the mock CVI oracle, which the dial picks up on its next poll.
 *
 * The "+N vUSD" preview under each button is computed locally with the TypeScript mirror of the
 * on-chain credit curve, so the borrower can see what a credential is worth before signing.
 */
export function AttestationPanel({
  oracle,
  held,
  cviTier,
  cviScore,
  collateral,
  isConnected,
  isVerified,
  onConfirmed,
}: Props) {
  const [pendingId, setPendingId] = useState<number | null>(null);
  const { writeContractAsync, isBusy, error } = useTrustFlowAction(onConfirmed);

  const currentLimit = maxBorrow(cviTier, cviScore, collateral);

  async function claim(id: number) {
    if (!oracle) return;
    setPendingId(id);
    try {
      await writeContractAsync({
        address: oracle,
        abi: attestationOracleAbi,
        functionName: "attest",
        args: [id],
      });
    } catch {
      // Surfaced via `error` below; nothing to do here.
    } finally {
      setPendingId(null);
    }
  }

  async function reset() {
    if (!oracle) return;
    try {
      await writeContractAsync({
        address: oracle,
        abi: attestationOracleAbi,
        functionName: "resetForDemo",
        args: [],
      });
    } catch {
      /* surfaced below */
    }
  }

  const allHeld = held.every(Boolean);

  return (
    <section className="card">
      <header className="card-head">
        <div>
          <h2 className="card-title">Identity Attestations</h2>
          <p className="card-sub">Each credential raises your CVI tier and credential score</p>
        </div>
        {isConnected && held.some(Boolean) && (
          <button onClick={reset} className="btn-ghost !px-2.5 !py-1.5 text-xs" disabled={isBusy}>
            Reset
          </button>
        )}
      </header>

      <div className="space-y-2 p-4">
        {CREDENTIALS.map((cred) => {
          const isHeld = held[cred.id] ?? false;

          // What this credential would unlock, computed with the same math the chain uses.
          const nextTier = Math.max(cviTier, cred.minTier);
          const nextScore = Math.min(1000, cviScore + cred.scoreDelta);
          const gain = maxBorrow(nextTier, nextScore, collateral) - currentLimit;
          const scoreGain = Number(trustScoreBps(nextTier, nextScore) - trustScoreBps(cviTier, cviScore));

          return (
            <button
              key={cred.id}
              onClick={() => claim(cred.id)}
              disabled={!isConnected || isHeld || isBusy}
              className={`group flex w-full items-center gap-3 rounded-xl border px-3.5 py-3 text-left
                          transition-all duration-150
                ${
                  isHeld
                    ? "border-mint-500/25 bg-mint-500/[0.07]"
                    : "border-white/[0.07] bg-white/[0.02] hover:border-mint-500/40 hover:bg-mint-500/[0.06] active:scale-[0.99]"
                }
                disabled:cursor-not-allowed ${!isConnected ? "opacity-40" : ""}`}
            >
              <span
                className={`flex h-8 w-8 shrink-0 items-center justify-center rounded-lg text-xs font-bold
                  ${isHeld ? "bg-mint-500 text-ink-950" : "bg-white/[0.06] text-slate-400 group-hover:bg-mint-500/20 group-hover:text-mint-400"}`}
              >
                {isHeld ? <CheckIcon /> : `+${cred.scoreDelta}`}
              </span>

              <span className="min-w-0 flex-1">
                <span className="flex items-center gap-2">
                  <span className="truncate text-sm font-medium text-slate-100">{cred.name}</span>
                  {cred.minTier > cviTier && !isHeld && (
                    <span className="chip border-iris-500/30 bg-iris-500/10 text-iris-400">
                      unlocks tier {cred.minTier}
                    </span>
                  )}
                </span>
                <span className="mt-0.5 block truncate text-xs text-slate-500">{cred.detail}</span>
              </span>

              <span className="shrink-0 text-right">
                {isHeld ? (
                  <span className="text-[11px] font-medium text-mint-400">Verified</span>
                ) : pendingId === cred.id && isBusy ? (
                  <span className="text-[11px] text-slate-400">Signing…</span>
                ) : gain === 0n && !isVerified ? (
                  // A credential that raises no tier adds no borrowing power on a cold wallet
                  // (tier 0 has a zero unsecured ceiling). But it is what opens the compliance
                  // gate, so say that instead of a misleading "+0".
                  <>
                    <span className="block text-sm font-semibold text-amber-400">Opens gate</span>
                    <span className="block text-[10px] text-slate-600">
                      +{(scoreGain / 100).toFixed(0)} trust
                    </span>
                  </>
                ) : (
                  <>
                    <span className="tnum block text-sm font-semibold text-mint-400">
                      +{fmtUsd(gain)}
                    </span>
                    <span className="block text-[10px] text-slate-600">
                      +{(scoreGain / 100).toFixed(0)} trust
                    </span>
                  </>
                )}
              </span>
            </button>
          );
        })}

        {allHeld && isConnected && (
          <div className="animate-fade-up rounded-xl border border-mint-500/25 bg-mint-500/[0.07] px-3.5 py-3 text-center">
            <p className="text-sm font-semibold text-mint-400">Fully verified — Tier 3</p>
            <p className="mt-0.5 text-xs text-slate-400">
              Maximum unsecured line of {fmtUsd(reputationLine(3, 1000))} vUSD, no collateral
              required.
            </p>
          </div>
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

function CheckIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 14 14" fill="none" aria-hidden>
      <path
        d="M2.5 7.5L5.5 10.5L11.5 3.5"
        stroke="currentColor"
        strokeWidth="2.2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

/** Wallet errors are enormous; the first line is the only useful part. */
export function shortError(message: string): string {
  const firstLine = message.split("\n")[0];
  return firstLine.length > 140 ? `${firstLine.slice(0, 140)}…` : firstLine;
}
