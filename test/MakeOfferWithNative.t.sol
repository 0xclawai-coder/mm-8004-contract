// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MoltMarketplace} from "../src/MoltMarketplace.sol";
import {MoltMarketplaceProxy} from "../src/MoltMarketplaceProxy.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Minimal WMON mock (WETH9 style)
contract MockWMON {
    string public name = "Wrapped MON";
    string public symbol = "WMON";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
        emit Transfer(address(0), msg.sender, msg.value);
    }

    function withdraw(uint256 wad) external {
        require(balanceOf[msg.sender] >= wad, "Insufficient balance");
        balanceOf[msg.sender] -= wad;
        payable(msg.sender).transfer(wad);
        emit Transfer(msg.sender, address(0), wad);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

// Minimal ERC721 mock
contract MockNFT {
    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function mint(address to, uint256 tokenId) external {
        ownerOf[tokenId] = to;
        balanceOf[to]++;
    }

    function approve(address to, uint256 tokenId) external {
        getApproved[tokenId] = to;
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "Not owner");
        require(
            msg.sender == from || getApproved[tokenId] == msg.sender || isApprovedForAll[from][msg.sender],
            "Not approved"
        );
        ownerOf[tokenId] = to;
        balanceOf[from]--;
        balanceOf[to]++;
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

contract MakeOfferWithNativeTest is Test {
    MoltMarketplace marketplace;
    MockWMON wmon;
    MockNFT nft;

    address admin = address(0xAD);
    address seller = address(0xBE);
    address buyer = address(0xCA);

    function setUp() public {
        // Deploy WMON mock
        wmon = new MockWMON();

        // Deploy marketplace via proxy
        vm.startPrank(admin);
        MoltMarketplace impl = new MoltMarketplace();
        bytes memory initData = abi.encodeCall(
            MoltMarketplace.initialize,
            (admin, admin, 500) // 5% fee
        );
        MoltMarketplaceProxy proxy = new MoltMarketplaceProxy(address(impl), initData);
        marketplace = MoltMarketplace(payable(address(proxy)));

        // Configure WMON
        marketplace.setWmonAddress(address(wmon));
        marketplace.addPaymentToken(address(wmon));
        vm.stopPrank();

        // Deploy NFT + mint to seller
        nft = new MockNFT();
        nft.mint(seller, 1);

        // Fund buyer
        vm.deal(buyer, 100 ether);
    }

    function test_makeOfferWithNative() public {
        uint256 offerAmount = 5 ether;
        uint256 expiry = block.timestamp + 1 days;

        // Buyer makes offer with native MON
        vm.prank(buyer);
        uint256 offerId = marketplace.makeOfferWithNative{value: offerAmount}(
            address(nft), 1, expiry
        );

        // Check offer stored correctly
        MoltMarketplace.Offer memory offer = marketplace.getOffer(offerId);
        assertEq(offer.offerer, buyer);
        assertEq(offer.nftContract, address(nft));
        assertEq(offer.tokenId, 1);
        assertEq(offer.paymentToken, address(wmon));
        assertEq(offer.amount, offerAmount);
        assertEq(uint256(offer.status), 0); // Active

        // WMON should be held by marketplace (escrowed)
        assertEq(wmon.balanceOf(address(marketplace)), offerAmount);
    }

    function test_acceptEscrowedOffer() public {
        uint256 offerAmount = 10 ether;
        uint256 expiry = block.timestamp + 1 days;

        // Buyer makes native offer
        vm.prank(buyer);
        uint256 offerId = marketplace.makeOfferWithNative{value: offerAmount}(
            address(nft), 1, expiry
        );

        // Seller accepts offer
        vm.startPrank(seller);
        nft.setApprovalForAll(address(marketplace), true);
        marketplace.acceptOffer(offerId);
        vm.stopPrank();

        // NFT transferred to buyer
        assertEq(nft.ownerOf(1), buyer);

        // Seller should receive WMON (minus platform fee)
        // 10 ETH - 5% fee = 9.5 ETH to seller
        uint256 sellerBalance = wmon.balanceOf(seller);
        assertEq(sellerBalance, 9.5 ether);
    }

    function test_cancelEscrowedOffer_refunds() public {
        uint256 offerAmount = 5 ether;
        uint256 expiry = block.timestamp + 1 days;

        vm.prank(buyer);
        uint256 offerId = marketplace.makeOfferWithNative{value: offerAmount}(
            address(nft), 1, expiry
        );

        // WMON held by marketplace
        assertEq(wmon.balanceOf(address(marketplace)), offerAmount);

        // Buyer cancels — should get WMON back
        vm.prank(buyer);
        marketplace.cancelOffer(offerId);

        assertEq(wmon.balanceOf(buyer), offerAmount);
        assertEq(wmon.balanceOf(address(marketplace)), 0);
    }

    function test_revert_makeOfferWithNative_noWmon() public {
        // Unset WMON
        vm.prank(admin);
        marketplace.setWmonAddress(address(0xdead)); // set to non-zero but no payment token

        vm.prank(admin);
        marketplace.removePaymentToken(address(wmon));

        vm.prank(buyer);
        vm.expectRevert("WMON not allowed as payment");
        marketplace.makeOfferWithNative{value: 1 ether}(address(nft), 1, block.timestamp + 1 days);
    }

    function test_revert_makeOfferWithNative_zeroValue() public {
        vm.prank(buyer);
        vm.expectRevert("Amount must be > 0");
        marketplace.makeOfferWithNative{value: 0}(address(nft), 1, block.timestamp + 1 days);
    }

    // Test upgrade path
    function test_upgradePreservesState() public {
        // Make an offer first
        vm.prank(buyer);
        uint256 offerId = marketplace.makeOfferWithNative{value: 3 ether}(
            address(nft), 1, block.timestamp + 1 days
        );

        // Upgrade to new implementation
        MoltMarketplace newImpl = new MoltMarketplace();
        vm.prank(admin);
        marketplace.upgradeToAndCall(address(newImpl), "");

        // State should be preserved
        MoltMarketplace.Offer memory offer = marketplace.getOffer(offerId);
        assertEq(offer.offerer, buyer);
        assertEq(offer.amount, 3 ether);
        assertEq(marketplace.wmonAddress(), address(wmon));
    }
}
