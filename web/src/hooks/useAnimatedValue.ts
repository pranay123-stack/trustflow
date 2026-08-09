"use client";

import { useEffect, useRef, useState } from "react";

/** easeOutExpo -- fast take-off, long settle. Reads as "the number is climbing to meet you". */
function easeOutExpo(t: number): number {
  return t === 1 ? 1 : 1 - Math.pow(2, -10 * t);
}

/**
 * Smoothly animates a number toward `target`.
 *
 * This is what makes the credit dial feel alive: when an attestation lands, the trust score and
 * the available-credit figure sweep up to their new values instead of snapping. Honours
 * prefers-reduced-motion by jumping straight to the target.
 */
export function useAnimatedValue(target: number, durationMs = 900): number {
  const [value, setValue] = useState(target);
  const fromRef = useRef(target);
  const startRef = useRef<number | null>(null);
  const frameRef = useRef<number | null>(null);

  useEffect(() => {
    const reduce =
      typeof window !== "undefined" &&
      window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;

    if (reduce || durationMs <= 0) {
      fromRef.current = target;
      setValue(target);
      return;
    }

    // Animate from wherever we currently are, so rapid updates chain smoothly.
    fromRef.current = value;
    startRef.current = null;

    const step = (ts: number) => {
      if (startRef.current === null) startRef.current = ts;
      const elapsed = ts - startRef.current;
      const t = Math.min(1, elapsed / durationMs);
      const next = fromRef.current + (target - fromRef.current) * easeOutExpo(t);

      setValue(next);

      if (t < 1) {
        frameRef.current = requestAnimationFrame(step);
      } else {
        setValue(target);
      }
    };

    frameRef.current = requestAnimationFrame(step);
    return () => {
      if (frameRef.current !== null) cancelAnimationFrame(frameRef.current);
    };
    // `value` is intentionally excluded: including it would restart the animation every frame.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [target, durationMs]);

  return value;
}

/** Animates a bigint token amount, returning a float in whole-token units for display. */
export function useAnimatedTokenAmount(target: bigint | undefined, decimals = 18): number {
  const asNumber = target === undefined ? 0 : Number(target) / 10 ** decimals;
  return useAnimatedValue(Number.isFinite(asNumber) ? asNumber : 0);
}

/** True for `ms` after `trigger` changes -- drives one-shot celebration effects. */
export function usePulse(trigger: unknown, ms = 1400): boolean {
  const [active, setActive] = useState(false);
  const first = useRef(true);

  useEffect(() => {
    if (first.current) {
      first.current = false;
      return;
    }
    setActive(true);
    const id = setTimeout(() => setActive(false), ms);
    return () => clearTimeout(id);
  }, [trigger, ms]);

  return active;
}
