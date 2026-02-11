# MoltMarketplace

ERC-721 NFT Marketplace smart contract with ERC-8004 (Trustless Agent) integration. Built for Monad.

## Features

| Feature | Description |
|---------|-------------|
| **Fixed-Price Listings** | List NFTs at a fixed price with expiry. Native (ETH/MON) or ERC-20 payments. |
| **Offers** | Buyers make ERC-20 offers on specific NFTs. Sellers accept on-chain. |
| **Collection Offers** | Make an offer on any NFT in a collection. Any holder can accept. |
| **English Auctions** | Ascending-bid auctions with reserve price, buy-now, scheduled start, anti-snipe (10min extension). |
| **Dutch Auctions** | Descending-price auctions with linear price decay over time. |
| **Bundle Listings** | List up to 20 NFTs as a single package at one price. |
| **ERC-2981 Royalties** | Automatic on-chain royalty distribution on every sale. |
| **ERC-8004 Compatible** | Works natively with ERC-8004 IdentityRegistry NFTs (agent trading). |

## Architecture

```
MoltMarketplace
├── AccessControl        (OZ v5 - role-based permissions)
├── Pausable             (OZ v5 - emergency circuit breaker)
├── ReentrancyGuard      (OZ v5 - reentrancy protection)
├── SafeERC20            (OZ v5 - safe token transfers)
└── IMoltMarketplace     (interface + structs/enums/events)
```

### Access Control (Roles)

The contract uses **OpenZeppelin AccessControl** with 4 roles:

| Role | Hex | Controls |
|------|-----|----------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | `grantRole()`, `revokeRole()` — manages all other roles |
| `PAUSER_ROLE` | `keccak256("PAUSER_ROLE")` | `pause()`, `unpause()` |
| `FEE_MANAGER_ROLE` | `keccak256("FEE_MANAGER_ROLE")` | `setPlatformFee()`, `setFeeRecipient()` |
| `TOKEN_MANAGER_ROLE` | `keccak256("TOKEN_MANAGER_ROLE")` | `addPaymentToken()`, `removePaymentToken()` |

On deployment, all 4 roles are granted to `initialAdmin`. After that:

```solidity
// Grant a role to a new address
marketplace.grantRole(PAUSER_ROLE, pauserAddress);

// Revoke a role
marketplace.revokeRole(PAUSER_ROLE, pauserAddress);

// Check if an address has a role
marketplace.hasRole(FEE_MANAGER_ROLE, someAddress);

// Self-renounce a role
marketplace.renounceRole(PAUSER_ROLE, msg.sender);
```

**Separation of duties example:**
- Ops team member gets `PAUSER_ROLE` only (can emergency-pause, nothing else)
- Finance role gets `FEE_MANAGER_ROLE` only (can adjust fees)
- Token governance gets `TOKEN_MANAGER_ROLE` only (can whitelist ERC-20s)
- Multisig holds `DEFAULT_ADMIN_ROLE` (can manage all roles)

### Payment Token Whitelist

Only whitelisted ERC-20 tokens can be used for listings, offers, and auctions. Native currency (address(0)) is always allowed.

```solidity
// Admin whitelists a token
marketplace.addPaymentToken(usdcAddress);

// Check if a token is allowed
marketplace.isPaymentTokenAllowed(usdcAddress); // true

// Admin removes a token
marketplace.removePaymentToken(usdcAddress);
```

### Platform Fee

- Configurable fee in basis points (1 BPS = 0.01%)
- **Hard cap: 10% (1000 BPS)** — enforced in contract, cannot be exceeded
- Fee is deducted from every sale and sent to `feeRecipient`
- Distribution order: Platform Fee → ERC-2981 Royalty → Seller

### Escrow Model

The marketplace contract itself acts as the escrow:

- **NFT escrow**: NFTs are transferred to the contract on listing/auction creation
- **Bid escrow**: Auction bids (native or ERC-20) are held in the contract
- **Failed refund escrow**: If a native refund fails (e.g., recipient contract reverts), funds are stored in `pendingWithdrawals` and can be claimed via `withdrawPending()`

## Security

### OpenZeppelin Integrations

| Module | Purpose |
|--------|---------|
| `AccessControl` | Role-based access (replaces single-owner pattern) |
| `Pausable` | Emergency pause — blocks new listings, buys, bids, offers |
| `ReentrancyGuard` | `nonReentrant` on all 15 external state-mutating functions with external calls |
| `SafeERC20` | Safe `transfer`/`transferFrom` — supports non-standard tokens (USDT, etc.) |

### Patterns Applied

- **Checks-Effects-Interactions (CEI)**: State changes (status updates) happen before external calls
- **Pull-payment for failed refunds**: Native refunds that fail don't revert the transaction — they go to `pendingWithdrawals`
- **Anti-snipe protection**: English auctions extend by 10 minutes if a bid arrives in the last 10 minutes
- **Pausable exit**: `cancelListing`, `cancelAuction`, `settleAuction` work even when paused (users can always exit positions)

### Audit Findings (Self-Audit)

| Severity | Finding | Status |
|----------|---------|--------|
| **HIGH** | Missing SafeERC20 for non-standard tokens | Fixed |
| **MEDIUM** | Auction bid griefing via reverting `receive()` | Fixed (pull-payment) |
| **MEDIUM** | `renounceOwnership()` could brick admin | Fixed (migrated to AccessControl) |
| **MEDIUM** | Bundle royalty only applied to first NFT | By design (documented) |
| **LOW** | No slippage protection on Dutch auction buy | Accepted |
| **LOW** | Dutch auctions have no expiry (must cancel manually) | Accepted |

## Build & Test

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast, anvil)
- Solidity 0.8.28

### Install

```bash
cd contract
forge install
```

### Build

```bash
forge build
```

### Test

```bash
# Run all 133 tests
forge test

# Verbose output
forge test -vv

# Run specific test file
forge test --match-path test/MoltMarketplace.t.sol
forge test --match-path test/MoltMarketplace8004.t.sol

# Run specific test
forge test --match-test test_grantRole_and_use
```

### Test Coverage

| Test File | Tests | Scope |
|-----------|-------|-------|
| `MoltMarketplace.t.sol` | 101 | Core marketplace: listings, offers, auctions, bundles, admin, roles |
| `MoltMarketplace8004.t.sol` | 32 | ERC-8004 integration: agent NFT trading, wallet clearing, resale |

## Deployment

### Environment Variables

```bash
export ADMIN="0x..."            # Initial admin (gets all roles)
export FEE_RECIPIENT="0x..."    # Platform fee recipient address
export PLATFORM_FEE_BPS=250     # 2.5% platform fee
export RPC_URL="https://..."    # Monad RPC endpoint
export PRIVATE_KEY="0x..."      # Deployer private key
```

### Deploy

```bash
forge script script/DeployMoltMarketplace.s.sol \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

### Post-Deployment Checklist

1. Verify contract on explorer
2. Whitelist ERC-20 payment tokens: `addPaymentToken(address)`
3. (Optional) Grant roles to team members / multisig
4. (Optional) Transfer `DEFAULT_ADMIN_ROLE` to a multisig

## Contract Interface

### User Functions

| Function | Payment | Description |
|----------|---------|-------------|
| `list(nftContract, tokenId, paymentToken, price, expiry)` | - | Create a fixed-price listing |
| `buy(listingId)` | ETH/ERC20 | Purchase a listed NFT |
| `cancelListing(listingId)` | - | Cancel your listing, reclaim NFT |
| `updateListingPrice(listingId, newPrice)` | - | Update listing price |
| `makeOffer(nftContract, tokenId, paymentToken, amount, expiry)` | - | Make an ERC-20 offer |
| `acceptOffer(offerId)` | - | Accept an offer (NFT owner) |
| `cancelOffer(offerId)` | - | Cancel your offer |
| `makeCollectionOffer(nftContract, paymentToken, amount, expiry)` | - | Offer on any NFT in collection |
| `acceptCollectionOffer(offerId, tokenId)` | - | Accept with a specific tokenId |
| `cancelCollectionOffer(offerId)` | - | Cancel collection offer |
| `createAuction(...)` | - | Create English auction |
| `bid(auctionId, amount)` | ETH/ERC20 | Place a bid |
| `settleAuction(auctionId)` | - | Settle ended auction |
| `cancelAuction(auctionId)` | - | Cancel auction (no bids only) |
| `createDutchAuction(...)` | - | Create Dutch auction |
| `buyDutchAuction(auctionId)` | ETH/ERC20 | Buy at current Dutch price |
| `cancelDutchAuction(auctionId)` | - | Cancel Dutch auction |
| `createBundleListing(...)` | - | List multiple NFTs as bundle |
| `buyBundle(bundleId)` | ETH/ERC20 | Buy entire bundle |
| `cancelBundleListing(bundleId)` | - | Cancel bundle listing |
| `withdrawPending()` | - | Claim escrowed failed refunds |

### Admin Functions

| Function | Required Role | Description |
|----------|---------------|-------------|
| `setPlatformFee(newFeeBps)` | `FEE_MANAGER_ROLE` | Set platform fee (max 10%) |
| `setFeeRecipient(newRecipient)` | `FEE_MANAGER_ROLE` | Set fee recipient address |
| `addPaymentToken(token)` | `TOKEN_MANAGER_ROLE` | Whitelist an ERC-20 token |
| `removePaymentToken(token)` | `TOKEN_MANAGER_ROLE` | Remove ERC-20 from whitelist |
| `pause()` | `PAUSER_ROLE` | Pause new listings/buys/bids |
| `unpause()` | `PAUSER_ROLE` | Resume operations |
| `grantRole(role, account)` | `DEFAULT_ADMIN_ROLE` | Grant a role |
| `revokeRole(role, account)` | `DEFAULT_ADMIN_ROLE` | Revoke a role |

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| OpenZeppelin Contracts | v5.x | AccessControl, Pausable, ReentrancyGuard, SafeERC20 |
| Forge Std | latest | Testing framework, IERC721 interface |

## License

MIT
