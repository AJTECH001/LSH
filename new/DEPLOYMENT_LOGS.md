# Liquidation Shield - Deployment & Interaction Logs

This document contains terminal outputs and transaction evidence from all deployments.

---

# 🟢 Deployment 2: Unichain Sepolia (2026-03-18)

**Deployer Address:** `0xa4280dd3f9E1f6Bf1778837AC12447615E1d0317`
**Networks:** Unichain Sepolia (1301) + Reactive Lasna (5318007)

---

## 1. Token Deployment — Unichain Sepolia

**Command:**
```bash
source .env && forge script script/DeployTokens.s.sol --rpc-url $UNICHAIN_RPC --broadcast -vvv
```

**Output:**
```text
== Logs ==
  Token0 deployed at: 0xdEDeBDB00a83a0bD09b414Ea5FD876dB40799529
  Token1 deployed at: 0xEEe28Afd5077a0Add3D1C59f85B8eaEE49816127

Chain 1301
✅ Hash: 0x2bb51399e5297e2476553edb288caba568ea52445bda4f8ab803c4c6fce0a153
✅ Hash: 0xa33ec6a98ee8a611e33b703314d02d7b672be6291b0aa60e6f50518809374f7a  (Token1: 0xEEe28A...)
✅ Hash: 0xc56d9b38fff0de949a84abf67b0c343e2f30eb2ef5bc2eebbcce1aa8e5d099a2  (Token0: 0xdEDeB...)
Total Paid: 0.000001426659853314 ETH
```

---

## 2. Hook & CallbackReceiver Deployment — Unichain Sepolia

**Command:**
```bash
source .env && forge script script/DeployUnichain.s.sol --rpc-url $UNICHAIN_RPC --broadcast -vvv
```

**Output:**
```text
== Logs ==
  CallbackReceiver deployed at: 0x045962833e855095DbE8B061d0e7E929a3f5C55c
  LiquidationShieldHook deployed at: 0xdA257AfcB7a3025690bf3B48ED9A0378FdE650C0
  Callback proxy authorized: 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4

Chain 1301
✅ Hash: 0x013bfd8daee14535ed944e42760c2af4f4333d5c24cf2e80f751a70c256322ab
✅ Hash: 0x7c51c5a7a47dcb30a2e69460da5632b4f1dcb689345aace46a0fd03aaddb565d  (Hook: 0xdA257A...)
✅ Hash: 0x3f7cc142318acc82e76488dcd7c18ac4b18d7e97c63005fe61bb8beb446d5caf
✅ Hash: 0x4f3236fcbd627584fb46eee3dca8e396c0f5122fd8d7d03300870e83b267109c  (CallbackReceiver: 0x045962...)
Total Paid: 0.000002155685811363 ETH
```

---

## 3. MockLendingPool Deployment — Unichain Sepolia

**Command:**
```bash
source .env && forge script script/DeployMockLending.s.sol --rpc-url $UNICHAIN_RPC --broadcast -vvv
```

**Output:**
```text
== Logs ==
  MockLendingPool deployed at: 0x66Cd8DfF334329F5657Ed4d0DBF5ffEca250C565

Chain 1301
✅ Hash: 0xa3e4e8f85354c585fc8d8f9079d0f28bf68a101993d306910b1afa644a2cba6a
Total Paid: 0.000000095625691251 ETH
```

---

## 4. HealthFactorMonitor Deployment — Reactive Lasna

**Command:**
```bash
source .env && forge script script/DeployLasna.s.sol --rpc-url $REACTIVE_RPC --broadcast -vvv
```

**Output:**
```text
== Logs ==
  HealthFactorMonitor deployed to Lasna at: 0xdEDeBDB00a83a0bD09b414Ea5FD876dB40799529

Chain 5318007
✅ Hash: 0x022d2b6b2318dda04ebe4c483e33c2cc1987ebda23108ec5240563afcb34c368
Block: 2781939
Total Paid: 0.186735024 ETH (1667277 gas * 112 gwei)
```

---

## 5. Monitor Initialization — Reactive Lasna

**Command:**
```bash
source .env && cast send $MONITOR_ADDRESS "init()" --rpc-url $REACTIVE_RPC --private-key $PRIVATE_KEY
```

**Output:**
```text
blockHash      0xb159c732b63d81f29c1b71212ae45af4e3e79d8d3db90dae40a6e57bdf4c6adb
blockNumber    2781948
status         1 (success)
transactionHash 0xd41d315b5391d97f0bed6e3bbab79d92b7c39323e71b96ea3e400a58a1358c86
gasUsed        129749
```

Subscription event emitted to system contract — monitor now listening for `HealthCheckRequested` from hook on Unichain Sepolia.

---

## 6. Pool Creation, Liquidity & Shield Activation — Unichain Sepolia

**Command:**
```bash
source .env && forge script script/InteractUnichain.s.sol \
  --rpc-url $UNICHAIN_RPC --broadcast --skip-simulation -vvv
```

**Output:**
```text
== Logs ==
  Pool initialized
  Liquidity added
  Shield activated for: 0xa4280dd3f9E1f6Bf1778837AC12447615E1d0317

Chain 1301
✅ Hash: 0x7a6361a7ab20fbccaac63a2d87e508282c6744e5fb1b7d3bdf2a733b78996742  (initializePool)
✅ Hash: 0x897a0b0aec77d32a1694b3d77e1b3036c00fe0c799e399ce5edd228663a8aee7  (approve token0)
✅ Hash: 0xbb56187a4c09c7c9950399c1ae56ac50cf0d246cb802d77ee9d98fd79b0c3d62  (approve token1)
✅ Hash: 0x0cfbecb2dda46de9ec9e8b2f6ec511c1dce4f321b598df777db5c034aa7c4f1a  (permit2 token0)
✅ Hash: 0xd3e61d4314ab8e86335b461cedc5e3fd97802cb49e085878b12cbbb6bb90a909  (permit2 token1)
✅ Hash: 0x70c6f6dad9d21a3229ef73b49bbb630b8fcced427fac57c5f10a8a25a5ce09a4  (modifyLiquidities)
✅ Hash: 0xdc7546daff7e1631e30f17d54123c9daf3927ba282af83ff3d90d46a997dd0c2  (approve hook)
✅ Hash: 0xab672e7f11b081c5b2f0744e2338a8eb2d6a40ad49ebf5fd454f243737b96e15  (activateShield)
Total Paid: 0.000000531543563085 ETH
```

---

## Deployed Contract Summary

| Contract | Network | Address |
|---|---|---|
| Token0 (STA) | Unichain Sepolia | `0xdEDeBDB00a83a0bD09b414Ea5FD876dB40799529` |
| Token1 (STB) | Unichain Sepolia | `0xEEe28Afd5077a0Add3D1C59f85B8eaEE49816127` |
| MockLendingPool | Unichain Sepolia | `0x66Cd8DfF334329F5657Ed4d0DBF5ffEca250C565` |
| CallbackReceiver | Unichain Sepolia | `0x045962833e855095DbE8B061d0e7E929a3f5C55c` |
| LiquidationShieldHook | Unichain Sepolia | `0xdA257AfcB7a3025690bf3B48ED9A0378FdE650C0` |
| HealthFactorMonitor | Reactive Lasna | `0xdEDeBDB00a83a0bD09b414Ea5FD876dB40799529` |

**Status:** ✅ End-to-End verified and operational.

---

---

# 🟡 Deployment 1: Ethereum Sepolia (2026-03-16)

**Deployer Address:** `0x8822F2965090Ddc102F7de354dfd6E642C090269`
**Networks:** Ethereum Sepolia (11155111) + Reactive Lasna (5318007)

---

## 1. Sepolia Token Deployment

**Command:** `forge script script/DeployTokens.s.sol --rpc-url $SEPOLIA_RPC --broadcast -vvv`

**Output:**
```text
== Logs ==
  Token0 deployed at: 0xe3fCC621Df2C3E78382bE425Cc3998d55752265d
  Token1 deployed at: 0xaa0C5D4170B14dc765806b14d9a28e71622979AB
```

---

## 2. Sepolia Hook & Receiver Deployment

**Command:** `forge script script/DeploySepolia.s.sol --rpc-url $SEPOLIA_RPC --broadcast -vvv`

**Output:**
```text
== Logs ==
  CallbackReceiver deployed at: 0x405A03BC2B2d60b70eaFa01b9784cC6FCD9564f7
  LiquidationShieldHook deployed at: 0xB5D8ca1A1C0Eb0aF80a77020F78e4760b906D0C0
```

---

## 3. Lasna Monitor Deployment

**Command:** `forge script script/DeployLasna.s.sol --rpc-url $REACTIVE_RPC --broadcast -vvv`

**Output:**
```text
== Logs ==
  HealthFactorMonitor deployed at: 0xfAa95DcF2c66b039359Bf64C936556C7a6eFe730
```

---

## 4. Pool Initialization & Shield Activation

**Command:** `forge script script/InteractLSH.s.sol --rpc-url $SEPOLIA_RPC --broadcast -vvv`

**Output:**
```text
== Logs ==
  Shield activated for user: 0x8822F2965090Ddc102F7de354dfd6E642C090269
```

---

## 5. Mock Lending Pool & Trigger Simulation

**Command:** `forge script script/DeployMockLending.s.sol --rpc-url $SEPOLIA_RPC --broadcast`

**Output:**
```text
== Logs ==
  MockLendingPool deployed at: 0x406BA4812160C568367Ff668483e371C93FB512d
```

**Trigger Borrow:**
`cast send 0x406BA4812160C568367Ff668483e371C93FB512d "triggerBorrow(address,uint256)" 0x8822... 100e18`
**Status:** success
**Tx Hash:** `0x9fba576441ccee5d2d367e9c7a4f96e02187917dffae5e5d28f5c759a1d0ce58`

---

## 6. Authorization & Monitor Init

**Authorize Proxy (Sepolia):**
```bash
cast send 0x405A03BC2B2d60b70eaFa01b9784cC6FCD9564f7 "addAuthorizedCaller(address)" $SEPOLIA_CALLBACK_PROXY
```
**Status:** success

**Initialize Monitor (Lasna):**
```bash
cast send 0xfAa95DcF2c66b039359Bf64C936556C7a6eFe730 "init()"
```
**Status:** success
**Tx Hash:** `0xa4c5b4ea57fc4068f4cde1b52f0cacb69b1680794c3a59af62bd2af26a2a315c`

---

## 7. Final Verification

**Command:** `cast call 0xB5D8ca1A1C0Eb0aF80a77020F78e4760b906D0C0 "positions(address)" 0x8822...`

**Output:** `0x0000...00000001`
✅ Position active and configured under protection.

**Status:** ✅ End-to-End verified as operational.
