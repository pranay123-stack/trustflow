"use client";

import { useEffect, useState } from "react";
import { useWatchContractEvent, usePublicClient } from "wagmi";
import type { AbiEvent, Log } from "viem";

import { trustFlowPoolAbi } from "@/lib/abis";
import { fmtBps, fmtUsd, shortAddress } from "@/lib/format";
import { explorerTxUrl } from "@/lib/chains";

/** Event fragments only -- `getLogs` needs these to decode `eventName`/`args` on backfill. */
const POOL_EVENTS = trustFlowPoolAbi.filter((item) => item.type === "event") as AbiEvent[];

type Entry = {
  id: string;
  kind: "borrow" | "repay" | "deposit" | "redeem" | "liquidate" | "default";
  who: string;
  amount: bigint;
  detail?: string;
  blockNumber: bigint;
  txHash?: string;
};

const KIND_STYLE: Record<Entry["kind"], { label: string; dot: string; text: string }> = {
  borrow: { label: "Borrow", dot: "bg-mint-400", text: "text-mint-400" },
  repay: { label: "Repay", dot: "bg-iris-400", text: "text-iris-400" },
  deposit: { label: "Supply", dot: "bg-sky-400", text: "text-sky-400" },
  redeem: { label: "Withdraw", dot: "bg-slate-400", text: "text-slate-400" },
  liquidate: { label: "Liquidation", dot: "bg-rose-400", text: "text-rose-400" },
  default: { label: "Default", dot: "bg-amber-400", text: "text-amber-400" },
};

/**
 * Live protocol activity, built entirely from contract events.
 *
 * On mount it backfills recent history so the feed is never empty during a demo, then switches
 * to a live subscription for anything new.
 */
export function ActivityFeed({ pool, chainId }: { pool?: `0x${string}`; chainId: number }) {
  const [entries, setEntries] = useState<Entry[]>([]);
  const publicClient = usePublicClient();

  // --- backfill -------------------------------------------------------------
  useEffect(() => {
    if (!pool || !publicClient) return;
    let cancelled = false;

    (async () => {
      try {
        const latest = await publicClient.getBlockNumber();
        // Testnet RPCs commonly cap getLogs ranges; 5k blocks is comfortably inside every limit.
        const fromBlock = latest > 5_000n ? latest - 5_000n : 0n;

        const logs = await publicClient.getLogs({
          address: pool,
          events: POOL_EVENTS,
          fromBlock,
          toBlock: latest,
        });

        if (cancelled) return;
        const parsed = logs.flatMap((log) => decode(log)).slice(-40).reverse();
        setEntries(parsed);
      } catch {
        // A restricted RPC just means no backfill; the live subscription still works.
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [pool, publicClient]);

  // --- live -----------------------------------------------------------------
  useWatchContractEvent({
    address: pool,
    abi: trustFlowPoolAbi,
    onLogs(logs) {
      const fresh = logs.flatMap((log) => decode(log as unknown as Log));
      if (fresh.length === 0) return;
      setEntries((prev) => [...fresh.reverse(), ...prev].slice(0, 40));
    },
    enabled: Boolean(pool),
  });

  return (
    <section className="card flex h-full flex-col">
      <header className="card-head">
        <div>
          <h2 className="card-title">Live Activity</h2>
          <p className="card-sub">Every credit event, straight from chain logs</p>
        </div>
        <span className="chip border-mint-500/25 bg-mint-500/10 text-mint-400">
          <span className="relative flex h-1.5 w-1.5">
            <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-mint-400 opacity-75" />
            <span className="relative inline-flex h-1.5 w-1.5 rounded-full bg-mint-400" />
          </span>
          Live
        </span>
      </header>

      <div className="min-h-0 flex-1 overflow-y-auto">
        {entries.length === 0 ? (
          <p className="px-5 py-8 text-center text-xs text-slate-600">
            No activity yet. Claim a credential and draw against your line to see events appear
            here.
          </p>
        ) : (
          <ul className="divide-y divide-white/[0.04]">
            {entries.map((e) => {
              const style = KIND_STYLE[e.kind];
              const url = e.txHash ? explorerTxUrl(chainId, e.txHash) : null;
              const Row = (
                <>
                  <span className={`mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full ${style.dot}`} />
                  <span className="min-w-0 flex-1">
                    <span className="flex items-baseline justify-between gap-2">
                      <span className={`text-xs font-semibold ${style.text}`}>{style.label}</span>
                      <span className="tnum text-xs font-semibold text-slate-200">
                        {fmtUsd(e.amount)} vUSD
                      </span>
                    </span>
                    <span className="mt-0.5 flex items-baseline justify-between gap-2">
                      <span className="font-mono text-[11px] text-slate-500">
                        {shortAddress(e.who)}
                      </span>
                      {e.detail && <span className="text-[10px] text-slate-600">{e.detail}</span>}
                    </span>
                  </span>
                </>
              );

              return (
                <li key={e.id}>
                  {url ? (
                    <a
                      href={url}
                      target="_blank"
                      rel="noreferrer"
                      className="flex animate-fade-up items-start gap-2.5 px-5 py-3 transition hover:bg-white/[0.03]"
                    >
                      {Row}
                    </a>
                  ) : (
                    <div className="flex animate-fade-up items-start gap-2.5 px-5 py-3">{Row}</div>
                  )}
                </li>
              );
            })}
          </ul>
        )}
      </div>
    </section>
  );
}

/** Map a raw log onto a feed entry. Unrecognised events are dropped. */
function decode(log: Log): Entry[] {
  const decoded = log as unknown as {
    eventName?: string;
    args?: Record<string, unknown>;
    blockNumber: bigint;
    logIndex: number;
    transactionHash?: string;
  };

  const name = decoded.eventName;
  const args = decoded.args ?? {};
  const id = `${decoded.transactionHash ?? "x"}-${decoded.logIndex}`;
  const base = { id, blockNumber: decoded.blockNumber, txHash: decoded.transactionHash };

  switch (name) {
    case "Borrowed":
      return [
        {
          ...base,
          kind: "borrow",
          who: String(args.borrower),
          amount: args.amount as bigint,
          detail: `tier ${args.cviTier} · ${fmtBps(args.rateBps as bigint)} APR`,
        },
      ];
    case "Repaid":
      return [
        { ...base, kind: "repay", who: String(args.borrower), amount: args.amount as bigint },
      ];
    case "Deposited":
      return [{ ...base, kind: "deposit", who: String(args.lp), amount: args.assets as bigint }];
    case "Redeemed":
      return [{ ...base, kind: "redeem", who: String(args.lp), amount: args.assets as bigint }];
    case "Liquidated":
      return [
        {
          ...base,
          kind: "liquidate",
          who: String(args.borrower),
          amount: args.repaid as bigint,
          detail: `seized ${fmtUsd(args.seized as bigint)}`,
        },
      ];
    case "DefaultRecorded":
      return [
        {
          ...base,
          kind: "default",
          who: String(args.borrower),
          amount: args.unrecoveredDebt as bigint,
          detail: "identity slash signalled",
        },
      ];
    default:
      return [];
  }
}
