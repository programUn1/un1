// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "../utils/Base.sol";
import {HistoryMock} from "../Reveal.t.sol";
import {UN1Beacon} from "../../src/UN1Beacon.sol";
import {DrandRound} from "../../src/libraries/DrandRound.sol";

/// @notice Fourth-review frontend recovery boundary: the beacon's maximum batch size is not a gas guarantee.
///         The bitmap fixture leaves ids 1..64 available, as in Findings / ReviewDealFairness; it does not construct
///         the ownership history of the other 9,936 ids. Purchases and beacon calls use the real local contracts,
///         with HistoryMock supplying the fallback hash. The UI must estimate and shrink batches in sparse pools.
contract ReviewSparseBatchTest is Base {
    function test_sparsePool_largeBatchExceedsBudget_smallBatchesFinish() public {
        _skipOpening();
        _buy(alice, 64 ether);
        (, uint64 round,) = token.slotOf(0);
        for (uint256 w; w < 40; ++w) {
            uint256 taken = w == 0 ? type(uint256).max << 64 : type(uint256).max;
            vm.store(address(token), bytes32(16 + w), bytes32(taken));
        }
        vm.store(address(token), bytes32(uint256(56)), bytes32(uint256(64)));
        vm.etch(beacon.HISTORY(), address(new HistoryMock()).code);
        vm.roll(block.number + 7200);
        vm.warp(DrandRound.roundTime(round) + 1 days);

        vm.cool(address(token));
        (bool ok,) = address(beacon).call{gas: 16_777_216}(
            abi.encodeCall(UN1Beacon.revealFallback, (round, 64, alice))
        );
        assertFalse(ok, "max64 exceeds the transaction budget in this sparse pool");
        assertEq(token.slotHead(), 0, "failed batch makes no progress");

        vm.cool(address(token));
        uint256 snap = vm.snapshotState();
        uint256 beforeGas = gasleft();
        assertEq(beacon.revealFallback(round, 64, alice), 64);
        emit log_named_uint("uncapped gas for 64 sparse pool slots", beforeGas - gasleft());
        assertTrue(vm.revertToState(snap));

        for (uint256 batch; batch < 16; ++batch) {
            vm.cool(address(token));
            assertEq(beacon.revealFallback{gas: 16_777_216}(round, 4, alice), 4);
            assertEq(token.slotHead(), (batch + 1) * 4, "each bounded batch advances");
        }
        assertEq(token.poolCount(), 0);
        assertEq(token.pendingCount(alice), 0);
        assertEq(token.idCount(alice), 64);
    }
}
