# Crowdfunding Platform — developer commands
#
# Requirements: Foundry (`curl -L https://foundry.paradigm.xyz | bash && foundryup`)

.PHONY: install build test test-v gas snapshot fmt clean anvil deploy deploy-dry

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
