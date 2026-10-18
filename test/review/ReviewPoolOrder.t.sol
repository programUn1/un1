// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "../utils/Base.sol";
import {Deal} from "../../src/libraries/Deal.sol";

/// @notice Fourth review R4-01: adding an owned id back to the pool may select that id, but must never switch
///         between two ids that were already in the pool. Small-pool fixtures match Findings / ReviewDealFairness.
contract ReviewPoolOrderTest is Base {
    function _poolOnly(uint256 a, uint256 b, uint256 c) private {
        for (uint256 w; w < 40; ++w) {
            uint256 bits = type(uint256).max;
            if ((a - 1) >> 8 == w) bits &= ~(uint256(1) << ((a - 1) & 255));
            if (b != 0 && (b - 1) >> 8 == w) bits &= ~(uint256(1) << ((b - 1) & 255));
            if (c != 0 && (c - 1) >> 8 == w) bits &= ~(uint256(1) << ((c - 1) & 255));
            vm.store(address(token), bytes32(16 + w), bytes32(bits));
        }
        vm.store(address(token), bytes32(uint256(56)), bytes32(uint256(1 + (b == 0 ? 0 : 1) + (c == 0 ? 0 : 1))));
    }

    function test_Review_saleCannotSwitchBetweenOtherPoolIds() public {
        _skipOpening();
        _buy(bob, 1 ether);
        _revealAll("r4-owner");
        uint256 sold = token.idsOf(bob)[0];
        assertEq(sold, 4988);
        _buy(alice, 1 ether);
        (, uint64 round,) = token.slotOf(1);
        _poolOnly(1, 5099, 0);
        bytes32 randomness = 0xe742a6fbb8569bd642adf6709550acf8cd5bdd83a8b6c3b362f188e71d2c5f09;
        uint256 snap = vm.snapshotState();
        assertEq(_fulfill(round, randomness, 1), 1);
        uint256 before = token.idsOf(alice)[0];
        assertTrue(vm.revertToState(snap));
        _sell(bob, 1 ether);
        assertEq(_fulfill(round, randomness, 1), 1);
        uint256 after_ = token.idsOf(alice)[0];
        assertTrue(after_ == before || after_ == sold, "adding an id may only keep the result or select the added id");
    }

    function testFuzz_addingAnIdDoesNotReorderExistingIds(bytes32 randomness, uint16 x, uint16 y, uint16 z) public {
        uint256 a = bound(x, 1, 10_000);
        uint256 b = bound(y, 1, 10_000);
        uint256 c = bound(z, 1, 10_000);
        vm.assume(a != b && a != c && b != c);
        _skipOpening();
        _buy(alice, 1 ether);
        (, uint64 round,) = token.slotOf(0);
        uint256 snap = vm.snapshotState();
        _poolOnly(a, b, 0);
        assertEq(_fulfill(round, randomness, 1), 1);
        uint256 before = token.idsOf(alice)[0];
        assertTrue(vm.revertToState(snap));
        _poolOnly(a, b, c);
        assertEq(_fulfill(round, randomness, 1), 1);
        uint256 after_ = token.idsOf(alice)[0];
        assertTrue(after_ == before || after_ == c, "a fixed seed must preserve the order of existing pool ids");
    }

    function test_Review_addedPrefixIdCanReplaceOnlyTheFallbackResult() public {
        _skipOpening();
        _buy(alice, 1 ether);
        (, uint64 round,) = token.slotOf(0);
        bytes32 randomness = keccak256("r4-prefix-boundary");
        bytes32 seed = keccak256(abi.encodePacked(randomness, uint256(0)));
        uint256 a = Deal.at(token.MAX_WALK(), seed);
        uint256 b = Deal.at(token.MAX_WALK() + 1, seed);
        uint256 first = Deal.at(0, seed);
        uint256 second = Deal.at(1, seed);
        uint256 snap = vm.snapshotState();
        _poolOnly(a, b, 0);
        assertEq(_fulfill(round, randomness, 1), 1);
        uint256 selected = token.idsOf(alice)[0];
        assertTrue(selected == a || selected == b);
        assertTrue(vm.revertToState(snap));
        _poolOnly(a, b, second);
        assertEq(_fulfill(round, randomness, 1), 1);
        assertEq(token.idsOf(alice)[0], second, "entering the prefix only selects the inserted id");
        assertTrue(vm.revertToState(snap));
        _poolOnly(first, second, a);
        assertEq(_fulfill(round, randomness, 1), 1);
        assertEq(token.idsOf(alice)[0], first, "the earliest prefix id wins");
    }

    function test_Review_largestPossibleFallbackPoolFitsTransactionGas() public {
        _skipOpening();
        _buy(alice, 1 ether);
        (, uint64 round,) = token.slotOf(0);
        bytes32 randomness = keccak256("r4-largest-fallback");
        bytes32 seed = keccak256(abi.encodePacked(randomness, uint256(0)));
        uint256[40] memory taken;
        for (uint256 k; k < token.MAX_WALK(); ++k) {
            uint256 i = Deal.at(k, seed) - 1;
            taken[i >> 8] |= uint256(1) << (i & 255);
        }
        for (uint256 w; w < 40; ++w) vm.store(address(token), bytes32(16 + w), bytes32(taken[w]));
        vm.store(address(token), bytes32(uint256(56)), bytes32(10_000 - token.MAX_WALK()));
        vm.cool(address(token));
        uint256 gasBefore = gasleft();
        assertEq(_fulfill(round, randomness, 1), 1);
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("gas: 8,976 remaining ids after a missed 1,024-id prefix", used);
        assertLt(used, 15_000_000, "leave room for the beacon within the transaction gas cap");
        assertEq(token.poolCount(), 8975);
        assertFalse(token.inPool(token.idsOf(alice)[0]));
    }

    function test_Review_oneToThreeRemainingIdsStayBelowThreeMillionGas() public {
        _skipOpening();
        _buy(alice, 1 ether);
        (, uint64 round,) = token.slotOf(0);
        bytes32 randomness = keccak256("r4-small-pool-gas");
        bytes32 seed = keccak256(abi.encodePacked(randomness, uint256(0)));
        uint256 a = Deal.at(token.MAX_WALK(), seed);
        uint256 b = Deal.at(token.MAX_WALK() + 1, seed);
        uint256 c = Deal.at(token.MAX_WALK() + 2, seed);
        uint256 snap = vm.snapshotState();
        for (uint256 n = 1; n <= 3; ++n) {
            assertTrue(vm.revertToState(snap));
            _poolOnly(a, n >= 2 ? b : 0, n == 3 ? c : 0);
            vm.cool(address(token));
            uint256 gasBefore = gasleft();
            assertEq(_fulfill(round, randomness, 1), 1);
            uint256 used = gasBefore - gasleft();
            emit log_named_uint(string.concat("gas: cold fallback with ", vm.toString(n), " ids"), used);
            assertLt(used, 3_000_000, "one reveal stays bounded even with a cold sparse bitmap");
            assertEq(token.poolCount(), n - 1);
        }
    }
}
