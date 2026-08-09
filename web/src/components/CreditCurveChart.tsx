"use client";

import { creditCurvePoints, TIER_LABELS } from "@/lib/creditCurve";
import { fmtUsd, fmtPct } from "@/lib/format";

/**
 * The credit curve, drawn. Shows every tier's unsecured line as a band from its CVA-0 floor to
 * its CVA-1000 ceiling, with the borrower's current tier highlighted.
 *
 * The point being made: borrowing power is a published, deterministic function of verified
 * identity — not a discretionary underwriting decision.
 */
export function CreditCurveChart({ currentTier }: { currentTier: number }) {
  // Rendered against a zero-collateral borrower so the bars show pure reputation credit.
  const points = creditCurvePoints(0n);
  const ceiling = points.reduce((m, p) => (p.maxLine > m ? p.maxLine : m), 1n);

  return (
    <section className="card">
      <header className="card-head">
        <div>
          <h2 className="card-title">The Credit Curve</h2>
          <p className="card-sub">Unsecured line by CVI tier, with no collateral posted</p>
        </div>
      </header>

      <div className="space-y-3 p-5">
        {points.map((p) => {
          const isCurrent = p.tier === currentTier;
          const floorPct = Number((p.minLine * 1000n) / ceiling) / 10;
          const ceilPct = Number((p.maxLine * 1000n) / ceiling) / 10;

          return (
            <div key={p.tier}>
              <div className="mb-1 flex items-baseline justify-between gap-2">
                <span
                  className={`text-xs font-medium ${isCurrent ? "text-mint-400" : "text-slate-400"}`}
                >
                  Tier {p.tier} · {TIER_LABELS[p.tier]}
                  {isCurrent && <span className="ml-1.5 text-[10px] text-mint-500">you</span>}
                </span>
                <span className="tnum text-[11px] text-slate-500">
                  {p.maxLine === 0n ? "collateral only" : `up to ${fmtUsd(p.maxLine)} vUSD`}
                </span>
              </div>

              <div className="relative h-6 overflow-hidden rounded-lg bg-white/[0.04]">
                {/* CVA-0 floor */}
                <div
                  className={`absolute inset-y-0 left-0 ${
                    isCurrent ? "bg-mint-600/60" : "bg-iris-600/35"
                  }`}
                  style={{ width: `${floorPct}%` }}
                />
                {/* CVA band, floor -> ceiling */}
                <div
                  className={`absolute inset-y-0 ${
                    isCurrent
                      ? "bg-gradient-to-r from-mint-600/60 to-mint-400/80"
                      : "bg-gradient-to-r from-iris-600/35 to-iris-400/45"
                  }`}
                  style={{ left: `${floorPct}%`, width: `${Math.max(0, ceilPct - floorPct)}%` }}
                />
                <div className="absolute inset-y-0 left-2 flex items-center">
                  <span className="text-[10px] font-semibold text-white/70">
                    {fmtPct(p.unsecuredShareBps)} unsecured
                  </span>
                </div>
                <div className="absolute inset-y-0 right-2 flex items-center">
                  <span className="tnum text-[10px] text-slate-500">
                    {(p.ltvBps / 100).toFixed(0)}% LTV on collateral
                  </span>
                </div>
              </div>
            </div>
          );
        })}

        <p className="pt-1 text-[11px] leading-relaxed text-slate-600">
          The solid segment is what a borrower gets at CVA 0; the gradient is the band the CVA
          score scales through up to 1000. Posting collateral adds to these lines at the LTV shown
          on the right — tier 3 levers collateral 8× because 90% of its line may be unsecured.
        </p>
      </div>
    </section>
  );
}
