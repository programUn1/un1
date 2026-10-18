// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {UN1Token} from "../src/UN1Token.sol";
import {UN1Mirror} from "../src/UN1Mirror.sol";
import {Appearance} from "../src/libraries/Appearance.sol";
import {Base} from "./utils/Base.sol";

/// @notice Composition: only parts that do not overlap compose; one token burns, one id retires, the appearance locks, layers add up; the composition chain, the light proof, halving, and a work back in the pool losing its entanglement.
contract ComposeTest is Base {
    using stdStorage for StdStorage;

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

    /// @dev Find two of `who`'s cards with disjoint parts.
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

    function _overlappingPair(address who) internal view returns (uint256 a, uint256 b) {
        uint256[] memory ids = token.idsOf(who);
        for (uint256 i; i < ids.length; ++i) {
            for (uint256 j = i + 1; j < ids.length; ++j) {
                (, uint8 mi,,) = token.cardOf(ids[i]);
                (, uint8 mj,,) = token.cardOf(ids[j]);
                if (mi & mj != 0) return (ids[i], ids[j]);
            }
        }
        revert("no overlapping pair");
    }

    /// @dev What the browser does: search a nonce for the light proof.
    /// @dev The light proof, searched without allocating memory per try (an unlucky search can run long).
    function _mine(address who, uint256 keep, uint256 other) internal view returns (uint256 nonce) {
        uint256 shift = 256 - token.PROOF_BITS();
        bytes memory pre = abi.encodePacked(who, uint16(keep), uint16(other), uint256(0)); // 56 bytes, nonce last
        for (;; ++nonce) {
            bytes32 h;
            assembly ("memory-safe") {
                mstore(add(pre, 0x38), nonce)
                if iszero(staticcall(gas(), 0x02, add(pre, 0x20), 56, 0x00, 0x20)) { revert(0, 0) }
                h := mload(0x00)
            }
            if (uint256(h) >> shift == 0) return nonce;
        }
    }

    function _compose(address who, uint256 keep, uint256 other) internal returns (bytes32) {
        uint256 nonce = _mine(who, keep, other);
        vm.prank(who);
        return token.compose(keep, other, nonce);
    }

    function _cards(address who, uint256 n, bytes32 salt) internal {
        _buy(who, n * 1 ether);
        _revealAll(salt);
    }

    // ---------------------------------------------------------------- basic rules

    struct Before {
        uint256 keep;
        uint256 other;
        uint8 mk;
        uint8 mo;
        uint64 lk;
        uint64 lo;
        uint256 supply;
        uint256 balance;
        uint256 weight;
        bytes32 head;
    }

    function _before(address who, bytes32 salt) internal returns (Before memory s) {
        _cards(who, 10, salt);
        (s.keep, s.other) = _disjointPair(who);
        (, s.mk,, s.lk) = token.cardOf(s.keep);
        (, s.mo,, s.lo) = token.cardOf(s.other);
        s.supply = token.totalSupply();
        s.balance = token.balanceOf(who);
        s.weight = token.weightOf(who);
        s.head = token.chainHead();
    }

    function test_compose_keptCard_unionAndLockedLook() public {
        Before memory s = _before(alice, "c1");
        _compose(alice, s.keep, s.other);
        (address owner, uint8 mask, uint8 layers, uint64 look) = token.cardOf(s.keep);
        assertEq(owner, alice);
        assertEq(mask, s.mk | s.mo, "parts: union");
        assertEq(layers, 2, "two fragments, one compose");
        assertEq(look, Appearance.merge(s.lk, s.lo, s.mk), "each part keeps its own appearance");
        assertEq(Appearance.groundOf(look), Appearance.groundOf(s.lk), "the kept id's ground");
        assertEq(token.weightOf(alice), s.weight - token.cardWeight(s.mk, 1) - token.cardWeight(s.mo, 1) + token.cardWeight(mask, 2));
    }

    /// @dev Art v7: every part's 32-bit detail travels with the part; the retired id's details are cleared.
    function test_compose_detailsTravelWithTheirParts() public {
        Before memory s = _before(alice, "c1");
        uint256 dk = token.detailsOf(s.keep);
        uint256 dOther = token.detailsOf(s.other);
        assertTrue(dk != 0 && dOther != 0 && dk != dOther, "measured with the look");
        _compose(alice, s.keep, s.other);
        uint256 d = token.detailsOf(s.keep);
        assertEq(d, Appearance.mergeDetails(dk, dOther, s.mk));
        for (uint256 i; i < 8; ++i) {
            uint256 lane = (d >> (224 - 32 * i)) & 0xffffffff;
            if ((s.mk >> i) & 1 == 1) assertEq(lane, (dk >> (224 - 32 * i)) & 0xffffffff, "kept part keeps its detail");
            else if ((s.mo >> i) & 1 == 1) assertEq(lane, (dOther >> (224 - 32 * i)) & 0xffffffff, "a composed part brings its detail");
        }
        assertEq(token.detailsOf(s.other), 0, "the retired id's details are cleared");
    }

    function test_compose_retiresOther_burnsOne_advancesChain() public {
        Before memory s = _before(alice, "c1");
        bytes32 commitment = _compose(alice, s.keep, s.other);
        assertEq(token.ownerOfId(s.other), address(0));
        assertFalse(token.inPool(s.other), "retired, not back in the pool");
        assertEq(token.retiredInto(s.other), s.keep);
        assertEq(token.retiredCount(), 1);
        vm.expectRevert(UN1Mirror.NonexistentToken.selector);
        mirror.ownerOf(s.other);
        assertEq(token.totalSupply(), s.supply - 1 ether, "one token burned");
        assertEq(token.balanceOf(alice), s.balance - 1 ether);
        assertEq(token.idCount(alice), 9);
        assertEq(token.composeCount(), 1);
        assertEq(token.chainHead(), commitment, "the chain advanced");
        assertTrue(commitment != s.head);
        assertEq(token.commitmentOf(s.keep), commitment);
        _checkInvariants(_holders());
    }

    function test_compose_commitmentWrapsBothInputsAndTheHead() public {
        _cards(alice, 6, "c2");
        (uint256 keep, uint256 other) = _disjointPair(alice);
        bytes32 ck = token.commitmentOf(keep);
        bytes32 co = token.commitmentOf(other);
        bytes32 head = token.chainHead();
        uint256 nonce = _mine(alice, keep, other);
        bytes32 proof = token.proofDigest(alice, keep, other, nonce);
        vm.prank(alice);
        bytes32 c = token.compose(keep, other, nonce);
        assertEq(c, sha256(abi.encodePacked(ck, co, head, proof)));
    }

    function test_compose_rejects() public {
        _cards(alice, 12, "c3");
        (uint256 a, uint256 b) = _disjointPair(alice);
        (uint256 x, uint256 y) = _overlappingPair(alice);

        vm.prank(alice);
        vm.expectRevert(UN1Token.SameCard.selector);
        token.compose(a, a, 0);

        uint256 n = _mine(alice, x, y);
        vm.prank(alice);
        vm.expectRevert(UN1Token.PartsOverlap.selector);
        token.compose(x, y, n);

        n = _mine(bob, a, b);
        vm.prank(bob);
        vm.expectRevert(UN1Token.NotOwner.selector);
        token.compose(a, b, n);

        uint256 bad = _mine(alice, a, b) + 1;
        while (uint256(token.proofDigest(alice, a, b, bad)) >> (256 - 16) == 0) ++bad;
        vm.prank(alice);
        vm.expectRevert(UN1Token.BadProof.selector);
        token.compose(a, b, bad);
    }

    function test_compose_pendingSlotsCannotCompose() public {
        _buy(alice, 2 ether); // not revealed: no ids yet
        assertEq(token.idCount(alice), 0);
        vm.prank(alice);
        vm.expectRevert(UN1Token.NotOwner.selector);
        token.compose(1, 2, 0);
    }

    function test_proof_isNotBoundToTheChainHead() public {
        _cards(alice, 12, "c4");
        _cards(bob, 12, "c5");
        (uint256 a, uint256 b) = _disjointPair(alice);
        uint256 nonceA = _mine(alice, a, b); // mined before anyone else composes
        (uint256 c, uint256 d) = _disjointPair(bob);
        _compose(bob, c, d); // the head moves
        vm.prank(alice);
        token.compose(a, b, nonceA); // still valid (audit C-1)
        assertEq(token.composeCount(), 2);
    }

    function test_compose_ofWorks_layersAddUp() public {
        _cards(alice, 16, "c6");
        (uint256 a, uint256 b) = _disjointPair(alice);
        _compose(alice, a, b);
        // find another card disjoint with the work
        (, uint8 mw,,) = token.cardOf(a);
        uint256[] memory ids = token.idsOf(alice);
        uint256 c;
        for (uint256 i; i < ids.length; ++i) {
            (, uint8 m,,) = token.cardOf(ids[i]);
            if (ids[i] != a && m & mw == 0) {
                c = ids[i];
                break;
            }
        }
        require(c != 0, "no third card");
        _compose(alice, c, a); // keep the fragment's id this time; the work's id retires
        (, uint8 mask, uint8 layers,) = token.cardOf(c);
        assertEq(layers, 3);
        assertEq(token.retiredInto(a), c);
        (, uint8 mc,,) = token.cardOf(c);
        assertEq(mask, mc);
        assertEq(token.retiredCount(), 2);
        _checkInvariants(_holders());
    }

    // ---------------------------------------------------------------- a work back in the pool loses its entanglement (X-1)

    function test_workSoldIntoPool_fallsBackToItsOwnParts() public {
        _cards(alice, 4, "c7");
        (uint256 keep, uint256 other) = _disjointPair(alice);
        _compose(alice, keep, other);
        uint256 balance = token.balanceOf(alice);
        _sell(alice, balance); // everything, the work included
        (address owner, uint8 mask, uint8 layers, uint64 look) = token.cardOf(keep);
        assertEq(owner, address(0));
        assertTrue(token.inPool(keep));
        assertEq(mask, token.originalMask(keep), "back to its own parts");
        assertEq(layers, 1);
        assertEq(look, 0);
        assertEq(token.detailsOf(keep), 0, "the work's details are cleared too");
        assertEq(token.detailsOf(other), 0);
        assertEq(token.commitmentOf(keep), sha256(abi.encodePacked(token.BLOCKS_SHA256(), uint16(keep), token.originalMask(keep))));
        assertFalse(token.inPool(other), "the retired id never comes back");
        _checkInvariants(_holders());
    }

    function test_work_survivesWalletAndMirrorTransfers() public {
        _cards(alice, 4, "c8");
        (uint256 keep, uint256 other) = _disjointPair(alice);
        _compose(alice, keep, other);
        (, uint8 mask,, uint64 look) = token.cardOf(keep);
        vm.prank(alice);
        mirror.transferFrom(alice, bob, keep);
        (address owner, uint8 m2, uint8 l2, uint64 look2) = token.cardOf(keep);
        assertEq(owner, bob);
        assertEq(m2, mask);
        assertEq(l2, 2);
        assertEq(look2, look, "entangled appearance travels with the work");
    }

    function test_works_leaveLast() public {
        _cards(alice, 6, "c9");
        (uint256 keep, uint256 other) = _disjointPair(alice);
        _compose(alice, keep, other);
        uint256 cards = token.idCount(alice);
        _sell(alice, (cards - 1) * 1 ether); // all fragments
        assertEq(token.ownerOfId(keep), alice, "the work is the last to go");
    }

    // ---------------------------------------------------------------- halving

    function test_halving_followsComposeCount() public {
        assertEq(hook.halvingFee(), 21_000);
        stdstore.target(address(token)).sig("composeCount()").checked_write(uint256(2_100));
        assertEq(hook.halvingFee(), 10_500, "epoch 2");
        assertEq(hook.totalFee(), 16_500, "1.65%");
        stdstore.target(address(token)).sig("composeCount()").checked_write(uint256(6_300));
        assertEq(hook.halvingFee(), 2_625, "epoch 4");
    }

    function test_cardWeight_levelV() public view {
        assertEq(token.cardWeight(0xff, 2), 8 * (10_000 + 200 + 500), "#5099 + upper mane: 8.56");
        assertEq(token.cardWeight(0xff, 6), 8 * (10_000 + 1_000 + 500), "six fragments: 9.2");
        assertEq(token.cardWeight(0x0f, 1), 4 * 10_000, "a 4-part fragment weighs 4");
    }

    function test_compose_gas() public {
        _cards(alice, 6, "g");
        (uint256 keep, uint256 other) = _disjointPair(alice);
        uint256 nonce = _mine(alice, keep, other);
        vm.prank(alice);
        uint256 g = gasleft();
        token.compose(keep, other, nonce);
        emit log_named_uint("compose gas", g - gasleft());
    }
}
