// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {MoltMarketplace} from "../src/MoltMarketplace.sol";
import {IMoltMarketplace} from "../src/interfaces/IMoltMarketplace.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MockERC721} from "./mocks/MockERC721.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract MoltMarketplaceTest is Test {
    MoltMarketplace public marketplace;
    MockERC721 public nft;
    MockERC20 public token;

    // Role constants (must match MoltMarketplace)
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 public constant TOKEN_MANAGER_ROLE = keccak256("TOKEN_MANAGER_ROLE");

    address public owner = makeAddr("owner");
    address public feeRecipient = makeAddr("feeRecipient");
    address public seller = makeAddr("seller");
    address public buyer = makeAddr("buyer");
    address public bidder1 = makeAddr("bidder1");
    address public bidder2 = makeAddr("bidder2");

    uint256 public constant PLATFORM_FEE_BPS = 250; // 2.5%
    uint256 public constant LISTING_PRICE = 1 ether;
    uint256 public constant TOKEN_ID = 1;

    function setUp() public {
        vm.startPrank(owner);
        marketplace = new MoltMarketplace(owner, feeRecipient, PLATFORM_FEE_BPS);
        vm.stopPrank();

        nft = new MockERC721("TestNFT", "TNFT");
        token = new MockERC20("TestToken", "TT", 18);

        // Whitelist ERC-20 token
        vm.prank(owner);
        marketplace.addPaymentToken(address(token));

        // Mint NFT to seller
        nft.mint(seller, TOKEN_ID);

        // Fund accounts
        vm.deal(buyer, 100 ether);
        vm.deal(bidder1, 100 ether);
        vm.deal(bidder2, 100 ether);
        token.mint(buyer, 1000 ether);
        token.mint(bidder1, 1000 ether);
        token.mint(bidder2, 1000 ether);
    }

    // ══════════════════════════════════════════════════════
    //                    LISTING TESTS
    // ══════════════════════════════════════════════════════

    function test_list_native() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        uint256 listingId = marketplace.list(address(nft), TOKEN_ID, address(0), LISTING_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        assertEq(listingId, 1);
        IMoltMarketplace.Listing memory listing = marketplace.getListing(1);
        assertEq(listing.seller, seller);
        assertEq(listing.price, LISTING_PRICE);
        assertEq(uint8(listing.status), uint8(IMoltMarketplace.ListingStatus.Active));
        assertEq(nft.ownerOf(TOKEN_ID), address(marketplace)); // escrowed
    }

    function test_list_erc20() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        uint256 listingId = marketplace.list(address(nft), TOKEN_ID, address(token), LISTING_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        IMoltMarketplace.Listing memory listing = marketplace.getListing(listingId);
        assertEq(listing.paymentToken, address(token));
    }

    function test_list_revert_zero_price() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        vm.expectRevert("Price must be > 0");
        marketplace.list(address(nft), TOKEN_ID, address(0), 0, block.timestamp + 1 days);
        vm.stopPrank();
    }

    function test_list_revert_expired() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        vm.expectRevert("Expiry in the past");
        marketplace.list(address(nft), TOKEN_ID, address(0), LISTING_PRICE, block.timestamp - 1);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════
    //                      BUY TESTS
    // ══════════════════════════════════════════════════════

    function test_buy_native() public {
        // List
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.list(address(nft), TOKEN_ID, address(0), LISTING_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        uint256 sellerBalBefore = seller.balance;
        uint256 feeBalBefore = feeRecipient.balance;

        // Buy
        vm.prank(buyer);
        marketplace.buy{value: LISTING_PRICE}(1);

        // NFT transferred to buyer
        assertEq(nft.ownerOf(TOKEN_ID), buyer);

        // Fee: 2.5% of 1 ether = 0.025 ether
        uint256 expectedFee = (LISTING_PRICE * PLATFORM_FEE_BPS) / 10_000;
        assertEq(feeRecipient.balance - feeBalBefore, expectedFee);

        // Seller gets remainder
        assertEq(seller.balance - sellerBalBefore, LISTING_PRICE - expectedFee);

        // Listing marked as sold
        IMoltMarketplace.Listing memory listing = marketplace.getListing(1);
        assertEq(uint8(listing.status), uint8(IMoltMarketplace.ListingStatus.Sold));
    }

    function test_buy_erc20() public {
        // List with ERC-20
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.list(address(nft), TOKEN_ID, address(token), LISTING_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        // Buy with ERC-20
        vm.startPrank(buyer);
        token.approve(address(marketplace), LISTING_PRICE);
        marketplace.buy(1);
        vm.stopPrank();

        assertEq(nft.ownerOf(TOKEN_ID), buyer);

        uint256 expectedFee = (LISTING_PRICE * PLATFORM_FEE_BPS) / 10_000;
        assertEq(token.balanceOf(feeRecipient), expectedFee);
        assertEq(token.balanceOf(seller), LISTING_PRICE - expectedFee);
    }

    function test_buy_revert_own_listing() public {
        vm.deal(seller, 10 ether);
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.list(address(nft), TOKEN_ID, address(0), LISTING_PRICE, block.timestamp + 1 days);
        vm.expectRevert("Cannot buy own listing");
        marketplace.buy{value: LISTING_PRICE}(1);
        vm.stopPrank();
    }

    function test_buy_revert_expired() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.list(address(nft), TOKEN_ID, address(0), LISTING_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);

        vm.prank(buyer);
        vm.expectRevert("Listing expired");
        marketplace.buy{value: LISTING_PRICE}(1);
    }

    function test_buy_refund_excess() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.list(address(nft), TOKEN_ID, address(0), LISTING_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        uint256 buyerBalBefore = buyer.balance;

        vm.prank(buyer);
        marketplace.buy{value: 2 ether}(1); // overpay

        // Should refund 1 ether excess
        uint256 spent = buyerBalBefore - buyer.balance;
        assertEq(spent, LISTING_PRICE); // only paid listing price
    }

    // ══════════════════════════════════════════════════════
    //                  CANCEL LISTING TESTS
    // ══════════════════════════════════════════════════════

    function test_cancelListing() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.list(address(nft), TOKEN_ID, address(0), LISTING_PRICE, block.timestamp + 1 days);
        marketplace.cancelListing(1);
        vm.stopPrank();

        assertEq(nft.ownerOf(TOKEN_ID), seller); // returned
        IMoltMarketplace.Listing memory listing = marketplace.getListing(1);
        assertEq(uint8(listing.status), uint8(IMoltMarketplace.ListingStatus.Cancelled));
    }

    function test_cancelListing_revert_not_seller() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.list(address(nft), TOKEN_ID, address(0), LISTING_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        vm.prank(buyer);
        vm.expectRevert("Not seller");
        marketplace.cancelListing(1);
    }

    // ══════════════════════════════════════════════════════
    //                    OFFER TESTS
    // ══════════════════════════════════════════════════════

    function test_makeOffer_and_accept() public {
        // Buyer makes offer
        vm.startPrank(buyer);
        token.approve(address(marketplace), LISTING_PRICE);
        uint256 offerId = marketplace.makeOffer(address(nft), TOKEN_ID, address(token), LISTING_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        assertEq(offerId, 1);

        // Seller accepts
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.acceptOffer(1);
        vm.stopPrank();

        // NFT goes to buyer
        assertEq(nft.ownerOf(TOKEN_ID), buyer);

        // Payment distributed
        uint256 expectedFee = (LISTING_PRICE * PLATFORM_FEE_BPS) / 10_000;
        assertEq(token.balanceOf(feeRecipient), expectedFee);
        assertEq(token.balanceOf(seller), LISTING_PRICE - expectedFee);
    }

    function test_makeOffer_revert_native() public {
        vm.prank(buyer);
        vm.expectRevert("Offers must use ERC-20");
        marketplace.makeOffer(address(nft), TOKEN_ID, address(0), LISTING_PRICE, block.timestamp + 1 days);
    }

    function test_cancelOffer() public {
        vm.startPrank(buyer);
        token.approve(address(marketplace), LISTING_PRICE);
        marketplace.makeOffer(address(nft), TOKEN_ID, address(token), LISTING_PRICE, block.timestamp + 1 days);
        marketplace.cancelOffer(1);
        vm.stopPrank();

        IMoltMarketplace.Offer memory offer = marketplace.getOffer(1);
        assertEq(uint8(offer.status), uint8(IMoltMarketplace.OfferStatus.Cancelled));
    }

    // ══════════════════════════════════════════════════════
    //                   AUCTION TESTS
    // ══════════════════════════════════════════════════════

    function test_auction_full_flow() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        uint256 auctionId = marketplace.createAuction(address(nft), TOKEN_ID, address(0), 1 ether, 0, 0, 0, 1 days);
        vm.stopPrank();

        assertEq(auctionId, 1);
        assertEq(nft.ownerOf(TOKEN_ID), address(marketplace)); // escrowed

        // Bid 1
        vm.prank(bidder1);
        marketplace.bid{value: 1 ether}(1, 0);

        IMoltMarketplace.Auction memory auction = marketplace.getAuction(1);
        assertEq(auction.highestBid, 1 ether);
        assertEq(auction.highestBidder, bidder1);

        // Bid 2 (must be >= 5% higher = 1.05 ether)
        vm.prank(bidder2);
        marketplace.bid{value: 1.1 ether}(1, 0);

        auction = marketplace.getAuction(1);
        assertEq(auction.highestBidder, bidder2);
        assertEq(auction.highestBid, 1.1 ether);

        // bidder1 should have been refunded
        assertEq(bidder1.balance, 100 ether); // back to original

        // Settle after end
        vm.warp(block.timestamp + 2 days);
        marketplace.settleAuction(1);

        assertEq(nft.ownerOf(TOKEN_ID), bidder2); // winner

        uint256 expectedFee = (1.1 ether * PLATFORM_FEE_BPS) / 10_000;
        assertEq(feeRecipient.balance, expectedFee);
    }

    function test_auction_anti_snipe() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.createAuction(address(nft), TOKEN_ID, address(0), 1 ether, 0, 0, 0, 1 days);
        vm.stopPrank();

        // Warp to 5 min before end
        vm.warp(block.timestamp + 1 days - 5 minutes);

        vm.prank(bidder1);
        marketplace.bid{value: 1 ether}(1, 0);

        // End time should be extended by 10 min
        IMoltMarketplace.Auction memory auction = marketplace.getAuction(1);
        assertEq(auction.endTime, block.timestamp + 10 minutes);
    }

    function test_auction_no_bids_returns_nft() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.createAuction(address(nft), TOKEN_ID, address(0), 1 ether, 0, 0, 0, 1 days);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);
        marketplace.settleAuction(1);

        assertEq(nft.ownerOf(TOKEN_ID), seller); // returned
    }

    function test_auction_cancel_no_bids() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.createAuction(address(nft), TOKEN_ID, address(0), 1 ether, 0, 0, 0, 1 days);
        marketplace.cancelAuction(1);
        vm.stopPrank();

        assertEq(nft.ownerOf(TOKEN_ID), seller);
    }

    function test_auction_cancel_revert_has_bids() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.createAuction(address(nft), TOKEN_ID, address(0), 1 ether, 0, 0, 0, 1 days);
        vm.stopPrank();

        vm.prank(bidder1);
        marketplace.bid{value: 1 ether}(1, 0);

        vm.prank(seller);
        vm.expectRevert("Has bids");
        marketplace.cancelAuction(1);
    }

    function test_bid_revert_too_low() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.createAuction(address(nft), TOKEN_ID, address(0), 1 ether, 0, 0, 0, 1 days);
        vm.stopPrank();

        vm.prank(bidder1);
        vm.expectRevert("Bid too low");
        marketplace.bid{value: 0.5 ether}(1, 0);
    }

    // ══════════════════════════════════════════════════════
    //                    ADMIN TESTS
    // ══════════════════════════════════════════════════════

    function test_setPlatformFee() public {
        vm.prank(owner);
        marketplace.setPlatformFee(500); // 5%

        assertEq(marketplace.platformFeeBps(), 500);
    }

    function test_setPlatformFee_zero() public {
        vm.prank(owner);
        marketplace.setPlatformFee(0); // 0% fee

        assertEq(marketplace.platformFeeBps(), 0);
    }

    function test_setPlatformFee_revert_exceeds_max() public {
        vm.prank(owner);
        vm.expectRevert("Fee exceeds max");
        marketplace.setPlatformFee(1_001); // > 10%
    }

    function test_setPlatformFee_revert_not_fee_manager() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, buyer, FEE_MANAGER_ROLE));
        marketplace.setPlatformFee(500);
    }

    function test_setFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");
        vm.prank(owner);
        marketplace.setFeeRecipient(newRecipient);

        assertEq(marketplace.feeRecipient(), newRecipient);
    }

    function test_grantRole_and_use() public {
        address feeManager = makeAddr("feeManager");

        vm.prank(owner);
        marketplace.grantRole(FEE_MANAGER_ROLE, feeManager);

        assertTrue(marketplace.hasRole(FEE_MANAGER_ROLE, feeManager));

        vm.prank(feeManager);
        marketplace.setPlatformFee(100);
        assertEq(marketplace.platformFeeBps(), 100);
    }

    // ══════════════════════════════════════════════════════
    //                 DYNAMIC FEE TESTS
    // ══════════════════════════════════════════════════════

    function test_dynamic_fee_reflected_in_sale() public {
        // Change fee to 5%
        vm.prank(owner);
        marketplace.setPlatformFee(500);

        // List and buy
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.list(address(nft), TOKEN_ID, address(0), LISTING_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        vm.prank(buyer);
        marketplace.buy{value: LISTING_PRICE}(1);

        // Fee should be 5% now
        uint256 expectedFee = (LISTING_PRICE * 500) / 10_000;
        assertEq(feeRecipient.balance, expectedFee);
        assertEq(seller.balance, LISTING_PRICE - expectedFee);
    }

    function test_zero_fee_sale() public {
        // Set fee to 0
        vm.prank(owner);
        marketplace.setPlatformFee(0);

        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.list(address(nft), TOKEN_ID, address(0), LISTING_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        vm.prank(buyer);
        marketplace.buy{value: LISTING_PRICE}(1);

        // No fee
        assertEq(feeRecipient.balance, 0);
        assertEq(seller.balance, LISTING_PRICE);
    }

    // ══════════════════════════════════════════════════════
    //              UPDATE LISTING PRICE TESTS
    // ══════════════════════════════════════════════════════

    function test_updateListingPrice() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.list(address(nft), TOKEN_ID, address(0), LISTING_PRICE, block.timestamp + 1 days);
        marketplace.updateListingPrice(1, 2 ether);
        vm.stopPrank();

        IMoltMarketplace.Listing memory listing = marketplace.getListing(1);
        assertEq(listing.price, 2 ether);
    }

    function test_updateListingPrice_revert_not_seller() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.list(address(nft), TOKEN_ID, address(0), LISTING_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        vm.prank(buyer);
        vm.expectRevert("Not seller");
        marketplace.updateListingPrice(1, 2 ether);
    }

    function test_updateListingPrice_revert_zero_price() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.list(address(nft), TOKEN_ID, address(0), LISTING_PRICE, block.timestamp + 1 days);
        vm.expectRevert("Price must be > 0");
        marketplace.updateListingPrice(1, 0);
        vm.stopPrank();
    }

    function test_updateListingPrice_revert_not_active() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.list(address(nft), TOKEN_ID, address(0), LISTING_PRICE, block.timestamp + 1 days);
        marketplace.cancelListing(1);
        vm.expectRevert("Not active");
        marketplace.updateListingPrice(1, 2 ether);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════
    //              COLLECTION OFFER TESTS
    // ══════════════════════════════════════════════════════

    function test_makeCollectionOffer_and_accept() public {
        vm.startPrank(buyer);
        token.approve(address(marketplace), LISTING_PRICE);
        uint256 offerId = marketplace.makeCollectionOffer(address(nft), address(token), LISTING_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        assertEq(offerId, 1);

        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.acceptCollectionOffer(1, TOKEN_ID);
        vm.stopPrank();

        assertEq(nft.ownerOf(TOKEN_ID), buyer);

        uint256 expectedFee = (LISTING_PRICE * PLATFORM_FEE_BPS) / 10_000;
        assertEq(token.balanceOf(feeRecipient), expectedFee);
        assertEq(token.balanceOf(seller), LISTING_PRICE - expectedFee);
    }

    function test_cancelCollectionOffer() public {
        vm.startPrank(buyer);
        token.approve(address(marketplace), LISTING_PRICE);
        marketplace.makeCollectionOffer(address(nft), address(token), LISTING_PRICE, block.timestamp + 1 days);
        marketplace.cancelCollectionOffer(1);
        vm.stopPrank();

        IMoltMarketplace.CollectionOffer memory offer = marketplace.getCollectionOffer(1);
        assertEq(uint8(offer.status), uint8(IMoltMarketplace.OfferStatus.Cancelled));
    }

    function test_collectionOffer_revert_expired() public {
        vm.startPrank(buyer);
        token.approve(address(marketplace), LISTING_PRICE);
        marketplace.makeCollectionOffer(address(nft), address(token), LISTING_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);

        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        vm.expectRevert("Offer expired");
        marketplace.acceptCollectionOffer(1, TOKEN_ID);
        vm.stopPrank();
    }

    function test_collectionOffer_revert_not_nft_owner() public {
        vm.startPrank(buyer);
        token.approve(address(marketplace), LISTING_PRICE);
        marketplace.makeCollectionOffer(address(nft), address(token), LISTING_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        vm.prank(buyer);
        vm.expectRevert("Not NFT owner");
        marketplace.acceptCollectionOffer(1, TOKEN_ID);
    }

    function test_collectionOffer_revert_native_payment() public {
        vm.prank(buyer);
        vm.expectRevert("Offers must use ERC-20");
        marketplace.makeCollectionOffer(address(nft), address(0), LISTING_PRICE, block.timestamp + 1 days);
    }

    // ══════════════════════════════════════════════════════
    //                DUTCH AUCTION TESTS
    // ══════════════════════════════════════════════════════

    function test_dutchAuction_create_and_buy_at_start() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        uint256 auctionId = marketplace.createDutchAuction(address(nft), TOKEN_ID, address(0), 10 ether, 1 ether, 1 days);
        vm.stopPrank();

        assertEq(auctionId, 1);
        assertEq(nft.ownerOf(TOKEN_ID), address(marketplace));

        uint256 sellerBalBefore = seller.balance;
        vm.prank(buyer);
        marketplace.buyDutchAuction{value: 10 ether}(1);

        assertEq(nft.ownerOf(TOKEN_ID), buyer);

        uint256 expectedFee = (10 ether * PLATFORM_FEE_BPS) / 10_000;
        assertEq(feeRecipient.balance, expectedFee);
        assertEq(seller.balance - sellerBalBefore, 10 ether - expectedFee);
    }

    function test_dutchAuction_buy_at_mid_price() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.createDutchAuction(address(nft), TOKEN_ID, address(0), 10 ether, 2 ether, 1 days);
        vm.stopPrank();

        vm.warp(block.timestamp + 12 hours);

        uint256 currentPrice = marketplace.getDutchAuctionCurrentPrice(1);
        assertEq(currentPrice, 6 ether);

        vm.prank(buyer);
        marketplace.buyDutchAuction{value: 6 ether}(1);

        assertEq(nft.ownerOf(TOKEN_ID), buyer);
    }

    function test_dutchAuction_buy_at_end_price() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.createDutchAuction(address(nft), TOKEN_ID, address(0), 10 ether, 1 ether, 1 days);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);

        vm.prank(buyer);
        marketplace.buyDutchAuction{value: 1 ether}(1);

        assertEq(nft.ownerOf(TOKEN_ID), buyer);
    }

    function test_dutchAuction_cancel() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.createDutchAuction(address(nft), TOKEN_ID, address(0), 10 ether, 1 ether, 1 days);
        marketplace.cancelDutchAuction(1);
        vm.stopPrank();

        assertEq(nft.ownerOf(TOKEN_ID), seller);
        IMoltMarketplace.DutchAuction memory auction = marketplace.getDutchAuction(1);
        assertEq(uint8(auction.status), uint8(IMoltMarketplace.DutchAuctionStatus.Cancelled));
    }

    function test_dutchAuction_revert_buy_own() public {
        vm.deal(seller, 100 ether);
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.createDutchAuction(address(nft), TOKEN_ID, address(0), 10 ether, 1 ether, 1 days);
        vm.expectRevert("Cannot buy own auction");
        marketplace.buyDutchAuction{value: 10 ether}(1);
        vm.stopPrank();
    }

    function test_dutchAuction_revert_end_price_gte_start() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        vm.expectRevert("End price >= start price");
        marketplace.createDutchAuction(address(nft), TOKEN_ID, address(0), 10 ether, 10 ether, 1 days);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════
    //                BUNDLE LISTING TESTS
    // ══════════════════════════════════════════════════════

    function test_bundle_create_and_buy() public {
        uint256 tokenId2 = 2;
        uint256 tokenId3 = 3;
        nft.mint(seller, tokenId2);
        nft.mint(seller, tokenId3);

        address[] memory nftContracts = new address[](3);
        nftContracts[0] = address(nft);
        nftContracts[1] = address(nft);
        nftContracts[2] = address(nft);

        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = TOKEN_ID;
        tokenIds[1] = tokenId2;
        tokenIds[2] = tokenId3;

        vm.startPrank(seller);
        nft.setApprovalForAll(address(marketplace), true);
        uint256 bundleId = marketplace.createBundleListing(nftContracts, tokenIds, address(0), 3 ether, block.timestamp + 1 days);
        vm.stopPrank();

        assertEq(bundleId, 1);
        assertEq(nft.ownerOf(TOKEN_ID), address(marketplace));
        assertEq(nft.ownerOf(tokenId2), address(marketplace));
        assertEq(nft.ownerOf(tokenId3), address(marketplace));

        uint256 sellerBalBefore = seller.balance;

        vm.prank(buyer);
        marketplace.buyBundle{value: 3 ether}(1);

        assertEq(nft.ownerOf(TOKEN_ID), buyer);
        assertEq(nft.ownerOf(tokenId2), buyer);
        assertEq(nft.ownerOf(tokenId3), buyer);

        uint256 expectedFee = (3 ether * PLATFORM_FEE_BPS) / 10_000;
        assertEq(feeRecipient.balance, expectedFee);
        assertEq(seller.balance - sellerBalBefore, 3 ether - expectedFee);
    }

    function test_bundle_cancel() public {
        uint256 tokenId2 = 2;
        nft.mint(seller, tokenId2);

        address[] memory nftContracts = new address[](2);
        nftContracts[0] = address(nft);
        nftContracts[1] = address(nft);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = TOKEN_ID;
        tokenIds[1] = tokenId2;

        vm.startPrank(seller);
        nft.setApprovalForAll(address(marketplace), true);
        marketplace.createBundleListing(nftContracts, tokenIds, address(0), 2 ether, block.timestamp + 1 days);
        marketplace.cancelBundleListing(1);
        vm.stopPrank();

        assertEq(nft.ownerOf(TOKEN_ID), seller);
        assertEq(nft.ownerOf(tokenId2), seller);
    }

    function test_bundle_revert_empty() public {
        address[] memory nftContracts = new address[](0);
        uint256[] memory tokenIds = new uint256[](0);

        vm.prank(seller);
        vm.expectRevert("Empty bundle");
        marketplace.createBundleListing(nftContracts, tokenIds, address(0), 1 ether, block.timestamp + 1 days);
    }

    function test_bundle_revert_too_large() public {
        address[] memory nftContracts = new address[](21);
        uint256[] memory tokenIds = new uint256[](21);
        for (uint256 i = 0; i < 21; i++) {
            nftContracts[i] = address(nft);
            tokenIds[i] = 100 + i;
        }

        vm.prank(seller);
        vm.expectRevert("Bundle too large");
        marketplace.createBundleListing(nftContracts, tokenIds, address(0), 1 ether, block.timestamp + 1 days);
    }

    function test_bundle_revert_buy_own() public {
        vm.deal(seller, 100 ether);
        uint256 tokenId2 = 2;
        nft.mint(seller, tokenId2);

        address[] memory nftContracts = new address[](2);
        nftContracts[0] = address(nft);
        nftContracts[1] = address(nft);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = TOKEN_ID;
        tokenIds[1] = tokenId2;

        vm.startPrank(seller);
        nft.setApprovalForAll(address(marketplace), true);
        marketplace.createBundleListing(nftContracts, tokenIds, address(0), 2 ether, block.timestamp + 1 days);
        vm.expectRevert("Cannot buy own bundle");
        marketplace.buyBundle{value: 2 ether}(1);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════
    //                 PAUSE / UNPAUSE TESTS
    // ══════════════════════════════════════════════════════

    function test_pause_blocks_new_listing() public {
        vm.prank(owner);
        marketplace.pause();

        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        marketplace.list(address(nft), TOKEN_ID, address(0), LISTING_PRICE, block.timestamp + 1 days);
        vm.stopPrank();
    }

    function test_pause_blocks_buy() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.list(address(nft), TOKEN_ID, address(0), LISTING_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        vm.prank(owner);
        marketplace.pause();

        vm.prank(buyer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        marketplace.buy{value: LISTING_PRICE}(1);
    }

    function test_pause_blocks_make_offer() public {
        vm.prank(owner);
        marketplace.pause();

        vm.startPrank(buyer);
        token.approve(address(marketplace), LISTING_PRICE);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        marketplace.makeOffer(address(nft), TOKEN_ID, address(token), LISTING_PRICE, block.timestamp + 1 days);
        vm.stopPrank();
    }

    function test_pause_blocks_create_auction() public {
        vm.prank(owner);
        marketplace.pause();

        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        marketplace.createAuction(address(nft), TOKEN_ID, address(0), 1 ether, 0, 0, 0, 1 days);
        vm.stopPrank();
    }

    function test_pause_allows_cancel_listing() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.list(address(nft), TOKEN_ID, address(0), LISTING_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        vm.prank(owner);
        marketplace.pause();

        vm.prank(seller);
        marketplace.cancelListing(1);

        assertEq(nft.ownerOf(TOKEN_ID), seller);
    }

    function test_pause_allows_settle_auction() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.createAuction(address(nft), TOKEN_ID, address(0), 1 ether, 0, 0, 0, 1 days);
        vm.stopPrank();

        vm.prank(bidder1);
        marketplace.bid{value: 1 ether}(1, 0);

        vm.prank(owner);
        marketplace.pause();

        vm.warp(block.timestamp + 2 days);

        marketplace.settleAuction(1);
        assertEq(nft.ownerOf(TOKEN_ID), bidder1);
    }

    function test_unpause_re_enables() public {
        vm.prank(owner);
        marketplace.pause();

        vm.prank(owner);
        marketplace.unpause();

        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        uint256 listingId = marketplace.list(address(nft), TOKEN_ID, address(0), LISTING_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        assertEq(listingId, 1);
    }

    function test_pause_revert_not_pauser() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, buyer, PAUSER_ROLE));
        marketplace.pause();
    }

    function test_unpause_revert_not_pauser() public {
        vm.prank(owner);
        marketplace.pause();

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, buyer, PAUSER_ROLE));
        marketplace.unpause();
    }

    // ══════════════════════════════════════════════════════
    //              AUCTION RESERVE PRICE TESTS
    // ══════════════════════════════════════════════════════

    function test_auction_reserve_not_met_returns_nft_and_refunds() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.createAuction(address(nft), TOKEN_ID, address(0), 1 ether, 5 ether, 0, 0, 1 days);
        vm.stopPrank();

        vm.prank(bidder1);
        marketplace.bid{value: 2 ether}(1, 0);

        uint256 bidder1BalBefore = bidder1.balance;

        vm.warp(block.timestamp + 2 days);
        marketplace.settleAuction(1);

        assertEq(nft.ownerOf(TOKEN_ID), seller);
        assertEq(bidder1.balance, bidder1BalBefore + 2 ether);
        assertEq(feeRecipient.balance, 0);
    }

    function test_auction_reserve_met_succeeds() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.createAuction(address(nft), TOKEN_ID, address(0), 1 ether, 2 ether, 0, 0, 1 days);
        vm.stopPrank();

        vm.prank(bidder1);
        marketplace.bid{value: 2 ether}(1, 0);

        vm.warp(block.timestamp + 2 days);
        marketplace.settleAuction(1);

        assertEq(nft.ownerOf(TOKEN_ID), bidder1);

        uint256 expectedFee = (2 ether * PLATFORM_FEE_BPS) / 10_000;
        assertEq(feeRecipient.balance, expectedFee);
    }

    // ══════════════════════════════════════════════════════
    //              AUCTION BUY-NOW TESTS
    // ══════════════════════════════════════════════════════

    function test_auction_buy_now_settles_immediately() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.createAuction(address(nft), TOKEN_ID, address(0), 1 ether, 0, 5 ether, 0, 1 days);
        vm.stopPrank();

        uint256 sellerBalBefore = seller.balance;

        vm.prank(bidder1);
        marketplace.bid{value: 5 ether}(1, 0);

        assertEq(nft.ownerOf(TOKEN_ID), bidder1);

        IMoltMarketplace.Auction memory auction = marketplace.getAuction(1);
        assertEq(uint8(auction.status), uint8(IMoltMarketplace.AuctionStatus.Ended));

        uint256 expectedFee = (5 ether * PLATFORM_FEE_BPS) / 10_000;
        assertEq(feeRecipient.balance, expectedFee);
        assertEq(seller.balance - sellerBalBefore, 5 ether - expectedFee);
    }

    function test_auction_buy_now_above_price_settles_at_buy_now() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.createAuction(address(nft), TOKEN_ID, address(0), 1 ether, 0, 5 ether, 0, 1 days);
        vm.stopPrank();

        uint256 bidder1BalBefore = bidder1.balance;

        vm.prank(bidder1);
        marketplace.bid{value: 8 ether}(1, 0);

        assertEq(nft.ownerOf(TOKEN_ID), bidder1);

        uint256 spent = bidder1BalBefore - bidder1.balance;
        assertEq(spent, 5 ether);
    }

    function test_auction_buy_now_refunds_previous_bidder() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.createAuction(address(nft), TOKEN_ID, address(0), 1 ether, 0, 5 ether, 0, 1 days);
        vm.stopPrank();

        vm.prank(bidder1);
        marketplace.bid{value: 2 ether}(1, 0);

        uint256 bidder1BalBefore = bidder1.balance;

        vm.prank(bidder2);
        marketplace.bid{value: 5 ether}(1, 0);

        assertEq(bidder1.balance, bidder1BalBefore + 2 ether);
        assertEq(nft.ownerOf(TOKEN_ID), bidder2);
    }

    // ══════════════════════════════════════════════════════
    //            AUCTION SCHEDULED START TESTS
    // ══════════════════════════════════════════════════════

    function test_auction_scheduled_start_cannot_bid_before() public {
        uint256 futureStart = block.timestamp + 1 hours;

        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.createAuction(address(nft), TOKEN_ID, address(0), 1 ether, 0, 0, futureStart, 1 days);
        vm.stopPrank();

        vm.prank(bidder1);
        vm.expectRevert("Not started");
        marketplace.bid{value: 1 ether}(1, 0);
    }

    function test_auction_scheduled_start_can_bid_after() public {
        uint256 futureStart = block.timestamp + 1 hours;

        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.createAuction(address(nft), TOKEN_ID, address(0), 1 ether, 0, 0, futureStart, 1 days);
        vm.stopPrank();

        vm.warp(futureStart);

        vm.prank(bidder1);
        marketplace.bid{value: 1 ether}(1, 0);

        IMoltMarketplace.Auction memory auction = marketplace.getAuction(1);
        assertEq(auction.highestBid, 1 ether);
        assertEq(auction.highestBidder, bidder1);
    }

    function test_auction_scheduled_start_stored_correctly() public {
        uint256 futureStart = block.timestamp + 2 hours;

        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.createAuction(address(nft), TOKEN_ID, address(0), 1 ether, 0, 0, futureStart, 1 days);
        vm.stopPrank();

        IMoltMarketplace.Auction memory auction = marketplace.getAuction(1);
        assertEq(auction.startTime, futureStart);
        assertEq(auction.endTime, futureStart + 1 days);
    }

    // ══════════════════════════════════════════════════════
    //              AUCTION BID COUNT TESTS
    // ══════════════════════════════════════════════════════

    function test_auction_bid_count_tracked() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.createAuction(address(nft), TOKEN_ID, address(0), 1 ether, 0, 0, 0, 1 days);
        vm.stopPrank();

        IMoltMarketplace.Auction memory auction = marketplace.getAuction(1);
        assertEq(auction.bidCount, 0);

        vm.prank(bidder1);
        marketplace.bid{value: 1 ether}(1, 0);
        auction = marketplace.getAuction(1);
        assertEq(auction.bidCount, 1);

        vm.prank(bidder2);
        marketplace.bid{value: 1.1 ether}(1, 0);
        auction = marketplace.getAuction(1);
        assertEq(auction.bidCount, 2);

        vm.prank(bidder1);
        marketplace.bid{value: 1.2 ether}(1, 0);
        auction = marketplace.getAuction(1);
        assertEq(auction.bidCount, 3);
    }

    function test_auction_bid_count_incremented_on_buy_now() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.createAuction(address(nft), TOKEN_ID, address(0), 1 ether, 0, 5 ether, 0, 1 days);
        vm.stopPrank();

        vm.prank(bidder1);
        marketplace.bid{value: 1 ether}(1, 0);

        vm.prank(bidder2);
        marketplace.bid{value: 5 ether}(1, 0);

        IMoltMarketplace.Auction memory auction = marketplace.getAuction(1);
        assertEq(auction.bidCount, 2);
    }

    // ══════════════════════════════════════════════════════
    //           AUCTION EXTENDED EVENT TESTS
    // ══════════════════════════════════════════════════════

    function test_auction_extended_event_emitted_on_anti_snipe() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.createAuction(address(nft), TOKEN_ID, address(0), 1 ether, 0, 0, 0, 1 days);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days - 3 minutes);

        vm.expectEmit(true, false, false, true);
        emit IMoltMarketplace.AuctionExtended(1, block.timestamp + 10 minutes);

        vm.prank(bidder1);
        marketplace.bid{value: 1 ether}(1, 0);
    }

    function test_auction_no_extension_outside_window() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.createAuction(address(nft), TOKEN_ID, address(0), 1 ether, 0, 0, 0, 1 days);
        vm.stopPrank();

        IMoltMarketplace.Auction memory auctionBefore = marketplace.getAuction(1);
        uint256 endTimeBefore = auctionBefore.endTime;

        vm.warp(block.timestamp + 1 days - 30 minutes);

        vm.prank(bidder1);
        marketplace.bid{value: 1 ether}(1, 0);

        IMoltMarketplace.Auction memory auctionAfter = marketplace.getAuction(1);
        assertEq(auctionAfter.endTime, endTimeBefore);
    }

    function test_auction_extended_event_with_multiple_snipe_bids() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.createAuction(address(nft), TOKEN_ID, address(0), 1 ether, 0, 0, 0, 1 days);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days - 5 minutes);

        vm.prank(bidder1);
        marketplace.bid{value: 1 ether}(1, 0);

        IMoltMarketplace.Auction memory auction = marketplace.getAuction(1);
        uint256 newEndTime1 = auction.endTime;
        assertEq(newEndTime1, block.timestamp + 10 minutes);

        vm.warp(newEndTime1 - 3 minutes);

        vm.expectEmit(true, false, false, true);
        emit IMoltMarketplace.AuctionExtended(1, block.timestamp + 10 minutes);

        vm.prank(bidder2);
        marketplace.bid{value: 1.1 ether}(1, 0);

        auction = marketplace.getAuction(1);
        assertEq(auction.endTime, block.timestamp + 10 minutes);
        assertTrue(auction.endTime > newEndTime1);
    }

    // ══════════════════════════════════════════════════════
    //           PAYMENT TOKEN WHITELIST TESTS
    // ══════════════════════════════════════════════════════

    function test_addPaymentToken() public {
        MockERC20 newToken = new MockERC20("NewToken", "NT", 18);

        vm.prank(owner);
        marketplace.addPaymentToken(address(newToken));

        assertTrue(marketplace.isPaymentTokenAllowed(address(newToken)));
    }

    function test_addPaymentToken_revert_not_token_manager() public {
        MockERC20 newToken = new MockERC20("NewToken", "NT", 18);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, buyer, TOKEN_MANAGER_ROLE));
        marketplace.addPaymentToken(address(newToken));
    }

    function test_addPaymentToken_revert_zero_address() public {
        vm.prank(owner);
        vm.expectRevert("Zero address");
        marketplace.addPaymentToken(address(0));
    }

    function test_addPaymentToken_revert_already_allowed() public {
        vm.prank(owner);
        vm.expectRevert("Already allowed");
        marketplace.addPaymentToken(address(token)); // already added in setUp
    }

    function test_removePaymentToken() public {
        vm.prank(owner);
        marketplace.removePaymentToken(address(token));

        assertFalse(marketplace.isPaymentTokenAllowed(address(token)));
    }

    function test_removePaymentToken_revert_not_allowed() public {
        MockERC20 newToken = new MockERC20("NewToken", "NT", 18);

        vm.prank(owner);
        vm.expectRevert("Not allowed");
        marketplace.removePaymentToken(address(newToken));
    }

    function test_list_revert_token_not_allowed() public {
        MockERC20 badToken = new MockERC20("BadToken", "BAD", 18);

        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        vm.expectRevert("Token not allowed");
        marketplace.list(address(nft), TOKEN_ID, address(badToken), LISTING_PRICE, block.timestamp + 1 days);
        vm.stopPrank();
    }

    function test_makeOffer_revert_token_not_allowed() public {
        MockERC20 badToken = new MockERC20("BadToken", "BAD", 18);
        badToken.mint(buyer, 1000 ether);

        vm.startPrank(buyer);
        badToken.approve(address(marketplace), LISTING_PRICE);
        vm.expectRevert("Token not allowed");
        marketplace.makeOffer(address(nft), TOKEN_ID, address(badToken), LISTING_PRICE, block.timestamp + 1 days);
        vm.stopPrank();
    }

    function test_createAuction_revert_token_not_allowed() public {
        MockERC20 badToken = new MockERC20("BadToken", "BAD", 18);

        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        vm.expectRevert("Token not allowed");
        marketplace.createAuction(address(nft), TOKEN_ID, address(badToken), 1 ether, 0, 0, 0, 1 days);
        vm.stopPrank();
    }

    function test_createDutchAuction_revert_token_not_allowed() public {
        MockERC20 badToken = new MockERC20("BadToken", "BAD", 18);

        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        vm.expectRevert("Token not allowed");
        marketplace.createDutchAuction(address(nft), TOKEN_ID, address(badToken), 10 ether, 1 ether, 1 days);
        vm.stopPrank();
    }

    function test_createBundleListing_revert_token_not_allowed() public {
        MockERC20 badToken = new MockERC20("BadToken", "BAD", 18);
        uint256 tokenId2 = 2;
        nft.mint(seller, tokenId2);

        address[] memory nftContracts = new address[](2);
        nftContracts[0] = address(nft);
        nftContracts[1] = address(nft);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = TOKEN_ID;
        tokenIds[1] = tokenId2;

        vm.startPrank(seller);
        nft.setApprovalForAll(address(marketplace), true);
        vm.expectRevert("Token not allowed");
        marketplace.createBundleListing(nftContracts, tokenIds, address(badToken), 2 ether, block.timestamp + 1 days);
        vm.stopPrank();
    }

    function test_native_payment_always_allowed() public {
        // Native (address(0)) should always work without whitelisting
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        uint256 listingId = marketplace.list(address(nft), TOKEN_ID, address(0), LISTING_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        assertEq(listingId, 1);
    }

    function test_removed_token_blocks_new_listings() public {
        // Remove the token
        vm.prank(owner);
        marketplace.removePaymentToken(address(token));

        // Try to list with removed token
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        vm.expectRevert("Token not allowed");
        marketplace.list(address(nft), TOKEN_ID, address(token), LISTING_PRICE, block.timestamp + 1 days);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════
    //           ACCESS CONTROL (ROLE) TESTS
    // ══════════════════════════════════════════════════════

    function test_initialAdmin_has_all_roles() public view {
        assertTrue(marketplace.hasRole(DEFAULT_ADMIN_ROLE, owner));
        assertTrue(marketplace.hasRole(PAUSER_ROLE, owner));
        assertTrue(marketplace.hasRole(FEE_MANAGER_ROLE, owner));
        assertTrue(marketplace.hasRole(TOKEN_MANAGER_ROLE, owner));
    }

    function test_non_admin_has_no_roles() public view {
        assertFalse(marketplace.hasRole(DEFAULT_ADMIN_ROLE, buyer));
        assertFalse(marketplace.hasRole(PAUSER_ROLE, buyer));
        assertFalse(marketplace.hasRole(FEE_MANAGER_ROLE, buyer));
        assertFalse(marketplace.hasRole(TOKEN_MANAGER_ROLE, buyer));
    }

    // ─── grantRole ───

    function test_admin_grants_pauser_role() public {
        address pauser = makeAddr("pauser");

        vm.prank(owner);
        marketplace.grantRole(PAUSER_ROLE, pauser);

        assertTrue(marketplace.hasRole(PAUSER_ROLE, pauser));

        // Pauser can now pause
        vm.prank(pauser);
        marketplace.pause();
        assertTrue(marketplace.paused());
    }

    function test_admin_grants_fee_manager_role() public {
        address feeManager = makeAddr("feeManager");

        vm.prank(owner);
        marketplace.grantRole(FEE_MANAGER_ROLE, feeManager);

        assertTrue(marketplace.hasRole(FEE_MANAGER_ROLE, feeManager));

        // Fee manager can set fee
        vm.prank(feeManager);
        marketplace.setPlatformFee(500);
        assertEq(marketplace.platformFeeBps(), 500);

        // Fee manager can set recipient
        address newRecipient = makeAddr("newRecipient");
        vm.prank(feeManager);
        marketplace.setFeeRecipient(newRecipient);
        assertEq(marketplace.feeRecipient(), newRecipient);
    }

    function test_admin_grants_token_manager_role() public {
        address tokenMgr = makeAddr("tokenMgr");
        MockERC20 newToken = new MockERC20("NewToken", "NT", 18);

        vm.prank(owner);
        marketplace.grantRole(TOKEN_MANAGER_ROLE, tokenMgr);

        assertTrue(marketplace.hasRole(TOKEN_MANAGER_ROLE, tokenMgr));

        // Token manager can add token
        vm.prank(tokenMgr);
        marketplace.addPaymentToken(address(newToken));
        assertTrue(marketplace.isPaymentTokenAllowed(address(newToken)));

        // Token manager can remove token
        vm.prank(tokenMgr);
        marketplace.removePaymentToken(address(newToken));
        assertFalse(marketplace.isPaymentTokenAllowed(address(newToken)));
    }

    function test_grantRole_revert_not_admin() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, buyer, DEFAULT_ADMIN_ROLE));
        marketplace.grantRole(PAUSER_ROLE, buyer);
    }

    // ─── revokeRole ───

    function test_admin_revokes_role() public {
        address pauser = makeAddr("pauser");

        vm.startPrank(owner);
        marketplace.grantRole(PAUSER_ROLE, pauser);
        assertTrue(marketplace.hasRole(PAUSER_ROLE, pauser));

        marketplace.revokeRole(PAUSER_ROLE, pauser);
        assertFalse(marketplace.hasRole(PAUSER_ROLE, pauser));
        vm.stopPrank();

        // Pauser can no longer pause
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, PAUSER_ROLE));
        marketplace.pause();
    }

    function test_revokeRole_revert_not_admin() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, buyer, DEFAULT_ADMIN_ROLE));
        marketplace.revokeRole(PAUSER_ROLE, owner);
    }

    // ─── renounceRole ───

    function test_renounceRole() public {
        // Owner renounces their PAUSER_ROLE
        vm.prank(owner);
        marketplace.renounceRole(PAUSER_ROLE, owner);

        assertFalse(marketplace.hasRole(PAUSER_ROLE, owner));

        // Owner can no longer pause
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, owner, PAUSER_ROLE));
        marketplace.pause();

        // But owner still has other roles
        assertTrue(marketplace.hasRole(FEE_MANAGER_ROLE, owner));
        assertTrue(marketplace.hasRole(DEFAULT_ADMIN_ROLE, owner));
    }

    // ─── Multiple role holders ───

    function test_multiple_pausers() public {
        address pauser1 = makeAddr("pauser1");
        address pauser2 = makeAddr("pauser2");

        vm.startPrank(owner);
        marketplace.grantRole(PAUSER_ROLE, pauser1);
        marketplace.grantRole(PAUSER_ROLE, pauser2);
        vm.stopPrank();

        // pauser1 pauses
        vm.prank(pauser1);
        marketplace.pause();
        assertTrue(marketplace.paused());

        // pauser2 unpauses
        vm.prank(pauser2);
        marketplace.unpause();
        assertFalse(marketplace.paused());
    }

    // ─── Role separation: granted role cannot perform other role's actions ───

    function test_pauser_cannot_set_fee() public {
        address pauser = makeAddr("pauser");

        vm.prank(owner);
        marketplace.grantRole(PAUSER_ROLE, pauser);

        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, FEE_MANAGER_ROLE));
        marketplace.setPlatformFee(500);
    }

    function test_fee_manager_cannot_pause() public {
        address feeManager = makeAddr("feeManager");

        vm.prank(owner);
        marketplace.grantRole(FEE_MANAGER_ROLE, feeManager);

        vm.prank(feeManager);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, feeManager, PAUSER_ROLE));
        marketplace.pause();
    }

    function test_token_manager_cannot_set_fee() public {
        address tokenMgr = makeAddr("tokenMgr");

        vm.prank(owner);
        marketplace.grantRole(TOKEN_MANAGER_ROLE, tokenMgr);

        vm.prank(tokenMgr);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, tokenMgr, FEE_MANAGER_ROLE));
        marketplace.setPlatformFee(500);
    }

    function test_fee_manager_cannot_add_token() public {
        address feeManager = makeAddr("feeManager");
        MockERC20 newToken = new MockERC20("NewToken", "NT", 18);

        vm.prank(owner);
        marketplace.grantRole(FEE_MANAGER_ROLE, feeManager);

        vm.prank(feeManager);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, feeManager, TOKEN_MANAGER_ROLE));
        marketplace.addPaymentToken(address(newToken));
    }

    // ─── Admin transfer (grant new admin, revoke old) ───

    function test_transfer_admin() public {
        address newAdmin = makeAddr("newAdmin");

        vm.startPrank(owner);
        marketplace.grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        marketplace.revokeRole(DEFAULT_ADMIN_ROLE, owner);
        vm.stopPrank();

        assertTrue(marketplace.hasRole(DEFAULT_ADMIN_ROLE, newAdmin));
        assertFalse(marketplace.hasRole(DEFAULT_ADMIN_ROLE, owner));

        // New admin can grant roles
        address pauser = makeAddr("pauser");
        vm.prank(newAdmin);
        marketplace.grantRole(PAUSER_ROLE, pauser);
        assertTrue(marketplace.hasRole(PAUSER_ROLE, pauser));

        // Old admin cannot grant roles
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, owner, DEFAULT_ADMIN_ROLE));
        marketplace.grantRole(PAUSER_ROLE, seller);
    }

    // ─── setFeeRecipient role check ───

    function test_setFeeRecipient_revert_not_fee_manager() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, buyer, FEE_MANAGER_ROLE));
        marketplace.setFeeRecipient(buyer);
    }

    // ─── removePaymentToken role check ───

    function test_removePaymentToken_revert_not_token_manager() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, buyer, TOKEN_MANAGER_ROLE));
        marketplace.removePaymentToken(address(token));
    }

    // ─── supportsInterface (ERC-165) ───

    function test_supportsInterface() public view {
        // AccessControl supports IAccessControl
        assertTrue(marketplace.supportsInterface(type(IAccessControl).interfaceId));
    }
}
