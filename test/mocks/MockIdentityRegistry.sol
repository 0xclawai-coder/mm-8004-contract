// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title MockIdentityRegistry — Simulates ERC-8004 IdentityRegistry for testing.
/// @dev Reproduces the key behaviors:
///   - ERC-721 compliance (mint via register, transferFrom, approve, etc.)
///   - register() auto-increments agentId, sets agentWallet, emits Registered + MetadataSet
///   - On transfer: clears agentWallet and emits MetadataSet before the Transfer event
contract MockIdentityRegistry {
    string public name = "AgentIdentity";
    string public symbol = "AGENT";

    uint256 private _lastId;

    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;
    mapping(uint256 => string) private _tokenURIs;
    mapping(uint256 => mapping(string => bytes)) private _metadata;

    // ──── ERC-8004 Events ────
    event Registered(uint256 indexed agentId, string agentURI, address indexed owner);
    event MetadataSet(uint256 indexed agentId, string indexed indexedMetadataKey, string metadataKey, bytes metadataValue);
    event URIUpdated(uint256 indexed agentId, string newURI, address indexed updatedBy);

    // ──── ERC-721 Events ────
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    // ══════════════════════════════════════════════════════
    //                  ERC-8004: REGISTER
    // ══════════════════════════════════════════════════════

    /// @notice Register a new agent (mint an 8004 NFT).
    function register(string memory agentURI) external returns (uint256 agentId) {
        agentId = _lastId++;
        _mint(msg.sender, agentId);
        _tokenURIs[agentId] = agentURI;

        // Auto-set agentWallet to caller
        bytes memory walletBytes = abi.encodePacked(msg.sender);
        _metadata[agentId]["agentWallet"] = walletBytes;

        emit Registered(agentId, agentURI, msg.sender);
        emit MetadataSet(agentId, "agentWallet", "agentWallet", walletBytes);
    }

    /// @notice Register without URI.
    function register() external returns (uint256 agentId) {
        agentId = _lastId++;
        _mint(msg.sender, agentId);

        bytes memory walletBytes = abi.encodePacked(msg.sender);
        _metadata[agentId]["agentWallet"] = walletBytes;

        emit Registered(agentId, "", msg.sender);
        emit MetadataSet(agentId, "agentWallet", "agentWallet", walletBytes);
    }

    // ══════════════════════════════════════════════════════
    //                  ERC-8004: METADATA
    // ══════════════════════════════════════════════════════

    function getAgentWallet(uint256 agentId) external view returns (address) {
        bytes memory data = _metadata[agentId]["agentWallet"];
        if (data.length == 0) return address(0);
        return address(bytes20(data));
    }

    function getMetadata(uint256 agentId, string memory key) external view returns (bytes memory) {
        return _metadata[agentId][key];
    }

    // ══════════════════════════════════════════════════════
    //                     ERC-721
    // ══════════════════════════════════════════════════════

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
        emit Approval(owner_, to, tokenId);
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        return _tokenApprovals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address owner_, address operator) external view returns (bool) {
        return _operatorApprovals[owner_][operator];
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        _transfer(from, to, tokenId);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x80ac58cd  // ERC721
            || interfaceId == 0x01ffc9a7; // ERC165
    }

    // ══════════════════════════════════════════════════════
    //                    INTERNAL
    // ══════════════════════════════════════════════════════

    function _mint(address to, uint256 tokenId) internal {
        require(_owners[tokenId] == address(0), "Already minted");
        _balances[to]++;
        _owners[tokenId] = to;
        emit Transfer(address(0), to, tokenId);
    }

    /// @dev Mimics IdentityRegistryUpgradeable._update():
    ///   - Clears agentWallet + emits MetadataSet BEFORE Transfer event.
    function _transfer(address from, address to, uint256 tokenId) internal {
        address owner_ = _owners[tokenId];
        require(owner_ == from, "Not owner");
        require(
            msg.sender == owner_
                || _tokenApprovals[tokenId] == msg.sender
                || _operatorApprovals[owner_][msg.sender],
            "Not authorized"
        );

        // ── ERC-8004 _update behavior: clear agentWallet on transfer ──
        _metadata[tokenId]["agentWallet"] = "";
        emit MetadataSet(tokenId, "agentWallet", "agentWallet", "");

        // ── Standard ERC-721 transfer ──
        delete _tokenApprovals[tokenId];
        _balances[from]--;
        _balances[to]++;
        _owners[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }
}
