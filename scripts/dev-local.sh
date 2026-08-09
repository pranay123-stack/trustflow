#!/usr/bin/env bash
#
# One-command local demo:
#   anvil -> deploy -> seed -> regenerate frontend bindings -> start the web app
#
# Safe to re-run. Reuses an Anvil already listening on :8545 rather than starting a second one,
# and cleans up only the node it started itself.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACTS="$ROOT/contracts"
WEB="$ROOT/web"
RPC="${LOCAL_RPC:-http://127.0.0.1:8545}"
PORT="${ANVIL_PORT:-8545}"

# Anvil account #0. Local only.
export PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

ANVIL_PID=""
STARTED_ANVIL=false

# %b (not %s) so callers can embed \n in their messages.
cyan() { printf "\033[36m%b\033[0m\n" "$1"; }
green() { printf "\033[32m%b\033[0m\n" "$1"; }
red() { printf "\033[31m%b\033[0m\n" "$1"; }

cleanup() {
  if [ "$STARTED_ANVIL" = true ] && [ -n "$ANVIL_PID" ]; then
    cyan "\nStopping Anvil (pid $ANVIL_PID)…"
    kill "$ANVIL_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- preflight
for cmd in forge cast anvil node npm; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    red "Missing required tool: $cmd"
    [ "$cmd" = "forge" ] && echo "  Install Foundry: curl -L https://foundry.paradigm.xyz | bash && foundryup"
    exit 1
  fi
done

if [ ! -d "$WEB/node_modules" ]; then
  cyan "Installing frontend dependencies…"
  (cd "$WEB" && npm install --no-audit --no-fund)
fi

# ------------------------------------------------------------------- anvil
if cast block-number --rpc-url "$RPC" >/dev/null 2>&1; then
  green "Anvil already running on $RPC — reusing it."
else
  cyan "Starting Anvil on port $PORT…"
  # Bind IPv4 AND IPv6. On many Linux setups `localhost` resolves to ::1 first, and Anvil's
  # default IPv4-only bind then leaves anything that doesn't fall back to 127.0.0.1 unable to
  # connect. Browser page fetches do fall back; MetaMask's extension service worker does not --
  # which produces a wallet that shows a 0 balance and cannot estimate gas, while the dApp
  # itself works perfectly. Listening on both removes the whole class of problem.
  anvil --silent --port "$PORT" --host :: &
  ANVIL_PID=$!
  STARTED_ANVIL=true

  for _ in $(seq 1 40); do
    if cast block-number --rpc-url "$RPC" >/dev/null 2>&1; then break; fi
    sleep 0.25
  done

  if ! cast block-number --rpc-url "$RPC" >/dev/null 2>&1; then
    red "Anvil failed to become ready on $RPC"
    exit 1
  fi
  green "Anvil ready."
fi

# ------------------------------------------------------------------ deploy
cyan "\nDeploying TrustFlow…"
(cd "$CONTRACTS" && forge script script/Deploy.s.sol --rpc-url "$RPC" --broadcast >/dev/null)
green "Deployed."

cyan "Seeding demo borrowers and activity…"
(cd "$CONTRACTS" && forge script script/Seed.s.sol --rpc-url "$RPC" --broadcast >/dev/null)
green "Seeded."

cyan "Regenerating frontend ABIs + addresses…"
(cd "$WEB" && npm run genabi --silent)

# --------------------------------------------------------------- addresses
DEPLOYMENT="$CONTRACTS/deployments/31337.json"
if [ -f "$DEPLOYMENT" ]; then
  echo ""
  green "Deployed addresses:"
  node -e "
    const d = require('$DEPLOYMENT');
    console.log('  vUSD   ', d.vUSD);
    console.log('  Oracle ', d.attestationOracle);
    console.log('  Pool   ', d.trustFlowPool);
  "
fi

cat <<'BANNER'

  ─────────────────────────────────────────────────────────────
   TrustFlow is up.  http://localhost:3000

   In MetaMask, add the local network:
     Network name  Anvil
     RPC URL       http://127.0.0.1:8545
     Chain ID      31337
     Currency      ETH

   Import this account to have test funds:
     0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

   Or connect any wallet and press "Faucet" for 10,000 vUSD.
  ─────────────────────────────────────────────────────────────

BANNER

cd "$WEB" && npm run dev
