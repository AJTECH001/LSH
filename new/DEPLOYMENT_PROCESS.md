# Liquidation Shield - End-to-End Deployment & Verification Guide

This guide documents the full process for deploying, configuring, and verifying the cross-chain Liquidation Shield Hook system.

Two deployment targets are documented:
- **Sepolia** — original deployment (2026-03-16)
- **Unichain Sepolia** — current deployment (2026-03-18)

---

## 📋 Prerequisites

### `.env` file
```bash
PRIVATE_KEY=0x...

# RPCs
UNICHAIN_RPC=https://sepolia.unichain.org
REACTIVE_RPC=https://lasna-rpc.rnk.dev/

# Unichain Sepolia (1301) — Uniswap v4 Core
POOL_MANAGER=0x00b036b58a818b1bc34d502d3fe730db729e62ac
POSITION_MANAGER=0xf969aee60879c54baaed9f3ed26147db216fd664
UNIVERSAL_ROUTER=0xf70536b3bcc1bd1a972dc186a2cf84cc6da6be5d
STATE_VIEW=0xc199f1072a74d4e905aba1a84d9a45e2546b6222
QUOTER=0x56dcd40a3f2d466f48e7f48bdbe5cc9b92ae4472
PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3
CREATE2_FACTORY=0x4e59b44847b379578588920cA78FbF26c0B4956C

# Reactive Network
UNICHAIN_CALLBACK_PROXY=0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4
SYSTEM_CONTRACT_ADDR=0x0000000000000000000000000000000000fffFfF

# Filled after each deploy step
TOKEN0_ADDRESS=
TOKEN1_ADDRESS=
CALLBACK_RECEIVER_ADDRESS=
HOOK_ADDRESS=
MONITOR_ADDRESS=
MOCK_LENDING_POOL=
```

### Faucets
- Unichain Sepolia ETH: https://faucet.unichain.org
- Reactive Lasna ETH: https://faucet.reactive.network

> Note: Lasna gas is expensive (~112 gwei). Have at least 0.5 ETH on Lasna before deploying the monitor.

---

## 🚀 Step 1: Deploy Mock Tokens (Unichain Sepolia)

```bash
source .env && forge script script/DeployTokens.s.sol \
  --rpc-url $UNICHAIN_RPC --broadcast -vvv
```

Copy output addresses into `.env` as `TOKEN0_ADDRESS` and `TOKEN1_ADDRESS`.

---

## 🚀 Step 2: Deploy Hook & CallbackReceiver (Unichain Sepolia)

Uses `DeployUnichain.s.sol` — extends plain `Script` (not `BaseScript`) to avoid forge's Deployers fork issue on live networks.

```bash
source .env && forge script script/DeployUnichain.s.sol \
  --rpc-url $UNICHAIN_RPC --broadcast -vvv
```

Copy output addresses into `.env` as `HOOK_ADDRESS` and `CALLBACK_RECEIVER_ADDRESS`.

> The Reactive callback proxy (`UNICHAIN_CALLBACK_PROXY`) is authorized automatically inside this script.

---

## 🚀 Step 3: Deploy MockLendingPool (Unichain Sepolia)

```bash
source .env && forge script script/DeployMockLending.s.sol \
  --rpc-url $UNICHAIN_RPC --broadcast -vvv
```

Copy output into `.env` as `MOCK_LENDING_POOL`.

---

## ⚡ Step 4: Deploy HealthFactorMonitor (Reactive Lasna)

```bash
source .env && forge script script/DeployLasna.s.sol \
  --rpc-url $REACTIVE_RPC --broadcast -vvv
```

Copy output into `.env` as `MONITOR_ADDRESS`.

---

## 🛠 Step 5: Initialize Monitor (Reactive Lasna)

Sets up base event subscriptions so the monitor listens for `HealthCheckRequested` events from the hook.

```bash
source .env && cast send $MONITOR_ADDRESS "init()" \
  --rpc-url $REACTIVE_RPC --private-key $PRIVATE_KEY
```

---

## 🧪 Step 6: Create Pool, Add Liquidity & Activate Shield (Unichain Sepolia)

Uses `InteractUnichain.s.sol`. Run with `--skip-simulation` to avoid RPC race condition on fast chains.

```bash
source .env && forge script script/InteractUnichain.s.sol \
  --rpc-url $UNICHAIN_RPC --broadcast --skip-simulation -vvv
```

This atomically:
1. Initializes the `STA/STB` pool (3000 bps fee, tick spacing 60)
2. Approves tokens via Permit2
3. Adds liquidity
4. Activates the shield for the deployer wallet

---

## ✅ Step 7: Verify Shield is Active

```bash
source .env && cast call $HOOK_ADDRESS \
  "isProtected(address)" $(cast wallet address --private-key $PRIVATE_KEY) \
  --rpc-url $UNICHAIN_RPC
```

Returns `0x0000...0001` = active.

```bash
source .env && cast call $HOOK_ADDRESS \
  "getRegisteredUserCount()" \
  --rpc-url $UNICHAIN_RPC
```

---

## 🔗 Network Reference

| Network | Chain ID | Explorer | Faucet |
|---|---|---|---|
| Unichain Sepolia | 1301 | https://sepolia.uniscan.xyz | https://faucet.unichain.org |
| Reactive Lasna | 5318007 | — | https://faucet.reactive.network |

| Reactive Callback Proxy | Network |
|---|---|
| `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4` | Unichain Sepolia |
| `0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA` | Ethereum Sepolia |

---

## ⚠️ Known Issues & Fixes

| Issue | Fix |
|---|---|
| `could not instantiate forked environment` | Add `--skip-simulation` flag |
| `BaseScript` fork error on live network | Use scripts that extend `Script` not `BaseScript` |
| `Stack too deep` | Set `via_ir = true` in `foundry.toml` |
| `Identifier already declared: CREATE2_FACTORY` | Remove duplicate — already defined in forge-std `Base.sol` |
| Insufficient funds on Lasna | Claim from faucet; need 0.5+ ETH for monitor deploy |

---

**Status:** ✅ End-to-End verified on Unichain Sepolia (2026-03-18)
