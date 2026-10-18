// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Deal} from "../src/libraries/Deal.sol";
import {DrandRound} from "../src/libraries/DrandRound.sol";

/// @notice Properties of the algorithms themselves, independent of the token logic.
contract AlgorithmsTest is Test {
    /// @dev The dealing order is a permutation of 1..10,000 for any key: 10,000 steps, every id exactly once. So a slot
    ///      always finds an id while the pool is not empty (and pool ≥ pending slots ≥ 1 when one is revealed).
    /// forge-config: default.fuzz.runs = 16
    function testFuzz_deal_isAPermutationOfAllIds(bytes32 key) public pure {
        uint256[40] memory seen;
        for (uint256 k; k < 10_000; ++k) {
            uint256 i = Deal.at(k, key) - 1;
            assertLt(i, 10_000);
            assertEq((seen[i >> 8] >> (i & 255)) & 1, 0, "each id once");
            seen[i >> 8] |= 1 << (i & 255);
        }
    }

    /// @dev Cost of the walk: the expected number of steps is about 10,000 / (ids in the pool). Logged for 07-AUDIT G-1.
    function test_deal_walkGas() public {
        bytes32 key = keccak256("walk");
        uint256 g = gasleft();
        for (uint256 k; k < 10_000; ++k) Deal.at(k, key);
        console.log("10,000 steps of Deal.at (no pool check):", g - gasleft());
    }

    /// @dev A slot's round is published 15 to 44 seconds after the buy, and every target is a bucket boundary.
    function testFuzz_drandTarget_15to44SecondsLater(uint40 t) public pure {
        vm.assume(t > DrandRound.GENESIS);
        uint64 r = DrandRound.target(t);
        uint256 at = DrandRound.roundTime(r);
        assertEq(r % DrandRound.BUCKET, 0);
        assertGe(at, uint256(t) + 15, "never known when the block is built");
        assertLe(at, uint256(t) + 44);
        assertGe(DrandRound.target(uint256(t) + 1), r, "targets never go back in time");
    }
}
