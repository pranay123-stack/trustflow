import { http, createConfig, createStorage, cookieStorage } from "wagmi";
import { injected } from "wagmi/connectors";
import { localhost, monadTestnet } from "./chains";

/// Injected-only by design: a browser wallet needs no WalletConnect project id, so the demo
/// runs from a fresh clone with zero configuration.
export const wagmiConfig = createConfig({
  chains: [localhost, monadTestnet],
  connectors: [injected({ shimDisconnect: true })],
  storage: createStorage({ storage: cookieStorage }),
  ssr: true,
  transports: {
    [localhost.id]: http(localhost.rpcUrls.default.http[0]),
    [monadTestnet.id]: http(monadTestnet.rpcUrls.default.http[0]),
  },
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
