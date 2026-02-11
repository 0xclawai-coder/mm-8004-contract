// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IMoltMarketplace - ERC-721 NFT Marketplace Interface
/// @notice Fixed-price listings, offers, collection offers, English auctions,
///         Dutch auctions, bundle listings. Native + ERC-20 payments.
interface IMoltMarketplace {
    // ──────────────────── Enums ────────────────────

    enum ListingStatus { Active, Sold, Cancelled }
    enum OfferStatus { Active, Accepted, Cancelled }
    enum AuctionStatus { Active, Ended, Cancelled }
    enum DutchAuctionStatus { Active, Sold, Cancelled }

    // ──────────────────── Structs ────────────────────

    struct Listing {
        address seller;
        address nftContract;
        uint256 tokenId;
        address paymentToken;
        uint256 price;
        uint256 expiry;
        ListingStatus status;
    }

    struct Offer {
        address offerer;
        address nftContract;
        uint256 tokenId;
        address paymentToken;
        uint256 amount;
        uint256 expiry;
        OfferStatus status;
    }

    struct CollectionOffer {
        address offerer;
        address nftContract;
        address paymentToken;
        uint256 amount;
        uint256 expiry;
        OfferStatus status;
    }

    struct Auction {
        address seller;
        address nftContract;
        uint256 tokenId;
        address paymentToken;
        uint256 startPrice;
        uint256 reservePrice;
        uint256 buyNowPrice;
        uint256 highestBid;
        address highestBidder;
        uint256 startTime;
        uint256 endTime;
        uint256 bidCount;
        AuctionStatus status;
    }

    struct DutchAuction {
        address seller;
        address nftContract;
        uint256 tokenId;
        address paymentToken;
        uint256 startPrice;
        uint256 endPrice;
        uint256 startTime;
        uint256 endTime;
        DutchAuctionStatus status;
    }

    struct BundleListing {
        address seller;
        address[] nftContracts;
        uint256[] tokenIds;
        address paymentToken;
        uint256 price;
        uint256 expiry;
        ListingStatus status;
    }

    // ──────────────────── Events: Listing ────────────────────

    event Listed(uint256 indexed listingId, address indexed seller, address indexed nftContract, uint256 tokenId, address paymentToken, uint256 price, uint256 expiry);
    event Bought(uint256 indexed listingId, address indexed buyer, uint256 price);
    event ListingCancelled(uint256 indexed listingId);
    event ListingPriceUpdated(uint256 indexed listingId, uint256 oldPrice, uint256 newPrice);

    // ──────────────────── Events: Offer ────────────────────

    event OfferMade(uint256 indexed offerId, address indexed offerer, address indexed nftContract, uint256 tokenId, address paymentToken, uint256 amount, uint256 expiry);
    event OfferAccepted(uint256 indexed offerId, address indexed seller);
    event OfferCancelled(uint256 indexed offerId);

    // ──────────────────── Events: Collection Offer ────────────────────

    event CollectionOfferMade(uint256 indexed offerId, address indexed offerer, address indexed nftContract, address paymentToken, uint256 amount, uint256 expiry);
    event CollectionOfferAccepted(uint256 indexed offerId, address indexed seller, uint256 tokenId);
    event CollectionOfferCancelled(uint256 indexed offerId);

    // ──────────────────── Events: Auction ────────────────────

    event AuctionCreated(uint256 indexed auctionId, address indexed seller, address indexed nftContract, uint256 tokenId, address paymentToken, uint256 startPrice, uint256 reservePrice, uint256 buyNowPrice, uint256 startTime, uint256 endTime);
    event BidPlaced(uint256 indexed auctionId, address indexed bidder, uint256 amount);
    event AuctionSettled(uint256 indexed auctionId, address indexed winner, uint256 amount);
    event AuctionCancelled(uint256 indexed auctionId);
    event AuctionExtended(uint256 indexed auctionId, uint256 newEndTime);
    event AuctionBuyNow(uint256 indexed auctionId, address indexed buyer, uint256 price);
    event AuctionReserveNotMet(uint256 indexed auctionId, uint256 highestBid, uint256 reservePrice);

    // ──────────────────── Events: Dutch Auction ────────────────────

    event DutchAuctionCreated(uint256 indexed auctionId, address indexed seller, address indexed nftContract, uint256 tokenId, address paymentToken, uint256 startPrice, uint256 endPrice, uint256 startTime, uint256 endTime);
    event DutchAuctionBought(uint256 indexed auctionId, address indexed buyer, uint256 price);
    event DutchAuctionCancelled(uint256 indexed auctionId);

    // ──────────────────── Events: Bundle ────────────────────

    event BundleListed(uint256 indexed bundleId, address indexed seller, uint256 itemCount, address paymentToken, uint256 price, uint256 expiry);
    event BundleBought(uint256 indexed bundleId, address indexed buyer, uint256 price);
    event BundleListingCancelled(uint256 indexed bundleId);

    // ──────────────────── Events: Admin ────────────────────

    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);
    event PaymentTokenAdded(address indexed token);
    event PaymentTokenRemoved(address indexed token);
    event RefundEscrowed(address indexed recipient, uint256 amount);

    // ──────────────────── Listing ────────────────────

    function list(address nftContract, uint256 tokenId, address paymentToken, uint256 price, uint256 expiry) external returns (uint256 listingId);
    function buy(uint256 listingId) external payable;
    function cancelListing(uint256 listingId) external;
    function updateListingPrice(uint256 listingId, uint256 newPrice) external;

    // ──────────────────── Offer ────────────────────

    function makeOffer(address nftContract, uint256 tokenId, address paymentToken, uint256 amount, uint256 expiry) external returns (uint256 offerId);
    function acceptOffer(uint256 offerId) external;
    function cancelOffer(uint256 offerId) external;

    // ──────────────────── Collection Offer ────────────────────

    function makeCollectionOffer(address nftContract, address paymentToken, uint256 amount, uint256 expiry) external returns (uint256 offerId);
    function acceptCollectionOffer(uint256 offerId, uint256 tokenId) external;
    function cancelCollectionOffer(uint256 offerId) external;

    // ──────────────────── Auction (English) ────────────────────

    function createAuction(address nftContract, uint256 tokenId, address paymentToken, uint256 startPrice, uint256 reservePrice, uint256 buyNowPrice, uint256 startTime, uint256 duration) external returns (uint256 auctionId);
    function bid(uint256 auctionId, uint256 amount) external payable;
    function settleAuction(uint256 auctionId) external;
    function cancelAuction(uint256 auctionId) external;

    // ──────────────────── Dutch Auction ────────────────────

    function createDutchAuction(address nftContract, uint256 tokenId, address paymentToken, uint256 startPrice, uint256 endPrice, uint256 duration) external returns (uint256 auctionId);
    function buyDutchAuction(uint256 auctionId) external payable;
    function cancelDutchAuction(uint256 auctionId) external;

    // ──────────────────── Bundle Listing ────────────────────

    function createBundleListing(address[] calldata nftContracts, uint256[] calldata tokenIds, address paymentToken, uint256 price, uint256 expiry) external returns (uint256 bundleId);
    function buyBundle(uint256 bundleId) external payable;
    function cancelBundleListing(uint256 bundleId) external;

    // ──────────────────── Admin ────────────────────

    function setPlatformFee(uint256 newFeeBps) external;
    function setFeeRecipient(address newRecipient) external;
    function addPaymentToken(address token) external;
    function removePaymentToken(address token) external;
    function pause() external;
    function unpause() external;

    // ──────────────────── View ────────────────────

    function getListing(uint256 listingId) external view returns (Listing memory);
    function getOffer(uint256 offerId) external view returns (Offer memory);
    function getCollectionOffer(uint256 offerId) external view returns (CollectionOffer memory);
    function getAuction(uint256 auctionId) external view returns (Auction memory);
    function getDutchAuction(uint256 auctionId) external view returns (DutchAuction memory);
    function getDutchAuctionCurrentPrice(uint256 auctionId) external view returns (uint256);
    function getBundleListing(uint256 bundleId) external view returns (BundleListing memory);
    function platformFeeBps() external view returns (uint256);
    function feeRecipient() external view returns (address);
    function isPaymentTokenAllowed(address token) external view returns (bool);
}
