// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {MoltMarketplace} from "../src/MoltMarketplace.sol";
import {IMoltMarketplace} from "../src/interfaces/IMoltMarketplace.sol";
import {MockERC721} from "./mocks/MockERC721.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract MoltMarketplaceTest is Test {
    MoltMarketplace public marketplace;
    MockERC721 public nft;
    MockERC20 public token;

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
        marketplace = new MoltMarketplace(feeRecipient, PLATFORM_FEE_BPS);
        vm.stopPrank();

        nft = new MockERC721("TestNFT", "TNFT");
        token = new MockERC20("TestToken", "TT", 18);

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
        uint256 expectedFee = (LISTING_PRICE * PLATFORM_FEE_BPS) / 10_000;
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
        // Create auction
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        uint256 auctionId = marketplace.createAuction(address(nft), TOKEN_ID, address(0), 1 ether, 1 days);
        vm.stopPrank();

        assertEq(auctionId, 1);
        assertEq(nft.ownerOf(TOKEN_ID), address(marketplace)); // escrowed

        // Bid 1
        vm.prank(bidder1);
        marketplace.bid{value: 1 ether}(1);

        IMoltMarketplace.Auction memory auction = marketplace.getAuction(1);
        assertEq(auction.highestBid, 1 ether);
        assertEq(auction.highestBidder, bidder1);

        // Bid 2 (must be >= 5% higher = 1.05 ether)
        vm.prank(bidder2);
        marketplace.bid{value: 1.1 ether}(1);

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
        marketplace.createAuction(address(nft), TOKEN_ID, address(0), 1 ether, 1 days);
        vm.stopPrank();

        // Warp to 5 min before end
        vm.warp(block.timestamp + 1 days - 5 minutes);

        vm.prank(bidder1);
        marketplace.bid{value: 1 ether}(1);

        // End time should be extended by 10 min
        IMoltMarketplace.Auction memory auction = marketplace.getAuction(1);
        assertEq(auction.endTime, block.timestamp + 10 minutes);
    }

    function test_auction_no_bids_returns_nft() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.createAuction(address(nft), TOKEN_ID, address(0), 1 ether, 1 days);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);
        marketplace.settleAuction(1);

        assertEq(nft.ownerOf(TOKEN_ID), seller); // returned
    }

    function test_auction_cancel_no_bids() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.createAuction(address(nft), TOKEN_ID, address(0), 1 ether, 1 days);
        marketplace.cancelAuction(1);
        vm.stopPrank();

        assertEq(nft.ownerOf(TOKEN_ID), seller);
    }

    function test_auction_cancel_revert_has_bids() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.createAuction(address(nft), TOKEN_ID, address(0), 1 ether, 1 days);
        vm.stopPrank();

        vm.prank(bidder1);
        marketplace.bid{value: 1 ether}(1);

        vm.prank(seller);
        vm.expectRevert("Has bids");
        marketplace.cancelAuction(1);
    }

    function test_bid_revert_too_low() public {
        vm.startPrank(seller);
        nft.approve(address(marketplace), TOKEN_ID);
        marketplace.createAuction(address(nft), TOKEN_ID, address(0), 1 ether, 1 days);
        vm.stopPrank();

        vm.prank(bidder1);
        vm.expectRevert("Bid too low");
        marketplace.bid{value: 0.5 ether}(1);
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

    function test_setPlatformFee_revert_not_owner() public {
        vm.prank(buyer);
        vm.expectRevert("Not owner");
        marketplace.setPlatformFee(500);
    }

    function test_setFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");
        vm.prank(owner);
        marketplace.setFeeRecipient(newRecipient);

        assertEq(marketplace.feeRecipient(), newRecipient);
    }

    function test_transferOwnership() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        marketplace.transferOwnership(newOwner);

        assertEq(marketplace.owner(), newOwner);

        // New owner can set fee
        vm.prank(newOwner);
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
}
