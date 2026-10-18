// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Buf} from "./libraries/Buf.sol";
import {Polish} from "./libraries/Polish.sol";

/// @title UN1Renderer
/// @notice Fully on-chain SVG and metadata, art v7. Byte-for-byte the same as art/render_onchain.py (tested on fixtures).
///  32×32 cells of 10 units. Parts are drawn in priority order from 64 bitmaps (data contract `parts`, 256 bytes per
///  variant: 32 rows of all cells, then 32 rows of accent cells; bit 31 of a row is x = 0). An owned part's bitmap is
///  polished with its 32-bit detail (libraries/Polish.sol) and filled with its measured colours; the other parts keep
///  their plain shape and are written, faded, with the hex characters of the card's provenance commitment.
///  Stateless and independent of the token, so it is deployed before the launch as public infrastructure (the launch
///  transaction must stay under the EIP-7825 gas cap); the mirror reads the card and calls `render`.
contract UN1Renderer {
    using Buf for Buf.B;
    using Strings for uint256;

    bytes32 public constant PARTS_SHA256 = 0x803964e797696b1abdaec6e3ef62729f9b593fdb4436af33d99517e7204fccb5;
    uint256 private constant N = 32;
    uint256 private constant FULL = 0xffffffff;

    address public immutable parts;

    error BadParts();

    constructor(address parts_) {
        parts = parts_;
        if (parts_.code.length != 1 + 512 * 33 || _partsHash(parts_) != PARTS_SHA256) revert BadParts();
    }

    // ================= entry points =================

    /// @notice Render any card state (used by tokenURI, the website and the tests).
    function render(uint256 id, uint8 mask, uint8 layers, uint64 look, uint256 details, bytes32 commitment)
        public
        view
        returns (bytes memory image, bytes memory uri)
    {
        image = svg(id, mask, look, details, commitment);
        Buf.B memory j = Buf.init(image.length * 4 / 3 + 4096);
        j.add('{"name":"UN1 #');
        j.adds(_pad4(id));
        j.add('","description":"Fragment of Bitcoin block ');
        j.adds(_thousands(id - 1));
        j.add(". ");
        j.adds(_popcount(mask).toString());
        j.add(' of 8 qubits measured. Composition adds a layer of SHA-256.","image":"data:image/svg+xml;base64,');
        j.adds(Base64.encode(image));
        j.add('","attributes":[');
        _attributes(j, id, mask, layers, look);
        j.add("]}");
        uri = abi.encodePacked("data:application/json;base64,", Base64.encode(j.done()));
    }

    // ================= SVG =================

    struct Layout {
        uint256[N] occ;
        uint256[N] owned;
        uint256[N][8] cells;
        uint256[N][8] accs;
        uint256[N] t3; // the eyes' recognition cell (tone 3)
    }

    function svg(uint256 id, uint8 mask, uint64 look, uint256 details, bytes32 commitment) public view returns (bytes memory) {
        Layout memory l = _layout(mask, look, details);
        uint256 g = (look >> 56) & 3;
        Buf.B memory b = Buf.init(100_000);
        b.add('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 320" shape-rendering="crispEdges">');
        b.add('<rect width="320" height="320" fill="');
        b.add(_groundColor(g, 0));
        b.add('"/>');
        _outline(b, l, _groundColor(g, 1));
        _owned(b, l, look);
        _unowned(b, l, commitment, _groundColor(g, 2));
        _idBlock(b, id, mask, g);
        b.add("</svg>");
        return b.done();
    }

    /// @dev Priority: eyes, horn, ears, muzzle, swirl, face, upper mane, lower mane (part indices 0 1 2 4 7 3 5 6).
    function _layout(uint8 mask, uint64 look, uint256 details) private view returns (Layout memory l) {
        uint256 order = 0x01020407030506; // one byte per part index, first to last
        for (uint256 k; k < 8; ++k) {
            uint256 i = (order >> (8 * (7 - k))) & 0xff;
            bool has = (mask >> i) & 1 == 1;
            uint256 shape = has ? (look >> (7 * i)) & 7 : 0;
            bytes memory d = _variant(i, shape);
            Polish.Part memory p;
            for (uint256 y; y < N; ++y) (p.cells[y], p.acc[y]) = (_row(d, y), _row(d, N + y));
            if (has) Polish.polish(i, shape, p, (details >> (224 - 32 * i)) & FULL);
            for (uint256 y; y < N; ++y) {
                uint256 c = p.cells[y] & ~l.occ[y] & FULL;
                l.occ[y] |= c;
                l.cells[i][y] = c;
                l.accs[i][y] = p.acc[y] & c;
                if (has) l.owned[y] |= c;
                if (i == 0) l.t3[y] = p.t3[y] & c;
            }
        }
    }

    function _ring(uint256[N] memory r, uint256 y) private pure returns (uint256 n) {
        n = ((r[y] << 1) | (r[y] >> 1)) & FULL;
        if (y > 0) n |= r[y - 1];
        if (y < N - 1) n |= r[y + 1];
    }

    /// @dev Outline cells next to an owned part in full; cells next only to parts not owned at 40%.
    function _outline(Buf.B memory b, Layout memory l, bytes memory edge) private pure {
        uint256[N] memory ghost;
        bool anyGhost;
        for (uint256 y; y < N; ++y) {
            uint256 nearOwned = _ring(l.owned, y);
            _runs(b, nearOwned & ~l.occ[y] & FULL, y, edge);
            ghost[y] = _ring(l.occ, y) & ~nearOwned & ~l.occ[y] & FULL;
            if (ghost[y] != 0) anyGhost = true;
        }
        if (!anyGhost) return;
        b.add('<g opacity="0.4">');
        for (uint256 y; y < N; ++y) _runs(b, ghost[y], y, edge);
        b.add("</g>");
    }

    /// @dev Owned cells row by row, consecutive cells of the same colour merged into one rect.
    function _owned(Buf.B memory b, Layout memory l, uint64 look) private pure {
        for (uint256 y; y < N; ++y) {
            uint256 row = l.owned[y];
            uint256 x;
            while (x < N) {
                if ((row >> (31 - x)) & 1 == 0) {
                    ++x;
                    continue;
                }
                uint256 key = _colorKey(l, look, x, y);
                uint256 s = x;
                ++x;
                while (x < N && (row >> (31 - x)) & 1 == 1 && _colorKey(l, look, x, y) == key) ++x;
                _rect(b, s * 10, y * 10, (x - s) * 10, 10, _fill(key));
            }
        }
    }

    /// @dev One number per distinct fill: 24-bit colours below 2^24; rainbow cells (never equal to a neighbour) above.
    function _colorKey(Layout memory l, uint64 look, uint256 x, uint256 y) private pure returns (uint256) {
        uint256 bit = uint256(1) << (31 - x);
        uint256 i;
        while (l.cells[i][y] & bit == 0) ++i;
        uint256 ph = (look >> (7 * i + 3)) & 15;
        // the recognition cell belongs to the eye phase: white on Ink eyes, ink on every other phase
        if (i == 0 && l.t3[y] & bit != 0) return ph == 0 ? 0xffffff : 0x111111;
        uint256 tone = l.accs[i][y] & bit != 0 ? 2 : 1;
        if (_isRainbow(i, ph)) return (1 << 32) | (((x * 9 + y * 6) % 360) << 8) | tone;
        return _phaseRgb(i, ph, tone);
    }

    function _fill(uint256 key) private pure returns (bytes memory) {
        if (key >> 32 == 0) return _hex24(key);
        return abi.encodePacked("hsl(", ((key >> 8) & 0xffff).toString(), ",95%,", key & 0xff == 2 ? "74" : "60", "%)");
    }

    function _unowned(Buf.B memory b, Layout memory l, bytes32 commitment, bytes memory fill) private pure {
        b.add('<g font-family="monospace" font-size="9.5" text-anchor="middle" fill="');
        b.add(fill);
        b.add('" opacity="0.68">');
        uint256 k;
        for (uint256 y; y < N; ++y) {
            uint256 row = l.occ[y] & ~l.owned[y] & FULL;
            if (row == 0) continue;
            b.add('<text x="');
            bool first = true;
            for (uint256 x; x < N; ++x) {
                if ((row >> (31 - x)) & 1 == 0) continue;
                if (!first) b.add(" ");
                first = false;
                b.adds((x * 10 + 5).toString());
            }
            b.add('" y="');
            b.adds((y * 10 + 8).toString());
            b.add('.2">');
            for (uint256 x; x < N; ++x) {
                if ((row >> (31 - x)) & 1 == 0) continue;
                b.addByte(_hexChar(commitment, k % 64));
                ++k;
            }
            b.add("</text>");
        }
        b.add("</g>");
    }

    /// @dev Bottom-left: the id in a 3×5 pixel font, then 8 qubit dots (filled = part owned). No fonts involved.
    function _idBlock(Buf.B memory b, uint256 id, uint8 mask, uint256 g) private pure {
        bytes memory ink = _ink(g);
        bytes memory digits = bytes(_pad4(id));
        for (uint256 d; d < digits.length; ++d) {
            uint256 glyph = _glyph(uint8(digits[d]) - 48);
            for (uint256 k; k < 15; ++k) {
                if ((glyph >> (14 - k)) & 1 == 0) continue;
                _rect(b, 10 + (d * 4 + k % 3) * 4, 270 + (k / 3) * 4, 4, 4, ink);
            }
        }
        bytes memory dim = _groundColor(g, 2);
        for (uint256 i; i < 8; ++i) {
            if ((mask >> i) & 1 == 1) {
                _rect(b, 10 + i * 12, 298, 8, 8, ink);
            } else {
                b.add('<rect x="');
                b.adds((10 + i * 12).toString());
                b.add('" y="298" width="8" height="8" fill="');
                b.add(dim);
                b.add('" opacity="0.68"/>');
            }
        }
    }

    // ================= drawing helpers =================

    function _runs(Buf.B memory b, uint256 row, uint256 y, bytes memory fill) private pure {
        uint256 x;
        while (x < N) {
            if ((row >> (31 - x)) & 1 == 0) {
                ++x;
                continue;
            }
            uint256 s = x;
            while (x < N && (row >> (31 - x)) & 1 == 1) ++x;
            _rect(b, s * 10, y * 10, (x - s) * 10, 10, fill);
        }
    }

    function _rect(Buf.B memory b, uint256 x, uint256 y, uint256 w, uint256 h, bytes memory fill) private pure {
        b.add('<rect x="');
        b.adds(x.toString());
        b.add('" y="');
        b.adds(y.toString());
        b.add('" width="');
        b.adds(w.toString());
        b.add('" height="');
        b.adds(h.toString());
        b.add('" fill="');
        b.add(fill);
        b.add('"/>');
    }

    // ================= metadata =================

    function _attributes(Buf.B memory j, uint256 id, uint8 mask, uint8 layers, uint64 look) private pure {
        for (uint256 i; i < 8; ++i) {
            if ((mask >> i) & 1 == 0) continue;
            uint256 sh = (look >> (7 * i)) & 7;
            uint256 ph = (look >> (7 * i + 3)) & 15;
            j.add('{"trait_type":"');
            j.adds(_label(i));
            j.add('","value":"');
            j.adds(_shapeName(i, sh));
            j.add('"},{"trait_type":"');
            j.adds(_label(i));
            j.add(' Phase","value":"');
            j.adds(_phaseName(i, ph));
            j.add('"},');
        }
        uint256 g = (look >> 56) & 3;
        uint256 n = _popcount(mask);
        j.add('{"trait_type":"Ground","value":"');
        j.add(bytes(g == 0 ? "Paper" : g == 1 ? "Night" : "Satoshi"));
        j.add('"},{"trait_type":"Qubits","value":');
        j.adds(n.toString());
        j.add(',"display_type":"number","max_value":8},{"trait_type":"Level","value":"');
        j.add(bytes(mask == 0xff ? "V" : "-"));
        j.add('"},{"trait_type":"State","value":"');
        j.add(bytes(layers > 1 ? "Entangled" : "Measured"));
        j.add('"},{"trait_type":"Layers","value":');
        j.adds(uint256(layers).toString());
        j.add(',"display_type":"number"},{"trait_type":"Weight","value":');
        uint256 w = n * (10_000 + 200 * (uint256(layers) - 1) + (mask == 0xff ? 500 : 0));
        j.add(abi.encodePacked((w / 10_000).toString(), ".", _two((w % 10_000) / 100)));
        j.add(',"display_type":"number"},{"trait_type":"Rarity Score","value":');
        uint256 r = _rarity(mask, look);
        j.add(abi.encodePacked((r / 100).toString(), ".", ((r % 100) / 10).toString()));
        j.add(',"display_type":"number"},{"trait_type":"Bitcoin Block","value":');
        j.adds((id - 1).toString());
        j.add(',"display_type":"number"}');
    }

    /// @dev Sum of -log2(probability) in hundredths: ground plus shape and phase of every owned part.
    function _rarity(uint8 mask, uint64 look) private pure returns (uint256 s) {
        s = _pick16(0x0020011c0196, (look >> 56) & 3, 3);
        for (uint256 i; i < 8; ++i) {
            if ((mask >> i) & 1 == 0) continue;
            s += _pick16(0x00b800e801120132014c016c01b00234, (look >> (7 * i)) & 7, 8);
            uint256 ph = (look >> (7 * i + 3)) & 15;
            s += i == 0
                ? _pick16(0x009c00e8011c0132016c019601b00298, ph, 8)
                : _pick16(0x0000ce00e801320132015b016c018001d001fa0298, ph, 10);
        }
    }

    /// @dev k-th of n big-endian 16-bit values packed in `table`.
    function _pick16(uint256 table, uint256 k, uint256 n) private pure returns (uint256) {
        return (table >> (16 * (n - 1 - k))) & 0xffff;
    }

    function _label(uint256 i) private pure returns (string memory) {
        if (i == 0) return "Eyes";
        if (i == 1) return "Horn";
        if (i == 2) return "Ears";
        if (i == 3) return "Face";
        if (i == 4) return "Muzzle";
        if (i == 5) return "Upper Mane";
        if (i == 6) return "Lower Mane";
        return "Swirl";
    }

    function _shapeName(uint256 i, uint256 s) private pure returns (string memory) {
        string[8] memory n;
        if (i == 0) n = ["Round", "Calm", "Almond", "Lash", "Wide", "Sleepy", "Star", "Laser"];
        else if (i == 1) n = ["Ringed", "Plain", "Short", "Long", "Curved", "Spiral", "Twin", "Crystal"];
        else if (i == 2) n = ["Pointed", "Tall", "Short", "Swept", "Round", "Notched", "Tufted", "Twin"];
        else if (i == 3) n = ["Plain", "Blush", "Blaze", "Freckles", "Star", "Striped", "Moon", "Circuit"];
        else if (i == 4) n = ["Calm", "Smile", "Open", "Snort", "Freckles", "Tongue", "Ring", "Breath"];
        else if (i == 5) n = ["Wave", "Spiky", "Bare", "Full", "Curly", "Feather", "Flame", "Aurora"];
        else if (i == 6) n = ["Wave", "Spiky", "Long", "Short", "Braid", "Ribbon", "Full", "Comet"];
        else n = ["Curl", "Double", "Tight", "Ring", "Wave", "Knot", "Orbit", "Galaxy"];
        return n[s];
    }

    function _phaseName(uint256 i, uint256 ph) private pure returns (string memory) {
        if (i == 0) {
            string[8] memory e = ["Ink", "Magenta", "Violet", "Cyan", "Mint", "Gold", "Satoshi", "Rainbow"];
            return e[ph];
        }
        string[10] memory p = ["White", "Pink", "Lilac", "Silver", "Cyan", "Mint", "Violet", "Gold", "Satoshi", "Rainbow"];
        return p[ph];
    }

    // ================= colours =================

    function _isRainbow(uint256 i, uint256 ph) private pure returns (bool) {
        return i == 0 ? ph == 7 : ph == 9;
    }

    /// @dev tone 1 = main, 2 = accent. 6 hex digits each, packed.
    function _phaseRgb(uint256 i, uint256 ph, uint256 tone) private pure returns (uint256 c) {
        if (i == 0) {
            c = tone == 1
                ? _pick24(0x111111ff2fa68a4dff16c5e01fcf86e8a900f7931a, ph, 7)
                : _pick24(0xffffffffffffffffffffffffffffffffffffffe0b8, ph, 7);
        } else {
            c = tone == 1
                ? _pick24(0xffffffff2fa6b9a2ffb8c0d02fe6ff3df2a68a4dffffc531f7931a, ph, 9)
                : _pick24(0xd9d4ffff9ad4e4daffeef1f6c4f9ffc7fbe3c9aefffff0b3ffd199, ph, 9);
        }
    }

    /// @dev 0 bg, 1 edge, 2 hash. Paper / Night / Satoshi.
    function _groundColor(uint256 g, uint256 role) private pure returns (bytes memory) {
        uint256 c;
        if (g == 0) c = role == 0 ? 0xf2f0eb : role == 1 ? 0x111111 : 0xb5ae9f;
        else if (g == 1) c = role == 0 ? 0x071538 : role == 1 ? 0x2e3f8f : 0x4d6fc4;
        else c = role == 0 ? 0x111111 : role == 1 ? 0xf7931a : 0x7a4300;
        return _hex24(c);
    }

    function _ink(uint256 g) private pure returns (bytes memory) {
        return _hex24(g == 0 ? 0x111111 : g == 1 ? 0x8fa6e0 : 0xf7931a);
    }

    function _pick24(uint256 table, uint256 k, uint256 n) private pure returns (uint256) {
        return (table >> (24 * (n - 1 - k))) & 0xffffff;
    }

    function _hex24(uint256 c) private pure returns (bytes memory s) {
        s = new bytes(7);
        s[0] = "#";
        for (uint256 i; i < 6; ++i) s[1 + i] = _nibble((c >> (4 * (5 - i))) & 15);
    }

    // ================= small helpers =================

    /// @dev 256 logical bytes = 8 PUSH32 chunks of UN1PartsData (logical byte i at 2 + (i / 32) * 33 + (i % 32)).
    function _variant(uint256 part, uint256 shape) private view returns (bytes memory d) {
        d = new bytes(256);
        address p = parts;
        uint256 firstChunk = (part * 8 + shape) * 8;
        assembly ("memory-safe") {
            for { let j := 0 } lt(j, 8) { j := add(j, 1) } {
                extcodecopy(p, add(add(d, 0x20), mul(j, 32)), add(2, mul(add(firstChunk, j), 33)), 32)
            }
        }
    }

    function _row(bytes memory d, uint256 r) private pure returns (uint256 v) {
        assembly ("memory-safe") {
            v := shr(224, mload(add(add(d, 0x20), mul(r, 4))))
        }
    }

    function _partsHash(address p) private view returns (bytes32) {
        bytes memory d = new bytes(16_384);
        assembly ("memory-safe") {
            for { let j := 0 } lt(j, 512) { j := add(j, 1) } {
                extcodecopy(p, add(add(d, 0x20), mul(j, 32)), add(2, mul(j, 33)), 32)
            }
        }
        return sha256(d);
    }

    /// @dev 3×5 glyphs, row-major, MSB first.
    function _glyph(uint256 digit) private pure returns (uint256) {
        uint256[10] memory g =
            [uint256(0x7b6f), 0x2c97, 0x73e7, 0x73cf, 0x5bc9, 0x79cf, 0x79ef, 0x7292, 0x7bef, 0x7bcf];
        return g[digit];
    }

    function _hexChar(bytes32 h, uint256 k) private pure returns (uint8) {
        uint256 v = (uint256(h) >> (4 * (63 - k))) & 15;
        return uint8(_nibble(v));
    }

    function _nibble(uint256 v) private pure returns (bytes1) {
        return bytes1(uint8(v < 10 ? 48 + v : 87 + v));
    }

    function _pad4(uint256 id) private pure returns (string memory) {
        if (id >= 1000) return id.toString();
        if (id >= 100) return string.concat("0", id.toString());
        if (id >= 10) return string.concat("00", id.toString());
        return string.concat("000", id.toString());
    }

    function _thousands(uint256 n) private pure returns (string memory) {
        if (n < 1000) return n.toString();
        return string.concat((n / 1000).toString(), ",", _three(n % 1000));
    }

    function _three(uint256 n) private pure returns (string memory) {
        if (n >= 100) return n.toString();
        if (n >= 10) return string.concat("0", n.toString());
        return string.concat("00", n.toString());
    }

    function _two(uint256 n) private pure returns (string memory) {
        return n >= 10 ? n.toString() : string.concat("0", n.toString());
    }

    function _popcount(uint8 m) private pure returns (uint256 c) {
        for (; m != 0; m &= m - 1) ++c;
    }
}
