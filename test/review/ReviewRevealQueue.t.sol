// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "../utils/Base.sol";
import {HistoryMock} from "../Reveal.t.sol";
import {UN1Beacon} from "../../src/UN1Beacon.sol";
import {DrandRound} from "../../src/libraries/DrandRound.sol";

/// @notice Review R-03 (docs/reviews/gpt-review.md). Cancelled slots still cost a reveal walking past them; after the fix
///         (2026-10-15) anyone can clear them in bounded parts with `pruneSlots`, so the queue never gets stuck.
contract ReviewRevealQueueTest is Base {
    function _history() private {
        vm.etch(beacon.HISTORY(), address(new HistoryMock()).code);
        vm.roll(block.number + 7_200);
    }

    function test_Review_cancelledOnlyQueue_isPrunedByAnyone() public {
        _skipOpening();
        _buy(alice, 4 ether);
        (, uint64 round,) = token.slotOf(0);
        _sell(alice, 4 ether);
        assertEq(token.slotCount(), 4);
        _history();
        vm.warp(DrandRound.roundTime(round) + 1 days);

        vm.expectRevert(UN1Beacon.NothingToReveal.selector);
        beacon.revealFallback(round, 64, address(0)); // a reveal still needs a live slot
        vm.prank(bob);
        assertEq(token.pruneSlots(64), 4);
        assertEq(token.slotHead(), 4, "the head moved past the cancelled slots");
        assertEq(token.pruneSlots(64), 0, "nothing more to prune");
    }

    function test_Review_pruneStopsAtTheFirstLiveSlot() public {
        _skipOpening();
        _buy(alice, 3 ether);
        _sell(alice, 3 ether); // slots 0..2 cancelled
        _buy(bob, 1 ether); // slot 3 live
        _buy(alice, 2 ether);
        _sell(alice, 2 ether); // slots 4..5 cancelled, behind a live one
        assertEq(token.pruneSlots(100), 3);
        assertEq(token.slotHead(), 3, "never past a live slot");
        (,, bool alive) = token.slotOf(3);
        assertTrue(alive);
    }

    function test_Review_largeCancelledPrefix_isClearedInBoundedParts_thenRevealIsCheap() public {
        _skipOpening();
        for (uint256 batch; batch < 128; ++batch) {
            _buy(alice, 64 ether);
            _sell(alice, 64 ether);
        }
        _buy(bob, 1 ether);
        (, uint64 round,) = token.slotOf(8_192);
        _history();
        vm.warp(DrandRound.roundTime(round) + 1 days);

        // 8,192 cancelled slots: four calls of 2,048, each well within one transaction
        for (uint256 part; part < 4; ++part) {
            vm.cool(address(token));
            uint256 g = gasleft();
            assertEq(token.pruneSlots(2_048), 2_048);
            uint256 used = g - gasleft();
            assertLt(used, 8_000_000, "one part fits a transaction");
            if (part == 0) emit log_named_uint("gas to prune 2,048 cancelled slots", used);
        }
        assertEq(token.slotHead(), 8_192);

        vm.cool(address(token));
        uint256 beforeGas = gasleft();
        (bool ok,) = address(beacon).call{gas: 16_777_216}(abi.encodeCall(UN1Beacon.revealFallback, (round, 1, address(0))));
        assertTrue(ok, "the live slot reveals within the transaction budget");
        emit log_named_uint("gas to reveal after pruning", beforeGas - gasleft());
        assertEq(token.slotHead(), 8_193);
        assertEq(token.idCount(bob), 1);
    }
}
