// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal WETH9/WMON interface for wrap/unwrap
interface IWMON {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
}
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC2981} from "./interfaces/IERC2981.sol";
import {IMoltMarketplace} from "./interfaces/IMoltMarketplace.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title MoltMarketplace - ERC-721 NFT Marketplace
/// @notice Fixed-price listings, offers, collection offers, English auctions,
///         Dutch auctions, bundle listings. Native + ERC-20 payments.
/// @dev Platform fee is dynamic (admin-configurable) with a hard cap of 10%.
///      Uses OpenZeppelin AccessControl, Pausable, and ReentrancyGuard.
contract MoltMarketplace is IMoltMarketplace, AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuard, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    // ──────────────────── Constants ────────────────────

    uint256 public constant MAX_PLATFORM_FEE_BPS = 1_000; // 10% hard cap
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_BUNDLE_SIZE = 20;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 public constant TOKEN_MANAGER_ROLE = keccak256("TOKEN_MANAGER_ROLE");

    // ──────────────────── State ────────────────────

    address public override feeRecipient;
    uint256 public override platformFeeBps;

    uint256 private _nextListingId;
    uint256 private _nextOfferId;
    uint256 private _nextCollectionOfferId;
    uint256 private _nextAuctionId;
    uint256 private _nextDutchAuctionId;
    uint256 private _nextBundleId;

    mapping(uint256 => Listing) private _listings;
    mapping(uint256 => Offer) private _offers;
    mapping(uint256 => CollectionOffer) private _collectionOffers;
    mapping(uint256 => Auction) private _auctions;
    mapping(uint256 => DutchAuction) private _dutchAuctions;
    mapping(uint256 => BundleListing) private _bundles;
    mapping(address => bool) private _allowedPaymentTokens;
    mapping(address => uint256) public pendingWithdrawals;

    /// @notice WMON (Wrapped MON) address — set by admin for native offer wrapping
    address public wmonAddress;
    /// @notice Tracks offers where WMON is escrowed in the contract (from makeOfferWithNative)
    mapping(uint256 => bool) private _escrowedOffers;

    // ──────────────────── Modifiers ────────────────────

    modifier validPaymentToken(address token) {
        require(token == address(0) || _allowedPaymentTokens[token], "Token not allowed");
        _;
    }

    // ──────────────────── Constructor / Initializer ────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialAdmin, address _feeRecipient, uint256 _platformFeeBps) external initializer {
        require(initialAdmin != address(0), "Zero admin");
        require(_platformFeeBps <= MAX_PLATFORM_FEE_BPS, "Fee exceeds max");
        require(_feeRecipient != address(0), "Zero address");

        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);
        _grantRole(FEE_MANAGER_ROLE, initialAdmin);
        _grantRole(TOKEN_MANAGER_ROLE, initialAdmin);

        feeRecipient = _feeRecipient;
        platformFeeBps = _platformFeeBps;

        _nextListingId = 1;
        _nextOfferId = 1;
        _nextCollectionOfferId = 1;
        _nextAuctionId = 1;
        _nextDutchAuctionId = 1;
        _nextBundleId = 1;
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ══════════════════════════════════════════════════════
    //                      LISTING
    // ══════════════════════════════════════════════════════

    /// @inheritdoc IMoltMarketplace
    function list(
        address nftContract,
        uint256 tokenId,
        address paymentToken,
        uint256 price,
        uint256 expiry
    ) external nonReentrant whenNotPaused validPaymentToken(paymentToken) returns (uint256 listingId) {
        require(price > 0, "Price must be > 0");
        require(expiry > block.timestamp, "Expiry in the past");

        IERC721(nftContract).transferFrom(msg.sender, address(this), tokenId);

        listingId = _nextListingId++;
        _listings[listingId] = Listing({
            seller: msg.sender,
            nftContract: nftContract,
            tokenId: tokenId,
            paymentToken: paymentToken,
            price: price,
            expiry: expiry,
            status: ListingStatus.Active
        });

        emit Listed(listingId, msg.sender, nftContract, tokenId, paymentToken, price, expiry);
    }

    /// @inheritdoc IMoltMarketplace
    function buy(uint256 listingId) external payable nonReentrant whenNotPaused {
        Listing storage listing = _listings[listingId];
        require(listing.status == ListingStatus.Active, "Not active");
        require(block.timestamp <= listing.expiry, "Listing expired");
        require(msg.sender != listing.seller, "Cannot buy own listing");

        listing.status = ListingStatus.Sold;

        _collectPayment(msg.sender, listing.paymentToken, listing.price);
        _distributeFunds(listing.nftContract, listing.tokenId, listing.seller, listing.paymentToken, listing.price);
        IERC721(listing.nftContract).transferFrom(address(this), msg.sender, listing.tokenId);

        emit Bought(listingId, msg.sender, listing.price);
    }

    /// @inheritdoc IMoltMarketplace
    function cancelListing(uint256 listingId) external nonReentrant {
        Listing storage listing = _listings[listingId];
        require(listing.status == ListingStatus.Active, "Not active");
        require(msg.sender == listing.seller, "Not seller");

        listing.status = ListingStatus.Cancelled;
        IERC721(listing.nftContract).transferFrom(address(this), msg.sender, listing.tokenId);

        emit ListingCancelled(listingId);
    }

    /// @inheritdoc IMoltMarketplace
    function updateListingPrice(uint256 listingId, uint256 newPrice) external {
        Listing storage listing = _listings[listingId];
        require(listing.status == ListingStatus.Active, "Not active");
        require(msg.sender == listing.seller, "Not seller");
        require(newPrice > 0, "Price must be > 0");

        uint256 oldPrice = listing.price;
        listing.price = newPrice;

        emit ListingPriceUpdated(listingId, oldPrice, newPrice);
    }

    // ══════════════════════════════════════════════════════
    //                       OFFER
    // ══════════════════════════════════════════════════════

    /// @inheritdoc IMoltMarketplace
    function makeOffer(
        address nftContract,
        uint256 tokenId,
        address paymentToken,
        uint256 amount,
        uint256 expiry
    ) external nonReentrant whenNotPaused validPaymentToken(paymentToken) returns (uint256 offerId) {
        require(amount > 0, "Amount must be > 0");
        require(expiry > block.timestamp, "Expiry in the past");
        require(paymentToken != address(0), "Offers must use ERC-20");
        require(IERC20(paymentToken).balanceOf(msg.sender) >= amount, "Insufficient balance");
        require(IERC20(paymentToken).allowance(msg.sender, address(this)) >= amount, "Insufficient allowance");

        offerId = _nextOfferId++;
        _offers[offerId] = Offer({
            offerer: msg.sender,
            nftContract: nftContract,
            tokenId: tokenId,
            paymentToken: paymentToken,
            amount: amount,
            expiry: expiry,
            status: OfferStatus.Active
        });

        emit OfferMade(offerId, msg.sender, nftContract, tokenId, paymentToken, amount, expiry);
    }

    /// @notice Make an offer using native MON — automatically wraps to WMON.
    ///         Single transaction: wrap + approve + create offer.
    /// @param nftContract The NFT contract address
    /// @param tokenId The token ID to make an offer on
    /// @param expiry Timestamp when the offer expires
    /// @return offerId The ID of the created offer
    function makeOfferWithNative(
        address nftContract,
        uint256 tokenId,
        uint256 expiry
    ) external payable nonReentrant whenNotPaused returns (uint256 offerId) {
        require(wmonAddress != address(0), "WMON not configured");
        require(_allowedPaymentTokens[wmonAddress], "WMON not allowed as payment");
        require(msg.value > 0, "Amount must be > 0");
        require(expiry > block.timestamp, "Expiry in the past");

        uint256 amount = msg.value;

        // Wrap MON → WMON (WMON is held by this contract as escrow)
        IWMON(wmonAddress).deposit{value: amount}();

        offerId = _nextOfferId++;
        _offers[offerId] = Offer({
            offerer: msg.sender,
            nftContract: nftContract,
            tokenId: tokenId,
            paymentToken: wmonAddress,
            amount: amount,
            expiry: expiry,
            status: OfferStatus.Active
        });

        // Mark this offer as escrowed (WMON held by marketplace)
        _escrowedOffers[offerId] = true;

        emit OfferMade(offerId, msg.sender, nftContract, tokenId, wmonAddress, amount, expiry);
    }

    /// @inheritdoc IMoltMarketplace
    function acceptOffer(uint256 offerId) external nonReentrant whenNotPaused {
        Offer storage offer = _offers[offerId];
        require(offer.status == OfferStatus.Active, "Not active");
        require(block.timestamp <= offer.expiry, "Offer expired");

        address nftOwner = IERC721(offer.nftContract).ownerOf(offer.tokenId);
        require(msg.sender == nftOwner, "Not NFT owner");

        offer.status = OfferStatus.Accepted;

        if (_escrowedOffers[offerId]) {
            // WMON already held by this contract — distribute directly
            _distributeFunds(offer.nftContract, offer.tokenId, msg.sender, offer.paymentToken, offer.amount);
        } else {
            // Standard: pull ERC-20 from offerer
            IERC20(offer.paymentToken).safeTransferFrom(offer.offerer, address(this), offer.amount);
            _distributeFunds(offer.nftContract, offer.tokenId, msg.sender, offer.paymentToken, offer.amount);
        }
        IERC721(offer.nftContract).transferFrom(msg.sender, offer.offerer, offer.tokenId);

        emit OfferAccepted(offerId, msg.sender);
    }

    /// @inheritdoc IMoltMarketplace
    function cancelOffer(uint256 offerId) external nonReentrant {
        Offer storage offer = _offers[offerId];
        require(offer.status == OfferStatus.Active, "Not active");
        require(msg.sender == offer.offerer, "Not offerer");

        offer.status = OfferStatus.Cancelled;

        // Refund escrowed WMON
        if (_escrowedOffers[offerId]) {
            IERC20(offer.paymentToken).safeTransfer(offer.offerer, offer.amount);
            delete _escrowedOffers[offerId];
        }

        emit OfferCancelled(offerId);
    }

    // ══════════════════════════════════════════════════════
    //                  COLLECTION OFFER
    // ══════════════════════════════════════════════════════

    /// @inheritdoc IMoltMarketplace
    function makeCollectionOffer(
        address nftContract,
        address paymentToken,
        uint256 amount,
        uint256 expiry
    ) external nonReentrant whenNotPaused validPaymentToken(paymentToken) returns (uint256 offerId) {
        require(amount > 0, "Amount must be > 0");
        require(expiry > block.timestamp, "Expiry in the past");
        require(paymentToken != address(0), "Offers must use ERC-20");
        require(IERC20(paymentToken).balanceOf(msg.sender) >= amount, "Insufficient balance");
        require(IERC20(paymentToken).allowance(msg.sender, address(this)) >= amount, "Insufficient allowance");

        offerId = _nextCollectionOfferId++;
        _collectionOffers[offerId] = CollectionOffer({
            offerer: msg.sender,
            nftContract: nftContract,
            paymentToken: paymentToken,
            amount: amount,
            expiry: expiry,
            status: OfferStatus.Active
        });

        emit CollectionOfferMade(offerId, msg.sender, nftContract, paymentToken, amount, expiry);
    }

    /// @inheritdoc IMoltMarketplace
    function acceptCollectionOffer(uint256 offerId, uint256 tokenId) external nonReentrant whenNotPaused {
        CollectionOffer storage offer = _collectionOffers[offerId];
        require(offer.status == OfferStatus.Active, "Not active");
        require(block.timestamp <= offer.expiry, "Offer expired");

        address nftOwner = IERC721(offer.nftContract).ownerOf(tokenId);
        require(msg.sender == nftOwner, "Not NFT owner");

        offer.status = OfferStatus.Accepted;

        IERC20(offer.paymentToken).safeTransferFrom(offer.offerer, address(this), offer.amount);
        _distributeFunds(offer.nftContract, tokenId, msg.sender, offer.paymentToken, offer.amount);
        IERC721(offer.nftContract).transferFrom(msg.sender, offer.offerer, tokenId);

        emit CollectionOfferAccepted(offerId, msg.sender, tokenId);
    }

    /// @inheritdoc IMoltMarketplace
    function cancelCollectionOffer(uint256 offerId) external {
        CollectionOffer storage offer = _collectionOffers[offerId];
        require(offer.status == OfferStatus.Active, "Not active");
        require(msg.sender == offer.offerer, "Not offerer");

        offer.status = OfferStatus.Cancelled;
        emit CollectionOfferCancelled(offerId);
    }

    // ══════════════════════════════════════════════════════
    //                 AUCTION (ENGLISH)
    // ══════════════════════════════════════════════════════

    /// @inheritdoc IMoltMarketplace
    function createAuction(
        address nftContract,
        uint256 tokenId,
        address paymentToken,
        uint256 startPrice,
        uint256 reservePrice,
        uint256 buyNowPrice,
        uint256 startTime,
        uint256 duration
    ) external nonReentrant whenNotPaused validPaymentToken(paymentToken) returns (uint256 auctionId) {
        require(startPrice > 0, "Start price must be > 0");
        require(duration >= 1 hours, "Duration too short");
        require(duration <= 30 days, "Duration too long");
        if (reservePrice > 0) {
            require(reservePrice >= startPrice, "Reserve < start price");
        }
        if (buyNowPrice > 0) {
            require(buyNowPrice > startPrice, "BuyNow <= start price");
            if (reservePrice > 0) {
                require(buyNowPrice >= reservePrice, "BuyNow < reserve");
            }
        }

        // startTime: 0 or past = start now
        uint256 effectiveStart = (startTime > block.timestamp) ? startTime : block.timestamp;
        uint256 endTime = effectiveStart + duration;

        IERC721(nftContract).transferFrom(msg.sender, address(this), tokenId);

        auctionId = _nextAuctionId++;
        _auctions[auctionId] = Auction({
            seller: msg.sender,
            nftContract: nftContract,
            tokenId: tokenId,
            paymentToken: paymentToken,
            startPrice: startPrice,
            reservePrice: reservePrice,
            buyNowPrice: buyNowPrice,
            highestBid: 0,
            highestBidder: address(0),
            startTime: effectiveStart,
            endTime: endTime,
            bidCount: 0,
            status: AuctionStatus.Active
        });

        emit AuctionCreated(auctionId, msg.sender, nftContract, tokenId, paymentToken, startPrice, reservePrice, buyNowPrice, effectiveStart, endTime);
    }

    /// @inheritdoc IMoltMarketplace
    function bid(uint256 auctionId, uint256 amount) external payable nonReentrant whenNotPaused {
        Auction storage auction = _auctions[auctionId];
        require(auction.status == AuctionStatus.Active, "Not active");
        require(block.timestamp >= auction.startTime, "Not started");
        require(block.timestamp < auction.endTime, "Auction ended");
        require(msg.sender != auction.seller, "Seller cannot bid");

        uint256 bidAmount;
        if (auction.paymentToken == address(0)) {
            bidAmount = msg.value;
        } else {
            require(msg.value == 0, "Native sent for ERC-20 auction");
            bidAmount = amount;
        }

        uint256 minBid = auction.highestBid == 0
            ? auction.startPrice
            : auction.highestBid + (auction.highestBid / 20); // 5% min increment
        require(bidAmount >= minBid, "Bid too low");

        // Buy-now: if bid >= buyNowPrice, settle immediately at buyNowPrice
        if (auction.buyNowPrice > 0 && bidAmount >= auction.buyNowPrice) {
            _settleBuyNow(auctionId, auction);
            return;
        }

        // Refund previous highest bidder (safe: failed native refunds go to pendingWithdrawals)
        if (auction.highestBidder != address(0)) {
            _safeRefund(auction.highestBidder, auction.paymentToken, auction.highestBid);
        }

        // Hold new bid in escrow
        if (auction.paymentToken != address(0)) {
            IERC20(auction.paymentToken).safeTransferFrom(msg.sender, address(this), bidAmount);
        }

        auction.highestBid = bidAmount;
        auction.highestBidder = msg.sender;
        auction.bidCount++;

        // Anti-snipe: extend by 10 min if bid in last 10 min
        if (auction.endTime - block.timestamp < 10 minutes) {
            auction.endTime = block.timestamp + 10 minutes;
            emit AuctionExtended(auctionId, auction.endTime);
        }

        emit BidPlaced(auctionId, msg.sender, bidAmount);
    }

    /// @inheritdoc IMoltMarketplace
    function settleAuction(uint256 auctionId) external nonReentrant {
        Auction storage auction = _auctions[auctionId];
        require(auction.status == AuctionStatus.Active, "Not active");
        require(block.timestamp >= auction.endTime, "Auction not ended");

        auction.status = AuctionStatus.Ended;

        if (auction.highestBidder == address(0)) {
            // No bids — return NFT
            IERC721(auction.nftContract).transferFrom(address(this), auction.seller, auction.tokenId);
            emit AuctionCancelled(auctionId);
        } else if (auction.reservePrice > 0 && auction.highestBid < auction.reservePrice) {
            // Reserve not met — refund bidder, return NFT (safe: failed native refunds go to pendingWithdrawals)
            _safeRefund(auction.highestBidder, auction.paymentToken, auction.highestBid);
            IERC721(auction.nftContract).transferFrom(address(this), auction.seller, auction.tokenId);
            emit AuctionReserveNotMet(auctionId, auction.highestBid, auction.reservePrice);
        } else {
            // Successful sale
            _distributeFunds(auction.nftContract, auction.tokenId, auction.seller, auction.paymentToken, auction.highestBid);
            IERC721(auction.nftContract).transferFrom(address(this), auction.highestBidder, auction.tokenId);
            emit AuctionSettled(auctionId, auction.highestBidder, auction.highestBid);
        }
    }

    /// @inheritdoc IMoltMarketplace
    function cancelAuction(uint256 auctionId) external nonReentrant {
        Auction storage auction = _auctions[auctionId];
        require(auction.status == AuctionStatus.Active, "Not active");
        require(msg.sender == auction.seller, "Not seller");
        require(auction.highestBidder == address(0), "Has bids");

        auction.status = AuctionStatus.Cancelled;
        IERC721(auction.nftContract).transferFrom(address(this), msg.sender, auction.tokenId);

        emit AuctionCancelled(auctionId);
    }

    // ══════════════════════════════════════════════════════
    //                   DUTCH AUCTION
    // ══════════════════════════════════════════════════════

    /// @inheritdoc IMoltMarketplace
    function createDutchAuction(
        address nftContract,
        uint256 tokenId,
        address paymentToken,
        uint256 startPrice,
        uint256 endPrice,
        uint256 duration
    ) external nonReentrant whenNotPaused validPaymentToken(paymentToken) returns (uint256 auctionId) {
        require(startPrice > 0, "Start price must be > 0");
        require(endPrice < startPrice, "End price >= start price");
        require(duration >= 1 hours, "Duration too short");
        require(duration <= 30 days, "Duration too long");

        IERC721(nftContract).transferFrom(msg.sender, address(this), tokenId);

        auctionId = _nextDutchAuctionId++;
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + duration;

        _dutchAuctions[auctionId] = DutchAuction({
            seller: msg.sender,
            nftContract: nftContract,
            tokenId: tokenId,
            paymentToken: paymentToken,
            startPrice: startPrice,
            endPrice: endPrice,
            startTime: startTime,
            endTime: endTime,
            status: DutchAuctionStatus.Active
        });

        emit DutchAuctionCreated(auctionId, msg.sender, nftContract, tokenId, paymentToken, startPrice, endPrice, startTime, endTime);
    }

    /// @inheritdoc IMoltMarketplace
    function buyDutchAuction(uint256 auctionId) external payable nonReentrant whenNotPaused {
        DutchAuction storage auction = _dutchAuctions[auctionId];
        require(auction.status == DutchAuctionStatus.Active, "Not active");
        require(block.timestamp >= auction.startTime, "Not started");
        require(msg.sender != auction.seller, "Cannot buy own auction");

        uint256 currentPrice = _getDutchPrice(auction);

        auction.status = DutchAuctionStatus.Sold;

        // Collect payment at current price
        _collectPayment(msg.sender, auction.paymentToken, currentPrice);
        _distributeFunds(auction.nftContract, auction.tokenId, auction.seller, auction.paymentToken, currentPrice);
        IERC721(auction.nftContract).transferFrom(address(this), msg.sender, auction.tokenId);

        emit DutchAuctionBought(auctionId, msg.sender, currentPrice);
    }

    /// @inheritdoc IMoltMarketplace
    function cancelDutchAuction(uint256 auctionId) external nonReentrant {
        DutchAuction storage auction = _dutchAuctions[auctionId];
        require(auction.status == DutchAuctionStatus.Active, "Not active");
        require(msg.sender == auction.seller, "Not seller");

        auction.status = DutchAuctionStatus.Cancelled;
        IERC721(auction.nftContract).transferFrom(address(this), msg.sender, auction.tokenId);

        emit DutchAuctionCancelled(auctionId);
    }

    // ══════════════════════════════════════════════════════
    //                   BUNDLE LISTING
    // ══════════════════════════════════════════════════════

    /// @inheritdoc IMoltMarketplace
    function createBundleListing(
        address[] calldata nftContracts,
        uint256[] calldata tokenIds,
        address paymentToken,
        uint256 price,
        uint256 expiry
    ) external nonReentrant whenNotPaused validPaymentToken(paymentToken) returns (uint256 bundleId) {
        uint256 len = nftContracts.length;
        require(len > 0, "Empty bundle");
        require(len <= MAX_BUNDLE_SIZE, "Bundle too large");
        require(len == tokenIds.length, "Length mismatch");
        require(price > 0, "Price must be > 0");
        require(expiry > block.timestamp, "Expiry in the past");

        // Transfer all NFTs to escrow
        for (uint256 i = 0; i < len; i++) {
            IERC721(nftContracts[i]).transferFrom(msg.sender, address(this), tokenIds[i]);
        }

        bundleId = _nextBundleId++;
        _bundles[bundleId] = BundleListing({
            seller: msg.sender,
            nftContracts: nftContracts,
            tokenIds: tokenIds,
            paymentToken: paymentToken,
            price: price,
            expiry: expiry,
            status: ListingStatus.Active
        });

        emit BundleListed(bundleId, msg.sender, len, paymentToken, price, expiry);
    }

    /// @inheritdoc IMoltMarketplace
    function buyBundle(uint256 bundleId) external payable nonReentrant whenNotPaused {
        BundleListing storage bundle = _bundles[bundleId];
        require(bundle.status == ListingStatus.Active, "Not active");
        require(block.timestamp <= bundle.expiry, "Bundle expired");
        require(msg.sender != bundle.seller, "Cannot buy own bundle");

        bundle.status = ListingStatus.Sold;

        _collectPayment(msg.sender, bundle.paymentToken, bundle.price);

        // Distribute funds — use first NFT for royalty check
        _distributeFunds(bundle.nftContracts[0], bundle.tokenIds[0], bundle.seller, bundle.paymentToken, bundle.price);

        // Transfer all NFTs to buyer
        for (uint256 i = 0; i < bundle.nftContracts.length; i++) {
            IERC721(bundle.nftContracts[i]).transferFrom(address(this), msg.sender, bundle.tokenIds[i]);
        }

        emit BundleBought(bundleId, msg.sender, bundle.price);
    }

    /// @inheritdoc IMoltMarketplace
    function cancelBundleListing(uint256 bundleId) external nonReentrant {
        BundleListing storage bundle = _bundles[bundleId];
        require(bundle.status == ListingStatus.Active, "Not active");
        require(msg.sender == bundle.seller, "Not seller");

        bundle.status = ListingStatus.Cancelled;

        for (uint256 i = 0; i < bundle.nftContracts.length; i++) {
            IERC721(bundle.nftContracts[i]).transferFrom(address(this), msg.sender, bundle.tokenIds[i]);
        }

        emit BundleListingCancelled(bundleId);
    }

    // ══════════════════════════════════════════════════════
    //                       ADMIN
    // ══════════════════════════════════════════════════════

    /// @inheritdoc IMoltMarketplace
    function setPlatformFee(uint256 newFeeBps) external onlyRole(FEE_MANAGER_ROLE) {
        require(newFeeBps <= MAX_PLATFORM_FEE_BPS, "Fee exceeds max");
        uint256 oldFee = platformFeeBps;
        platformFeeBps = newFeeBps;
        emit PlatformFeeUpdated(oldFee, newFeeBps);
    }

    /// @inheritdoc IMoltMarketplace
    function setFeeRecipient(address newRecipient) external onlyRole(FEE_MANAGER_ROLE) {
        require(newRecipient != address(0), "Zero address");
        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(oldRecipient, newRecipient);
    }

    /// @notice Set the WMON address (admin only)
    function setWmonAddress(address _wmon) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_wmon != address(0), "Zero address");
        wmonAddress = _wmon;
    }

    /// @inheritdoc IMoltMarketplace
    function addPaymentToken(address token) external onlyRole(TOKEN_MANAGER_ROLE) {
        require(token != address(0), "Zero address");
        require(!_allowedPaymentTokens[token], "Already allowed");
        _allowedPaymentTokens[token] = true;
        emit PaymentTokenAdded(token);
    }

    /// @inheritdoc IMoltMarketplace
    function removePaymentToken(address token) external onlyRole(TOKEN_MANAGER_ROLE) {
        require(_allowedPaymentTokens[token], "Not allowed");
        _allowedPaymentTokens[token] = false;
        emit PaymentTokenRemoved(token);
    }

    /// @inheritdoc IMoltMarketplace
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @inheritdoc IMoltMarketplace
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ══════════════════════════════════════════════════════
    //                       VIEW
    // ══════════════════════════════════════════════════════

    /// @inheritdoc IMoltMarketplace
    function getListing(uint256 listingId) external view returns (Listing memory) {
        return _listings[listingId];
    }

    /// @inheritdoc IMoltMarketplace
    function getOffer(uint256 offerId) external view returns (Offer memory) {
        return _offers[offerId];
    }

    /// @inheritdoc IMoltMarketplace
    function getCollectionOffer(uint256 offerId) external view returns (CollectionOffer memory) {
        return _collectionOffers[offerId];
    }

    /// @inheritdoc IMoltMarketplace
    function getAuction(uint256 auctionId) external view returns (Auction memory) {
        return _auctions[auctionId];
    }

    /// @inheritdoc IMoltMarketplace
    function getDutchAuction(uint256 auctionId) external view returns (DutchAuction memory) {
        return _dutchAuctions[auctionId];
    }

    /// @inheritdoc IMoltMarketplace
    function getDutchAuctionCurrentPrice(uint256 auctionId) external view returns (uint256) {
        DutchAuction storage auction = _dutchAuctions[auctionId];
        require(auction.status == DutchAuctionStatus.Active, "Not active");
        return _getDutchPrice(auction);
    }

    /// @inheritdoc IMoltMarketplace
    function getBundleListing(uint256 bundleId) external view returns (BundleListing memory) {
        return _bundles[bundleId];
    }

    /// @inheritdoc IMoltMarketplace
    function isPaymentTokenAllowed(address token) external view returns (bool) {
        return _allowedPaymentTokens[token];
    }

    // ══════════════════════════════════════════════════════
    //                     INTERNAL
    // ══════════════════════════════════════════════════════

    function _collectPayment(address from, address paymentToken, uint256 amount) internal {
        if (paymentToken == address(0)) {
            require(msg.value >= amount, "Insufficient native payment");
            if (msg.value > amount) {
                _sendNative(from, msg.value - amount);
            }
        } else {
            require(msg.value == 0, "Native sent for ERC-20 listing");
            IERC20(paymentToken).safeTransferFrom(from, address(this), amount);
        }
    }

    function _distributeFunds(
        address nftContract,
        uint256 tokenId,
        address seller,
        address paymentToken,
        uint256 totalAmount
    ) internal {
        uint256 remaining = totalAmount;

        // 1. Platform fee
        uint256 fee = (totalAmount * platformFeeBps) / BPS_DENOMINATOR;
        if (fee > 0) {
            _sendPayment(feeRecipient, paymentToken, fee);
            remaining -= fee;
        }

        // 2. Royalty (ERC-2981)
        try IERC2981(nftContract).royaltyInfo(tokenId, totalAmount) returns (address receiver, uint256 royaltyAmount) {
            if (royaltyAmount > 0 && receiver != address(0) && royaltyAmount <= remaining) {
                _sendPayment(receiver, paymentToken, royaltyAmount);
                remaining -= royaltyAmount;
            }
        } catch {}

        // 3. Seller gets the rest
        if (remaining > 0) {
            _sendPayment(seller, paymentToken, remaining);
        }
    }

    function _sendPayment(address to, address paymentToken, uint256 amount) internal {
        if (paymentToken == address(0)) {
            _sendNative(to, amount);
        } else {
            IERC20(paymentToken).safeTransfer(to, amount);
        }
    }

    function _sendNative(address to, uint256 amount) internal {
        (bool success,) = to.call{value: amount}("");
        require(success, "Native transfer failed");
    }

    /// @dev Settle auction immediately via buy-now.
    function _settleBuyNow(uint256 auctionId, Auction storage auction) internal {
        auction.status = AuctionStatus.Ended;
        auction.bidCount++;

        uint256 price = auction.buyNowPrice;

        // Refund previous highest bidder (safe: failed native refunds go to pendingWithdrawals)
        if (auction.highestBidder != address(0)) {
            _safeRefund(auction.highestBidder, auction.paymentToken, auction.highestBid);
        }

        // Collect buy-now price from buyer
        if (auction.paymentToken == address(0)) {
            require(msg.value >= price, "Insufficient native payment");
            if (msg.value > price) {
                _sendNative(msg.sender, msg.value - price);
            }
        } else {
            IERC20(auction.paymentToken).safeTransferFrom(msg.sender, address(this), price);
        }

        auction.highestBid = price;
        auction.highestBidder = msg.sender;

        _distributeFunds(auction.nftContract, auction.tokenId, auction.seller, auction.paymentToken, price);
        IERC721(auction.nftContract).transferFrom(address(this), msg.sender, auction.tokenId);

        emit AuctionBuyNow(auctionId, msg.sender, price);
    }

    /// @dev Calculate current Dutch auction price based on linear decay.
    function _getDutchPrice(DutchAuction storage auction) internal view returns (uint256) {
        if (block.timestamp >= auction.endTime) {
            return auction.endPrice;
        }
        uint256 elapsed = block.timestamp - auction.startTime;
        uint256 duration = auction.endTime - auction.startTime;
        uint256 priceDrop = ((auction.startPrice - auction.endPrice) * elapsed) / duration;
        return auction.startPrice - priceDrop;
    }

    /// @dev Refund that never reverts. Failed native refunds are escrowed in pendingWithdrawals.
    function _safeRefund(address to, address paymentToken, uint256 amount) internal {
        if (paymentToken == address(0)) {
            (bool success,) = to.call{ value: amount }("");
            if (!success) {
                pendingWithdrawals[to] += amount;
                emit RefundEscrowed(to, amount);
            }
        } else {
            IERC20(paymentToken).safeTransfer(to, amount);
        }
    }

    /// @notice Withdraw escrowed native refunds that failed to deliver.
    function withdrawPending() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "Nothing to withdraw");
        pendingWithdrawals[msg.sender] = 0;
        _sendNative(msg.sender, amount);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}
