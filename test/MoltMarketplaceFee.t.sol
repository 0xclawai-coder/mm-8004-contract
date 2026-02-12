// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {MoltMarketplace} from "../src/MoltMarketplace.sol";
import {MoltMarketplaceProxy} from "../src/MoltMarketplaceProxy.sol";
import {IMoltMarketplace} from "../src/interfaces/IMoltMarketplace.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {MockERC721} from "./mocks/MockERC721.sol";
import {MockERC2981NFT} from "./mocks/MockERC2981NFT.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract MoltMarketplaceFeeTest is Test {
    MoltMarketplace public marketplace;
    MoltMarketplace public impl;
    MockERC721 public nft; // no royalty
    MockERC2981NFT public royaltyNft; // 5% royalty
    MockERC20 public token;

    address public owner = makeAddr("owner");
    address public feeRecipient = makeAddr("feeRecipient");
    address public royaltyReceiver = makeAddr("royaltyReceiver");
    address public seller = makeAddr("seller");
    address public buyer = makeAddr("buyer");
    address public bidder1 = makeAddr("bidder1");

    uint256 public constant ROYALTY_BPS = 500; // 5%
    uint256 public constant BPS = 10_000;
    uint256 public constant PRICE = 10 ether;
    uint256 public constant TOKEN_PRICE = 1000e18;

    uint256 public nextTokenId = 1;

    function setUp() public {
        impl = new MoltMarketplace();
        bytes memory initData = abi.encodeCall(MoltMarketplace.initialize, (owner, feeRecipient, 250));
        MoltMarketplaceProxy proxy = new MoltMarketplaceProxy(address(impl), initData);
        marketplace = MoltMarketplace(payable(address(proxy)));

        nft = new MockERC721("TestNFT", "TNFT");
        royaltyNft = new MockERC2981NFT("RoyaltyNFT", "RNFT", royaltyReceiver, ROYALTY_BPS);
        token = new MockERC20("TestToken", "TT", 18);

        vm.prank(owner);
        marketplace.addPaymentToken(address(token));

        // Fund accounts
        vm.deal(seller, 100 ether);
        vm.deal(buyer, 100 ether);
        vm.deal(bidder1, 100 ether);
        token.mint(buyer, 10_000e18);
        token.mint(bidder1, 10_000e18);
    }

    // ══════════════════════════════════════════════════════
    //                      HELPERS
    // ══════════════════════════════════════════════════════

    function _mintNFT(address to, bool withRoyalty) internal returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        if (withRoyalty) {
            royaltyNft.mint(to, tokenId);
        } else {
            nft.mint(to, tokenId);
        }
    }

    function _nftAddr(bool withRoyalty) internal view returns (address) {
        return withRoyalty ? address(royaltyNft) : address(nft);
    }

    function _setFee(uint256 feeBps) internal {
        vm.prank(owner);
        marketplace.setPlatformFee(feeBps);
    }

    // ══════════════════════════════════════════════════════
    //              1. buy() — FIXED-PRICE LISTING
    // ══════════════════════════════════════════════════════

    // A: Native, 2.5%, no royalty
    function test_fee_buy_native_250bps_noRoyalty() public {
        uint256 tokenId = _mintNFT(seller, false);
        vm.startPrank(seller);
        nft.approve(address(marketplace), tokenId);
        marketplace.list(address(nft), tokenId, address(0), PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = feeRecipient.balance;

        vm.prank(buyer);
        marketplace.buy{value: PRICE}(1);

        uint256 expectedFee = (PRICE * 250) / BPS;
        uint256 expectedSeller = PRICE - expectedFee;
        assertEq(feeRecipient.balance - feeBefore, expectedFee, "fee mismatch");
        assertEq(seller.balance - sellerBefore, expectedSeller, "seller mismatch");
    }

    // B: ERC-20, 2.5%, no royalty
    function test_fee_buy_erc20_250bps_noRoyalty() public {
        uint256 tokenId = _mintNFT(seller, false);
        vm.startPrank(seller);
        nft.approve(address(marketplace), tokenId);
        marketplace.list(address(nft), tokenId, address(token), TOKEN_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        vm.startPrank(buyer);
        token.approve(address(marketplace), TOKEN_PRICE);
        marketplace.buy(1);
        vm.stopPrank();

        uint256 expectedFee = (TOKEN_PRICE * 250) / BPS;
        uint256 expectedSeller = TOKEN_PRICE - expectedFee;
        assertEq(token.balanceOf(feeRecipient), expectedFee, "fee mismatch");
        assertEq(token.balanceOf(seller), expectedSeller, "seller mismatch");
    }

    // C: Native, 2.5%, 5% royalty
    function test_fee_buy_native_250bps_royalty() public {
        uint256 tokenId = _mintNFT(seller, true);
        vm.startPrank(seller);
        royaltyNft.approve(address(marketplace), tokenId);
        marketplace.list(address(royaltyNft), tokenId, address(0), PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = feeRecipient.balance;
        uint256 royaltyBefore = royaltyReceiver.balance;

        vm.prank(buyer);
        marketplace.buy{value: PRICE}(1);

        uint256 expectedFee = (PRICE * 250) / BPS;
        uint256 expectedRoyalty = (PRICE * ROYALTY_BPS) / BPS;
        uint256 expectedSeller = PRICE - expectedFee - expectedRoyalty;
        assertEq(feeRecipient.balance - feeBefore, expectedFee, "fee mismatch");
        assertEq(royaltyReceiver.balance - royaltyBefore, expectedRoyalty, "royalty mismatch");
        assertEq(seller.balance - sellerBefore, expectedSeller, "seller mismatch");
    }

    // D: ERC-20, 2.5%, 5% royalty
    function test_fee_buy_erc20_250bps_royalty() public {
        uint256 tokenId = _mintNFT(seller, true);
        vm.startPrank(seller);
        royaltyNft.approve(address(marketplace), tokenId);
        marketplace.list(address(royaltyNft), tokenId, address(token), TOKEN_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        vm.startPrank(buyer);
        token.approve(address(marketplace), TOKEN_PRICE);
        marketplace.buy(1);
        vm.stopPrank();

        uint256 expectedFee = (TOKEN_PRICE * 250) / BPS;
        uint256 expectedRoyalty = (TOKEN_PRICE * ROYALTY_BPS) / BPS;
        uint256 expectedSeller = TOKEN_PRICE - expectedFee - expectedRoyalty;
        assertEq(token.balanceOf(feeRecipient), expectedFee, "fee mismatch");
        assertEq(token.balanceOf(royaltyReceiver), expectedRoyalty, "royalty mismatch");
        assertEq(token.balanceOf(seller), expectedSeller, "seller mismatch");
    }

    // E: Native, 10% MAX, no royalty
    function test_fee_buy_native_maxFee_noRoyalty() public {
        _setFee(1000); // 10%
        uint256 tokenId = _mintNFT(seller, false);
        vm.startPrank(seller);
        nft.approve(address(marketplace), tokenId);
        marketplace.list(address(nft), tokenId, address(0), PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = feeRecipient.balance;

        vm.prank(buyer);
        marketplace.buy{value: PRICE}(1);

        uint256 expectedFee = (PRICE * 1000) / BPS;
        uint256 expectedSeller = PRICE - expectedFee;
        assertEq(feeRecipient.balance - feeBefore, expectedFee, "fee mismatch");
        assertEq(seller.balance - sellerBefore, expectedSeller, "seller mismatch");
    }

    // F: Native, 0%, no royalty
    function test_fee_buy_native_zeroFee_noRoyalty() public {
        _setFee(0);
        uint256 tokenId = _mintNFT(seller, false);
        vm.startPrank(seller);
        nft.approve(address(marketplace), tokenId);
        marketplace.list(address(nft), tokenId, address(0), PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = feeRecipient.balance;

        vm.prank(buyer);
        marketplace.buy{value: PRICE}(1);

        assertEq(feeRecipient.balance - feeBefore, 0, "fee mismatch");
        assertEq(seller.balance - sellerBefore, PRICE, "seller mismatch");
    }

    // ══════════════════════════════════════════════════════
    //              2. acceptOffer()
    // ══════════════════════════════════════════════════════

    // A: (Offers are always ERC-20, skip native — test ERC-20 2.5% no royalty)
    // B: ERC-20, 2.5%, no royalty
    function test_fee_acceptOffer_erc20_250bps_noRoyalty() public {
        uint256 tokenId = _mintNFT(seller, false);
        vm.startPrank(buyer);
        token.approve(address(marketplace), TOKEN_PRICE);
        marketplace.makeOffer(address(nft), tokenId, address(token), TOKEN_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        vm.startPrank(seller);
        nft.approve(address(marketplace), tokenId);
        marketplace.acceptOffer(1);
        vm.stopPrank();

        uint256 expectedFee = (TOKEN_PRICE * 250) / BPS;
        uint256 expectedSeller = TOKEN_PRICE - expectedFee;
        assertEq(token.balanceOf(feeRecipient), expectedFee, "fee mismatch");
        assertEq(token.balanceOf(seller), expectedSeller, "seller mismatch");
    }

    // D: ERC-20, 2.5%, 5% royalty
    function test_fee_acceptOffer_erc20_250bps_royalty() public {
        uint256 tokenId = _mintNFT(seller, true);
        vm.startPrank(buyer);
        token.approve(address(marketplace), TOKEN_PRICE);
        marketplace.makeOffer(address(royaltyNft), tokenId, address(token), TOKEN_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        vm.startPrank(seller);
        royaltyNft.approve(address(marketplace), tokenId);
        marketplace.acceptOffer(1);
        vm.stopPrank();

        uint256 expectedFee = (TOKEN_PRICE * 250) / BPS;
        uint256 expectedRoyalty = (TOKEN_PRICE * ROYALTY_BPS) / BPS;
        uint256 expectedSeller = TOKEN_PRICE - expectedFee - expectedRoyalty;
        assertEq(token.balanceOf(feeRecipient), expectedFee, "fee mismatch");
        assertEq(token.balanceOf(royaltyReceiver), expectedRoyalty, "royalty mismatch");
        assertEq(token.balanceOf(seller), expectedSeller, "seller mismatch");
    }

    // E: ERC-20, 10% MAX, no royalty
    function test_fee_acceptOffer_erc20_maxFee_noRoyalty() public {
        _setFee(1000);
        uint256 tokenId = _mintNFT(seller, false);
        vm.startPrank(buyer);
        token.approve(address(marketplace), TOKEN_PRICE);
        marketplace.makeOffer(address(nft), tokenId, address(token), TOKEN_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        vm.startPrank(seller);
        nft.approve(address(marketplace), tokenId);
        marketplace.acceptOffer(1);
        vm.stopPrank();

        uint256 expectedFee = (TOKEN_PRICE * 1000) / BPS;
        uint256 expectedSeller = TOKEN_PRICE - expectedFee;
        assertEq(token.balanceOf(feeRecipient), expectedFee, "fee mismatch");
        assertEq(token.balanceOf(seller), expectedSeller, "seller mismatch");
    }

    // F: ERC-20, 0%, no royalty
    function test_fee_acceptOffer_erc20_zeroFee_noRoyalty() public {
        _setFee(0);
        uint256 tokenId = _mintNFT(seller, false);
        vm.startPrank(buyer);
        token.approve(address(marketplace), TOKEN_PRICE);
        marketplace.makeOffer(address(nft), tokenId, address(token), TOKEN_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        vm.startPrank(seller);
        nft.approve(address(marketplace), tokenId);
        marketplace.acceptOffer(1);
        vm.stopPrank();

        assertEq(token.balanceOf(feeRecipient), 0, "fee mismatch");
        assertEq(token.balanceOf(seller), TOKEN_PRICE, "seller mismatch");
    }

    // ══════════════════════════════════════════════════════
    //              3. acceptCollectionOffer()
    // ══════════════════════════════════════════════════════

    // B: ERC-20, 2.5%, no royalty
    function test_fee_acceptCollectionOffer_erc20_250bps_noRoyalty() public {
        uint256 tokenId = _mintNFT(seller, false);
        vm.startPrank(buyer);
        token.approve(address(marketplace), TOKEN_PRICE);
        marketplace.makeCollectionOffer(address(nft), address(token), TOKEN_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        vm.startPrank(seller);
        nft.approve(address(marketplace), tokenId);
        marketplace.acceptCollectionOffer(1, tokenId);
        vm.stopPrank();

        uint256 expectedFee = (TOKEN_PRICE * 250) / BPS;
        uint256 expectedSeller = TOKEN_PRICE - expectedFee;
        assertEq(token.balanceOf(feeRecipient), expectedFee, "fee mismatch");
        assertEq(token.balanceOf(seller), expectedSeller, "seller mismatch");
    }

    // D: ERC-20, 2.5%, 5% royalty
    function test_fee_acceptCollectionOffer_erc20_250bps_royalty() public {
        uint256 tokenId = _mintNFT(seller, true);
        vm.startPrank(buyer);
        token.approve(address(marketplace), TOKEN_PRICE);
        marketplace.makeCollectionOffer(address(royaltyNft), address(token), TOKEN_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        vm.startPrank(seller);
        royaltyNft.approve(address(marketplace), tokenId);
        marketplace.acceptCollectionOffer(1, tokenId);
        vm.stopPrank();

        uint256 expectedFee = (TOKEN_PRICE * 250) / BPS;
        uint256 expectedRoyalty = (TOKEN_PRICE * ROYALTY_BPS) / BPS;
        uint256 expectedSeller = TOKEN_PRICE - expectedFee - expectedRoyalty;
        assertEq(token.balanceOf(feeRecipient), expectedFee, "fee mismatch");
        assertEq(token.balanceOf(royaltyReceiver), expectedRoyalty, "royalty mismatch");
        assertEq(token.balanceOf(seller), expectedSeller, "seller mismatch");
    }

    // E: ERC-20, 10% MAX, no royalty
    function test_fee_acceptCollectionOffer_erc20_maxFee_noRoyalty() public {
        _setFee(1000);
        uint256 tokenId = _mintNFT(seller, false);
        vm.startPrank(buyer);
        token.approve(address(marketplace), TOKEN_PRICE);
        marketplace.makeCollectionOffer(address(nft), address(token), TOKEN_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        vm.startPrank(seller);
        nft.approve(address(marketplace), tokenId);
        marketplace.acceptCollectionOffer(1, tokenId);
        vm.stopPrank();

        uint256 expectedFee = (TOKEN_PRICE * 1000) / BPS;
        uint256 expectedSeller = TOKEN_PRICE - expectedFee;
        assertEq(token.balanceOf(feeRecipient), expectedFee, "fee mismatch");
        assertEq(token.balanceOf(seller), expectedSeller, "seller mismatch");
    }

    // F: ERC-20, 0%, no royalty
    function test_fee_acceptCollectionOffer_erc20_zeroFee_noRoyalty() public {
        _setFee(0);
        uint256 tokenId = _mintNFT(seller, false);
        vm.startPrank(buyer);
        token.approve(address(marketplace), TOKEN_PRICE);
        marketplace.makeCollectionOffer(address(nft), address(token), TOKEN_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        vm.startPrank(seller);
        nft.approve(address(marketplace), tokenId);
        marketplace.acceptCollectionOffer(1, tokenId);
        vm.stopPrank();

        assertEq(token.balanceOf(feeRecipient), 0, "fee mismatch");
        assertEq(token.balanceOf(seller), TOKEN_PRICE, "seller mismatch");
    }

    // ══════════════════════════════════════════════════════
    //           4. settleAuction() — English Auction
    // ══════════════════════════════════════════════════════

    // A: Native, 2.5%, no royalty
    function test_fee_settleAuction_native_250bps_noRoyalty() public {
        uint256 tokenId = _mintNFT(seller, false);
        vm.startPrank(seller);
        nft.approve(address(marketplace), tokenId);
        marketplace.createAuction(address(nft), tokenId, address(0), 1 ether, 0, 0, 0, 1 days);
        vm.stopPrank();

        vm.prank(buyer);
        marketplace.bid{value: PRICE}(1, 0);

        vm.warp(block.timestamp + 2 days);

        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = feeRecipient.balance;

        marketplace.settleAuction(1);

        uint256 expectedFee = (PRICE * 250) / BPS;
        uint256 expectedSeller = PRICE - expectedFee;
        assertEq(feeRecipient.balance - feeBefore, expectedFee, "fee mismatch");
        assertEq(seller.balance - sellerBefore, expectedSeller, "seller mismatch");
    }

    // B: ERC-20, 2.5%, no royalty
    function test_fee_settleAuction_erc20_250bps_noRoyalty() public {
        uint256 tokenId = _mintNFT(seller, false);
        vm.startPrank(seller);
        nft.approve(address(marketplace), tokenId);
        marketplace.createAuction(address(nft), tokenId, address(token), 100e18, 0, 0, 0, 1 days);
        vm.stopPrank();

        vm.startPrank(buyer);
        token.approve(address(marketplace), TOKEN_PRICE);
        marketplace.bid(1, TOKEN_PRICE);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);
        marketplace.settleAuction(1);

        uint256 expectedFee = (TOKEN_PRICE * 250) / BPS;
        uint256 expectedSeller = TOKEN_PRICE - expectedFee;
        assertEq(token.balanceOf(feeRecipient), expectedFee, "fee mismatch");
        assertEq(token.balanceOf(seller), expectedSeller, "seller mismatch");
    }

    // C: Native, 2.5%, 5% royalty
    function test_fee_settleAuction_native_250bps_royalty() public {
        uint256 tokenId = _mintNFT(seller, true);
        vm.startPrank(seller);
        royaltyNft.approve(address(marketplace), tokenId);
        marketplace.createAuction(address(royaltyNft), tokenId, address(0), 1 ether, 0, 0, 0, 1 days);
        vm.stopPrank();

        vm.prank(buyer);
        marketplace.bid{value: PRICE}(1, 0);

        vm.warp(block.timestamp + 2 days);

        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = feeRecipient.balance;
        uint256 royaltyBefore = royaltyReceiver.balance;

        marketplace.settleAuction(1);

        uint256 expectedFee = (PRICE * 250) / BPS;
        uint256 expectedRoyalty = (PRICE * ROYALTY_BPS) / BPS;
        uint256 expectedSeller = PRICE - expectedFee - expectedRoyalty;
        assertEq(feeRecipient.balance - feeBefore, expectedFee, "fee mismatch");
        assertEq(royaltyReceiver.balance - royaltyBefore, expectedRoyalty, "royalty mismatch");
        assertEq(seller.balance - sellerBefore, expectedSeller, "seller mismatch");
    }

    // D: ERC-20, 2.5%, 5% royalty
    function test_fee_settleAuction_erc20_250bps_royalty() public {
        uint256 tokenId = _mintNFT(seller, true);
        vm.startPrank(seller);
        royaltyNft.approve(address(marketplace), tokenId);
        marketplace.createAuction(address(royaltyNft), tokenId, address(token), 100e18, 0, 0, 0, 1 days);
        vm.stopPrank();

        vm.startPrank(buyer);
        token.approve(address(marketplace), TOKEN_PRICE);
        marketplace.bid(1, TOKEN_PRICE);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);
        marketplace.settleAuction(1);

        uint256 expectedFee = (TOKEN_PRICE * 250) / BPS;
        uint256 expectedRoyalty = (TOKEN_PRICE * ROYALTY_BPS) / BPS;
        uint256 expectedSeller = TOKEN_PRICE - expectedFee - expectedRoyalty;
        assertEq(token.balanceOf(feeRecipient), expectedFee, "fee mismatch");
        assertEq(token.balanceOf(royaltyReceiver), expectedRoyalty, "royalty mismatch");
        assertEq(token.balanceOf(seller), expectedSeller, "seller mismatch");
    }

    // E: Native, 10% MAX, no royalty
    function test_fee_settleAuction_native_maxFee_noRoyalty() public {
        _setFee(1000);
        uint256 tokenId = _mintNFT(seller, false);
        vm.startPrank(seller);
        nft.approve(address(marketplace), tokenId);
        marketplace.createAuction(address(nft), tokenId, address(0), 1 ether, 0, 0, 0, 1 days);
        vm.stopPrank();

        vm.prank(buyer);
        marketplace.bid{value: PRICE}(1, 0);

        vm.warp(block.timestamp + 2 days);

        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = feeRecipient.balance;

        marketplace.settleAuction(1);

        uint256 expectedFee = (PRICE * 1000) / BPS;
        uint256 expectedSeller = PRICE - expectedFee;
        assertEq(feeRecipient.balance - feeBefore, expectedFee, "fee mismatch");
        assertEq(seller.balance - sellerBefore, expectedSeller, "seller mismatch");
    }

    // F: Native, 0%, no royalty
    function test_fee_settleAuction_native_zeroFee_noRoyalty() public {
        _setFee(0);
        uint256 tokenId = _mintNFT(seller, false);
        vm.startPrank(seller);
        nft.approve(address(marketplace), tokenId);
        marketplace.createAuction(address(nft), tokenId, address(0), 1 ether, 0, 0, 0, 1 days);
        vm.stopPrank();

        vm.prank(buyer);
        marketplace.bid{value: PRICE}(1, 0);

        vm.warp(block.timestamp + 2 days);

        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = feeRecipient.balance;

        marketplace.settleAuction(1);

        assertEq(feeRecipient.balance - feeBefore, 0, "fee mismatch");
        assertEq(seller.balance - sellerBefore, PRICE, "seller mismatch");
    }

    // ══════════════════════════════════════════════════════
    //         5. buyDutchAuction() — Dutch Auction
    // ══════════════════════════════════════════════════════

    // A: Native, 2.5%, no royalty
    function test_fee_buyDutchAuction_native_250bps_noRoyalty() public {
        uint256 tokenId = _mintNFT(seller, false);
        vm.startPrank(seller);
        nft.approve(address(marketplace), tokenId);
        marketplace.createDutchAuction(address(nft), tokenId, address(0), PRICE, 1 ether, 1 days);
        vm.stopPrank();

        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = feeRecipient.balance;

        vm.prank(buyer);
        marketplace.buyDutchAuction{value: PRICE}(1);

        uint256 expectedFee = (PRICE * 250) / BPS;
        uint256 expectedSeller = PRICE - expectedFee;
        assertEq(feeRecipient.balance - feeBefore, expectedFee, "fee mismatch");
        assertEq(seller.balance - sellerBefore, expectedSeller, "seller mismatch");
    }

    // B: ERC-20, 2.5%, no royalty
    function test_fee_buyDutchAuction_erc20_250bps_noRoyalty() public {
        uint256 tokenId = _mintNFT(seller, false);
        vm.startPrank(seller);
        nft.approve(address(marketplace), tokenId);
        marketplace.createDutchAuction(address(nft), tokenId, address(token), TOKEN_PRICE, 100e18, 1 days);
        vm.stopPrank();

        vm.startPrank(buyer);
        token.approve(address(marketplace), TOKEN_PRICE);
        marketplace.buyDutchAuction(1);
        vm.stopPrank();

        uint256 expectedFee = (TOKEN_PRICE * 250) / BPS;
        uint256 expectedSeller = TOKEN_PRICE - expectedFee;
        assertEq(token.balanceOf(feeRecipient), expectedFee, "fee mismatch");
        assertEq(token.balanceOf(seller), expectedSeller, "seller mismatch");
    }

    // C: Native, 2.5%, 5% royalty
    function test_fee_buyDutchAuction_native_250bps_royalty() public {
        uint256 tokenId = _mintNFT(seller, true);
        vm.startPrank(seller);
        royaltyNft.approve(address(marketplace), tokenId);
        marketplace.createDutchAuction(address(royaltyNft), tokenId, address(0), PRICE, 1 ether, 1 days);
        vm.stopPrank();

        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = feeRecipient.balance;
        uint256 royaltyBefore = royaltyReceiver.balance;

        vm.prank(buyer);
        marketplace.buyDutchAuction{value: PRICE}(1);

        uint256 expectedFee = (PRICE * 250) / BPS;
        uint256 expectedRoyalty = (PRICE * ROYALTY_BPS) / BPS;
        uint256 expectedSeller = PRICE - expectedFee - expectedRoyalty;
        assertEq(feeRecipient.balance - feeBefore, expectedFee, "fee mismatch");
        assertEq(royaltyReceiver.balance - royaltyBefore, expectedRoyalty, "royalty mismatch");
        assertEq(seller.balance - sellerBefore, expectedSeller, "seller mismatch");
    }

    // D: ERC-20, 2.5%, 5% royalty
    function test_fee_buyDutchAuction_erc20_250bps_royalty() public {
        uint256 tokenId = _mintNFT(seller, true);
        vm.startPrank(seller);
        royaltyNft.approve(address(marketplace), tokenId);
        marketplace.createDutchAuction(address(royaltyNft), tokenId, address(token), TOKEN_PRICE, 100e18, 1 days);
        vm.stopPrank();

        vm.startPrank(buyer);
        token.approve(address(marketplace), TOKEN_PRICE);
        marketplace.buyDutchAuction(1);
        vm.stopPrank();

        uint256 expectedFee = (TOKEN_PRICE * 250) / BPS;
        uint256 expectedRoyalty = (TOKEN_PRICE * ROYALTY_BPS) / BPS;
        uint256 expectedSeller = TOKEN_PRICE - expectedFee - expectedRoyalty;
        assertEq(token.balanceOf(feeRecipient), expectedFee, "fee mismatch");
        assertEq(token.balanceOf(royaltyReceiver), expectedRoyalty, "royalty mismatch");
        assertEq(token.balanceOf(seller), expectedSeller, "seller mismatch");
    }

    // E: Native, 10% MAX, no royalty
    function test_fee_buyDutchAuction_native_maxFee_noRoyalty() public {
        _setFee(1000);
        uint256 tokenId = _mintNFT(seller, false);
        vm.startPrank(seller);
        nft.approve(address(marketplace), tokenId);
        marketplace.createDutchAuction(address(nft), tokenId, address(0), PRICE, 1 ether, 1 days);
        vm.stopPrank();

        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = feeRecipient.balance;

        vm.prank(buyer);
        marketplace.buyDutchAuction{value: PRICE}(1);

        uint256 expectedFee = (PRICE * 1000) / BPS;
        uint256 expectedSeller = PRICE - expectedFee;
        assertEq(feeRecipient.balance - feeBefore, expectedFee, "fee mismatch");
        assertEq(seller.balance - sellerBefore, expectedSeller, "seller mismatch");
    }

    // F: Native, 0%, no royalty
    function test_fee_buyDutchAuction_native_zeroFee_noRoyalty() public {
        _setFee(0);
        uint256 tokenId = _mintNFT(seller, false);
        vm.startPrank(seller);
        nft.approve(address(marketplace), tokenId);
        marketplace.createDutchAuction(address(nft), tokenId, address(0), PRICE, 1 ether, 1 days);
        vm.stopPrank();

        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = feeRecipient.balance;

        vm.prank(buyer);
        marketplace.buyDutchAuction{value: PRICE}(1);

        assertEq(feeRecipient.balance - feeBefore, 0, "fee mismatch");
        assertEq(seller.balance - sellerBefore, PRICE, "seller mismatch");
    }

    // ══════════════════════════════════════════════════════
    //            6. buyBundle() — Bundle Listing
    // ══════════════════════════════════════════════════════

    // A: Native, 2.5%, no royalty
    function test_fee_buyBundle_native_250bps_noRoyalty() public {
        uint256 t1 = _mintNFT(seller, false);
        uint256 t2 = _mintNFT(seller, false);
        address[] memory c = new address[](2);
        c[0] = address(nft);
        c[1] = address(nft);
        uint256[] memory ids = new uint256[](2);
        ids[0] = t1;
        ids[1] = t2;

        vm.startPrank(seller);
        nft.setApprovalForAll(address(marketplace), true);
        marketplace.createBundleListing(c, ids, address(0), PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = feeRecipient.balance;

        vm.prank(buyer);
        marketplace.buyBundle{value: PRICE}(1);

        uint256 expectedFee = (PRICE * 250) / BPS;
        uint256 expectedSeller = PRICE - expectedFee;
        assertEq(feeRecipient.balance - feeBefore, expectedFee, "fee mismatch");
        assertEq(seller.balance - sellerBefore, expectedSeller, "seller mismatch");
    }

    // B: ERC-20, 2.5%, no royalty
    function test_fee_buyBundle_erc20_250bps_noRoyalty() public {
        uint256 t1 = _mintNFT(seller, false);
        uint256 t2 = _mintNFT(seller, false);
        address[] memory c = new address[](2);
        c[0] = address(nft);
        c[1] = address(nft);
        uint256[] memory ids = new uint256[](2);
        ids[0] = t1;
        ids[1] = t2;

        vm.startPrank(seller);
        nft.setApprovalForAll(address(marketplace), true);
        marketplace.createBundleListing(c, ids, address(token), TOKEN_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        vm.startPrank(buyer);
        token.approve(address(marketplace), TOKEN_PRICE);
        marketplace.buyBundle(1);
        vm.stopPrank();

        uint256 expectedFee = (TOKEN_PRICE * 250) / BPS;
        uint256 expectedSeller = TOKEN_PRICE - expectedFee;
        assertEq(token.balanceOf(feeRecipient), expectedFee, "fee mismatch");
        assertEq(token.balanceOf(seller), expectedSeller, "seller mismatch");
    }

    // C: Native, 2.5%, 5% royalty (first NFT has royalty)
    function test_fee_buyBundle_native_250bps_royalty() public {
        uint256 t1 = _mintNFT(seller, true); // royaltyNft
        uint256 t2 = _mintNFT(seller, false); // regular nft
        address[] memory c = new address[](2);
        c[0] = address(royaltyNft);
        c[1] = address(nft);
        uint256[] memory ids = new uint256[](2);
        ids[0] = t1;
        ids[1] = t2;

        vm.startPrank(seller);
        royaltyNft.setApprovalForAll(address(marketplace), true);
        nft.setApprovalForAll(address(marketplace), true);
        marketplace.createBundleListing(c, ids, address(0), PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = feeRecipient.balance;
        uint256 royaltyBefore = royaltyReceiver.balance;

        vm.prank(buyer);
        marketplace.buyBundle{value: PRICE}(1);

        uint256 expectedFee = (PRICE * 250) / BPS;
        uint256 expectedRoyalty = (PRICE * ROYALTY_BPS) / BPS;
        uint256 expectedSeller = PRICE - expectedFee - expectedRoyalty;
        assertEq(feeRecipient.balance - feeBefore, expectedFee, "fee mismatch");
        assertEq(royaltyReceiver.balance - royaltyBefore, expectedRoyalty, "royalty mismatch");
        assertEq(seller.balance - sellerBefore, expectedSeller, "seller mismatch");
    }

    // D: ERC-20, 2.5%, 5% royalty
    function test_fee_buyBundle_erc20_250bps_royalty() public {
        uint256 t1 = _mintNFT(seller, true);
        uint256 t2 = _mintNFT(seller, false);
        address[] memory c = new address[](2);
        c[0] = address(royaltyNft);
        c[1] = address(nft);
        uint256[] memory ids = new uint256[](2);
        ids[0] = t1;
        ids[1] = t2;

        vm.startPrank(seller);
        royaltyNft.setApprovalForAll(address(marketplace), true);
        nft.setApprovalForAll(address(marketplace), true);
        marketplace.createBundleListing(c, ids, address(token), TOKEN_PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        vm.startPrank(buyer);
        token.approve(address(marketplace), TOKEN_PRICE);
        marketplace.buyBundle(1);
        vm.stopPrank();

        uint256 expectedFee = (TOKEN_PRICE * 250) / BPS;
        uint256 expectedRoyalty = (TOKEN_PRICE * ROYALTY_BPS) / BPS;
        uint256 expectedSeller = TOKEN_PRICE - expectedFee - expectedRoyalty;
        assertEq(token.balanceOf(feeRecipient), expectedFee, "fee mismatch");
        assertEq(token.balanceOf(royaltyReceiver), expectedRoyalty, "royalty mismatch");
        assertEq(token.balanceOf(seller), expectedSeller, "seller mismatch");
    }

    // E: Native, 10% MAX, no royalty
    function test_fee_buyBundle_native_maxFee_noRoyalty() public {
        _setFee(1000);
        uint256 t1 = _mintNFT(seller, false);
        uint256 t2 = _mintNFT(seller, false);
        address[] memory c = new address[](2);
        c[0] = address(nft);
        c[1] = address(nft);
        uint256[] memory ids = new uint256[](2);
        ids[0] = t1;
        ids[1] = t2;

        vm.startPrank(seller);
        nft.setApprovalForAll(address(marketplace), true);
        marketplace.createBundleListing(c, ids, address(0), PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = feeRecipient.balance;

        vm.prank(buyer);
        marketplace.buyBundle{value: PRICE}(1);

        uint256 expectedFee = (PRICE * 1000) / BPS;
        uint256 expectedSeller = PRICE - expectedFee;
        assertEq(feeRecipient.balance - feeBefore, expectedFee, "fee mismatch");
        assertEq(seller.balance - sellerBefore, expectedSeller, "seller mismatch");
    }

    // F: Native, 0%, no royalty
    function test_fee_buyBundle_native_zeroFee_noRoyalty() public {
        _setFee(0);
        uint256 t1 = _mintNFT(seller, false);
        uint256 t2 = _mintNFT(seller, false);
        address[] memory c = new address[](2);
        c[0] = address(nft);
        c[1] = address(nft);
        uint256[] memory ids = new uint256[](2);
        ids[0] = t1;
        ids[1] = t2;

        vm.startPrank(seller);
        nft.setApprovalForAll(address(marketplace), true);
        marketplace.createBundleListing(c, ids, address(0), PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = feeRecipient.balance;

        vm.prank(buyer);
        marketplace.buyBundle{value: PRICE}(1);

        assertEq(feeRecipient.balance - feeBefore, 0, "fee mismatch");
        assertEq(seller.balance - sellerBefore, PRICE, "seller mismatch");
    }

    // ══════════════════════════════════════════════════════
    //     7. bid() at buyNowPrice → _settleBuyNow()
    // ══════════════════════════════════════════════════════

    // A: Native, 2.5%, no royalty
    function test_fee_buyNow_native_250bps_noRoyalty() public {
        uint256 tokenId = _mintNFT(seller, false);
        vm.startPrank(seller);
        nft.approve(address(marketplace), tokenId);
        marketplace.createAuction(address(nft), tokenId, address(0), 1 ether, 0, PRICE, 0, 1 days);
        vm.stopPrank();

        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = feeRecipient.balance;

        vm.prank(buyer);
        marketplace.bid{value: PRICE}(1, 0);

        uint256 expectedFee = (PRICE * 250) / BPS;
        uint256 expectedSeller = PRICE - expectedFee;
        assertEq(feeRecipient.balance - feeBefore, expectedFee, "fee mismatch");
        assertEq(seller.balance - sellerBefore, expectedSeller, "seller mismatch");
    }

    // B: ERC-20, 2.5%, no royalty
    function test_fee_buyNow_erc20_250bps_noRoyalty() public {
        uint256 tokenId = _mintNFT(seller, false);
        vm.startPrank(seller);
        nft.approve(address(marketplace), tokenId);
        marketplace.createAuction(address(nft), tokenId, address(token), 100e18, 0, TOKEN_PRICE, 0, 1 days);
        vm.stopPrank();

        vm.startPrank(buyer);
        token.approve(address(marketplace), TOKEN_PRICE);
        marketplace.bid(1, TOKEN_PRICE);
        vm.stopPrank();

        uint256 expectedFee = (TOKEN_PRICE * 250) / BPS;
        uint256 expectedSeller = TOKEN_PRICE - expectedFee;
        assertEq(token.balanceOf(feeRecipient), expectedFee, "fee mismatch");
        assertEq(token.balanceOf(seller), expectedSeller, "seller mismatch");
    }

    // C: Native, 2.5%, 5% royalty
    function test_fee_buyNow_native_250bps_royalty() public {
        uint256 tokenId = _mintNFT(seller, true);
        vm.startPrank(seller);
        royaltyNft.approve(address(marketplace), tokenId);
        marketplace.createAuction(address(royaltyNft), tokenId, address(0), 1 ether, 0, PRICE, 0, 1 days);
        vm.stopPrank();

        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = feeRecipient.balance;
        uint256 royaltyBefore = royaltyReceiver.balance;

        vm.prank(buyer);
        marketplace.bid{value: PRICE}(1, 0);

        uint256 expectedFee = (PRICE * 250) / BPS;
        uint256 expectedRoyalty = (PRICE * ROYALTY_BPS) / BPS;
        uint256 expectedSeller = PRICE - expectedFee - expectedRoyalty;
        assertEq(feeRecipient.balance - feeBefore, expectedFee, "fee mismatch");
        assertEq(royaltyReceiver.balance - royaltyBefore, expectedRoyalty, "royalty mismatch");
        assertEq(seller.balance - sellerBefore, expectedSeller, "seller mismatch");
    }

    // D: ERC-20, 2.5%, 5% royalty
    function test_fee_buyNow_erc20_250bps_royalty() public {
        uint256 tokenId = _mintNFT(seller, true);
        vm.startPrank(seller);
        royaltyNft.approve(address(marketplace), tokenId);
        marketplace.createAuction(address(royaltyNft), tokenId, address(token), 100e18, 0, TOKEN_PRICE, 0, 1 days);
        vm.stopPrank();

        vm.startPrank(buyer);
        token.approve(address(marketplace), TOKEN_PRICE);
        marketplace.bid(1, TOKEN_PRICE);
        vm.stopPrank();

        uint256 expectedFee = (TOKEN_PRICE * 250) / BPS;
        uint256 expectedRoyalty = (TOKEN_PRICE * ROYALTY_BPS) / BPS;
        uint256 expectedSeller = TOKEN_PRICE - expectedFee - expectedRoyalty;
        assertEq(token.balanceOf(feeRecipient), expectedFee, "fee mismatch");
        assertEq(token.balanceOf(royaltyReceiver), expectedRoyalty, "royalty mismatch");
        assertEq(token.balanceOf(seller), expectedSeller, "seller mismatch");
    }

    // E: Native, 10% MAX, no royalty
    function test_fee_buyNow_native_maxFee_noRoyalty() public {
        _setFee(1000);
        uint256 tokenId = _mintNFT(seller, false);
        vm.startPrank(seller);
        nft.approve(address(marketplace), tokenId);
        marketplace.createAuction(address(nft), tokenId, address(0), 1 ether, 0, PRICE, 0, 1 days);
        vm.stopPrank();

        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = feeRecipient.balance;

        vm.prank(buyer);
        marketplace.bid{value: PRICE}(1, 0);

        uint256 expectedFee = (PRICE * 1000) / BPS;
        uint256 expectedSeller = PRICE - expectedFee;
        assertEq(feeRecipient.balance - feeBefore, expectedFee, "fee mismatch");
        assertEq(seller.balance - sellerBefore, expectedSeller, "seller mismatch");
    }

    // F: Native, 0%, no royalty
    function test_fee_buyNow_native_zeroFee_noRoyalty() public {
        _setFee(0);
        uint256 tokenId = _mintNFT(seller, false);
        vm.startPrank(seller);
        nft.approve(address(marketplace), tokenId);
        marketplace.createAuction(address(nft), tokenId, address(0), 1 ether, 0, PRICE, 0, 1 days);
        vm.stopPrank();

        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = feeRecipient.balance;

        vm.prank(buyer);
        marketplace.bid{value: PRICE}(1, 0);

        assertEq(feeRecipient.balance - feeBefore, 0, "fee mismatch");
        assertEq(seller.balance - sellerBefore, PRICE, "seller mismatch");
    }

    // ══════════════════════════════════════════════════════
    //            UPGRADEABLE-SPECIFIC TESTS
    // ══════════════════════════════════════════════════════

    function test_proxy_initialized_correctly() public view {
        assertEq(marketplace.feeRecipient(), feeRecipient);
        assertEq(marketplace.platformFeeBps(), 250);
        assertTrue(marketplace.hasRole(marketplace.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(marketplace.hasRole(marketplace.PAUSER_ROLE(), owner));
        assertTrue(marketplace.hasRole(marketplace.FEE_MANAGER_ROLE(), owner));
        assertTrue(marketplace.hasRole(marketplace.TOKEN_MANAGER_ROLE(), owner));
    }

    function test_cannot_reinitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        marketplace.initialize(owner, feeRecipient, 250);
    }

    function test_implementation_cannot_initialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(owner, feeRecipient, 250);
    }

    function test_upgrade_revert_not_admin() public {
        MoltMarketplace newImpl = new MoltMarketplace();
        vm.startPrank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, buyer, marketplace.DEFAULT_ADMIN_ROLE())
        );
        marketplace.upgradeToAndCall(address(newImpl), "");
        vm.stopPrank();
    }

    function test_admin_can_upgrade() public {
        MoltMarketplace newImpl = new MoltMarketplace();
        vm.prank(owner);
        marketplace.upgradeToAndCall(address(newImpl), "");
        // Marketplace still functional after upgrade
        assertEq(marketplace.platformFeeBps(), 250);
    }

    function test_state_persists_through_upgrade() public {
        // Create a listing before upgrade
        uint256 tokenId = _mintNFT(seller, false);
        vm.startPrank(seller);
        nft.approve(address(marketplace), tokenId);
        marketplace.list(address(nft), tokenId, address(0), PRICE, block.timestamp + 1 days);
        vm.stopPrank();

        // Upgrade
        MoltMarketplace newImpl = new MoltMarketplace();
        vm.prank(owner);
        marketplace.upgradeToAndCall(address(newImpl), "");

        // Listing still exists
        IMoltMarketplace.Listing memory listing = marketplace.getListing(1);
        assertEq(listing.seller, seller);
        assertEq(listing.price, PRICE);
        assertEq(uint8(listing.status), uint8(IMoltMarketplace.ListingStatus.Active));

        // Can still buy the listing
        vm.prank(buyer);
        marketplace.buy{value: PRICE}(1);
        assertEq(nft.ownerOf(tokenId), buyer);
    }

    function test_counters_continue_after_upgrade() public {
        // Create listing #1
        uint256 t1 = _mintNFT(seller, false);
        vm.startPrank(seller);
        nft.approve(address(marketplace), t1);
        uint256 id1 = marketplace.list(address(nft), t1, address(0), PRICE, block.timestamp + 1 days);
        vm.stopPrank();
        assertEq(id1, 1);

        // Upgrade
        MoltMarketplace newImpl = new MoltMarketplace();
        vm.prank(owner);
        marketplace.upgradeToAndCall(address(newImpl), "");

        // Create listing #2 — counter should continue
        uint256 t2 = _mintNFT(seller, false);
        vm.startPrank(seller);
        nft.approve(address(marketplace), t2);
        uint256 id2 = marketplace.list(address(nft), t2, address(0), PRICE, block.timestamp + 1 days);
        vm.stopPrank();
        assertEq(id2, 2);
    }
}
