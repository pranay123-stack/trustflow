"use client";

import { useAnimatedValue, useAnimatedTokenAmount, usePulse } from "@/hooks/useAnimatedValue";
import { TIER_LABELS, TIER_BLURBS } from "@/lib/creditCurve";
import { fmtBps, fmtPct } from "@/lib/format";

type Props = {
  trustScoreBps: bigint;
  cviTier: number;
  cviScore: number;
  availableCredit: bigint;
  maxBorrow: bigint;
  rateBps: bigint;
  unsecuredShareBps: bigint;
  isVerified: boolean;
  isConnected: boolean;
};

// 270-degree sweep, starting at the lower-left. A full circle would make "empty" and "full"
// indistinguishable at a glance; the gap gives the eye a fixed reference.
const SWEEP = 270;
const START_ANGLE = 135;
const RADIUS = 108;
const STROKE = 16;
const SIZE = 280;

function polar(cx: number, cy: number, r: number, angleDeg: number) {
  const rad = ((angleDeg - 90) * Math.PI) / 180;
  return { x: cx + r * Math.cos(rad), y: cy + r * Math.sin(rad) };
}

function arcPath(cx: number, cy: number, r: number, startDeg: number, endDeg: number) {
  const start = polar(cx, cy, r, endDeg);
  const end = polar(cx, cy, r, startDeg);
  const largeArc = endDeg - startDeg <= 180 ? 0 : 1;
  return `M ${start.x} ${start.y} A ${r} ${r} 0 ${largeArc} 0 ${end.x} ${end.y}`;
}

export function TrustDial({
  trustScoreBps,
  cviTier,
  cviScore,
  availableCredit,
  maxBorrow,
  rateBps,
  unsecuredShareBps,
  isVerified,
  isConnected,
}: Props) {
  const targetScore = Number(trustScoreBps);
  const animatedScore = useAnimatedValue(targetScore);
  const animatedCredit = useAnimatedTokenAmount(availableCredit);
  const pulsing = usePulse(targetScore);

  const pct = Math.max(0, Math.min(1, animatedScore / 10_000));
  const cx = SIZE / 2;
  const cy = SIZE / 2;

  const trackPath = arcPath(cx, cy, RADIUS, START_ANGLE, START_ANGLE + SWEEP);
  const arcLength = (SWEEP / 360) * 2 * Math.PI * RADIUS;

  const tier = Math.max(0, Math.min(3, cviTier));
  const needleAngle = START_ANGLE + SWEEP * pct;
  const needle = polar(cx, cy, RADIUS, needleAngle);

  return (
    <div className="relative flex flex-col items-center">
      {/* Celebration ring, fired whenever the score changes. */}
      {pulsing && (
        <span
          aria-hidden
          className="pointer-events-none absolute top-[14px] h-[252px] w-[252px] animate-pulse-ring
                     rounded-full border-2 border-mint-400/50"
        />
      )}

      <svg
        width={SIZE}
        height={SIZE}
        viewBox={`0 0 ${SIZE} ${SIZE}`}
        role="img"
        aria-label={`Trust score ${(targetScore / 100).toFixed(0)} out of 100`}
      >
        <defs>
          <linearGradient id="dialGradient" x1="0%" y1="100%" x2="100%" y2="0%">
            <stop offset="0%" stopColor="#6d6ef5" />
            <stop offset="55%" stopColor="#4ade9f" />
            <stop offset="100%" stopColor="#22c98a" />
          </linearGradient>
          <filter id="dialGlow" x="-50%" y="-50%" width="200%" height="200%">
            <feGaussianBlur stdDeviation="6" result="blur" />
            <feMerge>
              <feMergeNode in="blur" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>
        </defs>

        {/* Track */}
        <path
          d={trackPath}
          fill="none"
          stroke="rgba(255,255,255,0.06)"
          strokeWidth={STROKE}
          strokeLinecap="round"
        />

        {/* Tier boundary ticks at 25 / 50 / 75 */}
        {[0.25, 0.5, 0.75].map((f) => {
          const a = START_ANGLE + SWEEP * f;
          const outer = polar(cx, cy, RADIUS + STROKE / 2 + 5, a);
          const inner = polar(cx, cy, RADIUS + STROKE / 2 + 1, a);
          return (
            <line
              key={f}
              x1={inner.x}
              y1={inner.y}
              x2={outer.x}
              y2={outer.y}
              stroke="rgba(255,255,255,0.16)"
              strokeWidth={2}
              strokeLinecap="round"
            />
          );
        })}

        {/* Progress */}
        <path
          d={trackPath}
          fill="none"
          stroke="url(#dialGradient)"
          strokeWidth={STROKE}
          strokeLinecap="round"
          strokeDasharray={arcLength}
          strokeDashoffset={arcLength * (1 - pct)}
          filter="url(#dialGlow)"
        />

        {/* Head marker */}
        {pct > 0.008 && (
          <circle cx={needle.x} cy={needle.y} r={5.5} fill="#eafff5" stroke="#12a874" strokeWidth={2.5} />
        )}

        {/* Centre readout */}
        <text
          x={cx}
          y={cy - 12}
          textAnchor="middle"
          className="fill-slate-100 tnum"
          style={{ fontSize: 52, fontWeight: 700, letterSpacing: "-0.03em" }}
        >
          {(animatedScore / 100).toFixed(0)}
        </text>
        <text
          x={cx}
          y={cy + 12}
          textAnchor="middle"
          className="fill-slate-500"
          style={{ fontSize: 11, fontWeight: 600, letterSpacing: "0.14em" }}
        >
          TRUST SCORE
        </text>
        <text
          x={cx}
          y={cy + 44}
          textAnchor="middle"
          className={isVerified ? "fill-mint-400" : "fill-slate-600"}
          style={{ fontSize: 13, fontWeight: 600 }}
        >
          {TIER_LABELS[tier]}
        </text>
      </svg>

      {/* Available credit -- the number judges will watch climb. */}
      <div className="-mt-3 flex flex-col items-center">
        <span className="stat-label">Available Credit</span>
        <div className="flex items-baseline gap-1.5">
          <span
            className={`tnum text-4xl font-bold tracking-tight transition-colors duration-500 ${
              animatedCredit > 0 ? "text-mint-400" : "text-slate-600"
            }`}
          >
            {animatedCredit.toLocaleString("en-US", {
              minimumFractionDigits: 0,
              maximumFractionDigits: 0,
            })}
          </span>
          <span className="text-sm font-medium text-slate-500">vUSD</span>
        </div>
      </div>

      {/* Supporting metrics */}
      <div className="mt-5 grid w-full grid-cols-3 gap-2">
        <Metric label="CVI Tier" value={isConnected ? `${tier} / 3` : "--"} />
        <Metric label="CVI Score" value={isConnected ? `${cviScore}` : "--"} sub="/ 1000" />
        <Metric
          label="Your APR"
          value={isConnected && maxBorrow > 0n ? fmtBps(rateBps) : "--"}
          tone="mint"
        />
      </div>

      <p className="mt-4 max-w-[300px] text-center text-xs leading-relaxed text-slate-500">
        {isConnected ? TIER_BLURBS[tier] : "Connect a wallet to see your identity-derived credit line."}
      </p>

      {isConnected && tier > 0 && (
        <div className="mt-3 chip border-mint-500/25 bg-mint-500/10 text-mint-400">
          <span className="h-1.5 w-1.5 rounded-full bg-mint-400" />
          Up to {fmtPct(unsecuredShareBps)} of this line is unsecured
        </div>
      )}
    </div>
  );
}

function Metric({
  label,
  value,
  sub,
  tone,
}: {
  label: string;
  value: string;
  sub?: string;
  tone?: "mint";
}) {
  return (
    <div className="rounded-xl border border-white/[0.06] bg-white/[0.02] px-3 py-2.5 text-center">
      <div className="stat-label">{label}</div>
      <div
        className={`tnum mt-0.5 text-sm font-semibold ${
          tone === "mint" ? "text-mint-400" : "text-slate-100"
        }`}
      >
        {value}
        {sub && <span className="ml-0.5 text-[10px] font-normal text-slate-600">{sub}</span>}
      </div>
    </div>
  );
}
