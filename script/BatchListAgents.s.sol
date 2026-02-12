// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MoltMarketplace} from "../src/MoltMarketplace.sol";

/**
 * @title BatchListAgents
 * @notice Creates diverse marketplace listings across all supported types.
 *
 * Token IDs 23-42 (20 agents) owned by deployer on testnet.
 *
 * Distribution:
 *   Fixed-price listings (Native MON):  23, 24, 25, 26, 27  (5 agents, varied prices)
 *   English auctions:                   28, 29, 30, 31, 32  (5 agents, varied settings)
 *   Dutch auctions:                     33, 34, 35, 36      (4 agents)
 *   Bundle listings:                    37-39 (bundle A), 40-42 (bundle B)  (6 agents in 2 bundles)
 *
 * Usage:
 *   source .env
 *   forge script script/BatchListAgents.s.sol:BatchListAgents \
 *     --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
 */
contract BatchListAgents is Script {
    // Testnet IdentityRegistry (NFT contract)
    address constant NFT = 0x8004A818BFB912233c491871b3d84c89A494BD9e;
    // Testnet marketplace proxy
    address constant MARKETPLACE = 0x0fd6B881b208d2b0b7Be11F1eB005A2873dD5D2e;

    // Native payment
    address constant NATIVE = address(0);

    function run() external {
        MoltMarketplace mp = MoltMarketplace(payable(MARKETPLACE));
        IERC721 nft = IERC721(NFT);

        vm.startBroadcast();

        // NOTE: setApprovalForAll must be done beforehand via cast send.
        // forge script batches all txs, so approval may not be mined in time.
        require(nft.isApprovedForAll(msg.sender, MARKETPLACE), "Marketplace not approved - run setApprovalForAll first");

        // ══════════════════════════════════════════════════════════════
        // 1. Fixed-price listings (Native MON) - tokens 23-27
        // ══════════════════════════════════════════════════════════════
        uint256 expiry7d = block.timestamp + 7 days;
        uint256 expiry30d = block.timestamp + 30 days;

        uint256 id;
        id = mp.list(NFT, 23, NATIVE, 0.5 ether, expiry7d);
        console.log("Listing #%d: Token 23 @ 0.5 MON (7d)", id);

        id = mp.list(NFT, 24, NATIVE, 1 ether, expiry7d);
        console.log("Listing #%d: Token 24 @ 1 MON (7d)", id);

        id = mp.list(NFT, 25, NATIVE, 5 ether, expiry30d);
        console.log("Listing #%d: Token 25 @ 5 MON (30d)", id);

        id = mp.list(NFT, 26, NATIVE, 10 ether, expiry30d);
        console.log("Listing #%d: Token 26 @ 10 MON (30d)", id);

        id = mp.list(NFT, 27, NATIVE, 100 ether, expiry30d);
        console.log("Listing #%d: Token 27 @ 100 MON (30d)", id);

        // ══════════════════════════════════════════════════════════════
        // 2. English auctions - tokens 28-32
        // ══════════════════════════════════════════════════════════════

        // 28: Basic auction - no reserve, no buyNow, 1 day
        id = mp.createAuction(NFT, 28, NATIVE, 0.1 ether, 0, 0, 0, 1 days);
        console.log("Auction #%d: Token 28 - basic, start 0.1 MON, 1d", id);

        // 29: With reserve price, 3 days
        id = mp.createAuction(NFT, 29, NATIVE, 0.5 ether, 2 ether, 0, 0, 3 days);
        console.log("Auction #%d: Token 29 - reserve 2 MON, 3d", id);

        // 30: With buy-now price, 1 day
        id = mp.createAuction(NFT, 30, NATIVE, 1 ether, 0, 10 ether, 0, 1 days);
        console.log("Auction #%d: Token 30 - buyNow 10 MON, 1d", id);

        // 31: Reserve + buy-now, 7 days
        id = mp.createAuction(NFT, 31, NATIVE, 1 ether, 5 ether, 20 ether, 0, 7 days);
        console.log("Auction #%d: Token 31 - reserve 5, buyNow 20, 7d", id);

        // 32: Scheduled start (1 hour from now), 2 days
        id = mp.createAuction(NFT, 32, NATIVE, 2 ether, 0, 50 ether, block.timestamp + 1 hours, 2 days);
        console.log("Auction #%d: Token 32 - scheduled +1h, buyNow 50, 2d", id);

        // ══════════════════════════════════════════════════════════════
        // 3. Dutch auctions - tokens 33-36
        // ══════════════════════════════════════════════════════════════

        // 33: 10 → 1 MON over 1 day
        id = mp.createDutchAuction(NFT, 33, NATIVE, 10 ether, 1 ether, 1 days);
        console.log("Dutch #%d: Token 33 - 10 -> 1 MON, 1d", id);

        // 34: 5 → 0.5 MON over 12 hours
        id = mp.createDutchAuction(NFT, 34, NATIVE, 5 ether, 0.5 ether, 12 hours);
        console.log("Dutch #%d: Token 34 - 5 -> 0.5 MON, 12h", id);

        // 35: 50 → 5 MON over 3 days
        id = mp.createDutchAuction(NFT, 35, NATIVE, 50 ether, 5 ether, 3 days);
        console.log("Dutch #%d: Token 35 - 50 -> 5 MON, 3d", id);

        // 36: 100 → 10 MON over 7 days
        id = mp.createDutchAuction(NFT, 36, NATIVE, 100 ether, 10 ether, 7 days);
        console.log("Dutch #%d: Token 36 - 100 -> 10 MON, 7d", id);

        // ══════════════════════════════════════════════════════════════
        // 4. Bundle listings - tokens 37-39, 40-42
        // ══════════════════════════════════════════════════════════════

        // Bundle A: tokens 37, 38, 39 - 3 MON for the pack
        address[] memory nftsA = new address[](3);
        uint256[] memory idsA = new uint256[](3);
        nftsA[0] = NFT; nftsA[1] = NFT; nftsA[2] = NFT;
        idsA[0] = 37;   idsA[1] = 38;   idsA[2] = 39;

        id = mp.createBundleListing(nftsA, idsA, NATIVE, 3 ether, expiry7d);
        console.log("Bundle #%d: Tokens 37-39 @ 3 MON (7d)", id);

        // Bundle B: tokens 40, 41, 42 - 15 MON for the pack
        address[] memory nftsB = new address[](3);
        uint256[] memory idsB = new uint256[](3);
        nftsB[0] = NFT; nftsB[1] = NFT; nftsB[2] = NFT;
        idsB[0] = 40;   idsB[1] = 41;   idsB[2] = 42;

        id = mp.createBundleListing(nftsB, idsB, NATIVE, 15 ether, expiry30d);
        console.log("Bundle #%d: Tokens 40-42 @ 15 MON (30d)", id);

        vm.stopBroadcast();

        console.log("=== All listings created successfully ===");
        console.log("  Fixed-price: 5 (tokens 23-27)");
        console.log("  English auctions: 5 (tokens 28-32)");
        console.log("  Dutch auctions: 4 (tokens 33-36)");
        console.log("  Bundles: 2 (tokens 37-42)");
    }
}
