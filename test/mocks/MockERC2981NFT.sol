// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract MockERC2981NFT {
    string public name;
    string public symbol;

    address public royaltyReceiver;
    uint256 public royaltyBps;

    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    constructor(string memory name_, string memory symbol_, address royaltyReceiver_, uint256 royaltyBps_) {
        name = name_;
        symbol = symbol_;
        royaltyReceiver = royaltyReceiver_;
        royaltyBps = royaltyBps_;
    }

    // ── ERC-2981 ──

    function royaltyInfo(uint256, uint256 salePrice) external view returns (address, uint256) {
        uint256 royaltyAmount = (salePrice * royaltyBps) / 10_000;
        return (royaltyReceiver, royaltyAmount);
    }

    // ── ERC-721 ──

    function balanceOf(address owner_) external view returns (uint256) {
        return _balances[owner_];
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner_ = _owners[tokenId];
        require(owner_ != address(0), "ERC721: nonexistent token");
        return owner_;
    }

    function approve(address to, uint256 tokenId) external {
        address owner_ = _owners[tokenId];
        require(msg.sender == owner_ || _operatorApprovals[owner_][msg.sender], "Not authorized");
        _tokenApprovals[tokenId] = to;
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        return _tokenApprovals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
    }

    function isApprovedForAll(address owner_, address operator) external view returns (bool) {
        return _operatorApprovals[owner_][operator];
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        address owner_ = _owners[tokenId];
        require(owner_ == from, "Not owner");
        require(
            msg.sender == owner_ || _tokenApprovals[tokenId] == msg.sender || _operatorApprovals[owner_][msg.sender],
            "Not authorized"
        );

        delete _tokenApprovals[tokenId];
        _balances[from]--;
        _balances[to]++;
        _owners[tokenId] = to;
    }

    function mint(address to, uint256 tokenId) external {
        require(_owners[tokenId] == address(0), "Already minted");
        _balances[to]++;
        _owners[tokenId] = to;
    }

    // ── ERC-165 ──

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x80ac58cd // ERC721
            || interfaceId == 0x2a55205a // ERC2981
            || interfaceId == 0x01ffc9a7; // ERC165
    }
}
