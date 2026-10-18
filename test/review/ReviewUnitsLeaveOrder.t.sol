// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "../utils/Base.sol";

/// @notice Independent checks for the documented transfer order, whole-token backing and component inheritance.
contract ReviewUnitsLeaveOrderTest is Base {
    /// @notice docs/02-TIMELINE section 4 says setOutFirst selects cards before pending slots, but code sends pending first.
    function test_Review_outFirstDoesNotPrecedePendingSlots() public {
        _skipOpening();
        _buy(alice, 2 ether);
        _revealAll("independent-leave-order");
        uint256 chosen = token.idsOf(alice)[0];
        _buy(alice, 1 ether);
        uint32[] memory preferred = new uint32[](1);
        preferred[0] = uint32(chosen);
        vm.startPrank(alice);
        token.setOutFirst(preferred);
        token.transfer(bob, 1 ether);
        vm.stopPrank();

        assertEq(token.ownerOfId(chosen), alice, "chosen card did not leave");
        assertEq(token.pendingCount(bob), 1, "pending slot left instead");
        assertEq(token.outFirstOf(alice)[0], chosen, "preference remains to affect a later transfer");
    }

    /// @notice A per-token approval on keep still authorizes all newly merged components, including those from other.
    ///         The project already acknowledges this risk (K-6); this reproduces the subsequent theft, not just approval state.
    function test_Review_oldApprovalCanTakeNewlyComposedComponents() public {
        _skipOpening();
        _buy(alice, 12 ether);
        _revealAll("independent-compose-approval");
        uint256[] memory ids = token.idsOf(alice);
        uint256 keep;
        uint256 other;
        for (uint256 i; i < ids.length && other == 0; ++i) {
            (, uint8 mi,,) = token.cardOf(ids[i]);
            for (uint256 j = i + 1; j < ids.length; ++j) {
                (, uint8 mj,,) = token.cardOf(ids[j]);
                if (mi & mj == 0) {
                    keep = ids[i];
                    other = ids[j];
                    break;
                }
            }
        }
        require(other != 0, "no disjoint pair");
        (, uint8 maskOther,,) = token.cardOf(other);
        vm.prank(alice);
        mirror.approve(bob, keep);
        uint256 nonce;
        while (uint256(token.proofDigest(alice, keep, other, nonce)) >> (256 - token.PROOF_BITS()) != 0) ++nonce;
        vm.prank(alice);
        token.compose(keep, other, nonce);
        vm.prank(bob);
        mirror.transferFrom(alice, bob, keep);
        (address owner, uint8 combined, uint8 layers,) = token.cardOf(keep);
        assertEq(owner, bob);
        assertGt(layers, 1);
        assertEq(combined & maskOther, maskOther, "old approval covers the formerly unapproved components");
        assertEq(token.retiredInto(other), keep);
    }
}
