// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Measures the appearance of a card from its reveal seed. Must match `measure()` in art/build_v6.py byte for byte.
///  d1 = sha256(seed), d2 = sha256(seed ‖ 0x01)
///  part i (0 eyes, 1 horn, 2 ears, 3 face, 4 muzzle, 5 upper mane, 6 lower mane, 7 swirl):
///    shape  = pick(SHAPE, d1[4i .. 4i+2]),  phase = pick(eyes ? EYE : PHASE, d1[4i+2 .. 4i+4])
///  ground = pick(GROUND, d2[0 .. 2])
///  packed: bits 7i .. 7i+2 shape, 7i+3 .. 7i+6 phase; bits 56 .. 57 ground
library Appearance {
    function measure(bytes32 seed) internal pure returns (uint64 look) {
        bytes32 d1 = sha256(abi.encodePacked(seed));
        bytes32 d2 = sha256(abi.encodePacked(seed, bytes1(0x01)));
        uint256 w = uint256(d1);
        for (uint256 i; i < 8; ++i) {
            uint256 chunk = (w >> (224 - 32 * i)) & 0xffffffff;
            uint256 shape = _pickShape(chunk >> 16);
            uint256 phase = i == 0 ? _pickEye(chunk & 0xffff) : _pickPhase(chunk & 0xffff);
            look |= uint64((shape | (phase << 3)) << (7 * i));
        }
        look |= uint64(_pickGround(uint256(d2) >> 240) << 56);
    }

    /// @notice The eight 32-bit part details of a reveal seed (art v7 micro-variation): sha256(seed ‖ 0x02),
    ///         part 0 in the top 32 bits. Same as `details_of` in art/render_onchain.py.
    function details(bytes32 seed) internal pure returns (uint256) {
        return uint256(sha256(abi.encodePacked(seed, bytes1(0x02))));
    }

    /// @dev Keep the detail lanes of the parts in `mask` from `a`, the others from `b`: a detail travels with its part.
    function mergeDetails(uint256 a, uint256 b, uint8 maskA) internal pure returns (uint256 out) {
        for (uint256 i; i < 8; ++i) {
            uint256 lane = uint256(0xffffffff) << (224 - 32 * i);
            out |= (maskA >> i) & 1 == 1 ? a & lane : b & lane;
        }
    }

    function shapeOf(uint64 look, uint256 part) internal pure returns (uint256) {
        return (look >> (7 * part)) & 7;
    }

    function phaseOf(uint64 look, uint256 part) internal pure returns (uint256) {
        return (look >> (7 * part + 3)) & 15;
    }

    function groundOf(uint64 look) internal pure returns (uint256) {
        return (look >> 56) & 3;
    }

    /// @dev Keep the 7 appearance bits of every part in `mask` from `a`, the others from `b`; the ground from `a`.
    function merge(uint64 a, uint64 b, uint8 maskA) internal pure returns (uint64 out) {
        for (uint256 i; i < 8; ++i) {
            uint64 bits = uint64(0x7f) << uint64(7 * i);
            out |= (maskA >> i) & 1 == 1 ? a & bits : b & bits;
        }
        out |= a & (uint64(3) << 56);
    }

    // weights: shape 28 20 15 12 10 8 5 2 · phase 24 20 12 12 9 8 7 4 3 1 · eye 34 20 14 12 8 6 5 1 · ground 80 14 6

    function _pickShape(uint256 r) private pure returns (uint256) {
        uint256 t = r % 100;
        if (t < 28) return 0;
        if (t < 48) return 1;
        if (t < 63) return 2;
        if (t < 75) return 3;
        if (t < 85) return 4;
        if (t < 93) return 5;
        if (t < 98) return 6;
        return 7;
    }

    function _pickPhase(uint256 r) private pure returns (uint256) {
        uint256 t = r % 100;
        if (t < 24) return 0;
        if (t < 44) return 1;
        if (t < 56) return 2;
        if (t < 68) return 3;
        if (t < 77) return 4;
        if (t < 85) return 5;
        if (t < 92) return 6;
        if (t < 96) return 7;
        if (t < 99) return 8;
        return 9;
    }

    function _pickEye(uint256 r) private pure returns (uint256) {
        uint256 t = r % 100;
        if (t < 34) return 0;
        if (t < 54) return 1;
        if (t < 68) return 2;
        if (t < 80) return 3;
        if (t < 88) return 4;
        if (t < 94) return 5;
        if (t < 99) return 6;
        return 7;
    }

    function _pickGround(uint256 r) private pure returns (uint256) {
        uint256 t = r % 100;
        if (t < 80) return 0;
        if (t < 94) return 1;
        return 2;
    }
}
