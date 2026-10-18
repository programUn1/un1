// SPDX-License-Identifier: MIT
// Source: Temo (https://temo.family/), DrandBeacon.sol, verified on Etherscan; copied unchanged below the pragma
// (refs/programmable/custom-launches/Temo/src/model/src/libraries/DrandBeacon.sol).
pragma solidity 0.8.26;

/// @notice Verifies drand "quicknet" beacons (scheme bls-unchained-g1-rfc9380) with the EIP-2537 precompiles.
///   - message   = sha256(round as 8-byte big-endian)
///   - signature = BLS on G1, public key on G2
///   - check     = e(H(m), pk) * e(sig, -G2) == 1
/// Signatures are passed uncompressed (x || y, 64-byte padded field elements each): the pairing precompile
/// rejects points that are not on the curve or not in the subgroup, so no decompression is needed on-chain.
library DrandBeacon {
    // precompiles (Prague)
    address private constant BLS_G1ADD = address(0x0b);
    address private constant BLS_PAIRING = address(0x0f);
    address private constant BLS_MAP_FP_TO_G1 = address(0x10);
    address private constant MODEXP = address(0x05);

    uint256 internal constant GENESIS = 1692803367;
    uint256 internal constant PERIOD = 3;

    // Constants are 32-byte words (PUSH32 immediates), never raw data in the code: a linear disassembly must not
    // mistake key or modulus bytes for opcodes.
    uint256 private constant DST_LEN = 43;
    bytes32 private constant DST0 = 0x424c535f5349475f424c53313233383147315f584d443a5348412d3235365f53;
    bytes32 private constant DST1 = 0x5357555f524f5f4e554c5f000000000000000000000000000000000000000000; // 11 bytes, zero-padded

    // drand quicknet public key (G2, 256 bytes uncompressed, EIP-2537 encoding)
    bytes32 private constant PK0 = 0x000000000000000000000000000000000d1fec758c921cc22b0e17e63aaf4bcb;
    bytes32 private constant PK1 = 0x5ed66304de9cf809bd274ca73bab4af5a6e9c76a4bc09e76eae8991ef5ece45a;
    bytes32 private constant PK2 = 0x0000000000000000000000000000000003cf0f2896adee7eb8b5f01fcad39122;
    bytes32 private constant PK3 = 0x12c437e0073e911fb90022d3e760183c8c4b450b6a0a6c3ac6a5776a2d106451;
    bytes32 private constant PK4 = 0x000000000000000000000000000000000e5db2b6bfbb01c867749cadffca88b3;
    bytes32 private constant PK5 = 0x6c24f3012ba09fc4d3022c5c37dce0f977d3adb5d183c7477c442b1f04515273;
    bytes32 private constant PK6 = 0x0000000000000000000000000000000001a714f2edb74119a2f2b0d5a7c75ba9;
    bytes32 private constant PK7 = 0x02d163700a61bc224ededd8e63aef7be1aaf8e93d7a9718b047ccddb3eb5d68b;

    // -G2 generator (256 bytes, EIP-2537 encoding)
    bytes32 private constant NG0 = 0x00000000000000000000000000000000024aa2b2f08f0a91260805272dc51051;
    bytes32 private constant NG1 = 0xc6e47ad4fa403b02b4510b647ae3d1770bac0326a805bbefd48056c8c121bdb8;
    bytes32 private constant NG2 = 0x0000000000000000000000000000000013e02b6052719f607dacd3a088274f65;
    bytes32 private constant NG3 = 0x596bd0d09920b61ab5da61bbdc7f5049334cf11213945d57e5ac7d055d042b7e;
    bytes32 private constant NG4 = 0x000000000000000000000000000000000d1b3cc2c7027888be51d9ef691d77bc;
    bytes32 private constant NG5 = 0xb679afda66c73f17f9ee3837a55024f78c71363275a75d75d86bab79f74782aa;
    bytes32 private constant NG6 = 0x0000000000000000000000000000000013fa4d4a0ad8b1ce186ed5061789213d;
    bytes32 private constant NG7 = 0x993923066dddaf1040bc3ff59f825c78df74f2d75467e25e0f55f8a00fa030ed;

    // BLS12-381 base field modulus p, 48 bytes
    bytes32 private constant FP0 = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f624;
    bytes32 private constant FP1 = 0x1eabfffeb153ffffb9feffffffffaaab00000000000000000000000000000000; // 16 bytes, zero-padded


    error BadSignatureLength();
    error PrecompileFailed();

    /// @notice First round whose time is >= `timestamp`.
    function roundAt(uint256 timestamp) internal pure returns (uint64) {
        if (timestamp <= GENESIS) return 1;
        return uint64((timestamp - GENESIS + PERIOD - 1) / PERIOD + 1);
    }

    function roundTime(uint64 round) internal pure returns (uint256) {
        return GENESIS + (uint256(round) - 1) * PERIOD;
    }

    function _pk() private pure returns (bytes memory) {
        return abi.encodePacked(PK0, PK1, PK2, PK3, PK4, PK5, PK6, PK7);
    }

    function _negG2() private pure returns (bytes memory) {
        return abi.encodePacked(NG0, NG1, NG2, NG3, NG4, NG5, NG6, NG7);
    }

    function _fieldP() private pure returns (bytes memory out) {
        out = abi.encodePacked(FP0, bytes16(FP1));
    }

    function _dst() private pure returns (bytes memory out) {
        out = abi.encodePacked(DST0, bytes11(DST1));
    }


    /// @notice True iff `sig` (128 bytes: x || y) is the quicknet signature of `round`.
    function verify(uint64 round, bytes memory sig) internal view returns (bool ok) {
        if (sig.length != 128) revert BadSignatureLength();
        bytes memory h = hashToG1(abi.encodePacked(sha256(abi.encodePacked(round))));
        bytes memory input = bytes.concat(h, _pk(), sig, _negG2());
        (bool success, bytes memory out) = BLS_PAIRING.staticcall(input);
        if (!success || out.length != 32) return false;
        ok = abi.decode(out, (uint256)) == 1;
    }

    /// @notice Randomness derived from a verified signature (unique per round: BLS signatures are deterministic).
    function randomness(bytes memory sig) internal pure returns (bytes32) {
        return keccak256(sig);
    }

    // ---------------- hash-to-curve, RFC 9380 BLS12381G1_XMD:SHA-256_SSWU_RO_ ----------------

    function hashToG1(bytes memory message) internal view returns (bytes memory point) {
        bytes memory uniform = expandMessageXmd(message, 128);
        bytes memory u0 = reduce(slice(uniform, 0, 64));
        bytes memory u1 = reduce(slice(uniform, 64, 64));
        bytes memory q0 = mapToG1(u0);
        bytes memory q1 = mapToG1(u1);
        (bool success, bytes memory out) = BLS_G1ADD.staticcall(bytes.concat(q0, q1));
        if (!success || out.length != 128) revert PrecompileFailed();
        point = out;
    }

    function expandMessageXmd(bytes memory message, uint256 lenInBytes) internal pure returns (bytes memory out) {
        uint256 ell = (lenInBytes + 31) / 32;
        bytes memory dstPrime = bytes.concat(_dst(), bytes1(uint8(DST_LEN)));
        bytes32 b0 = sha256(bytes.concat(new bytes(64), message, bytes2(uint16(lenInBytes)), bytes1(0), dstPrime));
        bytes32 bi = sha256(bytes.concat(b0, bytes1(uint8(1)), dstPrime));
        out = abi.encodePacked(bi);
        for (uint256 i = 2; i <= ell; ++i) {
            bi = sha256(bytes.concat(b0 ^ bi, bytes1(uint8(i)), dstPrime));
            out = bytes.concat(out, bi);
        }
        assembly ("memory-safe") {
            mstore(out, lenInBytes)
        }
    }

    /// @dev 64-byte big-endian integer mod p, returned as a 64-byte padded field element.
    function reduce(bytes memory x) internal view returns (bytes memory fe) {
        bytes memory input = bytes.concat(
            abi.encode(uint256(64)), abi.encode(uint256(1)), abi.encode(uint256(48)), x, bytes1(0x01), _fieldP()
        );
        (bool success, bytes memory out) = MODEXP.staticcall(input);
        if (!success || out.length != 48) revert PrecompileFailed();
        fe = bytes.concat(new bytes(16), out);
    }

    function mapToG1(bytes memory fe) internal view returns (bytes memory point) {
        (bool success, bytes memory out) = BLS_MAP_FP_TO_G1.staticcall(fe);
        if (!success || out.length != 128) revert PrecompileFailed();
        point = out;
    }

    function slice(bytes memory data, uint256 start, uint256 len) private pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i = 0; i < len; ++i) {
            out[i] = data[start + i];
        }
    }
}
