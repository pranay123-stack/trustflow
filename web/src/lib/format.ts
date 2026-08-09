import { formatUnits, parseUnits } from "viem";

export const VUSD_DECIMALS = 18;

/** Compact money display: 1.2k, 48.75k, 1.05M. */
export function fmtUsd(value: bigint | undefined, opts?: { decimals?: number }): string {
  if (value === undefined) return "--";
  const n = Number(formatUnits(value, VUSD_DECIMALS));
  const decimals = opts?.decimals ?? 2;

  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(2)}M`;
  if (n >= 10_000) return `${(n / 1_000).toFixed(1)}k`;
  return n.toLocaleString("en-US", {
    minimumFractionDigits: 0,
    maximumFractionDigits: decimals,
  });
}

/** Exact display with grouping, for tooltips and confirmations. */
export function fmtUsdExact(value: bigint | undefined, decimals = 4): string {
  if (value === undefined) return "--";
  const n = Number(formatUnits(value, VUSD_DECIMALS));
  return n.toLocaleString("en-US", { maximumFractionDigits: decimals });
}

export function toUnits(value: string): bigint {
  if (!value || Number.isNaN(Number(value))) return 0n;
  try {
    return parseUnits(value, VUSD_DECIMALS);
  } catch {
    return 0n;
  }
}

/** 1234 bps -> "12.34%" */
export function fmtBps(bps: bigint | number | undefined, decimals = 2): string {
  if (bps === undefined) return "--";
  return `${(Number(bps) / 100).toFixed(decimals)}%`;
}

/** 7000 bps (of 10_000) -> "70%" */
export function fmtPct(bps: bigint | number | undefined, decimals = 0): string {
  if (bps === undefined) return "--";
  return `${(Number(bps) / 100).toFixed(decimals)}%`;
}

export function shortAddress(addr?: string): string {
  if (!addr) return "";
  return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
}

/** Health factor is uint256 max when debt-free; render that as infinity, not a huge number. */
export const UINT256_MAX = (1n << 256n) - 1n;

export function fmtHealth(healthBps: bigint | undefined): string {
  if (healthBps === undefined) return "--";
  if (healthBps >= UINT256_MAX / 2n) return "∞";
  return (Number(healthBps) / 10_000).toFixed(2);
}

export function healthTone(healthBps: bigint | undefined): "safe" | "warn" | "danger" {
  if (healthBps === undefined) return "safe";
  if (healthBps >= UINT256_MAX / 2n) return "safe";
  const h = Number(healthBps) / 10_000;
  if (h >= 1.5) return "safe";
  if (h >= 1.05) return "warn";
  return "danger";
}
