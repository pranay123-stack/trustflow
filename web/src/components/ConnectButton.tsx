"use client";

import { useAccount, useConnect, useDisconnect, useSwitchChain } from "wagmi";
import { shortAddress } from "@/lib/format";
import { CHAIN_LABELS } from "@/lib/contracts";
import { supportedChains } from "@/lib/chains";

export function ConnectButton() {
  const { address, isConnected, chainId } = useAccount();
  const { connect, connectors, isPending } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();

  const onSupportedChain = supportedChains.some((c) => c.id === chainId);

  if (!isConnected) {
    const injected = connectors[0];
    return (
      <button
        onClick={() => injected && connect({ connector: injected })}
        disabled={isPending || !injected}
        className="btn-primary"
      >
        {isPending ? "Connecting…" : "Connect Wallet"}
      </button>
    );
  }

  return (
    <div className="flex items-center gap-2">
      {!onSupportedChain ? (
        <button
          onClick={() => switchChain({ chainId: supportedChains[0].id })}
          className="btn bg-amber-500 text-ink-950 hover:bg-amber-400"
        >
          Switch network
        </button>
      ) : (
        <span className="chip border-white/10 bg-white/[0.04] text-slate-400">
          <span className="h-1.5 w-1.5 rounded-full bg-mint-400" />
          {CHAIN_LABELS[chainId ?? 0] ?? `Chain ${chainId}`}
        </span>
      )}
      <button onClick={() => disconnect()} className="btn-secondary font-mono text-xs">
        {shortAddress(address)}
      </button>
    </div>
  );
}
