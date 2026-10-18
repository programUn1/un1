// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IUN1TokenForMirror {
    function idCount(address account) external view returns (uint256);
    function ownerOfId(uint256 id) external view returns (address);
    function mirrorTransfer(address from, address to, uint256 id) external;
    function cardOf(uint256 id) external view returns (address owner, uint8 mask, uint8 layers, uint64 look);
    function commitmentOf(uint256 id) external view returns (bytes32);
    function detailsOf(uint256 id) external view returns (uint256);
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external returns (bytes4);
}

interface IUN1Renderer {
    function render(uint256 id, uint8 mask, uint8 layers, uint64 look, uint256 details, bytes32 commitment)
        external
        view
        returns (bytes memory image, bytes memory uri);
}

/// @title UN1Mirror
/// @notice ERC721 view of the cards held in UN1Token (DN404 style): the token is the source of truth, the mirror emits
///  the events and keeps NFT approvals. Moving a card here moves exactly one token with it. Deployed before the launch as
///  public infrastructure (CREATE2 proxy), bound to the token's predicted address; the token checks the binding in its
///  initializer.
contract UN1Mirror {
    address public immutable token;
    address public immutable renderer;

    mapping(uint256 id => address) public getApproved;
    mapping(address owner => mapping(address operator => bool)) public isApprovedForAll;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event MetadataUpdate(uint256 tokenId); // ERC-4906

    error NotToken();
    error NotAuthorized();
    error NonexistentToken();
    error ZeroAddress();
    error UnsafeRecipient();

    constructor(address token_, address renderer_) {
        token = token_;
        renderer = renderer_;
    }

    // ================= ERC721 =================

    function name() external pure returns (string memory) {
        return "Un1corn";
    }

    function symbol() external pure returns (string memory) {
        return "UN1";
    }

    function tokenURI(uint256 id) external view returns (string memory) {
        (address owner, uint8 mask, uint8 layers, uint64 look) = IUN1TokenForMirror(token).cardOf(id);
        if (owner == address(0)) revert NonexistentToken();
        if (renderer == address(0)) return "";
        return string(_render(id, mask, layers, look));
    }

    function _render(uint256 id, uint8 mask, uint8 layers, uint64 look) private view returns (bytes memory uri) {
        IUN1TokenForMirror t = IUN1TokenForMirror(token);
        uint256 details = t.detailsOf(id);
        bytes32 commitment = t.commitmentOf(id);
        (, uri) = IUN1Renderer(renderer).render(id, mask, layers, look, details, commitment);
    }

    function balanceOf(address owner) external view returns (uint256) {
        if (owner == address(0)) revert ZeroAddress();
        return IUN1TokenForMirror(token).idCount(owner);
    }

    function ownerOf(uint256 id) public view returns (address owner) {
        owner = IUN1TokenForMirror(token).ownerOfId(id);
        if (owner == address(0)) revert NonexistentToken();
    }

    function approve(address spender, uint256 id) external {
        address owner = ownerOf(id);
        if (msg.sender != owner && !isApprovedForAll[owner][msg.sender]) revert NotAuthorized();
        getApproved[id] = spender;
        emit Approval(owner, spender, id);
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 id) public {
        if (to == address(0)) revert ZeroAddress();
        if (ownerOf(id) != from) revert NotAuthorized();
        if (msg.sender != from && !isApprovedForAll[from][msg.sender] && getApproved[id] != msg.sender) revert NotAuthorized();
        IUN1TokenForMirror(token).mirrorTransfer(from, to, id);
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        safeTransferFrom(from, to, id, "");
    }

    /// @dev State is fully updated before the receiver callback (audit E-2).
    function safeTransferFrom(address from, address to, uint256 id, bytes memory data) public {
        transferFrom(from, to, id);
        if (to.code.length != 0) {
            if (IERC721Receiver(to).onERC721Received(msg.sender, from, id, data) != IERC721Receiver.onERC721Received.selector) {
                revert UnsafeRecipient();
            }
        }
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 // ERC165
            || interfaceId == 0x80ac58cd // ERC721
            || interfaceId == 0x5b5e139f // ERC721Metadata
            || interfaceId == 0x49064906; // ERC4906
    }

    // ================= token hooks =================

    function logTransfer(address from, address to, uint256 id) external {
        if (msg.sender != token) revert NotToken();
        delete getApproved[id];
        emit Transfer(from, to, id);
    }

    function logMetadataUpdate(uint256 id) external {
        if (msg.sender != token) revert NotToken();
        emit MetadataUpdate(id);
    }
}
