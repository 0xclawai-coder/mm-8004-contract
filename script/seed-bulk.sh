#!/bin/bash
# ============================================================
# Bulk Seed Script — Register 100 agents + Create 50 listings + 50 auctions
# ============================================================
# Usage:
#   cd contract && source .env
#   bash script/seed-bulk.sh register     # Step 1: Register 100 agents
#   bash script/seed-bulk.sh transfer     # Step 2: Transfer to 4 wallets
#   bash script/seed-bulk.sh approve      # Step 3: Each wallet approves marketplace
#   bash script/seed-bulk.sh listings     # Step 4: Create fixed-price listings
#   bash script/seed-bulk.sh auctions     # Step 5: Create english auctions
#   bash script/seed-bulk.sh dutch        # Step 6: Create dutch auctions
#   bash script/seed-bulk.sh bundles      # Step 7: Create bundles
#   bash script/seed-bulk.sh all          # Run everything
# ============================================================

set -e

NFT="0x8004A818BFB912233c491871b3d84c89A494BD9e"
MARKETPLACE="0x0fd6B881b208d2b0b7Be11F1eB005A2873dD5D2e"
NATIVE="0x0000000000000000000000000000000000000000"
BASE_URI="https://raw.githubusercontent.com/0xclawai-coder/mm-8004-contract/main/script/test-agents/agent_"

# Deterministic wallet private keys
PK_A=$(cast keccak "molt-test-wallet-1")
PK_B=$(cast keccak "molt-test-wallet-2")
PK_C=$(cast keccak "molt-test-wallet-3")
PK_D=$(cast keccak "molt-test-wallet-4")

ADDR_A=$(cast wallet address --private-key $PK_A)
ADDR_B=$(cast wallet address --private-key $PK_B)
ADDR_C=$(cast wallet address --private-key $PK_C)
ADDR_D=$(cast wallet address --private-key $PK_D)

DEPLOYER=$(cast wallet address --private-key $PRIVATE_KEY)

# First token ID for this batch
FIRST_ID=${FIRST_ID:-64}
TOTAL_AGENTS=100

echo "============================================"
echo "Deployer: $DEPLOYER"
echo "Wallet A: $ADDR_A"
echo "Wallet B: $ADDR_B"
echo "Wallet C: $ADDR_C"
echo "Wallet D: $ADDR_D"
echo "First token ID: $FIRST_ID"
echo "============================================"

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
  echo "  FAILED after 3 attempts: $sig $@"
  return 1
}

# ─── Step 1: Register 100 agents ─────────────────────────────
do_register() {
  echo ""
  echo "=== STEP 1: Registering $TOTAL_AGENTS agents ==="

  for i in $(seq 0 $((TOTAL_AGENTS - 1))); do
    local idx=$((41 + i))  # agent_41.json .. agent_140.json
    local padded=$(printf "%02d" $idx)
    if [ $idx -ge 100 ]; then
      padded=$idx
    fi
    local uri="${BASE_URI}${padded}.json"

    echo -n "  Registering agent_${padded} (#$((FIRST_ID + i)))... "
    send "$PRIVATE_KEY" "$NFT" "register(string)" "$uri" --value 0
    echo "OK"
  done

  echo "=== Registration complete: tokens $FIRST_ID - $((FIRST_ID + TOTAL_AGENTS - 1)) ==="
}

# ─── Step 2: Transfer to wallets ─────────────────────────────
# Layout:
#   Deployer keeps: FIRST_ID+0 .. FIRST_ID+9    (10 tokens)
#   Wallet A:       FIRST_ID+10 .. FIRST_ID+34   (25 tokens)
#   Wallet B:       FIRST_ID+35 .. FIRST_ID+59   (25 tokens)
#   Wallet C:       FIRST_ID+60 .. FIRST_ID+79   (20 tokens)
#   Wallet D:       FIRST_ID+80 .. FIRST_ID+99   (20 tokens)
do_transfer() {
  echo ""
  echo "=== STEP 2: Transferring tokens to wallets ==="

  # Wallet A: 25 tokens
  echo "--- Wallet A ($ADDR_A): tokens $((FIRST_ID+10)) - $((FIRST_ID+34)) ---"
  for i in $(seq 10 34); do
    local tid=$((FIRST_ID + i))
    echo -n "  Transfer #$tid -> A... "
    send "$PRIVATE_KEY" "$NFT" "transferFrom(address,address,uint256)" "$DEPLOYER" "$ADDR_A" "$tid"
    echo "OK"
  done

  # Wallet B: 25 tokens
  echo "--- Wallet B ($ADDR_B): tokens $((FIRST_ID+35)) - $((FIRST_ID+59)) ---"
  for i in $(seq 35 59); do
    local tid=$((FIRST_ID + i))
    echo -n "  Transfer #$tid -> B... "
    send "$PRIVATE_KEY" "$NFT" "transferFrom(address,address,uint256)" "$DEPLOYER" "$ADDR_B" "$tid"
    echo "OK"
  done

  # Wallet C: 20 tokens
  echo "--- Wallet C ($ADDR_C): tokens $((FIRST_ID+60)) - $((FIRST_ID+79)) ---"
  for i in $(seq 60 79); do
    local tid=$((FIRST_ID + i))
    echo -n "  Transfer #$tid -> C... "
    send "$PRIVATE_KEY" "$NFT" "transferFrom(address,address,uint256)" "$DEPLOYER" "$ADDR_C" "$tid"
    echo "OK"
  done

  # Wallet D: 20 tokens
  echo "--- Wallet D ($ADDR_D): tokens $((FIRST_ID+80)) - $((FIRST_ID+99)) ---"
  for i in $(seq 80 99); do
    local tid=$((FIRST_ID + i))
    echo -n "  Transfer #$tid -> D... "
    send "$PRIVATE_KEY" "$NFT" "transferFrom(address,address,uint256)" "$DEPLOYER" "$ADDR_D" "$tid"
    echo "OK"
  done

  echo "=== Transfers complete ==="
}

# ─── Step 3: Approve marketplace ─────────────────────────────
do_approve() {
  echo ""
  echo "=== STEP 3: Approving marketplace for all wallets ==="

  # Deployer
  echo -n "  Deployer approving... "
  send "$PRIVATE_KEY" "$NFT" "setApprovalForAll(address,bool)" "$MARKETPLACE" true
  echo "OK"

  # Wallet A
  echo -n "  Wallet A approving... "
  send "$PK_A" "$NFT" "setApprovalForAll(address,bool)" "$MARKETPLACE" true
  echo "OK"

  # Wallet B
  echo -n "  Wallet B approving... "
  send "$PK_B" "$NFT" "setApprovalForAll(address,bool)" "$MARKETPLACE" true
  echo "OK"

  # Wallet C
  echo -n "  Wallet C approving... "
  send "$PK_C" "$NFT" "setApprovalForAll(address,bool)" "$MARKETPLACE" true
  echo "OK"

  # Wallet D
  echo -n "  Wallet D approving... "
  send "$PK_D" "$NFT" "setApprovalForAll(address,bool)" "$MARKETPLACE" true
  echo "OK"

  echo "=== Approvals complete ==="
}

# ─── Step 4: Fixed-price listings ────────────────────────────
# Deployer: 10 listings, Wallet A: 25 listings, Wallet C: 10 listings, Wallet D: 5 = 50 total
do_listings() {
  echo ""
  echo "=== STEP 4: Creating fixed-price listings (50 total) ==="

  # Price array for variety (in wei)
  local prices=(
    "250000000000000000"   # 0.25 MON
    "500000000000000000"   # 0.5 MON
    "750000000000000000"   # 0.75 MON
    "1000000000000000000"  # 1 MON
    "1500000000000000000"  # 1.5 MON
    "2000000000000000000"  # 2 MON
    "3000000000000000000"  # 3 MON
    "5000000000000000000"  # 5 MON
    "8000000000000000000"  # 8 MON
    "10000000000000000000" # 10 MON
    "15000000000000000000" # 15 MON
    "20000000000000000000" # 20 MON
    "25000000000000000000" # 25 MON
    "30000000000000000000" # 30 MON
    "50000000000000000000" # 50 MON
    "75000000000000000000" # 75 MON
    "100000000000000000000" # 100 MON
    "150000000000000000000" # 150 MON
    "200000000000000000000" # 200 MON
    "500000000000000000000" # 500 MON
  )

  local expiry_14d=$(($(date +%s) + 14 * 86400))
  local expiry_30d=$(($(date +%s) + 30 * 86400))

  # Deployer: 10 listings (FIRST_ID+0 .. FIRST_ID+9)
  echo "--- Deployer: 10 fixed-price listings ---"
  for i in $(seq 0 9); do
    local tid=$((FIRST_ID + i))
    local price=${prices[$((i % ${#prices[@]}))]}
    local expiry=$([[ $((i % 2)) -eq 0 ]] && echo $expiry_14d || echo $expiry_30d)
    echo -n "  List #$tid @ $(cast from-wei $price) MON... "
    send "$PRIVATE_KEY" "$MARKETPLACE" "list(address,uint256,address,uint256,uint256)" \
      "$NFT" "$tid" "$NATIVE" "$price" "$expiry"
    echo "OK"
  done

  # Wallet A: 25 listings (FIRST_ID+10 .. FIRST_ID+34)
  echo "--- Wallet A: 25 fixed-price listings ---"
  for i in $(seq 10 34); do
    local tid=$((FIRST_ID + i))
    local pi=$(( (i - 10) % ${#prices[@]} ))
    local price=${prices[$pi]}
    local expiry=$([[ $((i % 2)) -eq 0 ]] && echo $expiry_14d || echo $expiry_30d)
    echo -n "  List #$tid @ $(cast from-wei $price) MON... "
    send "$PK_A" "$MARKETPLACE" "list(address,uint256,address,uint256,uint256)" \
      "$NFT" "$tid" "$NATIVE" "$price" "$expiry"
    echo "OK"
  done

  # Wallet C: 10 listings (FIRST_ID+70 .. FIRST_ID+79)
  echo "--- Wallet C: 10 fixed-price listings ---"
  for i in $(seq 70 79); do
    local tid=$((FIRST_ID + i))
    local pi=$(( (i - 70) % ${#prices[@]} ))
    local price=${prices[$pi]}
    echo -n "  List #$tid @ $(cast from-wei $price) MON... "
    send "$PK_C" "$MARKETPLACE" "list(address,uint256,address,uint256,uint256)" \
      "$NFT" "$tid" "$NATIVE" "$price" "$expiry_30d"
    echo "OK"
  done

  # Wallet D: 5 listings (FIRST_ID+95 .. FIRST_ID+99)
  echo "--- Wallet D: 5 fixed-price listings ---"
  for i in $(seq 95 99); do
    local tid=$((FIRST_ID + i))
    local pi=$(( (i - 95) % ${#prices[@]} ))
    local price=${prices[$((pi + 5))]}
    echo -n "  List #$tid @ $(cast from-wei $price) MON... "
    send "$PK_D" "$MARKETPLACE" "list(address,uint256,address,uint256,uint256)" \
      "$NFT" "$tid" "$NATIVE" "$price" "$expiry_14d"
    echo "OK"
  done

  echo "=== Fixed-price listings complete (50 total) ==="
}

# ─── Step 5: English auctions ────────────────────────────────
# Wallet B: 25 auctions, Wallet D: 5 auctions = 30 total
do_auctions() {
  echo ""
  echo "=== STEP 5: Creating english auctions (30 total) ==="

  # Auction configs: startPrice, reservePrice, buyNowPrice, duration (seconds)
  # createAuction(address,uint256,address,uint256,uint256,uint256,uint256,uint256)
  # params: nft, tokenId, paymentToken, startPrice, reservePrice, buyNowPrice, startTime(0=now), duration

  # Wallet B: 25 english auctions (FIRST_ID+35 .. FIRST_ID+59)
  echo "--- Wallet B: 25 english auctions ---"
  local configs=(
    # startPrice reservePrice buyNowPrice duration
    "100000000000000000 0 0 172800"                          # 0.1 MON, no reserve, 2d
    "250000000000000000 0 0 259200"                          # 0.25 MON, 3d
    "500000000000000000 2000000000000000000 0 172800"        # 0.5 start, 2 reserve, 2d
    "500000000000000000 0 5000000000000000000 86400"         # 0.5 start, buyNow 5, 1d
    "1000000000000000000 0 0 345600"                         # 1 MON, 4d
    "1000000000000000000 3000000000000000000 0 259200"       # 1 start, 3 reserve, 3d
    "1000000000000000000 0 10000000000000000000 172800"      # 1 start, buyNow 10, 2d
    "1000000000000000000 5000000000000000000 15000000000000000000 259200" # full config 3d
    "2000000000000000000 0 0 172800"                         # 2 MON, 2d
    "2000000000000000000 8000000000000000000 0 432000"       # 2 start, 8 reserve, 5d
    "2000000000000000000 0 20000000000000000000 172800"      # 2 start, buyNow 20, 2d
    "3000000000000000000 10000000000000000000 30000000000000000000 259200" # 3d
    "5000000000000000000 0 0 604800"                         # 5 MON, 7d
    "5000000000000000000 15000000000000000000 0 345600"      # 5 start, 15 reserve, 4d
    "5000000000000000000 0 50000000000000000000 172800"      # buyNow 50, 2d
    "5000000000000000000 20000000000000000000 80000000000000000000 432000" # full 5d
    "10000000000000000000 0 0 259200"                        # 10 MON, 3d
    "10000000000000000000 30000000000000000000 0 345600"     # 10 start, 30 reserve, 4d
    "10000000000000000000 0 100000000000000000000 172800"    # buyNow 100, 2d
    "15000000000000000000 50000000000000000000 150000000000000000000 604800" # 7d
    "20000000000000000000 0 0 172800"                        # 20 MON, 2d
    "25000000000000000000 0 200000000000000000000 259200"    # buyNow 200, 3d
    "50000000000000000000 0 0 432000"                        # 50 MON, 5d
    "75000000000000000000 100000000000000000000 500000000000000000000 604800" # 7d
    "100000000000000000000 0 0 345600"                       # 100 MON, 4d
  )

  for i in $(seq 0 24); do
    local tid=$((FIRST_ID + 35 + i))
    local cfg=(${configs[$i]})
    local startP=${cfg[0]}
    local reserveP=${cfg[1]}
    local buyNowP=${cfg[2]}
    local duration=${cfg[3]}

    echo -n "  Auction #$tid: start=$(cast from-wei $startP) "
    [ "$reserveP" != "0" ] && echo -n "reserve=$(cast from-wei $reserveP) "
    [ "$buyNowP" != "0" ] && echo -n "buyNow=$(cast from-wei $buyNowP) "
    echo -n "${duration}s... "

    send "$PK_B" "$MARKETPLACE" \
      "createAuction(address,uint256,address,uint256,uint256,uint256,uint256,uint256)" \
      "$NFT" "$tid" "$NATIVE" "$startP" "$reserveP" "$buyNowP" "0" "$duration"
    echo "OK"
  done

  # Wallet D: 5 english auctions (FIRST_ID+90 .. FIRST_ID+94)
  echo "--- Wallet D: 5 english auctions ---"
  local d_configs=(
    "2000000000000000000 0 0 259200"
    "5000000000000000000 10000000000000000000 0 345600"
    "10000000000000000000 0 80000000000000000000 172800"
    "20000000000000000000 50000000000000000000 200000000000000000000 432000"
    "50000000000000000000 0 0 604800"
  )

  for i in $(seq 0 4); do
    local tid=$((FIRST_ID + 90 + i))
    local cfg=(${d_configs[$i]})
    local startP=${cfg[0]}
    local reserveP=${cfg[1]}
    local buyNowP=${cfg[2]}
    local duration=${cfg[3]}

    echo -n "  Auction #$tid: start=$(cast from-wei $startP)... "
    send "$PK_D" "$MARKETPLACE" \
      "createAuction(address,uint256,address,uint256,uint256,uint256,uint256,uint256)" \
      "$NFT" "$tid" "$NATIVE" "$startP" "$reserveP" "$buyNowP" "0" "$duration"
    echo "OK"
  done

  echo "=== English auctions complete (30 total) ==="
}

# ─── Step 6: Dutch auctions ──────────────────────────────────
# Wallet C: 10 dutch auctions (FIRST_ID+60 .. FIRST_ID+69)
do_dutch() {
  echo ""
  echo "=== STEP 6: Creating dutch auctions (10 total) ==="

  # createDutchAuction(address,uint256,address,uint256,uint256,uint256)
  # params: nft, tokenId, paymentToken, startPrice, endPrice, duration

  local configs=(
    "5000000000000000000 500000000000000000 86400"           # 5→0.5, 1d
    "8000000000000000000 1000000000000000000 43200"          # 8→1, 12h
    "10000000000000000000 1000000000000000000 172800"        # 10→1, 2d
    "15000000000000000000 2000000000000000000 259200"        # 15→2, 3d
    "20000000000000000000 3000000000000000000 86400"         # 20→3, 1d
    "30000000000000000000 5000000000000000000 172800"        # 30→5, 2d
    "50000000000000000000 8000000000000000000 432000"        # 50→8, 5d
    "75000000000000000000 10000000000000000000 345600"       # 75→10, 4d
    "100000000000000000000 15000000000000000000 604800"      # 100→15, 7d
    "200000000000000000000 25000000000000000000 604800"      # 200→25, 7d
  )

  echo "--- Wallet C: 10 dutch auctions ---"
  for i in $(seq 0 9); do
    local tid=$((FIRST_ID + 60 + i))
    local cfg=(${configs[$i]})
    local startP=${cfg[0]}
    local endP=${cfg[1]}
    local duration=${cfg[2]}

    echo -n "  Dutch #$tid: $(cast from-wei $startP) → $(cast from-wei $endP) MON, ${duration}s... "
    send "$PK_C" "$MARKETPLACE" \
      "createDutchAuction(address,uint256,address,uint256,uint256,uint256)" \
      "$NFT" "$tid" "$NATIVE" "$startP" "$endP" "$duration"
    echo "OK"
  done

  echo "=== Dutch auctions complete (10 total) ==="
}

# ─── Step 7: Bundles ─────────────────────────────────────────
# Wallet D: 5 bundles of 2 tokens each (FIRST_ID+80 .. FIRST_ID+89)
do_bundles() {
  echo ""
  echo "=== STEP 7: Creating bundles (5 total) ==="

  # createBundleListing(address[],uint256[],address,uint256,uint256)
  local bundle_prices=(
    "5000000000000000000"   # 5 MON
    "10000000000000000000"  # 10 MON
    "20000000000000000000"  # 20 MON
    "50000000000000000000"  # 50 MON
    "100000000000000000000" # 100 MON
  )

  local expiry=$(($(date +%s) + 30 * 86400))

  echo "--- Wallet D: 5 bundles (2 tokens each) ---"
  for b in $(seq 0 4); do
    local t1=$((FIRST_ID + 80 + b * 2))
    local t2=$((t1 + 1))
    local price=${bundle_prices[$b]}

    echo -n "  Bundle: tokens #$t1,#$t2 @ $(cast from-wei $price) MON... "
    send "$PK_D" "$MARKETPLACE" \
      "createBundleListing(address[],uint256[],address,uint256,uint256)" \
      "[${NFT},${NFT}]" "[$t1,$t2]" "$NATIVE" "$price" "$expiry"
    echo "OK"
  done

  echo "=== Bundles complete (5 total) ==="
}

# ─── Main ─────────────────────────────────────────────────────
case "${1:-all}" in
  register)  do_register ;;
  transfer)  do_transfer ;;
  approve)   do_approve ;;
  listings)  do_listings ;;
  auctions)  do_auctions ;;
  dutch)     do_dutch ;;
  bundles)   do_bundles ;;
  all)
    do_register
    do_transfer
    do_approve
    do_listings
    do_auctions
    do_dutch
    do_bundles
    echo ""
    echo "============================================"
    echo "=== ALL DONE ==="
    echo "  100 agents registered (tokens $FIRST_ID - $((FIRST_ID + 99)))"
    echo "  50 fixed-price listings"
    echo "  30 english auctions"
    echo "  10 dutch auctions"
    echo "  5 bundles"
    echo "============================================"
    ;;
  *)
    echo "Usage: $0 {register|transfer|approve|listings|auctions|dutch|bundles|all}"
    exit 1
    ;;
esac
