// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UN1Renderer} from "../src/UN1Renderer.sol";
import {UN1Mirror} from "../src/UN1Mirror.sol";
import {Base} from "./utils/Base.sol";

/// @notice On-chain rendering (art v7): SVG and tokenURI match the reference renderer byte for byte (art/exports/fixtures.json);
///  its polish rules were compared with the prototype cell by cell.
///  The renders are also written to preview/onchain/ to open in a browser.
contract RenderTest is Base {
    function setUp() public override {
        super.setUp();
        _skipOpening();
    }

    function test_fixtures_matchPythonByteForByte() public {
        string memory json = vm.readFile("../art/exports/fixtures.json");
        uint256 count = vm.parseJsonUint(json, ".count");
        for (uint256 i; i < count; ++i) _fixture(json, string.concat(".cases[", vm.toString(i), "]"), i < 6);
    }

    function _fixture(string memory json, string memory p, bool keep) internal {
        (bytes memory image, bytes memory uri) = renderer.render(
            vm.parseJsonUint(json, string.concat(p, ".id")),
            uint8(vm.parseJsonUint(json, string.concat(p, ".mask"))),
            uint8(vm.parseJsonUint(json, string.concat(p, ".layers"))),
            uint64(vm.parseJsonUint(json, string.concat(p, ".look"))),
            uint256(vm.parseJsonBytes32(json, string.concat(p, ".details"))),
            vm.parseJsonBytes32(json, string.concat(p, ".commitment"))
        );
        string memory tag = vm.parseJsonString(json, string.concat(p, ".tag"));
        if (keep) vm.writeFile(string.concat("../preview/onchain/", tag, ".svg"), string(image));
        assertEq(sha256(image), vm.parseJsonBytes32(json, string.concat(p, ".svgHash")), string.concat(tag, ": svg"));
        assertEq(sha256(uri), vm.parseJsonBytes32(json, string.concat(p, ".uriHash")), string.concat(tag, ": tokenURI"));
    }

    function test_badParts_rejected() public {
        address d = _deployMasks(new bytes(16_384));
        vm.expectRevert(UN1Renderer.BadParts.selector);
        new UN1Renderer(d);
    }

    function test_tokenURI_ofARealCard_throughTheMirror() public {
        _buy(alice, 1 ether);
        _revealAll("render");
        uint256 id = token.idsOf(alice)[0];
        uint256 g = gasleft();
        string memory uri = mirror.tokenURI(id);
        emit log_named_uint("tokenURI gas (eth_call)", g - gasleft());
        assertEq(_prefix(bytes(uri), 29), "data:application/json;base64,");
        (, uint8 mask, uint8 layers, uint64 look) = token.cardOf(id);
        (, bytes memory expected) = renderer.render(id, mask, layers, look, token.detailsOf(id), token.commitmentOf(id));
        assertTrue(token.detailsOf(id) != 0, "details measured with the look");
        assertEq(keccak256(bytes(uri)), keccak256(expected));
    }

    function test_tokenURI_revertsForPoolAndRetiredIds() public {
        vm.expectRevert(UN1Mirror.NonexistentToken.selector);
        mirror.tokenURI(1); // still in superposition
    }

    function test_render_worstCaseGas() public {
        // 1 owned part: almost every cell is a commitment character
        uint256 g = gasleft();
        renderer.render(1, 0x08, 1, 0, type(uint256).max, bytes32(uint256(1)));
        emit log_named_uint("render, 1 part (most text)", g - gasleft());
        // Level V, every part rainbow: one rect per cell
        uint64 rainbow;
        for (uint256 i; i < 8; ++i) rainbow |= uint64((i == 0 ? 7 : 9) << 3) << uint64(7 * i);
        g = gasleft();
        renderer.render(5099, 0xff, 8, rainbow, uint256(keccak256("details")), bytes32(uint256(2)));
        emit log_named_uint("render, Level V all rainbow (most rects)", g - gasleft());
    }

    function _prefix(bytes memory s, uint256 n) internal pure returns (string memory) {
        bytes memory out = new bytes(n);
        for (uint256 i; i < n; ++i) out[i] = s[i];
        return string(out);
    }
}
