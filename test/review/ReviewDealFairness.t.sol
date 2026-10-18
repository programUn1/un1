// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "../utils/Base.sol";
import {Deal} from "../../src/libraries/Deal.sol";

/// @notice Review R-06 (docs/reviews/gpt-review.md), same bitmap fixture as FindingsTest._poolOnly. The reproduction
///         asserted the gap-weighted bias. After R4-01, a slot that misses its MAX_WALK prefix selects the lowest
///         fixed per-id hash score. IDs 1 and 2 remain equally likely, and adding ids cannot reorder them.
contract ReviewDealFairnessTest is Base {
    uint256 private constant TAKEN_SLOT = 16;
    uint256 private constant POOL_COUNT_SLOT = 56;

    function test_Review_fallbackDrawsUniformlyAmongTheIdsLeft() public {
        _skipOpening();
        _buy(alice, 1 ether);
        (, uint64 round,) = token.slotOf(0);

        // Exactly IDs 1 and 2 are available. All other bits are occupied.
        for (uint256 w; w < 40; ++w) {
            uint256 word = w == 0 ? type(uint256).max ^ uint256(3) : type(uint256).max;
            vm.store(address(token), bytes32(TAKEN_SLOT + w), bytes32(word));
        }
        vm.store(address(token), bytes32(POOL_COUNT_SLOT), bytes32(uint256(2)));

        uint256 snapshot = vm.snapshotState();
        uint256 fallbackSamples;
        uint256 fallbackIdOne;
        uint256 allIdOne;
        uint256 samples = 128;
        for (uint256 trial; trial < samples; ++trial) {
            assertTrue(vm.revertToState(snapshot));
            bytes32 randomness = keccak256(abi.encode("un1-review-fairness", trial));
            bytes32 seed = keccak256(abi.encodePacked(randomness, uint256(0)));
            bool fallbackUsed = true;
            for (uint256 k; k < token.MAX_WALK(); ++k) {
                if (Deal.at(k, seed) <= 2) {
                    fallbackUsed = false;
                    break;
                }
            }
            assertEq(_fulfill(round, randomness, 1), 1);
            uint256 id = token.idsOf(alice)[0];
            assertTrue(id == 1 || id == 2);
            if (id == 1) ++allIdOne;
            if (fallbackUsed) {
                ++fallbackSamples;
                bytes32 orderSeed = keccak256(abi.encodePacked(seed, "un1.pool-order"));
                uint256 first = uint256(keccak256(abi.encode(orderSeed, uint256(1))));
                uint256 second = uint256(keccak256(abi.encode(orderSeed, uint256(2))));
                assertEq(id, first <= second ? 1 : 2, "the same fixed order for every pool containing these ids");
                if (id == 1) ++fallbackIdOne;
            }
        }
        emit log_named_uint("samples", samples);
        emit log_named_uint("all selections of ID 1", allIdOne);
        emit log_named_uint("fallback samples", fallbackSamples);
        emit log_named_uint("fallback selections of ID 1", fallbackIdOne);
        // deterministic sample: within four standard deviations of half (64 +- 22)
        assertGt(fallbackSamples, 64);
        assertGt(allIdOne, 41);
        assertLt(allIdOne, 87);
        // Also check the fallback population itself, not only its mixture with prefix hits.
        uint256 deviation = fallbackIdOne * 2 > fallbackSamples
            ? fallbackIdOne * 2 - fallbackSamples : fallbackSamples - fallbackIdOne * 2;
        assertLt(deviation * deviation, 16 * fallbackSamples, "fallback within four standard deviations");
    }
}
