#!/usr/bin/env bash
# =============================================================================
#  LiquidationShield — Live Demo Script (Unichain Sepolia)
#  Run: bash demo.sh
# =============================================================================

set -e
source .env

HOOK=$HOOK_ADDRESS
RECEIVER=$CALLBACK_RECEIVER_ADDRESS
MOCK_POOL=$MOCK_LENDING_POOL
TOKEN0=$TOKEN0_ADDRESS
DEPLOYER=$(cast wallet address --private-key $PRIVATE_KEY)

# Repay amount for demo: 1 token — small enough to leave visible balance after protection
REPAY_AMOUNT=1000000000000000000

# Top-up amount: 20 tokens — ensures a healthy balance for the demo
TOPUP_AMOUNT=20000000000000000000

# Helper: convert raw wei to human-readable
to_ether() {
  python3 -c "print('{:.6f}'.format(int('$1'.strip('[]').split('[')[0]) / 1e18))" 2>/dev/null || echo "$1 wei"
}

SEP="\n──────────────────────────────────────────────────────────────\n"

echo -e "$SEP"
echo "  🛡️  LiquidationShield — Live Demo"
echo "  Admin wallet: $DEPLOYER"
echo -e "$SEP"

# ── Step 0: Verify owner ──────────────────────────────────────────────────────
OWNER=$(cast call $HOOK "owner()(address)" --rpc-url $UNICHAIN_RPC)
OWNER_LOWER=$(echo "$OWNER" | tr '[:upper:]' '[:lower:]')
DEPLOYER_LOWER=$(echo "$DEPLOYER" | tr '[:upper:]' '[:lower:]')
if [ "$OWNER_LOWER" != "$DEPLOYER_LOWER" ]; then
  IS_OWNER=false
else
  IS_OWNER=true
fi

# ── Setup: Top up Alice's deposit so demo always has enough balance ───────────
echo "🔧 SETUP: Topping up Alice's protection deposit for demo"
echo ""

IERC20_APPROVE="approve(address,uint256)"
cast send $TOKEN0 "$IERC20_APPROVE" $HOOK $TOPUP_AMOUNT \
  --rpc-url $UNICHAIN_RPC \
  --private-key $PRIVATE_KEY \
  --json | jq -r '"  approve tx: " + .transactionHash + "  " + (if .status == "0x1" then "✅" else "❌" end)'

sleep 3

cast send $HOOK \
  "topUpDeposit(uint256)" $TOPUP_AMOUNT \
  --rpc-url $UNICHAIN_RPC \
  --private-key $PRIVATE_KEY \
  --json | jq -r '"  topUp tx:   " + .transactionHash + "  " + (if .status == "0x1" then "✅" else "❌" end)'

sleep 3

echo -e "$SEP"

# ── Step 1: Show the shield is active ────────────────────────────────────────
echo "📋 STEP 1: Check Alice's shield position"
echo ""

IS_PROTECTED=$(cast call $HOOK "isProtected(address)(bool)" $DEPLOYER --rpc-url $UNICHAIN_RPC)
echo "  isProtected:         $IS_PROTECTED"

TOTAL_BEFORE=$(cast call $HOOK "totalProtections()(uint256)" --rpc-url $UNICHAIN_RPC)
echo "  Total protections:   $TOTAL_BEFORE"

FEES_BEFORE_RAW=$(cast call $HOOK "feesCollected(address)(uint256)" $TOKEN0 --rpc-url $UNICHAIN_RPC)
echo "  Fees collected:      $(to_ether $FEES_BEFORE_RAW) tokens"

POS=$(cast call $HOOK "getPosition(address)((address,uint256,address,address,address,uint256,uint256,uint256,uint256,bool))" $DEPLOYER --rpc-url $UNICHAIN_RPC)
DEPOSIT_RAW=$(python3 -c "import re; nums=re.findall(r'\b\d{10,}\b','$POS'); print(nums[1] if len(nums)>1 else 0)")
echo "  Deposit balance:     $(to_ether $DEPOSIT_RAW) tokens"

echo -e "$SEP"

# ── Step 2: Simulate a dangerous borrow event ─────────────────────────────────
echo "⚠️  STEP 2: Alice borrows on Aave — health factor drops below threshold"
echo "  (In production, Reactive Network detects this on Aave automatically)"
echo ""

cast send $MOCK_POOL \
  "triggerBorrow(address,uint256)" $DEPLOYER 100000000000000000000 \
  --rpc-url $UNICHAIN_RPC \
  --private-key $PRIVATE_KEY \
  --json | jq -r '"  tx: " + .transactionHash + "\n  status: " + (if .status == "0x1" then "✅ success" else "❌ failed" end)'

echo "  Borrow event emitted — Reactive Network watcher triggered"

sleep 5

# Check cooldown — wait if last protection was less than 5 minutes ago
COOLDOWN=300
POS_CD=$(cast call $HOOK "getPosition(address)((address,uint256,address,address,address,uint256,uint256,uint256,uint256,bool))" $DEPLOYER --rpc-url $UNICHAIN_RPC)
LAST_TRIGGERED=$(python3 -c "import re; nums=re.findall(r'\b\d{9,}\b','$POS_CD'); print(nums[2] if len(nums)>2 else 0)")
NOW=$(cast block latest --rpc-url $UNICHAIN_RPC --field timestamp | python3 -c "import sys; print(int(sys.stdin.read().strip(), 16))")
REMAINING=$(python3 -c "r=$COOLDOWN-($NOW-$LAST_TRIGGERED); print(max(0,r))")
if [ "$REMAINING" -gt 0 ]; then
  echo "  ⏳ Cooldown active — waiting ${REMAINING}s before protection can fire..."
  sleep $REMAINING
  sleep 3
fi

echo -e "$SEP"

# ── Step 3: Simulate Reactive callback → executeProtection ───────────────────
echo "🔁 STEP 3: Reactive Network fires callback → protection executes"
echo "  (CallbackReceiver.triggerProtection simulates the Reactive relayer delivery)"
echo ""

cast send $RECEIVER \
  "triggerProtection(address,uint256,uint256)" \
  $DEPLOYER 1100000000000000000 $REPAY_AMOUNT \
  --rpc-url $UNICHAIN_RPC \
  --private-key $PRIVATE_KEY \
  --json | jq -r '"  tx: " + .transactionHash + "\n  status: " + (if .status == "0x1" then "✅ success" else "❌ failed" end)'

sleep 3

echo -e "$SEP"

# ── Step 4: Show deposit deducted and fees collected ─────────────────────────
echo "📊 STEP 4: State after protection"
echo ""

TOTAL_AFTER=$(cast call $HOOK "totalProtections()(uint256)" --rpc-url $UNICHAIN_RPC)
echo "  Total protections:   $TOTAL_AFTER"

FEES_AFTER_RAW=$(cast call $HOOK "feesCollected(address)(uint256)" $TOKEN0 --rpc-url $UNICHAIN_RPC)
echo "  Fees collected:      $(to_ether $FEES_AFTER_RAW) tokens  (0.5% of repay)"

POS2=$(cast call $HOOK "getPosition(address)((address,uint256,address,address,address,uint256,uint256,uint256,uint256,bool))" $DEPLOYER --rpc-url $UNICHAIN_RPC)
DEPOSIT_RAW2=$(python3 -c "import re; nums=re.findall(r'\b\d{10,}\b','$POS2'); print(nums[1] if len(nums)>1 else 0)")
echo "  Deposit balance:     $(to_ether $DEPOSIT_RAW2) tokens  ← reduced by repay, Alice still protected"

echo -e "$SEP"

# ── Step 5: Fees sitting in hook ──────────────────────────────────────────────
echo "💰 STEP 5: Protocol fees accumulated in hook"
echo ""

FEES_FINAL_RAW=$(cast call $HOOK "feesCollected(address)(uint256)" $TOKEN0 --rpc-url $UNICHAIN_RPC)
echo "  Fees in hook:   $(to_ether $FEES_FINAL_RAW) tokens"
echo "  Hook address:   $HOOK"
echo ""

if [ "$IS_OWNER" = false ]; then
  echo "  ℹ️  Fee withdrawal skipped — hook owner is the CREATE2 factory (deployment quirk)."
  echo "  In production the constructor sets owner = deployer, making withdrawFees callable directly."
  echo "  Fees are verifiable on-chain at the hook address above."
else
  ADMIN_BAL_RAW=$(cast call $TOKEN0 "balanceOf(address)(uint256)" $DEPLOYER --rpc-url $UNICHAIN_RPC)
  echo "  Admin balance before: $(to_ether $ADMIN_BAL_RAW) tokens"

  cast send $HOOK \
    "withdrawFees(address,address)" $TOKEN0 $DEPLOYER \
    --rpc-url $UNICHAIN_RPC \
    --private-key $PRIVATE_KEY \
    --json | jq -r '"  tx: " + .transactionHash + "\n  status: " + (if .status == "0x1" then "✅ success" else "❌ failed" end)'

  sleep 3

  ADMIN_BAL_AFTER_RAW=$(cast call $TOKEN0 "balanceOf(address)(uint256)" $DEPLOYER --rpc-url $UNICHAIN_RPC)
  echo "  Admin balance after:  $(to_ether $ADMIN_BAL_AFTER_RAW) tokens"
fi

echo -e "$SEP"
echo "  ✅ Demo complete."
echo "  Alice's position was rescued automatically — no keepers, no bots."
echo "  Her deposit is reduced but she remains protected for future events."
echo -e "$SEP"
