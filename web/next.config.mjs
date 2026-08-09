/** @type {import('next').NextConfig} */

/**
 * `@wagmi/connectors` is a barrel: importing `injected` from it also pulls in the Base Account
 * connector, which reaches @coinbase/cdp-sdk -> the optional @x402/* payment SDKs. TrustFlow
 * only ever uses the injected connector, so these are aliased away rather than installed.
 */
const UNUSED_OPTIONAL_DEPS = [
  "@x402/core/client",
  "@x402/evm",
  "@x402/evm/exact/client",
  "@x402/evm/upto/client",
  "@x402/svm/exact/client",
];

const nextConfig = {
  reactStrictMode: true,
  webpack: (config) => {
    // Native/node-only deps that wagmi + viem reference but never need in the browser.
    config.externals.push("pino-pretty", "lokijs", "encoding");

    config.resolve.alias = {
      ...config.resolve.alias,
      ...Object.fromEntries(UNUSED_OPTIONAL_DEPS.map((mod) => [mod, false])),
    };

    return config;
  },
};

export default nextConfig;
