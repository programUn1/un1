// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "../utils/Base.sol";
import {UN1Beacon} from "../../src/UN1Beacon.sol";
import {DrandRound} from "../../src/libraries/DrandRound.sol";

/// @notice Second review F2-02 (docs/reviews/gpt-review-2.md), the reproduction from its appendix B with the real
///         EIP-2935 runtime. It showed a started round switching randomness at the one-day boundary and when the history
///         hash expires. After the second fix the first successful batch fixes the round's randomness: the same pending
///         slot gets the same id on either side of each boundary.
contract ReviewSourceBoundaryTest is Base {
    uint64 constant R = 20_000_000;
    uint256 constant BUY_TIME = 1_752_803_334;
    bytes constant SIG =
        hex"0000000000000000000000000000000016892582a33552a7b67ba44ef09c3ccd535bbebe760c93ecf45be8958d0c0f06390c6d19d7bf492eb806af7eef6b125c000000000000000000000000000000000a37c6379b6195ff2eecdcd2c96be15f7660c663d1263b1ae5da70b6f1052bcddd07e01e6cad165d3ef383334c0ff765";
    // Exact runtime from EIP-2935. Only its historical storage is initialized by this fixture.
    bytes constant HISTORY_CODE =
        hex"3373fffffffffffffffffffffffffffffffffffffffe14604657602036036042575f35600143038111604257611fff81430311604257611fff9006545f5260205ff35b5f5ffd5b5f35611fff60014303065500";

    function _startTime() internal pure override returns (uint256) {
        return BUY_TIME - 5 minutes - 1;
    }

    function _prepare() internal returns (uint256 n, uint256 boundary) {
        vm.warp(BUY_TIME);
        _buy(alice, 1 ether);
        _buy(bob, 2 ether);
        (, uint64 round,) = token.slotOf(0);
        assertEq(round, R);
        n = token.lastBlockOf(R) + 1;
        vm.etch(beacon.HISTORY(), HISTORY_CODE);
        vm.store(beacon.HISTORY(), bytes32(n % 8191), keccak256(abi.encode(n)));
        boundary = DrandRound.roundTime(R) + 1 days;
        vm.warp(DrandRound.roundTime(R));
        assertEq(beacon.reveal(R, SIG, 1, address(0)), 1); // the round starts with drand
        assertEq(token.slotHead(), 1);
        assertEq(beacon.randomnessOf(R), keccak256(SIG), "the round's randomness is fixed");
    }

    function test_review2_dayBoundary_keepsTheRoundsRandomness() public {
        (uint256 n, uint256 boundary) = _prepare();
        vm.roll(n + 7200);
        vm.warp(boundary - 1);
        uint256 snap = vm.snapshotState();
        assertEq(beacon.reveal(R, SIG, 1, address(0)), 1);
        uint256 before = token.idsOf(bob)[0];
        assertTrue(vm.revertToState(snap));
        vm.roll(n + 7201);
        vm.warp(boundary);
        assertEq(beacon.revealFallback(R, 1, address(0)), 1, "either entry continues the started round");
        uint256 atBoundary = token.idsOf(bob)[0];
        assertEq(atBoundary, before, "same slot, same id across the day boundary");
        assertFalse(beacon.fallbackUsedOf(R), "still the drand randomness");
    }

    function test_review2_historyExpiry_keepsTheRoundsRandomness() public {
        (uint256 n, uint256 boundary) = _prepare();
        vm.roll(n + 8191);
        vm.warp(boundary + 3 hours);
        uint256 snap = vm.snapshotState();
        assertEq(beacon.revealFallback(R, 1, address(0)), 1);
        uint256 inWindow = token.idsOf(bob)[0];
        assertTrue(vm.revertToState(snap));
        vm.roll(n + 8192);
        vm.warp(boundary + 3 hours + 12);
        assertEq(beacon.reveal(R, "", 1, address(0)), 1, "no signature needed once the round has started");
        assertEq(token.idsOf(bob)[0], inWindow, "same slot, same id across the history expiry");
    }

    /// @dev A round that has not started takes the source of the moment; the first batch then fixes it.
    function test_review2_unstartedRound_followsTheWindows_thenStaysFixed() public {
        vm.warp(BUY_TIME);
        _buy(alice, 2 ether);
        uint256 n = token.lastBlockOf(R) + 1;
        vm.etch(beacon.HISTORY(), HISTORY_CODE);
        vm.store(beacon.HISTORY(), bytes32(n % 8191), keccak256(abi.encode(n)));
        vm.warp(DrandRound.roundTime(R) + 1 days);
        vm.roll(n + 7200);
        vm.expectRevert(UN1Beacon.UseFallback.selector);
        beacon.reveal(R, SIG, 1, address(0));
        assertEq(beacon.revealFallback(R, 1, address(0)), 1);
        assertTrue(beacon.fallbackUsedOf(R));
        bytes32 r = beacon.randomnessOf(R);
        assertEq(r, keccak256(abi.encodePacked("un1.fallback", R, keccak256(abi.encode(n)))));
        // after the history expired, the round still continues with the fallback randomness it started with
        vm.roll(n + 9000);
        assertEq(beacon.reveal(R, "", 1, address(0)), 1);
        assertEq(beacon.randomnessOf(R), r);
        assertEq(token.idCount(alice), 2);
    }

    function test_review2_blockhash256ToHistory257HasNoSourceGap() public {
        vm.warp(BUY_TIME);
        _buy(bob, 1 ether);
        uint256 n = token.lastBlockOf(R) + 1;
        vm.etch(beacon.HISTORY(), HISTORY_CODE);
        vm.store(beacon.HISTORY(), bytes32(n % 8191), keccak256(abi.encode(n)));
        vm.warp(DrandRound.roundTime(R) + 1 days);
        vm.roll(n + 256);
        vm.setBlockhash(n, keccak256(abi.encode(n)));
        uint256 snap = vm.snapshotState();
        vm.expectRevert(UN1Beacon.UseFallback.selector);
        beacon.reveal(R, SIG, 1, address(0));
        assertEq(beacon.revealFallback(R, 1, address(0)), 1);
        uint256 opcodeId = token.idsOf(bob)[0];
        assertTrue(vm.revertToState(snap));
        vm.roll(n + 257);
        vm.expectRevert(UN1Beacon.UseFallback.selector);
        beacon.reveal(R, SIG, 1, address(0));
        assertEq(beacon.revealFallback(R, 1, address(0)), 1);
        assertEq(token.idsOf(bob)[0], opcodeId);
    }
}
