#!/bin/bash
# ============================================================
# Cron Activity — Diverse on-chain actions per run
# Rotates: Register, List, Auction, Bid, Offer, Buy, Transfer
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/.env"
export PATH="$HOME/.foundry/bin:$PATH"

NFT="0x8004A818BFB912233c491871b3d84c89A494BD9e"
MARKETPLACE="0x0fd6B881b208d2b0b7Be11F1eB005A2873dD5D2e"
NATIVE="0x0000000000000000000000000000000000000000"
BASE_URI="https://raw.githubusercontent.com/0xclawai-coder/mm-8004-contract/main/script/test-agents/agent_"
DEPLOYER=$(cast wallet address --private-key $PRIVATE_KEY)

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

WALLETS_PK=("$PK_1" "$PK_2" "$PK_3" "$PK_4" "$PK_5")
WALLETS_ADDR=("$ADDR_1" "$ADDR_2" "$ADDR_3" "$ADDR_4" "$ADDR_5")

STATE_FILE="$SCRIPT_DIR/script/.cron-state.json"
[ ! -f "$STATE_FILE" ] && echo '{"next_agent_idx":68,"run_count":20,"last_token_id":227}' > "$STATE_FILE"

RUN_COUNT=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('run_count',20))")
NEXT_IDX=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('next_agent_idx',68))")
LAST_TOKEN=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('last_token_id',227))")

ACTION=$((RUN_COUNT % 7))
W_IDX=$((RUN_COUNT % 5))
CUR_PK="${WALLETS_PK[$W_IDX]}"
CUR_ADDR="${WALLETS_ADDR[$W_IDX]}"
EXPIRY=$(($(date +%s) + 14 * 86400))

ensure_funded() {
  local addr="$1"
  local bal=$(cast balance "$addr" --rpc-url "$RPC_URL" --ether 2>/dev/null || echo "0")
  if python3 -c "exit(0 if float('$bal') < 2 else 1)" 2>/dev/null; then
    echo "  Funding $addr..."
    cast send --private-key "$PRIVATE_KEY" "$addr" --value "5ether" --rpc-url "$RPC_URL" >/dev/null 2>&1 || true
    sleep 1
  fi
}

get_padded() {
  local mod=$(( ($1 % 140) + 1 ))
  if [ $mod -ge 100 ]; then echo "$mod"; else printf "%02d" $mod; fi
}

# Register helper — returns new tokenId
do_register() {
  local pk="$1"
  local padded=$(get_padded $NEXT_IDX)
  local uri="${BASE_URI}${padded}.json"
  cast send --private-key "$pk" "$NFT" "register(string)" "$uri" --rpc-url "$RPC_URL" >/dev/null 2>&1
  NEXT_IDX=$((NEXT_IDX + 1))
  LAST_TOKEN=$((LAST_TOKEN + 1))
  sleep 1
  echo "$LAST_TOKEN"
}

RESULT=""

case $ACTION in
  0)
    # Register new agent
    PADDED=$(get_padded $NEXT_IDX)
    TOKEN_ID=$(do_register "$PRIVATE_KEY")
    RESULT="✅ Registered agent_${PADDED} (token #$TOKEN_ID)"
    ;;

  1)
    # Register + List on marketplace
    PADDED=$(get_padded $NEXT_IDX)
    TOKEN_ID=$(do_register "$PRIVATE_KEY")
    
    # Approve + List
    cast send --private-key "$PRIVATE_KEY" "$NFT" "setApprovalForAll(address,bool)" "$MARKETPLACE" true --rpc-url "$RPC_URL" >/dev/null 2>&1
    sleep 1
    
    PRICE=$(python3 -c "import random; print(random.choice(['500000000000000000','1000000000000000000','2000000000000000000','5000000000000000000']))")
    if cast send --private-key "$PRIVATE_KEY" "$MARKETPLACE" "list(address,uint256,address,uint256,uint256)" "$NFT" "$TOKEN_ID" "$NATIVE" "$PRICE" "$EXPIRY" --rpc-url "$RPC_URL" >/dev/null 2>&1; then
      RESULT="✅ Listed agent_${PADDED} (token #$TOKEN_ID) @ $(python3 -c "print($PRICE / 1e18)") MON"
    else
      RESULT="⚠️ Registered agent_${PADDED} but list() failed"
    fi
    ;;

  2)
    # Register + Create Auction
    PADDED=$(get_padded $NEXT_IDX)
    TOKEN_ID=$(do_register "$PRIVATE_KEY")
    
    cast send --private-key "$PRIVATE_KEY" "$NFT" "setApprovalForAll(address,bool)" "$MARKETPLACE" true --rpc-url "$RPC_URL" >/dev/null 2>&1
    sleep 1
    
    START_PRICE=$(python3 -c "import random; print(random.choice(['500000000000000000','1000000000000000000','2000000000000000000']))")
    BUY_NOW=$(python3 -c "print(int($START_PRICE) * 5)")
    DURATION=$((3 * 86400))  # 3 days
    START_TIME=$(date +%s)
    
    if cast send --private-key "$PRIVATE_KEY" "$MARKETPLACE" "createAuction(address,uint256,address,uint256,uint256,uint256,uint256,uint256)" \
      "$NFT" "$TOKEN_ID" "$NATIVE" "$START_PRICE" "0" "$BUY_NOW" "$START_TIME" "$DURATION" \
      --rpc-url "$RPC_URL" >/dev/null 2>&1; then
      RESULT="✅ Auction created for agent_${PADDED} (token #$TOKEN_ID) starting $(python3 -c "print($START_PRICE / 1e18)") MON"
    else
      RESULT="⚠️ Registered agent_${PADDED} but createAuction() failed"
    fi
    ;;

  3)
    # Bid on active auction
    ensure_funded "$CUR_ADDR"
    
    BID_OK=false
    for AUC_ID in $(python3 -c "import random; ids=list(range(1,8)); random.shuffle(ids); print(' '.join(map(str,ids)))"); do
      BID_AMOUNT=$(python3 -c "import random; print(random.choice(['500000000000000000','1000000000000000000','1500000000000000000','2000000000000000000','3000000000000000000']))")
      if cast send --private-key "$CUR_PK" "$MARKETPLACE" "bid(uint256,uint256)" "$AUC_ID" "$BID_AMOUNT" --value "$BID_AMOUNT" --rpc-url "$RPC_URL" >/dev/null 2>&1; then
        RESULT="✅ Bid $(python3 -c "print($BID_AMOUNT / 1e18)") MON on auction #$AUC_ID"
        BID_OK=true
        break
      fi
    done
    
    if [ "$BID_OK" = false ]; then
      PADDED=$(get_padded $NEXT_IDX)
      TOKEN_ID=$(do_register "$PRIVATE_KEY")
      RESULT="⚠️ No active auctions — registered agent_${PADDED} instead"
    fi
    ;;

  4)
    # Make offer on existing token
    ensure_funded "$CUR_ADDR"
    
    OFFER_AMOUNT=$(python3 -c "import random; print(random.choice(['300000000000000000','500000000000000000','1000000000000000000','1500000000000000000']))")
    TOKEN_TARGET=$((182 + RUN_COUNT % 30))
    
    if cast send --private-key "$CUR_PK" "$MARKETPLACE" "makeOfferWithNative(address,uint256,uint256)" "$NFT" "$TOKEN_TARGET" "$EXPIRY" --value "$OFFER_AMOUNT" --rpc-url "$RPC_URL" >/dev/null 2>&1; then
      RESULT="✅ Offer $(python3 -c "print($OFFER_AMOUNT / 1e18)") MON on token #$TOKEN_TARGET"
    else
      PADDED=$(get_padded $NEXT_IDX)
      TOKEN_ID=$(do_register "$PRIVATE_KEY")
      RESULT="⚠️ Offer failed — registered agent_${PADDED} instead"
    fi
    ;;

  5)
    # Buy a listing (from test wallet)
    ensure_funded "$CUR_ADDR"
    
    BUY_OK=false
    for LIST_ID in $(python3 -c "import random; ids=list(range(1,11)); random.shuffle(ids); print(' '.join(map(str,ids)))"); do
      # Get listing price from contract
      LIST_DATA=$(cast call "$MARKETPLACE" "getListing(uint256)" "$LIST_ID" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
      if [ -z "$LIST_DATA" ]; then continue; fi
      
      # Try to buy
      PRICE=$(python3 -c "
data='$LIST_DATA'
# price is at offset 4*64 = 256 chars from start (5th field, 0-indexed field 4)
price_hex = data[2+4*64:2+5*64]
print(int(price_hex, 16))
" 2>/dev/null || echo "0")
      
      if [ "$PRICE" != "0" ] && cast send --private-key "$CUR_PK" "$MARKETPLACE" "buy(uint256)" "$LIST_ID" --value "$PRICE" --rpc-url "$RPC_URL" >/dev/null 2>&1; then
        RESULT="✅ Bought listing #$LIST_ID for $(python3 -c "print($PRICE / 1e18)") MON"
        BUY_OK=true
        break
      fi
    done
    
    if [ "$BUY_OK" = false ]; then
      PADDED=$(get_padded $NEXT_IDX)
      TOKEN_ID=$(do_register "$PRIVATE_KEY")
      RESULT="⚠️ No buyable listings — registered agent_${PADDED} instead"
    fi
    ;;

  6)
    # Register + Transfer to random wallet
    PADDED=$(get_padded $NEXT_IDX)
    TOKEN_ID=$(do_register "$PRIVATE_KEY")
    
    TARGET_ADDR="${WALLETS_ADDR[$((RUN_COUNT % 5))]}"
    if cast send --private-key "$PRIVATE_KEY" "$NFT" "transferFrom(address,address,uint256)" "$DEPLOYER" "$TARGET_ADDR" "$TOKEN_ID" --rpc-url "$RPC_URL" >/dev/null 2>&1; then
      RESULT="✅ Transferred token #$TOKEN_ID to ${TARGET_ADDR:0:8}..."
    else
      RESULT="⚠️ Registered agent_${PADDED} but transfer failed"
    fi
    ;;
esac

# Update state
RUN_COUNT=$((RUN_COUNT + 1))
python3 -c "
import json
state = {'next_agent_idx': $NEXT_IDX, 'run_count': $RUN_COUNT, 'last_token_id': $LAST_TOKEN, 'last_result': '''$RESULT'''}
json.dump(state, open('$STATE_FILE', 'w'))
"

echo "$RESULT (run #$RUN_COUNT)"
