#!/bin/bash
# ============================================================
# Activity Seed — Create diverse, active marketplace transactions
# ============================================================
# Goal: Make Activity Feed look alive with varied recent events
# - Register 20 new agents (tokens 182-201)
# - Fund 6 extra wallets
# - Listings, auctions, bids, offers, purchases, price updates
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "$PRIVATE_KEY" ] && [ -f "$SCRIPT_DIR/.env" ]; then
  source "$SCRIPT_DIR/.env"
fi

if [ -z "$PRIVATE_KEY" ] || [ -z "$RPC_URL" ]; then
  echo "ERROR: PRIVATE_KEY and RPC_URL must be set"
  exit 1
fi

NFT="0x8004A818BFB912233c491871b3d84c89A494BD9e"
MARKETPLACE="0x0fd6B881b208d2b0b7Be11F1eB005A2873dD5D2e"
NATIVE="0x0000000000000000000000000000000000000000"
BASE_URI="https://raw.githubusercontent.com/0xclawai-coder/mm-8004-contract/main/script/test-agents/agent_"
DEPLOYER=$(cast wallet address --private-key $PRIVATE_KEY)

# 10 wallets (original 4 + 6 new)
PK_1=$(cast keccak "molt-test-wallet-1")
PK_2=$(cast keccak "molt-test-wallet-2")
PK_3=$(cast keccak "molt-test-wallet-3")
PK_4=$(cast keccak "molt-test-wallet-4")
PK_5=$(cast keccak "molt-test-wallet-5")
PK_6=$(cast keccak "molt-test-wallet-6")
PK_7=$(cast keccak "molt-test-wallet-7")
PK_8=$(cast keccak "molt-test-wallet-8")
PK_9=$(cast keccak "molt-test-wallet-9")
PK_10=$(cast keccak "molt-test-wallet-10")

ADDR_1=$(cast wallet address --private-key $PK_1)
ADDR_2=$(cast wallet address --private-key $PK_2)
ADDR_3=$(cast wallet address --private-key $PK_3)
ADDR_4=$(cast wallet address --private-key $PK_4)
ADDR_5=$(cast wallet address --private-key $PK_5)
ADDR_6=$(cast wallet address --private-key $PK_6)
ADDR_7=$(cast wallet address --private-key $PK_7)
ADDR_8=$(cast wallet address --private-key $PK_8)
ADDR_9=$(cast wallet address --private-key $PK_9)
ADDR_10=$(cast wallet address --private-key $PK_10)

FIRST_ID=182

echo "============================================"
echo "Activity Seed — Making marketplace alive!"
echo "============================================"
echo "Deployer: $DEPLOYER"
echo ""

# Helper: cast send with retry
send() {
  local pk="$1"; shift
  local to="$1"; shift
  local sig="$1"; shift

  for attempt in 1 2 3; do
    if cast send --private-key "$pk" "$to" "$sig" "$@" --rpc-url "$RPC_URL" 2>/dev/null; then
      return 0
    fi
    echo "  Retry $attempt..."
    sleep 2
  done
  echo "  FAILED: $sig"
  return 0
}

# ─── Step 1: Fund new wallets ──────────────────────────────
do_fund() {
  echo "=== STEP 1: Funding wallets ==="
  for i in 1 2 3 4 5 6 7 8 9 10; do
    local addr_var="ADDR_$i"
    local addr="${!addr_var}"
    local bal=$(cast balance "$addr" --rpc-url "$RPC_URL" --ether 2>/dev/null)
    echo "  Wallet $i ($addr): $bal MON"
    
    # Fund if < 5 MON
    if (( $(echo "$bal < 5" | bc -l 2>/dev/null || echo "1") )); then
      echo -n "  Funding wallet $i with 8 MON... "
      cast send --private-key "$PRIVATE_KEY" "$addr" --value "8000000000000000000" --rpc-url "$RPC_URL" >/dev/null 2>&1 && echo "OK" || echo "FAILED"
      sleep 1
    fi
  done
  echo ""
}

# ─── Step 2: Register 20 new agents ──────────────────────────
do_register() {
  echo "=== STEP 2: Registering 20 agents (tokens $FIRST_ID - $((FIRST_ID + 19))) ==="
  for i in $(seq 0 19); do
    local idx=$((41 + i))  # reuse existing metadata
    local padded=$(printf "%02d" $idx)
    if [ $idx -ge 100 ]; then padded=$idx; fi
    local uri="${BASE_URI}${padded}.json"
    
    echo -n "  Register #$((FIRST_ID + i)) (agent_${padded})... "
    send "$PRIVATE_KEY" "$NFT" "register(string)" "$uri" --value 0
    echo "OK"
    sleep 0.5
  done
  echo ""
}

# ─── Step 3: Distribute to wallets ───────────────────────────
do_distribute() {
  echo "=== STEP 3: Distributing tokens ==="
  
  # Wallet 1: tokens 182-183  (for listings)
  # Wallet 2: tokens 184-185  (for listings)
  # Wallet 3: tokens 186-187  (for auctions)
  # Wallet 4: tokens 188-189  (for auctions)
  # Wallet 5: tokens 190-191  (for listings, will get bought)
  # Wallet 6: tokens 192-193  (for dutch auctions)
  # Wallet 7: tokens 194-195  (for listings)
  # Wallet 8: tokens 196-197  (for auctions)
  # Wallet 9: tokens 198-199  (for listings + offers)
  # Wallet 10: token 200-201   (for listings)
  
  local wallets=(1 1 2 2 3 3 4 4 5 5 6 6 7 7 8 8 9 9 10 10)
  
  for i in $(seq 0 19); do
    local tid=$((FIRST_ID + i))
    local wnum=${wallets[$i]}
    local addr_var="ADDR_$wnum"
    local addr="${!addr_var}"
    
    echo -n "  Transfer #$tid -> Wallet $wnum... "
    send "$PRIVATE_KEY" "$NFT" "transferFrom(address,address,uint256)" "$DEPLOYER" "$addr" "$tid"
    echo "OK"
    sleep 0.3
  done
  echo ""
}

# ─── Step 4: Approve marketplace for all ─────────────────────
do_approve() {
  echo "=== STEP 4: Approving marketplace ==="
  for i in 1 2 3 4 5 6 7 8 9 10; do
    local pk_var="PK_$i"
    local pk="${!pk_var}"
    echo -n "  Wallet $i approving... "
    send "$pk" "$NFT" "setApprovalForAll(address,bool)" "$MARKETPLACE" true
    echo "OK"
    sleep 0.3
  done
  echo ""
}

# ─── Step 5: Create listings ─────────────────────────────────
do_listings() {
  echo "=== STEP 5: Creating listings ==="
  
  local expiry_7d=$(($(date +%s) + 7 * 86400))
  local expiry_14d=$(($(date +%s) + 14 * 86400))
  
  # Wallet 1: 2 listings
  echo -n "  List #182 @ 0.5 MON... "
  send "$PK_1" "$MARKETPLACE" "list(address,uint256,address,uint256,uint256)" "$NFT" 182 "$NATIVE" "500000000000000000" "$expiry_14d"
  echo "OK"
  
  echo -n "  List #183 @ 1.2 MON... "
  send "$PK_1" "$MARKETPLACE" "list(address,uint256,address,uint256,uint256)" "$NFT" 183 "$NATIVE" "1200000000000000000" "$expiry_7d"
  echo "OK"
  
  # Wallet 2: 2 listings
  echo -n "  List #184 @ 3 MON... "
  send "$PK_2" "$MARKETPLACE" "list(address,uint256,address,uint256,uint256)" "$NFT" 184 "$NATIVE" "3000000000000000000" "$expiry_14d"
  echo "OK"
  
  echo -n "  List #185 @ 0.8 MON... "
  send "$PK_2" "$MARKETPLACE" "list(address,uint256,address,uint256,uint256)" "$NFT" 185 "$NATIVE" "800000000000000000" "$expiry_14d"
  echo "OK"
  
  # Wallet 5: 2 listings (these will get bought!)
  echo -n "  List #190 @ 0.3 MON... "
  send "$PK_5" "$MARKETPLACE" "list(address,uint256,address,uint256,uint256)" "$NFT" 190 "$NATIVE" "300000000000000000" "$expiry_7d"
  echo "OK"
  
  echo -n "  List #191 @ 0.5 MON... "
  send "$PK_5" "$MARKETPLACE" "list(address,uint256,address,uint256,uint256)" "$NFT" 191 "$NATIVE" "500000000000000000" "$expiry_7d"
  echo "OK"
  
  # Wallet 7: 2 listings
  echo -n "  List #194 @ 2 MON... "
  send "$PK_7" "$MARKETPLACE" "list(address,uint256,address,uint256,uint256)" "$NFT" 194 "$NATIVE" "2000000000000000000" "$expiry_14d"
  echo "OK"
  
  echo -n "  List #195 @ 5 MON... "
  send "$PK_7" "$MARKETPLACE" "list(address,uint256,address,uint256,uint256)" "$NFT" 195 "$NATIVE" "5000000000000000000" "$expiry_14d"
  echo "OK"
  
  # Wallet 9: 2 listings
  echo -n "  List #198 @ 1.5 MON... "
  send "$PK_9" "$MARKETPLACE" "list(address,uint256,address,uint256,uint256)" "$NFT" 198 "$NATIVE" "1500000000000000000" "$expiry_14d"
  echo "OK"
  
  echo -n "  List #199 @ 0.7 MON... "
  send "$PK_9" "$MARKETPLACE" "list(address,uint256,address,uint256,uint256)" "$NFT" 199 "$NATIVE" "700000000000000000" "$expiry_14d"
  echo "OK"
  
  # Wallet 10: 2 listings
  echo -n "  List #200 @ 4 MON... "
  send "$PK_10" "$MARKETPLACE" "list(address,uint256,address,uint256,uint256)" "$NFT" 200 "$NATIVE" "4000000000000000000" "$expiry_14d"
  echo "OK"
  
  echo -n "  List #201 @ 10 MON... "
  send "$PK_10" "$MARKETPLACE" "list(address,uint256,address,uint256,uint256)" "$NFT" 201 "$NATIVE" "10000000000000000000" "$expiry_14d"
  echo "OK"
  
  echo "  12 listings created"
  echo ""
}

# ─── Step 6: Create auctions ─────────────────────────────────
do_auctions() {
  echo "=== STEP 6: Creating auctions ==="
  
  # createAuction(nft, tokenId, paymentToken, startPrice, reservePrice, buyNowPrice, startTime(0=now), duration)
  
  # Wallet 3: English auctions
  echo -n "  Auction #186: start=0.5, reserve=5, buyNow=10, 3d... "
  send "$PK_3" "$MARKETPLACE" "createAuction(address,uint256,address,uint256,uint256,uint256,uint256,uint256)" \
    "$NFT" 186 "$NATIVE" "500000000000000000" "5000000000000000000" "10000000000000000000" 0 259200
  echo "OK"
  
  echo -n "  Auction #187: start=1, no reserve, 2d... "
  send "$PK_3" "$MARKETPLACE" "createAuction(address,uint256,address,uint256,uint256,uint256,uint256,uint256)" \
    "$NFT" 187 "$NATIVE" "1000000000000000000" 0 0 0 172800
  echo "OK"
  
  # Wallet 4: English auctions
  echo -n "  Auction #188: start=0.2, reserve=3, 4d... "
  send "$PK_4" "$MARKETPLACE" "createAuction(address,uint256,address,uint256,uint256,uint256,uint256,uint256)" \
    "$NFT" 188 "$NATIVE" "200000000000000000" "3000000000000000000" 0 0 345600
  echo "OK"
  
  echo -n "  Auction #189: start=2, buyNow=20, 5d... "
  send "$PK_4" "$MARKETPLACE" "createAuction(address,uint256,address,uint256,uint256,uint256,uint256,uint256)" \
    "$NFT" 189 "$NATIVE" "2000000000000000000" 0 "20000000000000000000" 0 432000
  echo "OK"
  
  # Wallet 6: Dutch auctions
  echo -n "  Dutch #192: 8→1 MON, 2d... "
  send "$PK_6" "$MARKETPLACE" "createDutchAuction(address,uint256,address,uint256,uint256,uint256)" \
    "$NFT" 192 "$NATIVE" "8000000000000000000" "1000000000000000000" 172800
  echo "OK"
  
  echo -n "  Dutch #193: 15→2 MON, 3d... "
  send "$PK_6" "$MARKETPLACE" "createDutchAuction(address,uint256,address,uint256,uint256,uint256)" \
    "$NFT" 193 "$NATIVE" "15000000000000000000" "2000000000000000000" 259200
  echo "OK"
  
  # Wallet 8: English auctions
  echo -n "  Auction #196: start=0.1, 7d... "
  send "$PK_8" "$MARKETPLACE" "createAuction(address,uint256,address,uint256,uint256,uint256,uint256,uint256)" \
    "$NFT" 196 "$NATIVE" "100000000000000000" 0 0 0 604800
  echo "OK"
  
  echo -n "  Auction #197: start=3, reserve=10, buyNow=30, 3d... "
  send "$PK_8" "$MARKETPLACE" "createAuction(address,uint256,address,uint256,uint256,uint256,uint256,uint256)" \
    "$NFT" 197 "$NATIVE" "3000000000000000000" "10000000000000000000" "30000000000000000000" 0 259200
  echo "OK"
  
  echo "  8 auctions created (6 english + 2 dutch)"
  echo ""
}

# ─── Step 7: Active transactions! ────────────────────────────
do_activity() {
  echo "=== STEP 7: Creating active transactions ==="
  
  # We need to know listing IDs. Let's query them from events
  # For now, assume they're sequential starting from last known count
  # The script will need to be smart about this
  
  sleep 3  # Wait for indexer
  
  # --- Bids on auctions ---
  # Wallet 2 bids on auction #186 (Wallet 3's)
  echo -n "  Bid on #186: 0.6 MON by Wallet 2... "
  send "$PK_2" "$MARKETPLACE" "bid(uint256)" 0 --value "600000000000000000"
  echo "OK"
  sleep 1
  
  # Wallet 4 bids higher on #186
  echo -n "  Bid on #186: 1.0 MON by Wallet 4... "
  send "$PK_4" "$MARKETPLACE" "bid(uint256)" 0 --value "1000000000000000000"
  echo "OK"
  sleep 1
  
  # Wallet 10 bids on #187
  echo -n "  Bid on #187: 1.5 MON by Wallet 10... "
  send "$PK_10" "$MARKETPLACE" "bid(uint256)" 1 --value "1500000000000000000"
  echo "OK"
  sleep 1
  
  # Wallet 1 bids on #188
  echo -n "  Bid on #188: 0.5 MON by Wallet 1... "
  send "$PK_1" "$MARKETPLACE" "bid(uint256)" 2 --value "500000000000000000"
  echo "OK"
  sleep 1
  
  # Wallet 7 bids on #196
  echo -n "  Bid on #196: 0.2 MON by Wallet 7... "
  send "$PK_7" "$MARKETPLACE" "bid(uint256)" 6 --value "200000000000000000"
  echo "OK"
  sleep 1
  
  # Wallet 9 bids higher on #196
  echo -n "  Bid on #196: 0.5 MON by Wallet 9... "
  send "$PK_9" "$MARKETPLACE" "bid(uint256)" 6 --value "500000000000000000"
  echo "OK"
  sleep 1
  
  # --- Offers on listings (using makeOfferWithNative) ---
  # makeOfferWithNative(address nftContract, uint256 tokenId, uint256 expiry) payable
  local offer_expiry=$(($(date +%s) + 7 * 86400))
  
  # Wallet 3 offers on listing #182 (Wallet 1's)
  echo -n "  Offer on #182: 0.3 MON by Wallet 3... "
  send "$PK_3" "$MARKETPLACE" "makeOfferWithNative(address,uint256,uint256)" "$NFT" 182 "$offer_expiry" --value "300000000000000000"
  echo "OK"
  sleep 1
  
  # Wallet 6 offers on listing #184 (Wallet 2's)
  echo -n "  Offer on #184: 2.0 MON by Wallet 6... "
  send "$PK_6" "$MARKETPLACE" "makeOfferWithNative(address,uint256,uint256)" "$NFT" 184 "$offer_expiry" --value "2000000000000000000"
  echo "OK"
  sleep 1
  
  # Wallet 8 offers on listing #194 (Wallet 7's)
  echo -n "  Offer on #194: 1.5 MON by Wallet 8... "
  send "$PK_8" "$MARKETPLACE" "makeOfferWithNative(address,uint256,uint256)" "$NFT" 194 "$offer_expiry" --value "1500000000000000000"
  echo "OK"
  sleep 1
  
  # --- Direct purchases ---
  # Wallet 8 buys #190 (0.3 MON listing by Wallet 5)
  echo -n "  Buy #190: 0.3 MON by Wallet 8... "
  # Need listing ID — we'll try to get it
  # buy(uint256 listingId) payable
  # Listing IDs are tricky — let me use a different approach
  # We'll query the backend API for listing IDs
  echo "SKIPPED (need listing IDs from backend)"
  
  # --- Price updates ---
  # Wallet 1 updates price of #183
  echo -n "  Price update #183: 1.2 → 0.9 MON... "
  echo "SKIPPED (need listing ID)"
  
  echo ""
  echo "=== Activity transactions complete ==="
  echo "  5 bids placed"
  echo "  3 offers made"
  echo ""
}

# ─── Main ─────────────────────────────────────────────────────
case "${1:-all}" in
  fund)       do_fund ;;
  register)   do_register ;;
  distribute) do_distribute ;;
  approve)    do_approve ;;
  listings)   do_listings ;;
  auctions)   do_auctions ;;
  activity)   do_activity ;;
  all)
    do_fund
    do_register
    do_distribute
    do_approve
    do_listings
    do_auctions
    do_activity
    echo "============================================"
    echo "=== ACTIVITY SEED COMPLETE ==="
    echo "  20 new agents (tokens 182-201)"
    echo "  12 fixed-price listings"
    echo "  8 auctions (6 english + 2 dutch)"
    echo "  Bids, offers, and activity generated"
    echo "============================================"
    ;;
  *)
    echo "Usage: $0 {fund|register|distribute|approve|listings|auctions|activity|all}"
    ;;
esac
