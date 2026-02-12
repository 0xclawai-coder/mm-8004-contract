// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MoltMarketplace} from "../src/MoltMarketplace.sol";

interface IIdentityRegistry {
    function register(string calldata agentURI) external returns (uint256 agentId);
    function totalSupply() external view returns (uint256);
    function setApprovalForAll(address operator, bool approved) external;
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/**
 * @title SeedMultiWallet
 * @notice Registers 20 new agents, distributes to 4 deterministic wallets,
 *         and creates diverse marketplace listings from each wallet.
 *
 * Deterministic wallets derived from keccak256("molt-test-wallet-{1..4}").
 *
 * Run in 2 phases (use --slow to wait for confirmations):
 *
 *   Phase 1 — Deployer registers + distributes:
 *     forge script script/SeedMultiWallet.s.sol:SeedMultiWallet \
 *       --sig "phase1()" --rpc-url $RPC_URL --broadcast --slow
 *
 *   Phase 2 — Each wallet creates listings:
 *     forge script script/SeedMultiWallet.s.sol:SeedMultiWallet \
 *       --sig "phase2()" --rpc-url $RPC_URL --broadcast --slow
 */
contract SeedMultiWallet is Script {
    address constant NFT = 0x8004A818BFB912233c491871b3d84c89A494BD9e;
    address constant MARKETPLACE = 0x0fd6B881b208d2b0b7Be11F1eB005A2873dD5D2e;
    address constant NATIVE = address(0);

    // 4 deterministic wallet private keys
    uint256 constant PK_A = uint256(keccak256("molt-test-wallet-1"));
    uint256 constant PK_B = uint256(keccak256("molt-test-wallet-2"));
    uint256 constant PK_C = uint256(keccak256("molt-test-wallet-3"));
    uint256 constant PK_D = uint256(keccak256("molt-test-wallet-4"));

    string constant BASE_URI = "https://raw.githubusercontent.com/0xclawai-coder/mm-8004-contract/main/script/test-agents/agent_";

    function _wallets() internal pure returns (uint256[4] memory pks, address[4] memory addrs) {
        pks = [PK_A, PK_B, PK_C, PK_D];
        addrs[0] = vm.addr(PK_A);
        addrs[1] = vm.addr(PK_B);
        addrs[2] = vm.addr(PK_C);
        addrs[3] = vm.addr(PK_D);
    }

    /// @notice Print deterministic wallet addresses (no broadcast needed)
    function wallets() external view {
        (, address[4] memory addrs) = _wallets();
        for (uint256 i = 0; i < 4; i++) {
            console.log("Wallet %d: %s", i + 1, addrs[i]);
        }
    }

    /// @notice Phase 1: Deployer registers agents, transfers NFTs + gas
    function phase1() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        IIdentityRegistry registry = IIdentityRegistry(NFT);
        (, address[4] memory addrs) = _wallets();

        uint256 supplyBefore = registry.totalSupply();
        console.log("Current totalSupply:", supplyBefore);

        // ── Register 20 new agents ──
        vm.startBroadcast(deployerKey);

        uint256 firstId;
        for (uint256 i = 0; i < 20; i++) {
            uint256 idx = 21 + i; // agent_21.json .. agent_40.json
            string memory uri = string.concat(
                BASE_URI,
                idx < 10 ? "0" : "",
                vm.toString(idx),
                ".json"
            );
            uint256 agentId = registry.register(uri);
            if (i == 0) firstId = agentId;
            console.log("Registered agent_%d -> tokenId %d", idx, agentId);
        }

        console.log("First new tokenId:", firstId);
        console.log("Token range: %d - %d", firstId, firstId + 19);

        // ── Transfer 5 NFTs to each wallet ──
        for (uint256 w = 0; w < 4; w++) {
            for (uint256 t = 0; t < 5; t++) {
                uint256 tokenId = firstId + (w * 5) + t;
                registry.transferFrom(deployer, addrs[w], tokenId);
                console.log("  Transfer token %d -> Wallet %d (%s)", tokenId, w + 1, addrs[w]);
            }
        }

        // ── Send gas MON to each wallet (0.5 MON each) ──
        for (uint256 w = 0; w < 4; w++) {
            (bool ok,) = addrs[w].call{value: 0.5 ether}("");
            require(ok, "MON transfer failed");
            console.log("  Sent 0.5 MON gas -> Wallet %d", w + 1);
        }

        vm.stopBroadcast();

        console.log("=== Phase 1 complete ===");
        console.log("  20 agents registered (tokens %d-%d)", firstId, firstId + 19);
        console.log("  5 NFTs + 0.5 MON sent to each of 4 wallets");
    }

    /// @notice Phase 2: Each wallet approves marketplace and creates listings
    /// @param firstTokenId The first token ID from phase 1 output
    function phase2(uint256 firstTokenId) external {
        (uint256[4] memory pks,) = _wallets();
        IERC721 nft = IERC721(NFT);
        MoltMarketplace mp = MoltMarketplace(payable(MARKETPLACE));

        // ── Wallet A: Fixed-price listings (5 tokens, varied prices) ──
        {
            uint256 base = firstTokenId;
            vm.startBroadcast(pks[0]);

            if (!nft.isApprovedForAll(vm.addr(pks[0]), MARKETPLACE)) {
                IIdentityRegistry(NFT).setApprovalForAll(MARKETPLACE, true);
            }

            uint256 id;
            id = mp.list(NFT, base + 0, NATIVE, 0.25 ether, block.timestamp + 14 days);
            console.log("[A] Listing #%d: Token %d @ 0.25 MON", id, base + 0);

            id = mp.list(NFT, base + 1, NATIVE, 2 ether, block.timestamp + 7 days);
            console.log("[A] Listing #%d: Token %d @ 2 MON", id, base + 1);

            id = mp.list(NFT, base + 2, NATIVE, 8 ether, block.timestamp + 30 days);
            console.log("[A] Listing #%d: Token %d @ 8 MON", id, base + 2);

            id = mp.list(NFT, base + 3, NATIVE, 25 ether, block.timestamp + 30 days);
            console.log("[A] Listing #%d: Token %d @ 25 MON", id, base + 3);

            id = mp.list(NFT, base + 4, NATIVE, 50 ether, block.timestamp + 14 days);
            console.log("[A] Listing #%d: Token %d @ 50 MON", id, base + 4);

            vm.stopBroadcast();
        }

        // ── Wallet B: English auctions (5 tokens, varied settings) ──
        {
            uint256 base = firstTokenId + 5;
            vm.startBroadcast(pks[1]);

            if (!nft.isApprovedForAll(vm.addr(pks[1]), MARKETPLACE)) {
                IIdentityRegistry(NFT).setApprovalForAll(MARKETPLACE, true);
            }

            uint256 id;
            // Basic auction, 2 days
            id = mp.createAuction(NFT, base + 0, NATIVE, 0.5 ether, 0, 0, 0, 2 days);
            console.log("[B] Auction #%d: Token %d - basic 0.5 MON, 2d", id, base + 0);

            // Reserve + 3 days
            id = mp.createAuction(NFT, base + 1, NATIVE, 1 ether, 5 ether, 0, 0, 3 days);
            console.log("[B] Auction #%d: Token %d - reserve 5 MON, 3d", id, base + 1);

            // Buy-now, 1 day
            id = mp.createAuction(NFT, base + 2, NATIVE, 2 ether, 0, 15 ether, 0, 1 days);
            console.log("[B] Auction #%d: Token %d - buyNow 15 MON, 1d", id, base + 2);

            // Reserve + buy-now, 5 days
            id = mp.createAuction(NFT, base + 3, NATIVE, 3 ether, 10 ether, 30 ether, 0, 5 days);
            console.log("[B] Auction #%d: Token %d - reserve 10, buyNow 30, 5d", id, base + 3);

            // Scheduled start (+2h), 3 days
            id = mp.createAuction(NFT, base + 4, NATIVE, 5 ether, 0, 100 ether, block.timestamp + 2 hours, 3 days);
            console.log("[B] Auction #%d: Token %d - scheduled +2h, buyNow 100, 3d", id, base + 4);

            vm.stopBroadcast();
        }

        // ── Wallet C: Dutch auctions (4) + fixed-price (1) ──
        {
            uint256 base = firstTokenId + 10;
            vm.startBroadcast(pks[2]);

            if (!nft.isApprovedForAll(vm.addr(pks[2]), MARKETPLACE)) {
                IIdentityRegistry(NFT).setApprovalForAll(MARKETPLACE, true);
            }

            uint256 id;
            // Dutch: 20 → 2 MON, 1 day
            id = mp.createDutchAuction(NFT, base + 0, NATIVE, 20 ether, 2 ether, 1 days);
            console.log("[C] Dutch #%d: Token %d - 20 -> 2 MON, 1d", id, base + 0);

            // Dutch: 8 → 1 MON, 6 hours
            id = mp.createDutchAuction(NFT, base + 1, NATIVE, 8 ether, 1 ether, 6 hours);
            console.log("[C] Dutch #%d: Token %d - 8 -> 1 MON, 6h", id, base + 1);

            // Dutch: 75 → 10 MON, 5 days
            id = mp.createDutchAuction(NFT, base + 2, NATIVE, 75 ether, 10 ether, 5 days);
            console.log("[C] Dutch #%d: Token %d - 75 -> 10 MON, 5d", id, base + 2);

            // Dutch: 200 → 25 MON, 7 days
            id = mp.createDutchAuction(NFT, base + 3, NATIVE, 200 ether, 25 ether, 7 days);
            console.log("[C] Dutch #%d: Token %d - 200 -> 25 MON, 7d", id, base + 3);

            // Fixed-price: 12 MON
            id = mp.list(NFT, base + 4, NATIVE, 12 ether, block.timestamp + 14 days);
            console.log("[C] Listing #%d: Token %d @ 12 MON", id, base + 4);

            vm.stopBroadcast();
        }

        // ── Wallet D: Bundle (3) + Fixed-price (1) + Auction (1) ──
        {
            uint256 base = firstTokenId + 15;
            vm.startBroadcast(pks[3]);

            if (!nft.isApprovedForAll(vm.addr(pks[3]), MARKETPLACE)) {
                IIdentityRegistry(NFT).setApprovalForAll(MARKETPLACE, true);
            }

            uint256 id;

            // Bundle: tokens base+0, base+1, base+2 @ 7 MON
            address[] memory bundleNfts = new address[](3);
            uint256[] memory bundleIds = new uint256[](3);
            bundleNfts[0] = NFT; bundleNfts[1] = NFT; bundleNfts[2] = NFT;
            bundleIds[0] = base + 0; bundleIds[1] = base + 1; bundleIds[2] = base + 2;

            id = mp.createBundleListing(bundleNfts, bundleIds, NATIVE, 7 ether, block.timestamp + 14 days);
            console.log("[D] Bundle #%d: Tokens %d-%d @ 7 MON", id, base + 0, base + 2);

            // Fixed-price: 35 MON
            id = mp.list(NFT, base + 3, NATIVE, 35 ether, block.timestamp + 30 days);
            console.log("[D] Listing #%d: Token %d @ 35 MON", id, base + 3);

            // English auction: reserve + buyNow, 4 days
            id = mp.createAuction(NFT, base + 4, NATIVE, 10 ether, 20 ether, 80 ether, 0, 4 days);
            console.log("[D] Auction #%d: Token %d - reserve 20, buyNow 80, 4d", id, base + 4);

            vm.stopBroadcast();
        }

        console.log("=== Phase 2 complete ===");
        console.log("  Wallet A: 5 fixed-price listings");
        console.log("  Wallet B: 5 english auctions");
        console.log("  Wallet C: 4 dutch auctions + 1 fixed-price");
        console.log("  Wallet D: 1 bundle + 1 fixed-price + 1 auction");
    }

    /// @notice Convenience: run both phases (requires --slow flag)
    function run() external {
        this.phase1();
        // Read the first token ID from totalSupply
        uint256 total = IIdentityRegistry(NFT).totalSupply();
        uint256 firstTokenId = total - 19; // We just registered 20
        console.log("Auto-detected firstTokenId: %d", firstTokenId);
        this.phase2(firstTokenId);
    }
}
