// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UN1Token} from "../src/UN1Token.sol";
import {Base} from "./utils/Base.sol";
import {UN1Hook} from "../src/UN1Hook.sol";
import {Fees} from "./utils/Fees.sol";

using Fees for UN1Hook;

/// @notice Findings of the 2026-10-15 code review, one group of cases each:
///  fixed ones (K-1 work guard, K-2 draw credit, K-5 revoke, K-7 readable and clearable sell order, G-1 bounded walk) assert the fixed behavior;
///  kept ones (K-1 default, K-4, K-6) assert the current behavior, which the website and the docs explain. K-3's bounty cap is in Reveal.t.sol.
contract FindingsTest is Base {
    uint256 constant TAKEN_SLOT = 16; // UN1Token._taken (forge inspect UN1Token storageLayout)
    uint256 constant POOL_COUNT_SLOT = 56; // UN1Token.poolCount

    function _disjointPair(address who) internal view returns (uint256 a, uint256 b) {
        uint256[] memory ids = token.idsOf(who);
        for (uint256 i; i < ids.length; ++i) {
            for (uint256 j = i + 1; j < ids.length; ++j) {
                (, uint8 mi,,) = token.cardOf(ids[i]);
                (, uint8 mj,,) = token.cardOf(ids[j]);
                if (mi & mj == 0) return (ids[i], ids[j]);
            }
        }
        revert("no disjoint pair");
    }

    function _compose(address who, uint256 keep, uint256 other) internal {
        uint256 nonce;
        while (uint256(token.proofDigest(who, keep, other, nonce)) >> (256 - token.PROOF_BITS()) != 0) ++nonce;
        vm.prank(who);
        token.compose(keep, other, nonce);
    }

    /// @dev Alice: one composed work and four fragments, five tokens.
    function _aliceWithAWork(bytes32 salt) internal returns (uint256 keep, uint256 other) {
        _buy(alice, 6 ether);
        _revealAll(salt);
        (keep, other) = _disjointPair(alice);
        _compose(alice, keep, other);
        assertEq(token.balanceOf(alice), 5 ether);
    }

    /// @dev Alice holds only the work, backed by exactly one token.
    function _aliceWithOnlyAWork(bytes32 salt) internal returns (uint256 keep, uint256 other) {
        (keep, other) = _aliceWithAWork(salt);
        _sell(alice, 4 ether); // the four fragments leave first
        assertEq(token.idCount(alice), 1);
        assertEq(token.ownerOfId(keep), alice, "the work is the last unit");
    }

    // ================================================================ K-1 a work rests on one token

    /// @dev Default (guard off): a thousandth of the last token is enough to send the work back to the pool.
    function test_K1_default_aFractionalSale_dissolvesTheLastWork() public {
        _skipOpening();
        (uint256 keep, uint256 other) = _aliceWithOnlyAWork("k1d");
        _sell(alice, 0.001 ether);
        assertEq(token.idCount(alice), 0);
        assertTrue(token.inPool(keep), "the work went back to the pool");
        (address owner, uint8 mask, uint8 layers, uint64 look) = token.cardOf(keep);
        assertEq(owner, address(0));
        assertEq(mask, token.originalMask(keep), "its own parts only");
        assertEq(layers, 1);
        assertEq(look, 0);
        assertEq(token.retiredInto(other), keep, "the retired id stays retired");
        assertFalse(token.inPool(other));
    }

    /// @dev Guard on: the same sale reverts, wherever it comes from (any router, any wallet).
    function test_K1_guard_blocksTheSaleThatWouldDissolveAWork() public {
        _skipOpening();
        (uint256 keep,) = _aliceWithOnlyAWork("k1d");
        vm.prank(alice);
        token.setGuard(true);
        assertTrue(token.isGuarded(alice));
        vm.expectRevert();
        _sell(alice, 0.001 ether);
        // a fractional wallet transfer the receiver cannot catch: refused too
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UN1Token.WorkGuarded.selector, keep));
        token.transfer(bob, 0.5 ether);
        assertEq(token.ownerOfId(keep), alice);
    }

    /// @dev Guard on: the work can still move whole to another holder, and the guard can be turned off to sell it.
    function test_K1_guard_stillLetsTheWorkMoveWhole() public {
        _skipOpening();
        (uint256 keep,) = _aliceWithAWork("k1d");
        vm.prank(alice);
        token.setGuard(true);
        _sell(alice, 4 ether); // fragments are not guarded
        assertEq(token.idCount(alice), 1);
        vm.prank(alice);
        mirror.transferFrom(alice, bob, keep); // the ERC721 way (OpenSea)
        assertEq(token.ownerOfId(keep), bob);
        assertEq(token.balanceOf(bob), 1 ether);
        // bob, unguarded, sends one whole token back: alice crosses a whole token and catches the work
        vm.prank(bob);
        token.transfer(alice, 1 ether);
        assertEq(token.ownerOfId(keep), alice);
        vm.prank(alice);
        token.setGuard(false);
        _sell(alice, 1 ether);
        assertTrue(token.inPool(keep), "sold on purpose with the guard off");
    }

    // ================================================================ K-2 draw credit: fractions cannot draw again

    /// @dev Selling a hundredth of a card's token sends the card back; buying the hundredth back gives a naked unit,
    ///      not a new draw: the credit it adds is far from a whole token.
    function test_K2_dust_doesNotDrawAgain() public {
        _skipOpening();
        _buy(alice, 1 ether);
        _revealAll("k2");
        assertEq(token.drawCreditOf(alice), 0, "the whole token became the slot");
        _sell(alice, 0.01 ether);
        assertEq(token.idCount(alice), 0);
        _buy(alice, 0.01 ether);
        assertEq(token.balanceOf(alice), 1 ether);
        assertEq(token.pendingCount(alice), 0, "no new draw");
        assertEq(token.nakedCount(alice), 1, "a naked unit");
        assertEq(token.drawCreditOf(alice), 0.01 ether);
    }

    /// @dev Cancelling a slot before its reveal with a fraction, then buying the fraction back: no new slot either.
    function test_K2_dust_cannotReplaceACancelledSlot() public {
        _skipOpening();
        _buy(alice, 1 ether);
        _sell(alice, 0.01 ether);
        (,, bool alive) = token.slotOf(0);
        assertFalse(alive, "the slot was cancelled");
        vm.warp(block.timestamp + 30);
        _buy(alice, 0.01 ether);
        assertEq(token.pendingCount(alice), 0);
        assertEq(token.slotCount(), 1, "no slot for a later round");
    }

    /// @dev A whole token bought in parts still draws: 0.6 + 0.6 opens one slot and keeps 0.2 of credit.
    function test_K2_wholeTokenBoughtInParts_draws() public {
        _skipOpening();
        _buy(alice, 0.6 ether);
        assertEq(token.pendingCount(alice), 0);
        assertEq(token.drawCreditOf(alice), 0.6 ether);
        _buy(alice, 0.6 ether);
        assertEq(token.pendingCount(alice), 1);
        assertEq(token.drawCreditOf(alice), 0.2 ether);
        _buy(alice, 0.8 ether); // 2.0: crosses with a whole token of credit
        assertEq(token.pendingCount(alice), 2);
        assertEq(token.drawCreditOf(alice), 0);
    }

    /// @dev Credit belongs to the buyer: tokens received from a wallet move existing units, they never add credit.
    function test_K2_transfersCarryNoCredit() public {
        _skipOpening();
        token.transfer(alice, 0.7 ether); // naked dust from the launch holder
        _buy(alice, 0.5 ether); // 1.2: crosses, but only 0.5 bought in the pool
        assertEq(token.pendingCount(alice), 0);
        assertEq(token.nakedCount(alice), 1);
        assertEq(token.drawCreditOf(alice), 0.5 ether);
        _buy(alice, 0.5 ether); // 1.7: a whole token of credit, no crossing yet
        assertEq(token.pendingCount(alice), 0);
        assertEq(token.drawCreditOf(alice), 1 ether);
        _buy(alice, 0.3 ether); // 2.0: crosses, the credit opens the slot
        assertEq(token.pendingCount(alice), 1);
        assertEq(token.drawCreditOf(alice), 0.3 ether);
    }

    /// @dev Over any sequence, the slots an account opens never exceed the whole tokens it bought in the official pool.
    function testFuzz_K2_slotsNeverExceedTokensBought(uint64[6] memory amounts, bool[6] memory sells) public {
        _skipOpening();
        uint256 bought;
        for (uint256 i; i < 6; ++i) {
            uint256 a = bound(amounts[i], 0.001 ether, 3 ether);
            if (sells[i] && token.balanceOf(alice) >= a) {
                _sell(alice, a);
            } else {
                _buy(alice, a);
                bought += a;
            }
            vm.roll(block.number + 1);
        }
        assertLe(token.slotCount(), bought / 1 ether, "slots <= whole tokens bought");
        assertEq(token.slotCount() * 1 ether + token.drawCreditOf(alice), bought, "every bought wei is a slot or credit");
    }

    // ================================================================ K-4 the pool's first swap is the launch buy

    /// @dev K-4, now in the contracts: the Seeder refuses a launch without the dev buy (ReviewSeederLocal), so the pool's
    ///      first swap is always the launch buy. Launch protection counts it as the developer's (no opening fee, the
    ///      same 2% cap); every later buy during protection must come through the canonical router.
    function test_K4_firstSwapIsTheLaunchBuy_countedAsTheDevelopers() public {
        _buy(alice, 150 ether); // here the first swap stands for the launch buy
        assertEq(hook.boughtDuringProtection(DEV), 150 ether);
        assertEq(hook.boughtDuringProtection(alice), 0);
        assertEq(hook.openingFeesCollected(), 0);
        vm.expectRevert();
        _buy(bob, 1 ether); // not through the canonical router
    }

    // ================================================================ K-5 an address that got cards before it had code: revoke

    function test_K5_revoke_removesTheWeightOfAContractThatGotCodeLater() public {
        _skipOpening();
        address pair = makeAddr("a pair address known in advance (CREATE2)");
        _buy(alice, 1 ether);
        _revealAll("k5");
        vm.prank(alice);
        token.transfer(pair, 1 ether); // a card arrives while nothing is deployed there
        vm.etch(pair, hex"fe"); // then a contract is created at that address
        assertTrue(token.isWeighted(pair));
        uint256 total = token.totalWeight();
        uint256 w = token.weightOf(pair);
        assertGt(w, 0);

        vm.prank(bob); // anyone
        token.revoke(pair);
        assertFalse(token.isWeighted(pair));
        assertEq(token.weightOf(pair), 0);
        assertEq(token.totalWeight(), total - w);
        assertEq(token.idCount(pair), 1, "it still holds the card");
        vm.expectRevert(UN1Token.NotRevocable.selector);
        token.revoke(pair); // once

        vm.prank(pair); // a contract that wants weight opts in explicitly
        token.optIn();
        assertTrue(token.isWeighted(pair));
        vm.expectRevert(UN1Token.NotRevocable.selector);
        token.revoke(pair);
    }

    function test_K5_revoke_neverTouchesWalletsOr7702Accounts() public {
        _skipOpening();
        _buy(alice, 1 ether);
        _revealAll("k5b");
        vm.expectRevert(UN1Token.NotRevocable.selector);
        token.revoke(alice); // no code
        address delegated = makeAddr("7702");
        vm.prank(alice);
        token.transfer(delegated, 1 ether);
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(0xbeef))); // EIP-7702 delegation designator
        vm.expectRevert(UN1Token.NotRevocable.selector);
        token.revoke(delegated);
        assertTrue(token.isWeighted(delegated));
    }

    // ================================================================ K-6 composing keeps approvals (kept; the website warns)

    function test_K6_kept_approvalSurvivesCompose() public {
        _skipOpening();
        _buy(alice, 6 ether);
        _revealAll("k6");
        (uint256 keep, uint256 other) = _disjointPair(alice);
        vm.prank(alice);
        mirror.approve(bob, keep);
        _compose(alice, keep, other);
        assertEq(mirror.getApproved(keep), bob, "the approval now covers the work");
    }

    // ================================================================ K-7 a leftover sell order: readable and clearable

    function test_K7_leftoverOutFirst_isVisible_andClearable() public {
        _skipOpening();
        (uint256 keep,) = _aliceWithAWork("k7a");
        uint32[] memory first = new uint32[](1);
        first[0] = uint32(keep);
        vm.prank(alice);
        token.setOutFirst(first);
        uint32[] memory seen = token.outFirstOf(alice);
        assertEq(seen.length, 1);
        assertEq(seen[0], keep, "the site can see the leftover list");

        vm.prank(alice);
        token.setOutFirst(new uint32[](0)); // what the site sends when a sale does not happen
        assertEq(token.outFirstOf(alice).length, 0);
        vm.prank(alice);
        token.transfer(bob, 1 ether);
        assertEq(token.ownerOfId(keep), alice, "a fragment left, not the work");
    }

    function test_K7_outFirstOf_inLeaveOrder() public {
        uint32[] memory ids = new uint32[](3);
        (ids[0], ids[1], ids[2]) = (uint32(7), uint32(5099), uint32(42));
        vm.prank(alice);
        token.setOutFirst(ids);
        uint32[] memory seen = token.outFirstOf(alice);
        assertEq(seen.length, 3);
        assertEq(seen[0], 7);
        assertEq(seen[1], 5099);
        assertEq(seen[2], 42);
    }

    // ================================================================ G-1 reveal gas stays bounded in a tiny pool

    /// @dev Leave only `free` ids in the pool (bitmap and count), as if almost the whole supply were held.
    function _poolOnly(uint256[] memory free) internal {
        uint256[40] memory words;
        for (uint256 w; w < 40; ++w) words[w] = type(uint256).max;
        for (uint256 j; j < free.length; ++j) {
            uint256 i = free[j] - 1;
            words[i >> 8] &= ~(uint256(1) << (i & 255));
        }
        for (uint256 w; w < 40; ++w) vm.store(address(token), bytes32(TAKEN_SLOT + w), bytes32(words[w]));
        vm.store(address(token), bytes32(POOL_COUNT_SLOT), bytes32(free.length));
        for (uint256 j; j < free.length; ++j) assertTrue(token.inPool(free[j]));
    }

    function testFuzz_G1_tinyPool_revealStaysBounded(bytes32 randomness) public {
        _skipOpening();
        _buy(alice, 1 ether);
        (, uint64 round,) = token.slotOf(0);
        uint256[] memory free = new uint256[](3);
        (free[0], free[1], free[2]) = (1, 5099, 10_000); // first word, a middle word, the very last id
        _poolOnly(free);
        uint256 g = gasleft();
        _fulfill(round, randomness, 1);
        uint256 used = g - gasleft();
        uint256 id = token.idsOf(alice)[0];
        assertTrue(id == 1 || id == 5099 || id == 10_000, "an id from the pool");
        assertFalse(token.inPool(id));
        assertLt(used, 3_000_000, "at most 1,024 walk steps, then fixed per-id scores (40 bitmap words)");
    }

    function test_G1_lastIdLeft_isFound() public {
        _skipOpening();
        _buy(alice, 1 ether);
        (, uint64 round,) = token.slotOf(0);
        uint256[] memory free = new uint256[](1);
        free[0] = 10_000;
        _poolOnly(free);
        _fulfill(round, keccak256("g1"), 1);
        assertEq(token.idsOf(alice)[0], 10_000);
        assertEq(token.poolCount(), 0);
    }
}
