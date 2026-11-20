# Crowdfunding Platform — developer commands
#
# Requirements: Foundry (`curl -L https://foundry.paradigm.xyz | bash && foundryup`)
#
# Load project configuration from .env when present so `make deploy` works
# without manually exporting RPC_URL / PRIVATE_KEY.

-include .env
export PRIVATE_KEY RPC_URL OWNER FEE_RECIPIENT PLATFORM_FEE_BPS

.PHONY: install build test test-v gas snapshot fmt clean anvil deploy deploy-dry demo

# Install pinned dependencies (run once after cloning).
install:
	forge install foundry-rs/forge-std@v1.9.6 --no-git
	forge install OpenZeppelin/openzeppelin-contracts@v5.1.0 --no-git

build:
	forge build

test:
	forge test

test-v:
	forge test -vvv

gas:
	forge test --gas-report

snapshot:
	forge snapshot

fmt:
	forge fmt

clean:
	forge clean

anvil:
	anvil

# Usage: make deploy RPC_URL=https://...
deploy:
	@test -n "$(RPC_URL)" || (echo "RPC_URL is required" && exit 1)
	forge script script/Deploy.s.sol --rpc-url "$(RPC_URL)" --broadcast

# Simulate deployment without broadcasting.
deploy-dry:
	forge script script/Deploy.s.sol

# Serve the static demo dApp locally at http://127.0.0.1:8787
demo:
	python3 -m http.server 8787 --directory docs
