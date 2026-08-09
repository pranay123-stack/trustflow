import type { Metadata } from "next";
import "./globals.css";
import { Providers } from "./providers";

export const metadata: Metadata = {
  title: "TrustFlow — Identity-Gated Credit on Monad",
  description:
    "Undercollateralized lending where borrowing power comes from verified on-chain identity (CVI · CVA), not from posting excess collateral.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
