// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {MoltMarketplace} from "../src/MoltMarketplace.sol";
import {IMoltMarketplace} from "../src/interfaces/IMoltMarketplace.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title ERC-8004 x MoltMarketplace Integration Tests
/// @notice Tests all marketplace features using ERC-8004 IdentityRegistry NFTs.
///         Verifies register -> list/buy/offer/auction flow and Transfer event behavior.
contract MoltMarketplace8004Test is Test {
    MoltMarketplace public marketplace;
    MockIdentityRegistry public registry;
    MockERC20 public token;

    address public owner = makeAddr("owner");
    address public feeRecipient = makeAddr("feeRecipient");
    address public alice = makeAddr("alice");   // agent registrant / seller
    address public bob = makeAddr("bob");       // buyer / bidder
    address public carol = makeAddr("carol");   // second bidder

    uint256 public constant PLATFORM_FEE_BPS = 250; // 2.5%
    uint256 public constant LISTING_PRICE = 1 ether;

    uint256 public agentId0; // alice's agent

    function setUp() public {
        // Deploy marketplace
        vm.prank(owner);
        marketplace = new MoltMarketplace(owner, feeRecipient, PLATFORM_FEE_BPS);

        // Deploy mock 8004 registry
        registry = new MockIdentityRegistry();

        // Deploy ERC-20 payment token
        token = new MockERC20("USDC", "USDC", 6);

        // Whitelist ERC-20 token
        vm.prank(owner);
        marketplace.addPaymentToken(address(token));

        // Alice registers an 8004 agent (mints NFT)
        vm.prank(alice);
        agentId0 = registry.register("ipfs://agent-metadata");

        // Fund accounts
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        vm.deal(alice, 10 ether);
        token.mint(bob, 1000e6);
        token.mint(carol, 1000e6);
    }

    // ══════════════════════════════════════════════════════
    //               8004 REGISTRATION BASICS
    // ══════════════════════════════════════════════════════

    function test_register_mints_nft() public view {
        assertEq(registry.ownerOf(agentId0), alice);
        assertEq(registry.balanceOf(alice), 1);
    }

    function test_register_sets_agentWallet() public view {
        address wallet = registry.getAgentWallet(agentId0);
        assertEq(wallet, alice);
    }

    function test_register_emits_events() public {
        vm.prank(bob);
        vm.expectEmit(true, true, false, true);
        emit MockIdentityRegistry.Registered(1, "ipfs://bob-agent", bob);
        registry.register("ipfs://bob-agent");
    }

    // ══════════════════════════════════════════════════════
    //              8004 -> LISTING (NATIVE)
    // ══════════════════════════════════════════════════════

    function test_8004_list_and_buy_native() public {
        vm.startPrank(alice);
        registry.approve(address(marketplace), agentId0);
        uint256 listingId = marketplace.list(
            address(registry), agentId0, address(0), LISTING_PRICE, block.timestamp + 1 days
        );
        vm.stopPrank();

        assertEq(listingId, 1);
        assertEq(registry.ownerOf(agentId0), address(marketplace));

        uint256 aliceBalBefore = alice.balance;
        uint256 feeBalBefore = feeRecipient.balance;

        vm.prank(bob);
        marketplace.buy{value: LISTING_PRICE}(listingId);

        assertEq(registry.ownerOf(agentId0), bob);

        uint256 expectedFee = (LISTING_PRICE * PLATFORM_FEE_BPS) / 10_000;
        assertEq(feeRecipient.balance - feeBalBefore, expectedFee);
        assertEq(alice.balance - aliceBalBefore, LISTING_PRICE - expectedFee);

        IMoltMarketplace.Listing memory listing = marketplace.getListing(listingId);
        assertEq(uint8(listing.status), uint8(IMoltMarketplace.ListingStatus.Sold));
    }

    function test_8004_agentWallet_cleared_after_sale() public {
        vm.startPrank(alice);
        registry.approve(address(marketplace), agentId0);
        marketplace.list(address(registry), agentId0, address(0), LISTING_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        vm.prank(bob);
        marketplace.buy{value: LISTING_PRICE}(1);

        address wallet = registry.getAgentWallet(agentId0);
        assertEq(wallet, address(0));
    }

    // ══════════════════════════════════════════════════════
    //              8004 -> LISTING (ERC-20)
    // ══════════════════════════════════════════════════════

    function test_8004_list_and_buy_erc20() public {
        vm.startPrank(alice);
        registry.approve(address(marketplace), agentId0);
        uint256 listingId = marketplace.list(
            address(registry), agentId0, address(token), 100e6, block.timestamp + 1 days
        );
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(address(marketplace), 100e6);
        marketplace.buy(listingId);
        vm.stopPrank();

        assertEq(registry.ownerOf(agentId0), bob);
        uint256 expectedFee = (100e6 * PLATFORM_FEE_BPS) / 10_000;
        assertEq(token.balanceOf(feeRecipient), expectedFee);
        assertEq(token.balanceOf(alice), 100e6 - expectedFee);
    }

    // ══════════════════════════════════════════════════════
    //              8004 -> CANCEL LISTING
    // ══════════════════════════════════════════════════════

    function test_8004_cancel_listing() public {
        vm.startPrank(alice);
        registry.approve(address(marketplace), agentId0);
        uint256 listingId = marketplace.list(
            address(registry), agentId0, address(0), LISTING_PRICE, block.timestamp + 1 days
        );
        marketplace.cancelListing(listingId);
        vm.stopPrank();

        assertEq(registry.ownerOf(agentId0), alice);

        address wallet = registry.getAgentWallet(agentId0);
        assertEq(wallet, address(0));
    }

    // ══════════════════════════════════════════════════════
    //               8004 -> OFFER FLOW
    // ══════════════════════════════════════════════════════

    function test_8004_offer_and_accept() public {
        vm.startPrank(bob);
        token.approve(address(marketplace), 50e6);
        uint256 offerId = marketplace.makeOffer(
            address(registry), agentId0, address(token), 50e6, block.timestamp + 1 days
        );
        vm.stopPrank();

        assertEq(offerId, 1);

        vm.startPrank(alice);
        registry.approve(address(marketplace), agentId0);
        marketplace.acceptOffer(offerId);
        vm.stopPrank();

        assertEq(registry.ownerOf(agentId0), bob);

        uint256 expectedFee = (50e6 * PLATFORM_FEE_BPS) / 10_000;
        assertEq(token.balanceOf(feeRecipient), expectedFee);
        assertEq(token.balanceOf(alice), 50e6 - expectedFee);

        assertEq(registry.getAgentWallet(agentId0), address(0));
    }

    function test_8004_offer_cancel() public {
        vm.startPrank(bob);
        token.approve(address(marketplace), 50e6);
        uint256 offerId = marketplace.makeOffer(
            address(registry), agentId0, address(token), 50e6, block.timestamp + 1 days
        );
        marketplace.cancelOffer(offerId);
        vm.stopPrank();

        IMoltMarketplace.Offer memory offer = marketplace.getOffer(offerId);
        assertEq(uint8(offer.status), uint8(IMoltMarketplace.OfferStatus.Cancelled));

        assertEq(registry.ownerOf(agentId0), alice);
        assertEq(registry.getAgentWallet(agentId0), alice);
    }

    function test_8004_offer_revert_expired() public {
        vm.startPrank(bob);
        token.approve(address(marketplace), 50e6);
        marketplace.makeOffer(
            address(registry), agentId0, address(token), 50e6, block.timestamp + 1 days
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);

        vm.startPrank(alice);
        registry.approve(address(marketplace), agentId0);
        vm.expectRevert("Offer expired");
        marketplace.acceptOffer(1);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════
    //              8004 -> AUCTION (NATIVE)
    // ══════════════════════════════════════════════════════

    function test_8004_auction_full_flow_native() public {
        vm.startPrank(alice);
        registry.approve(address(marketplace), agentId0);
        uint256 auctionId = marketplace.createAuction(
            address(registry), agentId0, address(0), 1 ether, 0, 0, 0, 1 days
        );
        vm.stopPrank();

        assertEq(auctionId, 1);
        assertEq(registry.ownerOf(agentId0), address(marketplace));

        vm.prank(bob);
        marketplace.bid{value: 1 ether}(auctionId, 0);

        IMoltMarketplace.Auction memory auction = marketplace.getAuction(auctionId);
        assertEq(auction.highestBidder, bob);
        assertEq(auction.highestBid, 1 ether);

        vm.prank(carol);
        marketplace.bid{value: 1.1 ether}(auctionId, 0);

        auction = marketplace.getAuction(auctionId);
        assertEq(auction.highestBidder, carol);

        assertEq(bob.balance, 100 ether);

        vm.warp(block.timestamp + 2 days);
        marketplace.settleAuction(auctionId);

        assertEq(registry.ownerOf(agentId0), carol);

        assertEq(registry.getAgentWallet(agentId0), address(0));

        uint256 expectedFee = (1.1 ether * PLATFORM_FEE_BPS) / 10_000;
        assertEq(feeRecipient.balance, expectedFee);
    }

    function test_8004_auction_erc20() public {
        vm.startPrank(alice);
        registry.approve(address(marketplace), agentId0);
        uint256 auctionId = marketplace.createAuction(
            address(registry), agentId0, address(token), 10e6, 0, 0, 0, 1 days
        );
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(address(marketplace), 10e6);
        marketplace.bid(auctionId, 10e6);
        vm.stopPrank();

        vm.startPrank(carol);
        token.approve(address(marketplace), 11e6);
        marketplace.bid(auctionId, 11e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);
        marketplace.settleAuction(auctionId);

        assertEq(registry.ownerOf(agentId0), carol);
        uint256 expectedFee = (11e6 * PLATFORM_FEE_BPS) / 10_000;
        assertEq(token.balanceOf(feeRecipient), expectedFee);
    }

    function test_8004_auction_no_bids() public {
        vm.startPrank(alice);
        registry.approve(address(marketplace), agentId0);
        uint256 auctionId = marketplace.createAuction(
            address(registry), agentId0, address(0), 1 ether, 0, 0, 0, 1 days
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);
        marketplace.settleAuction(auctionId);

        assertEq(registry.ownerOf(agentId0), alice);
    }

    function test_8004_auction_cancel_no_bids() public {
        vm.startPrank(alice);
        registry.approve(address(marketplace), agentId0);
        uint256 auctionId = marketplace.createAuction(
            address(registry), agentId0, address(0), 1 ether, 0, 0, 0, 1 days
        );
        marketplace.cancelAuction(auctionId);
        vm.stopPrank();

        assertEq(registry.ownerOf(agentId0), alice);
    }

    function test_8004_auction_anti_snipe() public {
        vm.startPrank(alice);
        registry.approve(address(marketplace), agentId0);
        marketplace.createAuction(address(registry), agentId0, address(0), 1 ether, 0, 0, 0, 1 days);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days - 5 minutes);

        vm.prank(bob);
        marketplace.bid{value: 1 ether}(1, 0);

        IMoltMarketplace.Auction memory auction = marketplace.getAuction(1);
        assertEq(auction.endTime, block.timestamp + 10 minutes);
    }

    function test_8004_auction_revert_cancel_has_bids() public {
        vm.startPrank(alice);
        registry.approve(address(marketplace), agentId0);
        marketplace.createAuction(address(registry), agentId0, address(0), 1 ether, 0, 0, 0, 1 days);
        vm.stopPrank();

        vm.prank(bob);
        marketplace.bid{value: 1 ether}(1, 0);

        vm.prank(alice);
        vm.expectRevert("Has bids");
        marketplace.cancelAuction(1);
    }

    // ══════════════════════════════════════════════════════
    //          8004 TRANSFER OUTSIDE MARKETPLACE
    // ══════════════════════════════════════════════════════

    function test_8004_direct_transfer_clears_wallet() public {
        assertEq(registry.getAgentWallet(agentId0), alice);

        vm.prank(alice);
        registry.transferFrom(alice, bob, agentId0);

        assertEq(registry.ownerOf(agentId0), bob);

        assertEq(registry.getAgentWallet(agentId0), address(0));
    }

    function test_8004_transfer_emits_metadata_and_transfer_events() public {
        vm.expectEmit(true, true, false, true, address(registry));
        emit MockIdentityRegistry.MetadataSet(agentId0, "agentWallet", "agentWallet", "");

        vm.expectEmit(true, true, true, true, address(registry));
        emit MockIdentityRegistry.Transfer(alice, bob, agentId0);

        vm.prank(alice);
        registry.transferFrom(alice, bob, agentId0);
    }

    // ══════════════════════════════════════════════════════
    //           8004 -> RESALE (SECONDARY MARKET)
    // ══════════════════════════════════════════════════════

    function test_8004_resale_after_purchase() public {
        vm.startPrank(alice);
        registry.approve(address(marketplace), agentId0);
        marketplace.list(address(registry), agentId0, address(0), LISTING_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        vm.prank(bob);
        marketplace.buy{value: LISTING_PRICE}(1);
        assertEq(registry.ownerOf(agentId0), bob);

        vm.startPrank(bob);
        registry.approve(address(marketplace), agentId0);
        uint256 listingId2 = marketplace.list(
            address(registry), agentId0, address(0), 2 ether, block.timestamp + 1 days
        );
        vm.stopPrank();

        vm.prank(carol);
        marketplace.buy{value: 2 ether}(listingId2);

        assertEq(registry.ownerOf(agentId0), carol);

        uint256 expectedFee = (2 ether * PLATFORM_FEE_BPS) / 10_000;
        uint256 firstFee = (LISTING_PRICE * PLATFORM_FEE_BPS) / 10_000;
        assertEq(feeRecipient.balance, firstFee + expectedFee);
    }

    // ══════════════════════════════════════════════════════
    //           MULTIPLE AGENTS REGISTERED
    // ══════════════════════════════════════════════════════

    function test_8004_multiple_agents_independent() public {
        vm.prank(alice);
        uint256 agentId1 = registry.register("ipfs://agent-2");

        vm.startPrank(alice);
        registry.approve(address(marketplace), agentId0);
        marketplace.list(address(registry), agentId0, address(0), LISTING_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        vm.prank(bob);
        marketplace.buy{value: LISTING_PRICE}(1);

        assertEq(registry.ownerOf(agentId0), bob);
        assertEq(registry.ownerOf(agentId1), alice);

        assertEq(registry.getAgentWallet(agentId1), alice);
        assertEq(registry.getAgentWallet(agentId0), address(0));
    }

    // ══════════════════════════════════════════════════════
    //         8004 -> UPDATE LISTING PRICE
    // ══════════════════════════════════════════════════════

    function test_8004_update_listing_price() public {
        vm.startPrank(alice);
        registry.approve(address(marketplace), agentId0);
        uint256 listingId = marketplace.list(
            address(registry), agentId0, address(0), LISTING_PRICE, block.timestamp + 1 days
        );

        uint256 newPrice = 2 ether;
        marketplace.updateListingPrice(listingId, newPrice);
        vm.stopPrank();

        IMoltMarketplace.Listing memory listing = marketplace.getListing(listingId);
        assertEq(listing.price, newPrice);

        uint256 aliceBalBefore = alice.balance;
        vm.prank(bob);
        marketplace.buy{value: newPrice}(listingId);

        assertEq(registry.ownerOf(agentId0), bob);

        uint256 expectedFee = (newPrice * PLATFORM_FEE_BPS) / 10_000;
        assertEq(feeRecipient.balance, expectedFee);
        assertEq(alice.balance - aliceBalBefore, newPrice - expectedFee);

        assertEq(registry.getAgentWallet(agentId0), address(0));
    }

    // ══════════════════════════════════════════════════════
    //        8004 -> COLLECTION OFFER
    // ══════════════════════════════════════════════════════

    function test_8004_collection_offer_make_accept() public {
        vm.startPrank(bob);
        token.approve(address(marketplace), 80e6);
        uint256 offerId = marketplace.makeCollectionOffer(
            address(registry), address(token), 80e6, block.timestamp + 1 days
        );
        vm.stopPrank();

        assertEq(offerId, 1);

        vm.startPrank(alice);
        registry.approve(address(marketplace), agentId0);
        marketplace.acceptCollectionOffer(offerId, agentId0);
        vm.stopPrank();

        assertEq(registry.ownerOf(agentId0), bob);

        uint256 expectedFee = (80e6 * PLATFORM_FEE_BPS) / 10_000;
        assertEq(token.balanceOf(feeRecipient), expectedFee);
        assertEq(token.balanceOf(alice), 80e6 - expectedFee);

        assertEq(registry.getAgentWallet(agentId0), address(0));

        IMoltMarketplace.CollectionOffer memory offer = marketplace.getCollectionOffer(offerId);
        assertEq(uint8(offer.status), uint8(IMoltMarketplace.OfferStatus.Accepted));
    }

    function test_8004_collection_offer_cancel() public {
        vm.startPrank(bob);
        token.approve(address(marketplace), 80e6);
        uint256 offerId = marketplace.makeCollectionOffer(
            address(registry), address(token), 80e6, block.timestamp + 1 days
        );
        marketplace.cancelCollectionOffer(offerId);
        vm.stopPrank();

        IMoltMarketplace.CollectionOffer memory offer = marketplace.getCollectionOffer(offerId);
        assertEq(uint8(offer.status), uint8(IMoltMarketplace.OfferStatus.Cancelled));

        assertEq(registry.ownerOf(agentId0), alice);
        assertEq(registry.getAgentWallet(agentId0), alice);
    }

    // ══════════════════════════════════════════════════════
    //           8004 -> DUTCH AUCTION
    // ══════════════════════════════════════════════════════

    function test_8004_dutch_auction_create_and_buy() public {
        vm.startPrank(alice);
        registry.approve(address(marketplace), agentId0);
        uint256 auctionId = marketplace.createDutchAuction(
            address(registry), agentId0, address(0), 5 ether, 1 ether, 1 days
        );
        vm.stopPrank();

        assertEq(auctionId, 1);
        assertEq(registry.ownerOf(agentId0), address(marketplace));

        vm.warp(block.timestamp + 12 hours);

        uint256 currentPrice = marketplace.getDutchAuctionCurrentPrice(auctionId);
        assertEq(currentPrice, 3 ether);

        uint256 aliceBalBefore = alice.balance;

        vm.prank(bob);
        marketplace.buyDutchAuction{value: currentPrice}(auctionId);

        assertEq(registry.ownerOf(agentId0), bob);

        assertEq(registry.getAgentWallet(agentId0), address(0));

        uint256 expectedFee = (currentPrice * PLATFORM_FEE_BPS) / 10_000;
        assertEq(feeRecipient.balance, expectedFee);
        assertEq(alice.balance - aliceBalBefore, currentPrice - expectedFee);

        IMoltMarketplace.DutchAuction memory da = marketplace.getDutchAuction(auctionId);
        assertEq(uint8(da.status), uint8(IMoltMarketplace.DutchAuctionStatus.Sold));
    }

    function test_8004_dutch_auction_cancel() public {
        vm.startPrank(alice);
        registry.approve(address(marketplace), agentId0);
        uint256 auctionId = marketplace.createDutchAuction(
            address(registry), agentId0, address(0), 5 ether, 1 ether, 1 days
        );
        marketplace.cancelDutchAuction(auctionId);
        vm.stopPrank();

        assertEq(registry.ownerOf(agentId0), alice);

        IMoltMarketplace.DutchAuction memory da = marketplace.getDutchAuction(auctionId);
        assertEq(uint8(da.status), uint8(IMoltMarketplace.DutchAuctionStatus.Cancelled));
    }

    // ══════════════════════════════════════════════════════
    //           8004 -> BUNDLE LISTING
    // ══════════════════════════════════════════════════════

    function test_8004_bundle_listing_multiple_agents() public {
        vm.startPrank(alice);
        uint256 agentId1 = registry.register("ipfs://agent-1");
        uint256 agentId2 = registry.register("ipfs://agent-2");

        assertEq(registry.getAgentWallet(agentId0), alice);
        assertEq(registry.getAgentWallet(agentId1), alice);
        assertEq(registry.getAgentWallet(agentId2), alice);

        registry.approve(address(marketplace), agentId0);
        registry.approve(address(marketplace), agentId1);
        registry.approve(address(marketplace), agentId2);

        address[] memory nftContracts = new address[](3);
        nftContracts[0] = address(registry);
        nftContracts[1] = address(registry);
        nftContracts[2] = address(registry);

        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = agentId0;
        tokenIds[1] = agentId1;
        tokenIds[2] = agentId2;

        uint256 bundlePrice = 10 ether;
        uint256 bundleId = marketplace.createBundleListing(
            nftContracts, tokenIds, address(0), bundlePrice, block.timestamp + 1 days
        );
        vm.stopPrank();

        assertEq(bundleId, 1);

        assertEq(registry.ownerOf(agentId0), address(marketplace));
        assertEq(registry.ownerOf(agentId1), address(marketplace));
        assertEq(registry.ownerOf(agentId2), address(marketplace));

        uint256 aliceBalBefore = alice.balance;

        vm.prank(bob);
        marketplace.buyBundle{value: bundlePrice}(bundleId);

        assertEq(registry.ownerOf(agentId0), bob);
        assertEq(registry.ownerOf(agentId1), bob);
        assertEq(registry.ownerOf(agentId2), bob);

        assertEq(registry.getAgentWallet(agentId0), address(0));
        assertEq(registry.getAgentWallet(agentId1), address(0));
        assertEq(registry.getAgentWallet(agentId2), address(0));

        uint256 expectedFee = (bundlePrice * PLATFORM_FEE_BPS) / 10_000;
        assertEq(feeRecipient.balance, expectedFee);
        assertEq(alice.balance - aliceBalBefore, bundlePrice - expectedFee);

        IMoltMarketplace.BundleListing memory bundle = marketplace.getBundleListing(bundleId);
        assertEq(uint8(bundle.status), uint8(IMoltMarketplace.ListingStatus.Sold));
    }

    function test_8004_bundle_cancel() public {
        vm.startPrank(alice);
        uint256 agentId1 = registry.register("ipfs://agent-1");

        registry.approve(address(marketplace), agentId0);
        registry.approve(address(marketplace), agentId1);

        address[] memory nftContracts = new address[](2);
        nftContracts[0] = address(registry);
        nftContracts[1] = address(registry);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = agentId0;
        tokenIds[1] = agentId1;

        uint256 bundleId = marketplace.createBundleListing(
            nftContracts, tokenIds, address(0), 5 ether, block.timestamp + 1 days
        );
        marketplace.cancelBundleListing(bundleId);
        vm.stopPrank();

        assertEq(registry.ownerOf(agentId0), alice);
        assertEq(registry.ownerOf(agentId1), alice);

        IMoltMarketplace.BundleListing memory bundle = marketplace.getBundleListing(bundleId);
        assertEq(uint8(bundle.status), uint8(IMoltMarketplace.ListingStatus.Cancelled));
    }

    // ══════════════════════════════════════════════════════
    //      8004 -> AUCTION RESERVE NOT MET
    // ══════════════════════════════════════════════════════

    function test_8004_auction_reserve_not_met() public {
        vm.startPrank(alice);
        registry.approve(address(marketplace), agentId0);
        uint256 auctionId = marketplace.createAuction(
            address(registry), agentId0, address(0), 1 ether, 5 ether, 0, 0, 1 days
        );
        vm.stopPrank();

        vm.prank(bob);
        marketplace.bid{value: 2 ether}(auctionId, 0);

        IMoltMarketplace.Auction memory auction = marketplace.getAuction(auctionId);
        assertEq(auction.highestBid, 2 ether);
        assertEq(auction.highestBidder, bob);

        uint256 bobBalBefore = bob.balance;

        vm.warp(block.timestamp + 2 days);
        marketplace.settleAuction(auctionId);

        assertEq(registry.ownerOf(agentId0), alice);

        assertEq(bob.balance - bobBalBefore, 2 ether);

        assertEq(registry.getAgentWallet(agentId0), address(0));

        assertEq(feeRecipient.balance, 0);
    }

    // ══════════════════════════════════════════════════════
    //      8004 -> AUCTION BUY-NOW
    // ══════════════════════════════════════════════════════

    function test_8004_auction_buy_now() public {
        vm.startPrank(alice);
        registry.approve(address(marketplace), agentId0);
        uint256 auctionId = marketplace.createAuction(
            address(registry), agentId0, address(0), 1 ether, 0, 10 ether, 0, 1 days
        );
        vm.stopPrank();

        uint256 aliceBalBefore = alice.balance;

        vm.prank(bob);
        marketplace.bid{value: 10 ether}(auctionId, 0);

        assertEq(registry.ownerOf(agentId0), bob);

        assertEq(registry.getAgentWallet(agentId0), address(0));

        uint256 expectedFee = (10 ether * PLATFORM_FEE_BPS) / 10_000;
        assertEq(feeRecipient.balance, expectedFee);
        assertEq(alice.balance - aliceBalBefore, 10 ether - expectedFee);

        IMoltMarketplace.Auction memory auction = marketplace.getAuction(auctionId);
        assertEq(uint8(auction.status), uint8(IMoltMarketplace.AuctionStatus.Ended));
        assertEq(auction.highestBidder, bob);
        assertEq(auction.highestBid, 10 ether);
    }

    function test_8004_auction_buy_now_refunds_previous_bidder() public {
        vm.startPrank(alice);
        registry.approve(address(marketplace), agentId0);
        uint256 auctionId = marketplace.createAuction(
            address(registry), agentId0, address(0), 1 ether, 0, 10 ether, 0, 1 days
        );
        vm.stopPrank();

        vm.prank(carol);
        marketplace.bid{value: 2 ether}(auctionId, 0);

        uint256 carolBalBefore = carol.balance;

        vm.prank(bob);
        marketplace.bid{value: 10 ether}(auctionId, 0);

        assertEq(carol.balance - carolBalBefore, 2 ether);

        assertEq(registry.ownerOf(agentId0), bob);
        assertEq(registry.getAgentWallet(agentId0), address(0));
    }

    // ══════════════════════════════════════════════════════
    //      8004 -> AUCTION SCHEDULED START
    // ══════════════════════════════════════════════════════

    function test_8004_auction_scheduled_start() public {
        uint256 futureStart = block.timestamp + 1 hours;

        vm.startPrank(alice);
        registry.approve(address(marketplace), agentId0);
        uint256 auctionId = marketplace.createAuction(
            address(registry), agentId0, address(0), 1 ether, 0, 0, futureStart, 1 days
        );
        vm.stopPrank();

        IMoltMarketplace.Auction memory auction = marketplace.getAuction(auctionId);
        assertEq(auction.startTime, futureStart);
        assertEq(auction.endTime, futureStart + 1 days);

        assertEq(registry.ownerOf(agentId0), address(marketplace));

        vm.prank(bob);
        vm.expectRevert("Not started");
        marketplace.bid{value: 1 ether}(auctionId, 0);

        vm.warp(futureStart);

        vm.prank(bob);
        marketplace.bid{value: 1 ether}(auctionId, 0);

        auction = marketplace.getAuction(auctionId);
        assertEq(auction.highestBidder, bob);
        assertEq(auction.highestBid, 1 ether);
        assertEq(auction.bidCount, 1);

        vm.warp(futureStart + 1 days + 1);
        marketplace.settleAuction(auctionId);

        assertEq(registry.ownerOf(agentId0), bob);
        assertEq(registry.getAgentWallet(agentId0), address(0));
    }

    // ══════════════════════════════════════════════════════
    //           8004 -> PAUSE / UNPAUSE
    // ══════════════════════════════════════════════════════

    function test_8004_pause_blocks_listing() public {
        vm.prank(owner);
        marketplace.pause();

        vm.startPrank(alice);
        registry.approve(address(marketplace), agentId0);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        marketplace.list(address(registry), agentId0, address(0), LISTING_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        vm.prank(owner);
        marketplace.unpause();

        vm.startPrank(alice);
        uint256 listingId = marketplace.list(
            address(registry), agentId0, address(0), LISTING_PRICE, block.timestamp + 1 days
        );
        vm.stopPrank();

        assertEq(listingId, 1);
        assertEq(registry.ownerOf(agentId0), address(marketplace));
    }
}
