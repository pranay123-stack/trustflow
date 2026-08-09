import { defineChain } from "viem";
import { anvil } from "viem/chains";

/// Monad testnet. Defined locally rather than imported so the app pins the exact RPC/explorer
/// the demo was tested against, and so an operator can override the RPC via env.
export const monadTestnet = defineChain({
  id: 10_143,
  name: "Monad Testnet",
  nativeCurrency: { name: "Monad", symbol: "MON", decimals: 18 },
  rpcUrls: {
    default: {
      http: [process.env.NEXT_PUBLIC_MONAD_RPC_URL ?? "https://testnet-rpc.monad.xyz"],
    },
  },
  blockExplorers: {
    default: {
      name: "Monad Explorer",
      url: "https://testnet.monadexplorer.com",
    },
  },
  testnet: true,
});

export const localhost = {
  ...anvil,
  rpcUrls: {
    default: {
      http: [process.env.NEXT_PUBLIC_LOCAL_RPC_URL ?? "http://127.0.0.1:8545"],
    },
  },
};

export const supportedChains = [localhost, monadTestnet] as const;

export function explorerTxUrl(chainId: number, hash: string): string | null {
  if (chainId === monadTestnet.id) {
    return `${monadTestnet.blockExplorers.default.url}/tx/${hash}`;
  }
  return null;
}
