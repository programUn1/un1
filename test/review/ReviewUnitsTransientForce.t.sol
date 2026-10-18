// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Base} from "../utils/Base.sol";
import {UN1Token} from "../../src/UN1Token.sol";
import {UN1Mirror} from "../../src/UN1Mirror.sol";

/// @dev Two ordinary attacker-controlled accounts. No privileged calls or storage edits.
contract ReviewUnitsActor {
    function selfTransfer(UN1Mirror mirror, uint256 id) external {
        mirror.transferFrom(address(this), address(this), id);
    }

    function send(UN1Token token, address to, uint256 amount) external {
        token.transfer(to, amount);
    }
}

/// @notice Review R-01 (docs/reviews/gpt-review.md). The reproduction asserted the bug; after the fix (2026-10-15) the
///         same sequence must leave every card with its real owner.
contract ReviewUnitsTransientForceTest is Base {
    function _parts(uint8 m) private pure returns (uint256 count) {
        while (m != 0) {
            m &= m - 1;
            ++count;
        }
    }

    function _sameBucketPair() private view returns (uint256 a, uint256 b) {
        uint256[] memory ids = token.idsOf(alice);
        for (uint256 i; i < ids.length; ++i) {
            (, uint8 mi,,) = token.cardOf(ids[i]);
            for (uint256 j = i + 1; j < ids.length; ++j) {
                (, uint8 mj,,) = token.cardOf(ids[j]);
                if (_parts(mi) == _parts(mj)) return (ids[i], ids[j]);
            }
        }
        revert("no pair");
    }

    /// @notice An ERC721 self-transfer leaves nothing behind: the next transfer in the same transaction, from another
    ///         account, moves that account's own card.
    function test_Review_selfTransferDoesNotLeakIntoAnotherAccountsTransfer() public {
        _skipOpening();
        _buy(alice, 12 ether);
        _revealAll("independent-units-review");
        (uint256 a, uint256 b) = _sameBucketPair();
        ReviewUnitsActor first = new ReviewUnitsActor();
        ReviewUnitsActor second = new ReviewUnitsActor();
        address innocent = makeAddr("innocent buyer");

        vm.startPrank(alice);
        mirror.transferFrom(alice, address(first), a);
        mirror.transferFrom(alice, address(second), b);
        vm.stopPrank();

        // the same calls as the reproduction, in one transaction
        first.selfTransfer(mirror, a);
        second.send(token, innocent, 1 ether);

        assertEq(token.ownerOfId(a), address(first), "the self-transferred card stays put");
        assertEq(token.ownerOfId(b), innocent, "the sender's own card moved");
        assertEq(token.idCount(address(second)), 0);
        assertEq(token.idsOf(address(first)).length, 1);
        assertEq(token.idsOf(address(first))[0], a);
        assertEq(token.idsOf(innocent)[0], b);

        address thief = makeAddr("thief");
        first.send(token, thief, 1 ether);
        assertEq(token.ownerOfId(a), thief, "first can move only its own card");
        assertEq(token.ownerOfId(b), innocent, "the innocent holder keeps its card");
        assertEq(token.idCount(address(first)), 0);

        address[] memory holders = new address[](5);
        (holders[0], holders[1], holders[2], holders[3], holders[4]) = (address(first), address(second), innocent, thief, alice);
        _checkInvariants(holders);
    }

    /// @notice ERC721: a self-transfer clears the token approval and emits Transfer(from, from, id).
    function test_Review_mirrorSelfTransferClearsTokenApproval() public {
        _skipOpening();
        _buy(alice, 1 ether);
        _revealAll("independent-self-approval");
        uint256 id = token.idsOf(alice)[0];
        vm.startPrank(alice);
        mirror.approve(bob, id);
        vm.recordLogs();
        mirror.transferFrom(alice, alice, id);
        vm.stopPrank();
        assertEq(mirror.getApproved(id), address(0), "approval cleared");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(mirror) && logs[i].topics[0] == UN1Mirror.Transfer.selector) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), alice);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), alice);
                assertEq(uint256(logs[i].topics[3]), id);
                seen = true;
            }
        }
        assertTrue(seen, "Transfer(alice, alice, id)");
        assertEq(token.ownerOfId(id), alice);
        assertEq(token.balanceOf(alice), 1 ether);
    }
}
