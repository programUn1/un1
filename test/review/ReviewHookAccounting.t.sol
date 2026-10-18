// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "../utils/Base.sol";

/// @notice Review R-04 (docs/reviews/gpt-review.md). The reproduction asserted the bug; after the fix (2026-10-15) the
///         reserve counts the UNI the beacon already holds.
contract ReviewHookAccountingTest is Base {
    function test_review_collectingForTheBeacon_doesNotRaiseTheReserve() public {
        _skipOpening();
        modifyLiquidityRouter.modifyLiquidity(officialKey, _range(20_000 ether), ZERO_BYTES);

        for (uint256 i; i < 30; ++i) {
            vm.roll(block.number + 1);
            _swap(officialKey, true, -500 ether);
            _swap(officialKey, false, int256(450 ether));
            if (hook.owed(address(beacon)) != 0) {
                vm.prank(bob); // an unrelated account collects for the beacon
                hook.collect(address(beacon));
            }
        }

        uint256 held = uni.balanceOf(address(beacon)) + hook.owed(address(beacon));
        emit log_named_uint("beacon reserve (held + owed)", held);
        assertLe(held, hook.BOUNTY_RESERVE(), "never above 50 UNI");
        assertEq(held, hook.BOUNTY_RESERVE(), "and full");
        assertGt(hook.owed(DEV), 0, "the rest of the developer fee reaches the developer");
    }
}
