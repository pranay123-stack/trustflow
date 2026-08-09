SHELL := /bin/bash

# Load .env if present, so PRIVATE_KEY / MONAD_RPC_URL are available to every target.
ifneq (,$(wildcard ./.env))
    include .env
    export
endif

CONTRACTS := contracts
WEB       := web
LOCAL_RPC ?= http://127.0.0.1:8545

# Anvil account #0. Local development only -- never use this key on a public network.
ANVIL_KEY := 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@echo ""
	@echo "  TrustFlow -- identity-gated undercollateralized lending"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Quick start:  make install && make dev"
	@echo ""

# ---------------------------------------------------------------- setup

.PHONY: install
install: ## Install contract + frontend dependencies
	@# Pinned explicitly: the repo ships without git submodules, so a bare `forge install`
	@# would have nothing to resolve.
	cd $(CONTRACTS) && forge install foundry-rs/forge-std@v1.16.2 --no-git 2>/dev/null || true
	cd $(CONTRACTS) && forge install OpenZeppelin/openzeppelin-contracts@v5.1.0 --no-git 2>/dev/null || true
	cd $(WEB) && npm install
	$(MAKE) build
	$(MAKE) abi

# ------------------------------------------------------------- contracts

.PHONY: build
build: ## Compile contracts
	cd $(CONTRACTS) && forge build

.PHONY: test
test: ## Run the full Foundry suite (unit + fuzz + invariant)
	cd $(CONTRACTS) && forge test -vv

.PHONY: test-gas
test-gas: ## Run tests with a gas report
	cd $(CONTRACTS) && forge test --gas-report

.PHONY: coverage
coverage: ## Solidity line coverage
	cd $(CONTRACTS) && forge coverage --no-match-coverage "(script|test)"

.PHONY: fmt
fmt: ## Format Solidity
	cd $(CONTRACTS) && forge fmt

# ------------------------------------------------------------ deployment

.PHONY: anvil
anvil: ## Start a local Anvil node (foreground)
	anvil --host 0.0.0.0

.PHONY: deploy-local
deploy-local: ## Deploy to local Anvil
	cd $(CONTRACTS) && PRIVATE_KEY=$(ANVIL_KEY) \
		forge script script/Deploy.s.sol --rpc-url $(LOCAL_RPC) --broadcast

.PHONY: seed-local
seed-local: ## Seed local deployment with demo borrowers + activity
	cd $(CONTRACTS) && PRIVATE_KEY=$(ANVIL_KEY) \
		forge script script/Seed.s.sol --rpc-url $(LOCAL_RPC) --broadcast

.PHONY: deploy-monad
deploy-monad: ## Deploy to Monad testnet (needs PRIVATE_KEY + MONAD_RPC_URL in .env)
	@test -n "$(PRIVATE_KEY)" || (echo "PRIVATE_KEY not set -- copy .env.example to .env" && exit 1)
	@test -n "$(MONAD_RPC_URL)" || (echo "MONAD_RPC_URL not set -- copy .env.example to .env" && exit 1)
	cd $(CONTRACTS) && forge script script/Deploy.s.sol \
		--rpc-url $(MONAD_RPC_URL) --broadcast --slow
	$(MAKE) abi

.PHONY: seed-monad
seed-monad: ## Seed a Monad testnet deployment
	@test -n "$(MONAD_RPC_URL)" || (echo "MONAD_RPC_URL not set" && exit 1)
	cd $(CONTRACTS) && forge script script/Seed.s.sol \
		--rpc-url $(MONAD_RPC_URL) --broadcast --slow

# -------------------------------------------------------------- frontend

.PHONY: abi
abi: ## Regenerate frontend ABIs + addresses from build artifacts
	cd $(WEB) && npm run genabi

.PHONY: vectors
vectors: ## Re-export credit-curve parity vectors from Solidity
	cd $(CONTRACTS) && forge script script/ExportCurveVectors.s.sol

.PHONY: parity
parity: vectors ## Verify the TypeScript credit curve matches the Solidity exactly
	cd $(WEB) && npm run test:parity

.PHONY: verify-live
verify-live: ## Drive a LIVE deployment through its full lifecycle and check every number
	@# Independent of both the Solidity tests and the TS mirror: recomputes every expected
	@# value from the spec in plain JS, then asserts against a running chain. Needs `make dev`.
	cd $(WEB) && npm run verify:live

.PHONY: web
web: ## Start the frontend dev server
	cd $(WEB) && npm run dev

.PHONY: web-build
web-build: ## Production build of the frontend
	cd $(WEB) && npm run build

.PHONY: typecheck
typecheck: ## Typecheck the frontend
	cd $(WEB) && npm run typecheck

# ------------------------------------------------------------ one-command

.PHONY: dev
dev: ## ONE COMMAND: anvil + deploy + seed + abi + frontend
	@bash scripts/dev-local.sh

.PHONY: verify
verify: build test parity typecheck web-build ## Everything CI would run
	@echo ""
	@echo "  All checks passed."
	@echo ""

.PHONY: clean
clean: ## Remove build artifacts
	cd $(CONTRACTS) && forge clean
	rm -rf $(WEB)/.next
