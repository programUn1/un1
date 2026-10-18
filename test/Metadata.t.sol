// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Base} from "./utils/Base.sol";

/// @dev FoundationTokenV1's launch tuple (Programmable's own coins, Etherscan-verified source), in its field order.
struct FoundationMetadata {
    string name;
    string symbol;
    string description;
    string imageURI;
    string website;
    bytes socialData;
}

interface IFoundationToken {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function metadata() external view returns (string memory, string memory, string memory, bytes memory);
    function metadataHash() external view returns (bytes32);
}

/// @notice The coin metadata (2026-10-18, chosen by the project owner): Programmable's FoundationTokenV1 layout, so the
///  website and indexers that read Programmable's coins read UN1's the same way.
contract MetadataTest is Base {
    string constant DESCRIPTION = "A UN1corn, piece by piece.";
    string constant WEBSITE = "https://un1.art/";
    string constant IMAGE = "ipfs://bafkreieulpcs7d7rqzf537rcphmgzgcgmbrf3dkuuxqvfn2gfkmpxg2rou";
    bytes constant EXTRA = '{"v":1,"x":"https://x.com/UN1hook"}';

    function test_metadata_values() public view {
        assertEq(token.name(), "Un1corn");
        assertEq(token.symbol(), "UN1");
        (string memory d, string memory w, string memory i, bytes memory x) = token.metadata();
        assertEq(d, DESCRIPTION);
        assertEq(w, WEBSITE);
        assertEq(i, IMAGE);
        assertEq(x, EXTRA);
        assertEq(token.description(), DESCRIPTION);
        assertEq(token.website(), WEBSITE);
        assertEq(token.image(), IMAGE);
        assertEq(token.extraData(), EXTRA);
        assertEq(mirror.name(), "Un1corn", "the collection has the coin's name");
        assertEq(mirror.symbol(), "UN1");
    }

    function test_metadataHash_isTheFoundationEncoding() public view {
        bytes32 expected = keccak256(abi.encode(FoundationMetadata("Un1corn", "UN1", DESCRIPTION, IMAGE, WEBSITE, EXTRA)));
        assertEq(token.metadataHash(), expected);
    }
}

/// @notice The layout checked against a live FoundationTokenV1 (read only): its metadataHash() is keccak256 of the
///  ABI-encoded tuple rebuilt from its own getters, exactly as UN1Token computes its own.
contract MetadataForkTest is Test {
    IFoundationToken constant FOUNDATION_COIN = IFoundationToken(0xC28dDfE06f25fE597ec755e5427DDAFC307e0148);

    function test_fork_foundationLayout_matchesTheLiveCoin() public {
        string memory url = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(url).length == 0) vm.skip(true);
        vm.createSelectFork(url);
        (string memory d, string memory w, string memory i, bytes memory x) = FOUNDATION_COIN.metadata();
        bytes32 rebuilt = keccak256(abi.encode(FoundationMetadata(FOUNDATION_COIN.name(), FOUNDATION_COIN.symbol(), d, i, w, x)));
        assertEq(FOUNDATION_COIN.metadataHash(), rebuilt, "same tuple, same order, same encoding");
    }
}
