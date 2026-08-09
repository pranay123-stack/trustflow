"use client";

const POINTS = [
  {
    title: "Identity gates credit — CVI",
    body: "borrow() reverts unless the oracle reports a live, unexpired, compliant attestation. There is no admin override and no allowlist bypass — the check sits on the only path that reaches the transfer.",
  },
  {
    title: "Repayment is never blocked — CVI",
    body: "If an attestation is revoked mid-loan, the borrower can still repay. Freezing repayment would strand funds and leave a flagged wallet permanently indebted — worse for the lender, the borrower and the regulator alike.",
  },
  {
    title: "Credentials, not identities, go on-chain — CVI",
    body: "The chain stores a tier, a score and a hash pointing at the off-chain credential bundle. No names, no documents, no PII. A verifier can prove which documents backed a decision without the chain ever holding them.",
  },
  {
    title: "Downgrades take effect immediately — CVI",
    body: "Borrowing power is read from the oracle at call time, not cached at origination. A sanctions hit collapses the line on the very next block, and the position becomes liquidatable.",
  },
  {
    title: "Defaults have identity consequences — CVI",
    body: "When an unsecured line defaults there is no collateral left to seize. markDefault() emits a signal the attestation authority consumes to downgrade the wallet's CVI — the recourse lands on reputation, which is what made the credit possible.",
  },
  {
    title: "The asset carries its own rules — CVA",
    body: "vUSD is not a plain ERC20. Supply cannot be minted without naming the settlement that backed it and a digest of the proof — issue() reverts on a missing sourceRef. Every transfer is evaluated by a swappable policy before it settles, so the same asset can be governed differently per jurisdiction without redeploying it or migrating holders.",
  },
  {
    title: "Travel Rule enforced on-chain — the interlock",
    body: "Peer transfers at or above the threshold require a live CVI on both counterparties. That is an asset rule enforced by an identity fact — the CVA policy calls into the CVI oracle to decide. Neither primitive can express it alone, which is precisely what \u201cinterlocking identity and assets on every value transfer\u201d has to mean in code.",
  },
  {
    title: "Two independent kill switches",
    body: "Revoking a CVI stops new credit but does not by itself stop tokens moving. Blocking an address stops movement but does not erase their credentials. Sanctions are evaluated first and outrank everything, including a tier-3 identity. Neither switch substitutes for the other, and the demo exercises both.",
  },
];

/**
 * The "why is this compliant rather than evasive" card.
 *
 * Undercollateralized lending invites the question of whether identity gating is theatre. This
 * spells out the specific mechanisms, each of which maps to a line in the contracts.
 */
export function ComplianceCard() {
  return (
    <section className="card">
      <header className="card-head">
        <div>
          <h2 className="card-title">Why this is compliant, not evasive</h2>
          <p className="card-sub">Eight mechanisms, each mapping to a line in the contracts</p>
        </div>
        <span className="chip border-iris-500/25 bg-iris-500/10 text-iris-400">Verified Finance</span>
      </header>

      <ul className="divide-y divide-white/[0.04]">
        {POINTS.map((p) => (
          <li key={p.title} className="px-5 py-3.5">
            <div className="flex items-start gap-2.5">
              <span className="mt-1 text-mint-400">
                <ShieldIcon />
              </span>
              <div>
                <p className="text-xs font-semibold text-slate-100">{p.title}</p>
                <p className="mt-1 text-xs leading-relaxed text-slate-500">{p.body}</p>
              </div>
            </div>
          </li>
        ))}
      </ul>
    </section>
  );
}

function ShieldIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 16 16" fill="none" aria-hidden>
      <path
        d="M8 1.5l5 2v4c0 3.2-2.1 6-5 7-2.9-1-5-3.8-5-7v-4l5-2z"
        stroke="currentColor"
        strokeWidth="1.4"
        strokeLinejoin="round"
      />
      <path
        d="M5.8 8l1.6 1.6L10.4 6.6"
        stroke="currentColor"
        strokeWidth="1.4"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}
