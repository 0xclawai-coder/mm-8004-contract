// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC2981} from "./interfaces/IERC2981.sol";
import {IMoltMarketplace} from "./interfaces/IMoltMarketplace.sol";

/// @title MoltMarketplace - ERC-721 NFT Marketplace
/// @notice Fixed-price listings, offers, English auctions. Native + ERC-20 payments.
/// @dev Platform fee is dynamic (owner-configurable) with a hard cap of 10%.
contract MoltMarketplace is IMoltMarketplace {
    // ──────────────────── Constants ────────────────────

    uint256 public constant MAX_PLATFORM_FEE_BPS = 1_000; // 10% hard cap
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ──────────────────── State ────────────────────

    address public owner;
    address public override feeRecipient;
    uint256 public override platformFeeBps;

    uint256 private _nextListingId = 1;
    uint256 private _nextOfferId = 1;
    uint256 private _nextAuctionId = 1;

    mapping(uint256 => Listing) private _listings;
    mapping(uint256 => Offer) private _offers;
    mapping(uint256 => Auction) private _auctions;

    // ──────────────────── Modifiers ────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // ──────────────────── Constructor ────────────────────

    constructor(address _feeRecipient, uint256 _platformFeeBps) {
        require(_platformFeeBps <= MAX_PLATFORM_FEE_BPS, "Fee exceeds max");
        require(_feeRecipient != address(0), "Zero address");
        owner = msg.sender;
        feeRecipient = _feeRecipient;
        platformFeeBps = _platformFeeBps;
    }

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
    ) external returns (uint256 listingId) {
        require(price > 0, "Price must be > 0");
        require(expiry > block.timestamp, "Expiry in the past");

        // Transfer NFT to escrow
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
    function buy(uint256 listingId) external payable {
        Listing storage listing = _listings[listingId];
        require(listing.status == ListingStatus.Active, "Not active");
        require(block.timestamp <= listing.expiry, "Listing expired");
        require(msg.sender != listing.seller, "Cannot buy own listing");

        listing.status = ListingStatus.Sold;

        // Collect payment
        _collectPayment(msg.sender, listing.paymentToken, listing.price);

        // Distribute funds (fee + royalty + seller)
        _distributeFunds(listing.nftContract, listing.tokenId, listing.seller, listing.paymentToken, listing.price);

        // Transfer NFT to buyer
        IERC721(listing.nftContract).transferFrom(address(this), msg.sender, listing.tokenId);

        emit Bought(listingId, msg.sender, listing.price);
    }

    /// @inheritdoc IMoltMarketplace
    function cancelListing(uint256 listingId) external {
        Listing storage listing = _listings[listingId];
        require(listing.status == ListingStatus.Active, "Not active");
        require(msg.sender == listing.seller, "Not seller");

        listing.status = ListingStatus.Cancelled;

        // Return NFT from escrow
        IERC721(listing.nftContract).transferFrom(address(this), msg.sender, listing.tokenId);

        emit ListingCancelled(listingId);
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
    ) external returns (uint256 offerId) {
        require(amount > 0, "Amount must be > 0");
        require(expiry > block.timestamp, "Expiry in the past");
        require(paymentToken != address(0), "Offers must use ERC-20");

        // Verify offerer has sufficient balance and approval
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

    /// @inheritdoc IMoltMarketplace
    function acceptOffer(uint256 offerId) external {
        Offer storage offer = _offers[offerId];
        require(offer.status == OfferStatus.Active, "Not active");
        require(block.timestamp <= offer.expiry, "Offer expired");

        // Caller must own the NFT
        address nftOwner = IERC721(offer.nftContract).ownerOf(offer.tokenId);
        require(msg.sender == nftOwner, "Not NFT owner");

        offer.status = OfferStatus.Accepted;

        // Pull ERC-20 from offerer
        require(IERC20(offer.paymentToken).transferFrom(offer.offerer, address(this), offer.amount), "ERC20 transfer failed");

        // Distribute funds
        _distributeFunds(offer.nftContract, offer.tokenId, msg.sender, offer.paymentToken, offer.amount);

        // Transfer NFT to offerer
        IERC721(offer.nftContract).transferFrom(msg.sender, offer.offerer, offer.tokenId);

        emit OfferAccepted(offerId, msg.sender);
    }

    /// @inheritdoc IMoltMarketplace
    function cancelOffer(uint256 offerId) external {
        Offer storage offer = _offers[offerId];
        require(offer.status == OfferStatus.Active, "Not active");
        require(msg.sender == offer.offerer, "Not offerer");

        offer.status = OfferStatus.Cancelled;

        emit OfferCancelled(offerId);
    }

    // ══════════════════════════════════════════════════════
    //                      AUCTION
    // ══════════════════════════════════════════════════════

    /// @inheritdoc IMoltMarketplace
    function createAuction(
        address nftContract,
        uint256 tokenId,
        address paymentToken,
        uint256 startPrice,
        uint256 duration
    ) external returns (uint256 auctionId) {
        require(startPrice > 0, "Start price must be > 0");
        require(duration >= 1 hours, "Duration too short");
        require(duration <= 30 days, "Duration too long");

        // Transfer NFT to escrow
        IERC721(nftContract).transferFrom(msg.sender, address(this), tokenId);

        auctionId = _nextAuctionId++;
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + duration;

        _auctions[auctionId] = Auction({
            seller: msg.sender,
            nftContract: nftContract,
            tokenId: tokenId,
            paymentToken: paymentToken,
            startPrice: startPrice,
            highestBid: 0,
            highestBidder: address(0),
            startTime: startTime,
            endTime: endTime,
            status: AuctionStatus.Active
        });

        emit AuctionCreated(auctionId, msg.sender, nftContract, tokenId, paymentToken, startPrice, startTime, endTime);
    }

    /// @inheritdoc IMoltMarketplace
    function bid(uint256 auctionId) external payable {
        Auction storage auction = _auctions[auctionId];
        require(auction.status == AuctionStatus.Active, "Not active");
        require(block.timestamp >= auction.startTime, "Not started");
        require(block.timestamp < auction.endTime, "Auction ended");
        require(msg.sender != auction.seller, "Seller cannot bid");

        uint256 bidAmount;
        if (auction.paymentToken == address(0)) {
            bidAmount = msg.value;
        } else {
            // For ERC-20 auctions, read the bid amount from calldata via approval pattern
            // Bidder must have approved this contract. We pull tokens immediately.
            bidAmount = _getERC20BidAmount(auction.paymentToken, msg.sender);
        }

        uint256 minBid = auction.highestBid == 0 ? auction.startPrice : auction.highestBid + (auction.highestBid / 20); // 5% min increment
        require(bidAmount >= minBid, "Bid too low");

        // Refund previous highest bidder
        if (auction.highestBidder != address(0)) {
            _sendPayment(auction.highestBidder, auction.paymentToken, auction.highestBid);
        }

        // Hold new bid in escrow
        if (auction.paymentToken != address(0)) {
            require(IERC20(auction.paymentToken).transferFrom(msg.sender, address(this), bidAmount), "ERC20 transfer failed");
        }

        auction.highestBid = bidAmount;
        auction.highestBidder = msg.sender;

        // Extend auction by 10 min if bid placed in last 10 min (anti-snipe)
        if (auction.endTime - block.timestamp < 10 minutes) {
            auction.endTime = block.timestamp + 10 minutes;
        }

        emit BidPlaced(auctionId, msg.sender, bidAmount);
    }

    /// @inheritdoc IMoltMarketplace
    function settleAuction(uint256 auctionId) external {
        Auction storage auction = _auctions[auctionId];
        require(auction.status == AuctionStatus.Active, "Not active");
        require(block.timestamp >= auction.endTime, "Auction not ended");

        auction.status = AuctionStatus.Ended;

        if (auction.highestBidder != address(0)) {
            // Distribute funds from escrow
            _distributeFunds(auction.nftContract, auction.tokenId, auction.seller, auction.paymentToken, auction.highestBid);

            // Transfer NFT to winner
            IERC721(auction.nftContract).transferFrom(address(this), auction.highestBidder, auction.tokenId);

            emit AuctionSettled(auctionId, auction.highestBidder, auction.highestBid);
        } else {
            // No bids — return NFT to seller
            IERC721(auction.nftContract).transferFrom(address(this), auction.seller, auction.tokenId);

            emit AuctionCancelled(auctionId);
        }
    }

    /// @inheritdoc IMoltMarketplace
    function cancelAuction(uint256 auctionId) external {
        Auction storage auction = _auctions[auctionId];
        require(auction.status == AuctionStatus.Active, "Not active");
        require(msg.sender == auction.seller, "Not seller");
        require(auction.highestBidder == address(0), "Has bids");

        auction.status = AuctionStatus.Cancelled;

        // Return NFT from escrow
        IERC721(auction.nftContract).transferFrom(address(this), msg.sender, auction.tokenId);

        emit AuctionCancelled(auctionId);
    }

    // ══════════════════════════════════════════════════════
    //                       ADMIN
    // ══════════════════════════════════════════════════════

    /// @inheritdoc IMoltMarketplace
    function setPlatformFee(uint256 newFeeBps) external onlyOwner {
        require(newFeeBps <= MAX_PLATFORM_FEE_BPS, "Fee exceeds max");
        uint256 oldFee = platformFeeBps;
        platformFeeBps = newFeeBps;
        emit PlatformFeeUpdated(oldFee, newFeeBps);
    }

    /// @inheritdoc IMoltMarketplace
    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Zero address");
        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(oldRecipient, newRecipient);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
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
    function getAuction(uint256 auctionId) external view returns (Auction memory) {
        return _auctions[auctionId];
    }

    // ══════════════════════════════════════════════════════
    //                     INTERNAL
    // ══════════════════════════════════════════════════════

    /// @dev Collect payment from buyer. For native: check msg.value. For ERC-20: transferFrom.
    function _collectPayment(address from, address paymentToken, uint256 amount) internal {
        if (paymentToken == address(0)) {
            require(msg.value >= amount, "Insufficient native payment");
            // Refund excess
            if (msg.value > amount) {
                _sendNative(from, msg.value - amount);
            }
        } else {
            require(msg.value == 0, "Native sent for ERC-20 listing");
            require(IERC20(paymentToken).transferFrom(from, address(this), amount), "ERC20 transfer failed");
        }
    }

    /// @dev Distribute payment: platform fee → royalty → seller remainder.
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
        } catch {
            // NFT doesn't support ERC-2981, skip royalty
        }

        // 3. Seller gets the rest
        if (remaining > 0) {
            _sendPayment(seller, paymentToken, remaining);
        }
    }

    /// @dev Send payment in native or ERC-20.
    function _sendPayment(address to, address paymentToken, uint256 amount) internal {
        if (paymentToken == address(0)) {
            _sendNative(to, amount);
        } else {
            require(IERC20(paymentToken).transfer(to, amount), "ERC20 transfer failed");
        }
    }

    /// @dev Send native token with reentrancy-safe call.
    function _sendNative(address to, uint256 amount) internal {
        (bool success,) = to.call{value: amount}("");
        require(success, "Native transfer failed");
    }

    /// @dev For ERC-20 auction bids, determine bid amount from allowance.
    ///      Bidder must set exact allowance = bid amount before calling bid().
    function _getERC20BidAmount(address paymentToken, address bidder) internal view returns (uint256) {
        uint256 allowance = IERC20(paymentToken).allowance(bidder, address(this));
        require(allowance > 0, "No ERC-20 allowance");
        return allowance;
    }

    /// @dev Accept ERC-721 safe transfers (for escrow).
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}
