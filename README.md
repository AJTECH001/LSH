# 🛡️ Liquidation Shield Hook

**A Uniswap v4 hook that provides cross-chain, automated liquidation protection for DeFi lending positions — powered by Reactive Network.**

## The Problem

DeFi borrowers across Aave, Compound, and other lending protocols face a constant, invisible risk: **liquidation**. When your health factor drops below 1.0, your collateral is force-sold at a penalty — you lose 5-15% instantly.

The problem is that no one can monitor their positions 24/7 across multiple chains. You go to sleep, volatility hits, and you wake up liquidated. Existing solutions require centralized bots, trusted keepers, or constant manual monitoring.

## The Solution

The **Liquidation Shield Hook** combines **Uniswap v4 hooks** with **Reactive Network's event-driven smart contracts** to create a fully trustless, cross-chain liquidation protection system.

**How it works:**

1. **You register once** — set your health factor threshold and deposit protection funds into the hook
2. **Reactive Network watches** — a reactive smart contract monitors your lending positions across any EVM chain, 24/7, with no bots
3. **When danger hits** — if your health factor drops below your threshold, Reactive fires a callback
4. **The hook protects you** — your deposited funds are used to repay debt via Uniswap v4, restoring your health factor
5. **You keep your position** — no liquidation, no penalty, no manual intervention

The entire flow is **on-chain, trustless, and autonomous**. No keepers. No bots. No centralized infrastructure.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        USER INTERFACE                                │
│  1. activateShield(chainId, lendingPool, threshold, deposit)        │
│  2. Set it and forget it                                             │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                    ┌───────────▼───────────┐
                    │  LiquidationShield    │  (Uniswap v4 Hook)
                    │  Hook.sol             │  Deployed on Unichain/Sepolia
                    │                       │
                    │  • Manages deposits   │
                    │  • beforeSwap: fee    │
                    │    discount for       │
                    │    protection swaps   │
                    │  • afterSwap: log     │
                    │    protection events  │
                    │  • executeProtection  │
                    └───────────┬───────────┘
                                │ emits HealthCheckRequested
                                │
                    ┌───────────▼───────────┐
                    │  Reactive Network     │
                    │  HealthFactorMonitor  │  Deployed on Reactive Network
                    │                       │
                    │  • Subscribes to      │
                    │    lending events     │
                    │  • Monitors health    │
                    │    factor changes     │
                    │  • react() evaluates  │
                    │    conditions         │
                    └───────────┬───────────┘
                                │ emits Callback
                                │
                    ┌───────────▼───────────┐
                    │  CallbackReceiver     │  Deployed on Hook's chain
                    │                       │
                    │  • Receives callback  │
                    │  • Forwards to hook's │
                    │    executeProtection  │
                    └───────────────────────┘
                                │
                    ┌───────────▼───────────┐
                    │  Aave / Compound      │  Any EVM chain
                    │                       │
                    │  • Debt repaid        │
                    │  • Health factor      │
                    │    restored           │
                    │  • Position saved     │
                    └───────────────────────┘
```

---


## Key Features

- **Cross-chain monitoring** — watches lending positions on any EVM chain via Reactive Network
- **Automated protection** — no manual intervention, no bots, no keepers
- **Configurable thresholds** — set your own health factor trigger (1.0x to 2.0x)
- **Deposit-based model** — users deposit protection funds upfront, only used when needed
- **Fee discount** — protection swaps through the hook get reduced fees via `beforeSwap`
- **Cooldown protection** — prevents rapid-fire protections from draining deposits
- **Multi-user support** — single hook serves unlimited users efficiently

