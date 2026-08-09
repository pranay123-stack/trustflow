"use client";

import { useTrustFlow } from "@/hooks/useTrustFlow";
import { ConnectButton } from "@/components/ConnectButton";
import { TrustDial } from "@/components/TrustDial";
import { AttestationPanel } from "@/components/AttestationPanel";
import { BorrowPanel } from "@/components/BorrowPanel";
import { LpPanel } from "@/components/LpPanel";
import { ActivityFeed } from "@/components/ActivityFeed";
import { ComplianceCard } from "@/components/ComplianceCard";
import { CreditCurveChart } from "@/components/CreditCurveChart";
import { CvaAssetCard } from "@/components/CvaAssetCard";
import { fmtBps, fmtUsd } from "@/lib/format";

export default function Home() {
  const tf = useTrustFlow();
  const {
    status,
    stats,
    deployment,
    isConnected,
    chainId,
    oracleSourceId,
    heldCredentials,
    refetchAll,
  } = tf;

  return (
    <main className="mx-auto min-h-screen w-full max-w-[1400px] px-4 py-6 sm:px-6 lg:px-8">
      <Header oracleSourceId={oracleSourceId} />

      {!deployment ? (
        <NotDeployed chainId={chainId} />
      ) : (
        <>
          <PoolRibbon stats={stats} />

          <div className="mt-5 grid grid-cols-1 gap-5 lg:grid-cols-12">
            {/* ---- Hero: the dial ---- */}
            <div className="lg:col-span-4">
              <section className="card sticky top-6 p-6">
                <TrustDial
                  trustScoreBps={status?.trustScoreBps ?? 0n}
                  cviTier={status?.cviTier ?? 0}
                  cviScore={status?.cviScore ?? 0}
                  availableCredit={status?.available ?? 0n}
                  maxBorrow={status?.maxBorrow ?? 0n}
                  rateBps={status?.rateBps ?? 0n}
                  unsecuredShareBps={status?.unsecuredShareBps ?? 0n}
                  isVerified={status?.isVerified ?? false}
                  isConnected={isConnected}
                />
              </section>
            </div>

            {/* ---- Actions ---- */}
            <div className="space-y-5 lg:col-span-5">
              <AttestationPanel
                oracle={tf.oracle}
                held={heldCredentials}
                cviTier={status?.cviTier ?? 0}
                cviScore={status?.cviScore ?? 0}
                collateral={status?.collateral ?? 0n}
                isConnected={isConnected}
                isVerified={status?.isVerified ?? false}
                onConfirmed={refetchAll}
              />
              <BorrowPanel
                pool={tf.pool}
                vusd={tf.vusd}
                address={tf.address}
                status={status}
                stats={stats}
                allowance={tf.allowance}
                vusdBalance={tf.vusdBalance}
                isConnected={isConnected}
                onConfirmed={refetchAll}
              />
              <CreditCurveChart currentTier={status?.cviTier ?? 0} />
            </div>

            {/* ---- Pool + activity ---- */}
            <div className="space-y-5 lg:col-span-3">
              <LpPanel
                pool={tf.pool}
                vusd={tf.vusd}
                stats={stats}
                lpShares={tf.lpShares}
                vusdBalance={tf.vusdBalance}
                allowance={tf.allowance}
                address={tf.address}
                isConnected={isConnected}
                onConfirmed={refetchAll}
              />
              <div className="h-[380px]">
                <ActivityFeed pool={tf.pool} chainId={chainId} />
              </div>
            </div>

            <div className="lg:col-span-12">
              <CvaAssetCard
                vusd={tf.vusd}
                cvaPolicy={tf.deployment?.cvaPolicy}
                address={tf.address}
              />
            </div>

            <div className="lg:col-span-12">
              <ComplianceCard />
            </div>
          </div>
        </>
      )}

      <Footer deployment={deployment} />
    </main>
  );
}

function Header({ oracleSourceId }: { oracleSourceId: string }) {
  const isLive = oracleSourceId.startsWith("cleanverse");

  return (
    <header className="flex flex-wrap items-center justify-between gap-4">
      <div className="flex items-center gap-3">
        <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-gradient-to-br from-iris-500 to-mint-500 shadow-glow">
          <svg width="20" height="20" viewBox="0 0 20 20" fill="none" aria-hidden>
            <path
              d="M10 2l6.5 3v5c0 4-2.8 7.5-6.5 8.5C6.3 17.5 3.5 14 3.5 10V5L10 2z"
              fill="rgba(6,8,15,0.35)"
            />
            <path
              d="M6.8 10.2l2.2 2.2 4.4-4.6"
              stroke="#06080f"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>
        </div>
        <div>
          <h1 className="text-lg font-bold tracking-tight text-slate-50">TrustFlow</h1>
          <p className="text-xs text-slate-500">
            Undercollateralized credit — CVI identity, CVA assets · Monad
          </p>
        </div>
      </div>

      <div className="flex items-center gap-2">
        <span
          className={`chip ${
            isLive
              ? "border-mint-500/25 bg-mint-500/10 text-mint-400"
              : "border-amber-500/25 bg-amber-500/10 text-amber-400"
          }`}
          title="Which attestation feed the pool is currently reading"
        >
          {isLive ? "Live Cleanverse feed" : "Mock attestation feed"}
        </span>
        <ConnectButton />
      </div>
    </header>
  );
}

function PoolRibbon({ stats }: { stats?: { totalAssets: bigint; totalBorrows: bigint; availableLiquidity: bigint; utilizationBps: bigint; totalCollateral: bigint } }) {
  const items = [
    { label: "Total supplied", value: `${fmtUsd(stats?.totalAssets)} vUSD` },
    { label: "Total borrowed", value: `${fmtUsd(stats?.totalBorrows)} vUSD` },
    { label: "Available", value: `${fmtUsd(stats?.availableLiquidity)} vUSD` },
    { label: "Utilization", value: fmtBps(stats?.utilizationBps, 1) },
    { label: "Escrowed collateral", value: `${fmtUsd(stats?.totalCollateral)} vUSD` },
  ];

  return (
    <div className="mt-6 grid grid-cols-2 gap-px overflow-hidden rounded-2xl border border-white/[0.06] bg-white/[0.05] sm:grid-cols-3 lg:grid-cols-5">
      {items.map((i) => (
        <div key={i.label} className="bg-ink-900/80 px-4 py-3.5">
          <div className="stat-label">{i.label}</div>
          <div className="stat-value mt-0.5">{i.value}</div>
        </div>
      ))}
    </div>
  );
}

function NotDeployed({ chainId }: { chainId: number }) {
  return (
    <div className="card mt-8 p-8 text-center">
      <h2 className="text-base font-semibold text-slate-100">No deployment found for this chain</h2>
      <p className="mx-auto mt-2 max-w-lg text-sm text-slate-500">
        TrustFlow has no recorded addresses for chain {chainId}. Deploy the contracts, then
        regenerate the frontend bindings:
      </p>
      <pre className="mx-auto mt-4 w-fit rounded-xl border border-white/[0.07] bg-ink-950/70 px-4 py-3 text-left font-mono text-xs leading-relaxed text-slate-400">
        {`# from the repo root
make anvil          # terminal 1
make deploy-local   # terminal 2
make web`}
      </pre>
    </div>
  );
}

function Footer({ deployment }: { deployment: { trustFlowPool: string; attestationOracle: string } | null }) {
  return (
    <footer className="mt-8 flex flex-wrap items-center justify-between gap-3 border-t border-white/[0.05] pt-5 text-[11px] text-slate-600">
      <span>
        TrustFlow · Cleanverse &ldquo;Verified Finance&rdquo; hackathon · DeFi track. Testnet only —
        vUSD has no value.
      </span>
      {deployment && (
        <span className="font-mono">
          pool {deployment.trustFlowPool.slice(0, 10)}… · oracle{" "}
          {deployment.attestationOracle.slice(0, 10)}…
        </span>
      )}
    </footer>
  );
}
