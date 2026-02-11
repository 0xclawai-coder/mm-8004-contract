// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IMoltMarketplace - ERC-721 NFT Marketplace Interface
/// @notice Supports fixed-price listings, offers, and auctions with Native + ERC-20 payments
interface IMoltMarketplace {
    // ──────────────────── Enums ────────────────────

    enum ListingStatus { Active, Sold, Cancelled }
    enum OfferStatus { Active, Accepted, Cancelled, Expired }
    enum AuctionStatus { Active, Ended, Cancelled }

    // ──────────────────── Structs ────────────────────

    struct Listing {
        address seller;
        address nftContract;
        uint256 tokenId;
        address paymentToken; // address(0) = native token
        uint256 price;
        uint256 expiry;
        ListingStatus status;
    }

    struct Offer {
        address offerer;
        address nftContract;
        uint256 tokenId;
        address paymentToken; // must be ERC-20 (WMON for native offers)
        uint256 amount;
        uint256 expiry;
        OfferStatus status;
    }

    struct Auction {
        address seller;
        address nftContract;
        uint256 tokenId;
        address paymentToken; // address(0) = native token
        uint256 startPrice;
        uint256 highestBid;
        address highestBidder;
        uint256 startTime;
        uint256 endTime;
        AuctionStatus status;
    }

    // ──────────────────── Events ────────────────────

    // Listing
    event Listed(uint256 indexed listingId, address indexed seller, address indexed nftContract, uint256 tokenId, address paymentToken, uint256 price, uint256 expiry);
    event Bought(uint256 indexed listingId, address indexed buyer, uint256 price);
    event ListingCancelled(uint256 indexed listingId);

    // Offer
    event OfferMade(uint256 indexed offerId, address indexed offerer, address indexed nftContract, uint256 tokenId, address paymentToken, uint256 amount, uint256 expiry);
    event OfferAccepted(uint256 indexed offerId, address indexed seller);
    event OfferCancelled(uint256 indexed offerId);

    // Auction
    event AuctionCreated(uint256 indexed auctionId, address indexed seller, address indexed nftContract, uint256 tokenId, address paymentToken, uint256 startPrice, uint256 startTime, uint256 endTime);
    event BidPlaced(uint256 indexed auctionId, address indexed bidder, uint256 amount);
    event AuctionSettled(uint256 indexed auctionId, address indexed winner, uint256 amount);
    event AuctionCancelled(uint256 indexed auctionId);

    // Admin
    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);

    // ──────────────────── Listing ────────────────────

    function list(address nftContract, uint256 tokenId, address paymentToken, uint256 price, uint256 expiry) external returns (uint256 listingId);
    function buy(uint256 listingId) external payable;
    function cancelListing(uint256 listingId) external;

    // ──────────────────── Offer ────────────────────

    function makeOffer(address nftContract, uint256 tokenId, address paymentToken, uint256 amount, uint256 expiry) external returns (uint256 offerId);
    function acceptOffer(uint256 offerId) external;
    function cancelOffer(uint256 offerId) external;

    // ──────────────────── Auction ────────────────────

    function createAuction(address nftContract, uint256 tokenId, address paymentToken, uint256 startPrice, uint256 duration) external returns (uint256 auctionId);
    function bid(uint256 auctionId) external payable;
    function settleAuction(uint256 auctionId) external;
    function cancelAuction(uint256 auctionId) external;

    // ──────────────────── Admin ────────────────────

    function setPlatformFee(uint256 newFeeBps) external;
    function setFeeRecipient(address newRecipient) external;

    // ──────────────────── View ────────────────────

    function getListing(uint256 listingId) external view returns (Listing memory);
    function getOffer(uint256 offerId) external view returns (Offer memory);
    function getAuction(uint256 auctionId) external view returns (Auction memory);
    function platformFeeBps() external view returns (uint256);
    function feeRecipient() external view returns (address);
}
