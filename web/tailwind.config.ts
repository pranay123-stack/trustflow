import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        // Fintech dark palette: deep slate base, mint accent for trust, amber for risk.
        ink: {
          950: "#06080f",
          900: "#0a0e1a",
          850: "#0e1424",
          800: "#131a2e",
          700: "#1c2540",
          600: "#293350",
          500: "#3d4a6e",
        },
        mint: {
          400: "#4ade9f",
          500: "#22c98a",
          600: "#12a874",
        },
        iris: {
          400: "#8b8cf9",
          500: "#6d6ef5",
          600: "#5254e0",
        },
        amber: {
          400: "#fbbf5c",
          500: "#f59e0b",
        },
        rose: {
          400: "#fb7185",
          500: "#f43f5e",
        },
      },
      fontFamily: {
        sans: ["var(--font-sans)", "system-ui", "sans-serif"],
        mono: ["var(--font-mono)", "ui-monospace", "monospace"],
      },
      boxShadow: {
        glow: "0 0 40px -8px rgba(34, 201, 138, 0.35)",
        "glow-iris": "0 0 40px -8px rgba(109, 110, 245, 0.35)",
        card: "0 1px 0 0 rgba(255,255,255,0.04) inset, 0 8px 32px -12px rgba(0,0,0,0.8)",
      },
      keyframes: {
        "fade-up": {
          "0%": { opacity: "0", transform: "translateY(6px)" },
          "100%": { opacity: "1", transform: "translateY(0)" },
        },
        "pulse-ring": {
          "0%": { transform: "scale(0.95)", opacity: "0.7" },
          "70%": { transform: "scale(1.25)", opacity: "0" },
          "100%": { transform: "scale(1.25)", opacity: "0" },
        },
        shimmer: {
          "0%": { backgroundPosition: "-200% 0" },
          "100%": { backgroundPosition: "200% 0" },
        },
      },
      animation: {
        "fade-up": "fade-up 0.4s cubic-bezier(0.16, 1, 0.3, 1)",
        "pulse-ring": "pulse-ring 1.6s cubic-bezier(0.24, 0, 0.38, 1) infinite",
        shimmer: "shimmer 2.5s linear infinite",
      },
    },
  },
  plugins: [],
};

export default config;
