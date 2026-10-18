// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice drand quicknet round arithmetic (same constants as Temo's DrandBeacon).
library DrandRound {
    uint256 internal constant GENESIS = 1692803367;
    uint256 internal constant PERIOD = 3;
    uint256 internal constant DELAY = 15; // > one 12 s slot: no builder has seen the round when it seals the block
    uint256 internal constant BUCKET = 10; // rounds per batch: one signature reveals every slot of a 30 s bucket

    /// @notice First round whose time is >= `timestamp`.
    function roundAt(uint256 timestamp) internal pure returns (uint64) {
        if (timestamp <= GENESIS) return 1;
        return uint64((timestamp - GENESIS + PERIOD - 1) / PERIOD + 1);
    }

    function roundTime(uint64 round) internal pure returns (uint256) {
        return GENESIS + (uint256(round) - 1) * PERIOD;
    }

    /// @notice Target round for a slot opened at `timestamp`: at least DELAY seconds later, rounded up to the bucket.
    function target(uint256 timestamp) internal pure returns (uint64) {
        uint256 r = roundAt(timestamp + DELAY);
        return uint64((r + BUCKET - 1) / BUCKET * BUCKET);
    }
}
