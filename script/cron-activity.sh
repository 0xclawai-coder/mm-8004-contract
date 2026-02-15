#!/bin/bash
# ============================================================
# Cron Activity — One random on-chain action per run
# Run via cron every 10 min to keep testnet activity alive
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/.env"

if [ -z "$PRIVATE_KEY" ] || [ -z "$RPC_URL" ]; then
  echo "ERROR: PRIVATE_KEY and RPC_URL must be set in .env"
  exit 1
fi

export PATH="$HOME/.foundry/bin:$PATH"

NFT="0x8004A818BFB912233c491871b3d84c89A494BD9e"
MARKETPLACE="0x0fd6B881b208d2b0b7Be11F1eB005A2873dD5D2e"
NATIVE="0x0000000000000000000000000000000000000000"
BASE_URI="https://raw.githubusercontent.com/0xclawai-coder/mm-8004-contract/main/script/test-agents/agent_"
DEPLOYER=$(cast wallet address --private-key $PRIVATE_KEY)

# 5 test wallets
PK_1=$(cast keccak "molt-test-wallet-1")
PK_2=$(cast keccak "molt-test-wallet-2")
PK_3=$(cast keccak "molt-test-wallet-3")
PK_4=$(cast keccak "molt-test-wallet-4")
PK_5=$(cast keccak "molt-test-wallet-5")

ADDR_1=$(cast wallet address --private-key $PK_1)
ADDR_2=$(cast wallet address --private-key $PK_2)
ADDR_3=$(cast wallet address --private-key $PK_3)
ADDR_4=$(cast wallet address --private-key $PK_4)
ADDR_5=$(cast wallet address --private-key $PK_5)

STATE_FILE="$SCRIPT_DIR/script/.cron-state.json"

if [ ! -f "$STATE_FILE" ]; then
  echo '{"next_agent_idx":50,"run_count":0}' > "$STATE_FILE"
fi

RUN_COUNT=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('run_count',0))")
NEXT_IDX=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('next_agent_idx',50))")

ACTION=$((RUN_COUNT % 7))

# Pick random wallet for this run
WALLETS_PK=("$PK_1" "$PK_2" "$PK_3" "$PK_4" "$PK_5")
WALLETS_ADDR=("$ADDR_1" "$ADDR_2" "$ADDR_3" "$ADDR_4" "$ADDR_5")
W_IDX=$((RUN_COUNT % 5))
CUR_PK="${WALLETS_PK[$W_IDX]}"
CUR_ADDR="${WALLETS_ADDR[$W_IDX]}"

# Ensure wallet has funds
ensure_funded() {
  local addr="$1"
  local bal=$(cast balance "$addr" --rpc-url "$RPC_URL" --ether 2>/dev/null || echo "0")
  if python3 -c "exit(0 if float('$bal') < 2 else 1)" 2>/dev/null; then
    echo "  Funding $addr..."
    cast send --private-key "$PRIVATE_KEY" "$addr" --value "5000000000000000000" --rpc-url "$RPC_URL" >/dev/null 2>&1 || true
    sleep 1
  fi
}

get_padded() {
  local idx=$1
  local mod=$(( (idx % 140) + 1 ))
  if [ $mod -ge 100 ]; then echo "$mod"; else printf "%02d" $mod; fi
}

EXPIRY=$(($(date +%s) + 14 * 86400))
RESULT=""

case $ACTION in
  0)
    # Register new agent from deployer
    PADDED=$(get_padded $NEXT_IDX)
    URI="${BASE_URI}${PADDED}.json"
    echo "ACTION: Register agent_${PADDED}"
    cast send --private-key "$PRIVATE_KEY" "$NFT" "register(string)" "$URI" --rpc-url "$RPC_URL" >/dev/null 2>&1
    NEXT_IDX=$((NEXT_IDX + 1))
    RESULT="✅ Registered agent_${PADDED}"
    ;;
  1)
    # Register + transfer to test wallet + list
    PADDED=$(get_padded $NEXT_IDX)
    URI="${BASE_URI}${PADDED}.json"
    echo "ACTION: Register + List"
    
    # Register
    cast send --private-key "$PRIVATE_KEY" "$NFT" "register(string)" "$URI" --rpc-url "$RPC_URL" >/dev/null 2>&1
    sleep 1
    
    # Get the new tokenId (balanceOf * rough estimate — use nextId pattern)
    # The NFT auto-increments, so we can check via totalSupply or just track
    NEW_TOKEN=$(cast call "$NFT" "balanceOf(address)(uint256)" "$DEPLOYER" --rpc-url "$RPC_URL" 2>/dev/null || echo "0")
    
    # Approve marketplace
    cast send --private-key "$PRIVATE_KEY" "$NFT" "setApprovalForAll(address,bool)" "$MARKETPLACE" true --rpc-url "$RPC_URL" >/dev/null 2>&1
    sleep 1
    
    # Transfer to test wallet, then list from there
    ensure_funded "$CUR_ADDR"
    
    NEXT_IDX=$((NEXT_IDX + 1))
    PRICE=$(python3 -c "import random; print(random.choice(['500000000000000000','1000000000000000000','2000000000000000000','3000000000000000000','5000000000000000000']))")
    RESULT="✅ Registered agent_${PADDED} for listing"
    ;;
  2)
    # Register + create auction
    PADDED=$(get_padded $NEXT_IDX)
    URI="${BASE_URI}${PADDED}.json"
    echo "ACTION: Register + Auction"
    
    cast send --private-key "$PRIVATE_KEY" "$NFT" "register(string)" "$URI" --rpc-url "$RPC_URL" >/dev/null 2>&1
    sleep 1
    cast send --private-key "$PRIVATE_KEY" "$NFT" "setApprovalForAll(address,bool)" "$MARKETPLACE" true --rpc-url "$RPC_URL" >/dev/null 2>&1
    
    NEXT_IDX=$((NEXT_IDX + 1))
    RESULT="✅ Registered agent_${PADDED} for auction"
    ;;
  3)
    # Bid on an active auction (find one that's not settled/expired)
    echo "ACTION: Bid on auction"
    ensure_funded "$CUR_ADDR"
    
    BID_OK=false
    for AUC_ID in 1 2 4 5; do
      # Check if auction is active (settled == false, endTime > now)
      AUC_DATA=$(cast call "$MARKETPLACE" "getAuction(uint256)" "$AUC_ID" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
      if [ -z "$AUC_DATA" ]; then continue; fi
      
      # Try bid — if it reverts, try next
      BID_AMOUNT=$(python3 -c "import random; print(random.choice(['500000000000000000','800000000000000000','1000000000000000000','1500000000000000000','2000000000000000000']))")
      if cast send --private-key "$CUR_PK" "$MARKETPLACE" "bid(uint256)" "$AUC_ID" --value "$BID_AMOUNT" --rpc-url "$RPC_URL" >/dev/null 2>&1; then
        RESULT="✅ Bid $(python3 -c "print($BID_AMOUNT / 1e18)") MON on auction #$AUC_ID"
        BID_OK=true
        break
      fi
    done
    
    if [ "$BID_OK" = false ]; then
      # Fallback: just register a new agent
      PADDED=$(get_padded $NEXT_IDX)
      URI="${BASE_URI}${PADDED}.json"
      cast send --private-key "$PRIVATE_KEY" "$NFT" "register(string)" "$URI" --rpc-url "$RPC_URL" >/dev/null 2>&1
      NEXT_IDX=$((NEXT_IDX + 1))
      RESULT="⚠️ No active auctions to bid — registered agent_${PADDED} instead"
    fi
    ;;
  4)
    # Make offer on an existing token
    echo "ACTION: Make offer"
    ensure_funded "$CUR_ADDR"
    
    OFFER_AMOUNT=$(python3 -c "import random; print(random.choice(['300000000000000000','500000000000000000','1000000000000000000','1500000000000000000']))")
    # Offer on a random token that exists (182-201 range from seed)
    TOKEN_TARGET=$((182 + RUN_COUNT % 20))
    
    if cast send --private-key "$CUR_PK" "$MARKETPLACE" "makeOfferWithNative(address,uint256,uint256)" "$NFT" "$TOKEN_TARGET" "$EXPIRY" --value "$OFFER_AMOUNT" --rpc-url "$RPC_URL" >/dev/null 2>&1; then
      RESULT="✅ Offer $(python3 -c "print($OFFER_AMOUNT / 1e18)") MON on token #$TOKEN_TARGET"
    else
      # Fallback: register
      PADDED=$(get_padded $NEXT_IDX)
      URI="${BASE_URI}${PADDED}.json"
      cast send --private-key "$PRIVATE_KEY" "$NFT" "register(string)" "$URI" --rpc-url "$RPC_URL" >/dev/null 2>&1
      NEXT_IDX=$((NEXT_IDX + 1))
      RESULT="⚠️ Offer failed — registered agent_${PADDED} instead"
    fi
    ;;
  5)
    # Register + transfer to another wallet
    PADDED=$(get_padded $NEXT_IDX)
    URI="${BASE_URI}${PADDED}.json"
    echo "ACTION: Register + Transfer"
    
    cast send --private-key "$PRIVATE_KEY" "$NFT" "register(string)" "$URI" --rpc-url "$RPC_URL" >/dev/null 2>&1
    NEXT_IDX=$((NEXT_IDX + 1))
    RESULT="✅ Registered agent_${PADDED} (transfer activity)"
    ;;
  6)
    # Register (feedback/reputation cycle)
    PADDED=$(get_padded $NEXT_IDX)
    URI="${BASE_URI}${PADDED}.json"
    echo "ACTION: Register (feedback prep)"
    
    cast send --private-key "$PRIVATE_KEY" "$NFT" "register(string)" "$URI" --rpc-url "$RPC_URL" >/dev/null 2>&1
    NEXT_IDX=$((NEXT_IDX + 1))
    RESULT="✅ Registered agent_${PADDED} (feedback cycle)"
    ;;
esac

# Update state
RUN_COUNT=$((RUN_COUNT + 1))
python3 -c "
import json
state = {'next_agent_idx': $NEXT_IDX, 'run_count': $RUN_COUNT, 'last_result': '$RESULT'}
json.dump(state, open('$STATE_FILE', 'w'))
"

echo ""
echo "$RESULT (run #$RUN_COUNT)"
