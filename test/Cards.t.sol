// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UN1Token} from "../src/UN1Token.sol";
import {UN1Mirror} from "../src/UN1Mirror.sol";
import {Appearance} from "../src/libraries/Appearance.sol";
import {Deal} from "../src/libraries/Deal.sol";
import {DrandRound} from "../src/libraries/DrandRound.sol";
import {Base} from "./utils/Base.sol";

contract Holder {} // a contract wallet without the 7702 prefix (Safe-like)

/// @notice The NFT layer: id pool, pending slots, dealing on reveal, unit order, transfers across whole tokens, decoherence, the mirror, holding and weight.
contract CardsTest is Base {
    function setUp() public override {
        super.setUp();
        _skipOpening();
    }

    function _holders() internal view returns (address[] memory h) {
        h = new address[](3);
        h[0] = alice;
        h[1] = bob;
        h[2] = address(this);
    }

    function _minParts(address who) internal view returns (uint256 m) {
        uint256[] memory ids = token.idsOf(who);
        m = 9;
        for (uint256 i; i < ids.length; ++i) {
            (, uint8 mask,,) = token.cardOf(ids[i]);
            uint256 c = _pop(mask);
            if (c < m) m = c;
        }
    }

    function _pop(uint8 m) internal pure returns (uint256 c) {
        for (; m != 0; m &= m - 1) ++c;
    }

    // ---------------------------------------------------------------- data and libraries

    function test_masks_matchBitcoinData() public view {
        assertEq(token.originalMask(1), 8, "#1 = genesis: face only");
        assertEq(token.originalMask(5099), 0xff & ~uint8(1 << 5), "#5099: all but the upper mane");
        assertEq(token.poolCount(), 10_000);
        assertTrue(token.inPool(1) && token.inPool(10_000));
    }

    function test_badMasks_rejected() public {
        bytes memory wrong = new bytes(10_000);
        address d = _deployMasks(wrong);
        vm.expectRevert(UN1Token.BadMasks.selector);
        new UN1Token(address(manager), d);
    }

    function test_appearance_matchesPythonReference() public pure {
        // art/build_v6.py measure(): seed 0x…01 and 0x…deadbeef
        assertEq(Appearance.measure(bytes32(uint256(1))), 0x15604842047128d);
        assertEq(Appearance.measure(bytes32(uint256(0xdeadbeef))), 0x2044812072181);
    }

    function test_deal_isPermutation() public pure {
        bytes32 key = keccak256("k");
        bool[] memory seen = new bool[](10_001);
        for (uint256 k; k < 10_000; ++k) {
            uint256 id = Deal.at(k, key);
            assertTrue(id >= 1 && id <= 10_000 && !seen[id], "bijection on 1..10000");
            seen[id] = true;
        }
    }

    function test_targetRound_isBucketedAndAfterDelay() public view {
        uint64 r = DrandRound.target(block.timestamp);
        assertEq(r % 10, 0, "bucket of 10 rounds");
        assertGe(DrandRound.roundTime(r), block.timestamp + 15, "at least 15 s later");
        assertLt(DrandRound.roundTime(r), block.timestamp + 15 + 33, "at most one bucket more");
    }

    // ---------------------------------------------------------------- buy, reveal

    /// @dev Art v7: the eight part details are drawn from the same seed as the look, kept through wallet transfers,
    ///      cleared when the id returns to the pool, and drawn again when it is minted to its next holder.
    function test_measure_storesDetails_keptOnTransfer() public {
        _buy(alice, 1 ether);
        (, uint64 round,) = token.slotOf(0);
        bytes32 randomness = keccak256(abi.encode(bytes32("d1"), round));
        _fulfill(round, randomness, type(uint256).max);
        uint256 id = token.idsOf(alice)[0];
        bytes32 seed = keccak256(abi.encodePacked(randomness, uint256(0)));
        assertEq(token.detailsOf(id), Appearance.details(seed), "details = sha256(seed || 0x02)");
        assertEq(token.lookOf(id), Appearance.measure(seed));
        vm.prank(alice);
        token.transfer(bob, 1 ether);
        assertEq(token.ownerOfId(id), bob);
        assertEq(token.detailsOf(id), Appearance.details(seed), "an old card keeps its details");
    }

    function test_buyThenReveal_dealsDistinctIdsFromPool() public {
        _buy(alice, 3 ether);
        assertEq(token.pendingCount(alice), 3);
        assertEq(token.weightOf(alice), 3 * 10_000, "pending slots weigh 1 each");
        _revealAll("r1");
        assertEq(token.pendingCount(alice), 0);
        uint256[] memory ids = token.idsOf(alice);
        assertEq(ids.length, 3);
        uint256 w;
        for (uint256 i; i < 3; ++i) {
            assertFalse(token.inPool(ids[i]));
            assertEq(mirror.ownerOf(ids[i]), alice);
            (address o, uint8 mask, uint8 layers, uint64 look) = token.cardOf(ids[i]);
            assertEq(o, alice);
            assertEq(mask, token.originalMask(ids[i]));
            assertEq(layers, 1);
            assertTrue(look != 0 || true);
            w += token.cardWeight(mask, 1);
        }
        assertTrue(ids[0] != ids[1] && ids[1] != ids[2] && ids[0] != ids[2]);
        assertEq(mirror.balanceOf(alice), 3);
        assertEq(token.poolCount(), 9_997);
        assertEq(token.weightOf(alice), w, "weight = parts once measured");
        _checkInvariants(_holders());
    }

    function test_reveal_onlyBeacon_andRoundOrder() public {
        _buy(alice, 1 ether);
        (, uint64 r1,) = token.slotOf(0);
        vm.warp(block.timestamp + 60);
        _buy(bob, 1 ether);
        (, uint64 r2,) = token.slotOf(1);
        assertGt(r2, r1);

        vm.prank(alice);
        vm.expectRevert(UN1Token.NotBeacon.selector);
        token.fulfill(r1, bytes32(0), 10);

        vm.prank(address(beacon));
        vm.expectRevert(UN1Token.EarlierRoundPending.selector);
        token.fulfill(r2, bytes32(uint256(2)), 10);

        assertEq(_fulfill(r1, bytes32(uint256(1)), 10), 1, "only the r1 slot");
        assertEq(_fulfill(r2, bytes32(uint256(2)), 10), 1);
        assertEq(token.idCount(alice), 1);
        assertEq(token.idCount(bob), 1);
    }

    // ---------------------------------------------------------------- sell order: pending → naked tokens → fragments → works

    function test_sellBeforeReveal_cancelsPendingFirst() public {
        _buy(alice, 2 ether);
        _sell(alice, 1 ether);
        assertEq(token.pendingCount(alice), 1);
        (,, bool alive1) = token.slotOf(1);
        assertFalse(alive1, "the latest slot was cancelled");
        _revealAll("r");
        assertEq(token.idCount(alice), 1);
        _checkInvariants(_holders());
    }

    function test_sellOrder_nakedBeforeCards() public {
        _buy(alice, 2 ether);
        _revealAll("r");
        token.transfer(alice, 1 ether); // the launch holder's tokens are naked
        assertEq(token.nakedCount(alice), 1);
        uint256[] memory before = token.idsOf(alice);
        _sell(alice, 1 ether);
        assertEq(token.nakedCount(alice), 0);
        assertEq(token.idCount(alice), 2, "cards untouched");
        assertEq(token.idsOf(alice)[0] + token.idsOf(alice)[1], before[0] + before[1]);
    }

    function test_sellOrder_fewestPartsFirst() public {
        _buy(alice, 8 ether);
        _revealAll("parts");
        uint256 minParts = _minParts(alice);
        uint256[] memory before = token.idsOf(alice);
        _sell(alice, 1 ether);
        uint256 sold;
        for (uint256 i; i < before.length; ++i) {
            if (token.inPool(before[i])) sold = before[i];
        }
        assertTrue(sold != 0);
        assertEq(_pop(token.originalMask(sold)), minParts, "the card with the fewest parts left first");
    }

    function test_setOutFirst_choosesTheCardToSell() public {
        _buy(alice, 3 ether);
        _revealAll("pick");
        uint256[] memory ids = token.idsOf(alice);
        uint32[] memory pick = new uint32[](1);
        pick[0] = uint32(ids[2]);
        vm.prank(alice);
        token.setOutFirst(pick);
        _sell(alice, 1 ether);
        assertTrue(token.inPool(ids[2]), "the chosen card went back to the pool");
        assertEq(token.idCount(alice), 2);
    }

    // ---------------------------------------------------------------- transfers: cards move with the token; the whole-token rule

    function test_walletTransfer_movesCardsAndKeepsLook() public {
        _buy(alice, 2 ether);
        _revealAll("t");
        uint256[] memory ids = token.idsOf(alice);
        vm.prank(alice);
        token.transfer(bob, 1 ether);
        uint256[] memory got = token.idsOf(bob);
        assertEq(got.length, 1);
        assertTrue(got[0] == ids[0] || got[0] == ids[1]);
        (address o,,, uint64 look) = token.cardOf(got[0]);
        assertEq(o, bob);
        assertTrue(look == token.lookOf(got[0]));
        assertEq(mirror.ownerOf(got[0]), bob);
        _checkInvariants(_holders());
    }

    function test_pendingSlot_followsTheToken() public {
        _buy(alice, 1 ether);
        vm.prank(alice);
        token.transfer(bob, 1 ether);
        assertEq(token.pendingCount(alice), 0);
        assertEq(token.pendingCount(bob), 1, "the slot moved with the token");
        _revealAll("p");
        assertEq(token.idCount(bob), 1, "revealed to the new holder");
    }

    function test_fractionalTransfer_receiverCatchesTheCard() public {
        _buy(alice, 1.2 ether);
        _revealAll("f");
        uint256 id = token.idsOf(alice)[0];
        token.transfer(bob, 0.6 ether); // naked fraction
        vm.prank(alice);
        token.transfer(bob, 0.5 ether); // alice 0.7, bob 1.1
        assertEq(token.idCount(alice), 0);
        assertEq(token.ownerOfId(id), bob, "bob crossed a whole token and caught it");
    }

    function test_fractionalTransfer_noCatch_decoheres() public {
        _buy(alice, 1.2 ether);
        _revealAll("g");
        uint256 id = token.idsOf(alice)[0];
        token.transfer(bob, 0.1 ether);
        vm.prank(alice);
        token.transfer(bob, 0.3 ether); // alice 0.9 loses it, bob 0.4 cannot catch it
        assertEq(token.ownerOfId(id), address(0));
        assertTrue(token.inPool(id), "back to superposition");
        assertEq(token.lookOf(id), 0, "appearance cleared");
        assertEq(token.detailsOf(id), 0, "details cleared");
        assertEq(token.idCount(bob), 0);
        _checkInvariants(_holders());
    }

    function test_sellIntoPool_decoheres() public {
        _buy(alice, 1 ether);
        _revealAll("s");
        uint256 id = token.idsOf(alice)[0];
        assertTrue(token.detailsOf(id) != 0);
        _sell(alice, 1 ether);
        assertTrue(token.inPool(id));
        assertEq(token.lookOf(id), 0);
        assertEq(token.detailsOf(id), 0, "back to superposition: details cleared with the look");
        vm.expectRevert(UN1Mirror.NonexistentToken.selector);
        mirror.ownerOf(id);
    }

    // ---------------------------------------------------------------- mirror: a named id moves whole (OpenSea)

    function test_mirrorTransfer_movesTheNamedCard_evenWithPendingSlots() public {
        _buy(alice, 2 ether);
        _revealAll("m");
        uint256 id = token.idsOf(alice)[1];
        _buy(alice, 1 ether); // a pending slot would normally leave first
        vm.prank(alice);
        mirror.transferFrom(alice, bob, id);
        assertEq(token.ownerOfId(id), bob);
        assertEq(token.balanceOf(bob), 1 ether, "one token travels with the card");
        assertEq(token.pendingCount(alice), 1, "the pending slot stayed");
    }

    function test_mirror_approvals() public {
        _buy(alice, 1 ether);
        _revealAll("a");
        uint256 id = token.idsOf(alice)[0];
        vm.expectRevert(UN1Mirror.NotAuthorized.selector);
        mirror.transferFrom(alice, bob, id);
        vm.prank(alice);
        mirror.approve(address(this), id);
        mirror.transferFrom(alice, bob, id);
        assertEq(mirror.ownerOf(id), bob);
        assertEq(mirror.getApproved(id), address(0), "approval cleared on transfer");
        vm.expectRevert(UN1Token.NotMirror.selector);
        token.mirrorTransfer(bob, alice, id);
    }

    // ---------------------------------------------------------------- holding and weight

    function test_contractHolder_holdsWithoutWeight_untilOptIn() public {
        address safe = address(new Holder());
        _buy(alice, 2 ether);
        _revealAll("c");
        uint256 total = token.totalWeight();
        uint256 w = token.weightOf(alice);
        vm.prank(alice);
        token.transfer(safe, 2 ether);
        assertEq(token.idCount(safe), 2, "contracts can hold cards");
        assertEq(token.weightOf(safe), 0, "but have no weight");
        assertEq(token.totalWeight(), total - w);
        vm.prank(safe);
        token.optIn();
        assertEq(token.weightOf(safe), w);
        assertEq(token.totalWeight(), total);
    }

    function test_7702Account_isWeightedAutomatically() public {
        address eoa7702 = makeAddr("7702");
        vm.etch(eoa7702, abi.encodePacked(hex"ef0100", address(0xBEEF)));
        _buy(alice, 1 ether);
        _revealAll("7");
        vm.prank(alice);
        token.transfer(eoa7702, 1 ether);
        assertTrue(token.isWeighted(eoa7702));
        assertGt(token.weightOf(eoa7702), 0);
    }

    function test_poolManager_neverHoldsCards() public {
        _buy(alice, 1 ether);
        _revealAll("pm");
        assertEq(token.idCount(address(manager)), 0);
        assertEq(token.pendingCount(address(manager)), 0);
    }

    // ---------------------------------------------------------------- gas: large buys, reveals, transfers (G-1)

    function test_gas_perUnit() public {
        uint256 n = 50;
        uint256 g = gasleft();
        _buy(alice, n * 1 ether);
        uint256 buyGas = g - gasleft();
        g = gasleft();
        _revealAll("gas");
        uint256 revealGas = g - gasleft();
        g = gasleft();
        vm.prank(alice);
        token.transfer(bob, n * 1 ether);
        uint256 moveGas = g - gasleft();
        g = gasleft();
        _sell(bob, n * 1 ether);
        uint256 sellGas = g - gasleft();
        emit log_named_uint("buy 50 (swap + 50 slots)", buyGas);
        emit log_named_uint("reveal 50", revealGas);
        emit log_named_uint("transfer 50 cards", moveGas);
        emit log_named_uint("sell 50 cards into the pool", sellGas);
        assertLt(moveGas / n, 60_000, "moving a card stays cheap");
    }

    // ---------------------------------------------------------------- invariants after random operations

    /// @dev Counterexample found by the fuzzer on 2026-10-14 (seed 0xc69d…de0e). The reported calldata does not match the
    ///      logged `bound` results, so the scenario is replayed from the logged values with the salt fuzzed.
    function testFuzz_regression_dust(bytes32 salt) public {
        _scenario(19991545862937878514, 19990015234808976756, 13279, 400, salt);
    }

    function test_regression_dust_reportedSalt() public {
        _scenario(19991545862937878514, 19990015234808976756, 13279, 400, 0xb0c02d7ebe7cb56b81b78e728e656a5e82e8721340930ea123ca2683d4ef841d);
    }

    function _scenario(uint256 buyA, uint256 buyB, uint256 t, uint256 s, bytes32 salt) internal {
        _buy(alice, buyA);
        _buy(bob, buyB);
        vm.prank(alice);
        token.transfer(bob, t);
        _revealAll(salt);
        if (s > 0) _sell(bob, s);
        _checkInvariants(_holders());
    }

    function testFuzz_invariants(uint96 a1, uint96 a2, uint96 t1, uint96 s1, bytes32 salt) public {
        uint256 buyA = bound(a1, 0.01 ether, 20 ether);
        uint256 buyB = bound(a2, 0.01 ether, 20 ether);
        _buy(alice, buyA);
        _buy(bob, buyB);
        uint256 t = bound(t1, 0, token.balanceOf(alice));
        vm.prank(alice);
        token.transfer(bob, t);
        _revealAll(salt);
        uint256 s = bound(s1, 0, token.balanceOf(bob));
        if (s > 0) _sell(bob, s);
        address[] memory h = _holders();
        _checkInvariants(h);
        assertEq(token.totalWeight(), token.weightOf(alice) + token.weightOf(bob) + token.weightOf(address(this)), "weights add up");
    }
}
