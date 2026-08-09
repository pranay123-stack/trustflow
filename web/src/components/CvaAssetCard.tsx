"use client";

import { useReadContracts } from "wagmi";
import { cvaStablecoinAbi, cvaPolicyAbi } from "@/lib/abis";
import { fmtUsd, shortAddress } from "@/lib/format";

type Props = {
  vusd?: `0x${string}`;
  cvaPolicy?: `0x${string}`;
  address?: `0x${string}`;
};

/**
 * The CVA half of the dashboard.
 *
 * CVI answers *who* a counterparty is; CVA answers *what may move*. This card makes the second
 * primitive visible: the rule set governing vUSD, the Travel Rule threshold that triggers an
 * identity check on a peer transfer, and the origination record proving the supply came from a
 * real settlement rather than from nowhere.
 */
export function CvaAssetCard({ vusd, cvaPolicy, address }: Props) {
  const { data } = useReadContracts({
    contracts: [
      { address: vusd, abi: cvaStablecoinAbi, functionName: "lotCount" },
      { address: cvaPolicy, abi: cvaPolicyAbi, functionName: "policyId" },
      { address: cvaPolicy, abi: cvaPolicyAbi, functionName: "travelRuleThreshold" },
      { address: cvaPolicy, abi: cvaPolicyAbi, functionName: "requireVerifiedSender" },
      { address: cvaPolicy, abi: cvaPolicyAbi, functionName: "requireVerifiedRecipient" },
      {
        address: cvaPolicy,
        abi: cvaPolicyAbi,
        functionName: "isBlocked",
        args: address ? [address] : undefined,
      },
    ],
    query: { enabled: Boolean(vusd && cvaPolicy), refetchInterval: 4_000 },
  });

  const lotCount = (data?.[0]?.result as bigint | undefined) ?? 0n;
  const policyId = (data?.[1]?.result as string | undefined) ?? "—";
  const threshold = (data?.[2]?.result as bigint | undefined) ?? 0n;
  const needSender = (data?.[3]?.result as boolean | undefined) ?? false;
  const needRecipient = (data?.[4]?.result as boolean | undefined) ?? false;
  const blocked = (data?.[5]?.result as boolean | undefined) ?? false;

  return (
    <section className="card">
      <header className="card-head">
        <div>
          <h2 className="card-title">vUSD — Cleanverse Verified Asset</h2>
          <p className="card-sub">
            The pool&rsquo;s stablecoin is a CVA asset — clean origination, programmable rules, full
            traceability
          </p>
        </div>
        <span
          className={`chip ${
            blocked
              ? "border-rose-500/30 bg-rose-500/10 text-rose-400"
              : "border-iris-500/25 bg-iris-500/10 text-iris-400"
          }`}
        >
          {blocked ? "Address sanctioned" : "CVA"}
        </span>
      </header>

      <div className="grid grid-cols-1 gap-px bg-white/[0.05] sm:grid-cols-3">
        <Cell label="Active policy" value={policyId} mono />
        <Cell label="Travel Rule above" value={`${fmtUsd(threshold)} vUSD`} />
        <Cell label="Origination lots" value={lotCount.toString()} />
      </div>

      <div className="space-y-2.5 p-5 pt-4">
        <Rule
          on
          text="Sanctioned addresses cannot send or receive — checked first, overrides everything else, including a tier-3 identity."
        />
        <Rule
          on={needSender && needRecipient}
          text={`Peer transfers of ${fmtUsd(threshold)} vUSD or more require a live CVI on ${
            needSender && needRecipient ? "both sides" : needSender ? "the sender" : "the recipient"
          } — the on-chain analogue of FATF Recommendation 16.`}
        />
        <Rule
          on
          text="Below that threshold an unverified wallet may still hold and move vUSD. A verified stablecoin only verified users can touch is a walled garden, not a payment instrument."
        />
        <Rule
          on
          text="Every transfer emits both counterparties' CVI tiers alongside the amount, so verified value flow is reconstructible without any PII ever touching the chain."
        />

        <p className="border-t border-white/[0.05] pt-3 text-[11px] leading-relaxed text-slate-500">
          This is where the two Cleanverse primitives interlock. The pool is policy-exempt because
          it custodies value for many users at once and has no meaningful CVI of its own — identity
          for those flows is enforced by the borrow gate instead, where it can be expressed
          properly. {vusd && <span className="font-mono">{shortAddress(vusd)}</span>}
        </p>
      </div>
    </section>
  );
}

function Cell({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="bg-ink-900/80 px-4 py-3">
      <div className="stat-label">{label}</div>
      <div className={`mt-0.5 text-sm font-semibold text-slate-100 ${mono ? "font-mono text-xs" : "tnum"}`}>
        {value}
      </div>
    </div>
  );
}

function Rule({ on, text }: { on: boolean; text: string }) {
  return (
    <div className="flex items-start gap-2.5">
      <span className={`mt-0.5 shrink-0 ${on ? "text-mint-400" : "text-slate-600"}`}>
        {on ? <CheckIcon /> : <DotIcon />}
      </span>
      <p className="text-xs leading-relaxed text-slate-400">{text}</p>
    </div>
  );
}

function CheckIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 14 14" fill="none" aria-hidden>
      <circle cx="7" cy="7" r="6" stroke="currentColor" strokeWidth="1.3" />
      <path
        d="M4.2 7.2l2 2 3.6-4"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function DotIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 14 14" fill="none" aria-hidden>
      <circle cx="7" cy="7" r="6" stroke="currentColor" strokeWidth="1.3" />
    </svg>
  );
}
