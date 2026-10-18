// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Dealing order for one pending slot: a pseudo-random permutation of the ids 1..10,000 keyed by the slot's
///  seed (4-round Feistel on 14 bits, cycle-walked into range). The slot takes the first id along its own order that is
///  still in the pool. Every id in the pool is equally likely, and holding or releasing other ids cannot steer it
///  (audit R-2).
library Deal {
    uint256 internal constant N = 10_000;

    function permute(uint256 x, bytes32 key) internal pure returns (uint256) {
        uint256 l = x >> 7;
        uint256 r = x & 0x7f;
        for (uint256 i; i < 4; ++i) {
            uint256 f;
            assembly ("memory-safe") {
                mstore(0x00, key)
                mstore(0x20, or(shl(8, r), i))
                f := and(keccak256(0x00, 0x40), 0x7f)
            }
            (l, r) = (r, l ^ f);
        }
        return (l << 7) | r;
    }

    /// @return The k-th id (1-based) in the order keyed by `key`.
    function at(uint256 k, bytes32 key) internal pure returns (uint256) {
        uint256 x = permute(k, key);
        while (x >= N) x = permute(x, key);
        return x + 1;
    }
}
