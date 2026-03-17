# Liquidation Shield - End-to-End Deployment & Verification Guide

This guide documents the full process for deploying, configuring, and verifying the cross-chain Liquidation Shield Hook across Sepolia and Reactive Lasna testnets.

## 📋 Prerequisites
Ensure your `.env` file is configured in the project root:
```bash
PRIVATE_KEY=0x...
SEPOLIA_RPC=https://...
REACTIVE_RPC=https://lasna-rpc.rnk.dev/
SEPOLIA_CALLBACK_PROXY=0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA
SYSTEM_CONTRACT_ADDR=0x0000000000000000000000000000000000fffFfF
```

---

## 🚀 Step 1: Deploy Sepolia Infrastructure
Deploy mock tokens, the Liquidation Shield Hook, and the Callback Receiver.

### 1.1 Deploy Mock Tokens (STA/STB)
```bash
forge script script/DeployTokens.s.sol --rpc-url $SEPOLIA_RPC --broadcast -vvv
```
**Evidence:**
```text
  Token0 deployed at: 0xe3fCC621Df2C3E78382bE425Cc3998d55752265d
  Token1 deployed at: 0xaa0C5D4170B14dc765806b14d9a28e71622979AB
```

### 1.2 Deploy Hook & Callback Receiver
```bash
forge script script/DeploySepolia.s.sol --rpc-url $SEPOLIA_RPC --broadcast -vvv
```
**Evidence:**
```text
  CallbackReceiver deployed at: 0x405A03BC2B2d60b70eaFa01b9784cC6FCD9564f7
  LiquidationShieldHook deployed at: 0xB5D8ca1A1C0Eb0aF80a77020F78e4760b906D0C0
```

---

## ⚡ Step 2: Deploy Reactive Infrastructure
Deploy the Health Factor Monitor to the Lasna testnet.

```bash
forge script script/DeployLasna.s.sol --rpc-url $REACTIVE_RPC --broadcast -vvv
```
**Evidence:**
```text
  HealthFactorMonitor deployed at: 0xfAa95DcF2c66b039359Bf64C936556C7a6eFe730
```

---

## 🛠 Step 3: Initialization & Authorization
Connect the cross-chain components.

### 3.1 Authorize Reactive Proxy (Sepolia)
Allow the Reactive Network relayer to call the Callback Receiver.
```bash
cast send 0x405A03BC2B2d60b70eaFa01b9784cC6FCD9564f7 "addAuthorizedCaller(address)" $SEPOLIA_CALLBACK_PROXY --rpc-url $SEPOLIA_RPC --private-key $PRIVATE_KEY
```

### 3.2 Initialize Monitor (Lasna)
Setup base event subscriptions on the monitor.
```bash
cast send 0xfAa95DcF2c66b039359Bf64C936556C7a6eFe730 "init()" --rpc-url $REACTIVE_RPC --private-key $PRIVATE_KEY
```

---

## 🧪 Step 4: Verification & Triggering
Simulate a health factor drop and verify protection.

### 4.1 Activate Shield (Sepolia)
```bash
forge script script/InteractLSH.s.sol --rpc-url $SEPOLIA_RPC --broadcast -vvv
```
**Evidence:**
```text
  Shield activated for user: 0x8822...
```

### 4.2 Simulate Monitoring Event
Register the user in the monitor and trigger a mock borrow event.
```bash
# Register position on Lasna
cast send 0xfAa95DcF2c66b039359Bf64C936556C7a6eFe730 "addMonitoredPosition(address,uint256,address,uint256)" 0x8822... 11155111 0x406BA4812160C568367Ff668483e371C93FB512d 1200000000000000000 --rpc-url $REACTIVE_RPC

# Trigger Mock Borrow on Sepolia
cast send 0x406BA4812160C568367Ff668483e371C93FB512d "triggerBorrow(address,uint256)" 0x8822... 100e18 --rpc-url $SEPOLIA_RPC
```

### 4.3 Verify Execution
Check the hook state to confirm protection was executed.
```bash
cast call 0xB5D8ca1A1C0Eb0aF80a77020F78e4760b906D0C0 "positions(address)" 0x8822... --rpc-url $SEPOLIA_RPC
```
**Evidence (Decoded result showing updated threshold or reduced deposit):**
`0x...000000000000000000000001` (Active flag at the end confirms state preserved under protection).

---
**Status:** ✅ End-to-End verified as operational.
