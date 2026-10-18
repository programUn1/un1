// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "../utils/Base.sol";
import {DrandRound} from "../../src/libraries/DrandRound.sol";
import {UN1Beacon} from "../../src/UN1Beacon.sol";

/// @dev Local deterministic replacement for the EIP-2935 history contract, as in Reveal.t.sol.
contract ReviewHistoryMock {
    fallback(bytes calldata data) external returns (bytes memory) {
        return abi.encode(keccak256(abi.encode(abi.decode(data, (uint256)))));
    }
}

/// @notice Review R-05 (docs/reviews/gpt-review.md) and its follow-up F2-02 (gpt-review-2.md). The reproduction showed a
///         partially revealed round switching between drand and the fallback batch by batch. After the fixes the first
///         batch fixes the round's randomness, and a round that has not started takes only the source of the moment.
contract ReviewBeaconRandomnessTest is Base {
    uint64 private constant ROUND = 20_000_000;
    uint256 private constant BUY_TIME = 1_752_803_334;
    bytes private constant SIGNATURE =
        hex"0000000000000000000000000000000016892582a33552a7b67ba44ef09c3ccd535bbebe760c93ecf45be8958d0c0f06390c6d19d7bf492eb806af7eef6b125c000000000000000000000000000000000a37c6379b6195ff2eecdcd2c96be15f7660c663d1263b1ae5da70b6f1052bcddd07e01e6cad165d3ef383334c0ff765";

    function _startTime() internal pure override returns (uint256) {
        return BUY_TIME - 5 minutes - 1;
    }

    function test_review_aStartedRoundKeepsItsRandomness_whicheverEntryPoint() public {
        vm.warp(BUY_TIME);
        vm.etch(beacon.HISTORY(), address(new ReviewHistoryMock()).code);
        _buy(alice, 3 ether);
        vm.warp(DrandRound.roundTime(ROUND));
        vm.expectRevert(UN1Beacon.TooEarly.selector);
        beacon.revealFallback(ROUND, 1, address(0)); // a round that has not started: drand only within the day
        assertEq(beacon.reveal(ROUND, SIGNATURE, 1, address(0)), 1);

        // a day later the remaining slots continue with the same randomness through either entry point
        vm.warp(DrandRound.roundTime(ROUND) + 1 days);
        vm.roll(block.number + 7_200);
        uint256 snapshot = vm.snapshotState();
        assertEq(beacon.revealFallback(ROUND, 1, address(0)), 1);
        uint256[] memory a = token.idsOf(alice);
        assertTrue(vm.revertToState(snapshot));
        assertEq(beacon.reveal(ROUND, "", 1, address(0)), 1);
        uint256[] memory b = token.idsOf(alice);
        assertEq(a.length, 2);
        assertEq(a[0] + a[1], b[0] + b[1], "the same ids either way");
        assertTrue((a[0] == b[0] && a[1] == b[1]) || (a[0] == b[1] && a[1] == b[0]));
        assertFalse(beacon.fallbackUsedOf(ROUND));
        assertEq(beacon.reveal(ROUND, "", 1, address(0)), 1);
        assertEq(token.idCount(alice), 3);
    }
}
