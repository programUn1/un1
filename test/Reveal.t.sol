// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UN1Beacon} from "../src/UN1Beacon.sol";
import {DrandBeacon} from "../src/libraries/DrandBeacon.sol";
import {DrandRound} from "../src/libraries/DrandRound.sol";
import {Base} from "./utils/Base.sol";

/// @dev EIP-2935 stand-in for the local chain: hash(n) = keccak256(n).
contract HistoryMock {
    fallback(bytes calldata data) external returns (bytes memory) {
        return abi.encode(keccak256(abi.encode(abi.decode(data, (uint256)))));
    }
}

/// @notice Reveal, with real drand quicknet signatures (api.drand.sh, chain 52db9ba7…, decompressed to the form the beacon verifies).
contract RevealTest is Base {
    // round 20,000,000 (a multiple of 10: a bucket round)
    uint64 constant R = 20_000_000;
    bytes constant SIG_R =
        hex"0000000000000000000000000000000016892582a33552a7b67ba44ef09c3ccd535bbebe760c93ecf45be8958d0c0f06390c6d19d7bf492eb806af7eef6b125c000000000000000000000000000000000a37c6379b6195ff2eecdcd2c96be15f7660c663d1263b1ae5da70b6f1052bcddd07e01e6cad165d3ef383334c0ff765";
    bytes constant SIG_1M =
        hex"0000000000000000000000000000000003ad29e4c409f9470fc2ef02f90214df49e02b441a1a241a82d622d9f608ef98fd8b11a029f1bee9d9e83b45088abe720000000000000000000000000000000001776ff7408b39c5f6f9fa50746efd7eea17fbb61f2e7b9c849ff0528e5a3deeedd029d0df345199963d75ba93b5a02a";
    bytes constant SIG_1M10 =
        hex"000000000000000000000000000000000ae9d908a11b3a7507857f15085c535aeac5bfa572ec715d95022704b485cbf79f62c89d1aadddbffa50ea0f056f2d7f0000000000000000000000000000000000483eab92e2de9af2e35ec2d8a0073b629f21a89d9a454cee178bc415caafe3d73b136d7c9a65bdd11833ab06ce967e";

    // a buy at this time targets round R: roundAt(T_BUY + 15) = 19,999,995, rounded up to the bucket = 20,000,000
    uint256 constant T_BUY = 1_752_803_334;
    address payee = makeAddr("bot");

    function _startTime() internal pure override returns (uint256) {
        return T_BUY - 5 minutes - 1; // launch protection is over by the buy
    }

    function setUp() public override {
        super.setUp();
        vm.warp(T_BUY);
    }

    function _toRoundTime() internal {
        vm.warp(DrandRound.roundTime(R));
    }

    // ---------------------------------------------------------------- signatures (Temo's DrandBeacon)

    function test_verify_realSignatures() public view {
        assertTrue(DrandBeacon.verify(1_000_000, SIG_1M));
        assertTrue(DrandBeacon.verify(1_000_010, SIG_1M10));
        assertTrue(DrandBeacon.verify(R, SIG_R));
        assertFalse(DrandBeacon.verify(1_000_001, SIG_1M), "wrong round");
        assertFalse(DrandBeacon.verify(1_000_000, SIG_1M10), "another round's signature");
    }

    function test_verify_gas() public {
        uint256 g = gasleft();
        DrandBeacon.verify(R, SIG_R);
        emit log_named_uint("drand verify gas", g - gasleft());
    }

    // ---------------------------------------------------------------- reveal

    function test_buy_targetsTheBucketRound() public {
        _buy(alice, 2 ether);
        (, uint64 round,) = token.slotOf(0);
        assertEq(round, R);
        assertEq(token.lastBlockOf(R), block.number);
    }

    function test_reveal_withRealSignature() public {
        _buy(alice, 2 ether);
        _buy(bob, 1 ether);
        _toRoundTime();
        uint256 done = beacon.reveal(R, SIG_R, 10, payee);
        assertEq(done, 3);
        assertEq(token.idCount(alice), 2);
        assertEq(token.idCount(bob), 1);
        assertEq(token.pendingCount(alice) + token.pendingCount(bob), 0);
    }

    function test_reveal_resultIsFixedBySignature_notByCaller() public {
        _buy(alice, 3 ether);
        _toRoundTime();
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        beacon.reveal(R, SIG_R, 10, alice);
        uint256[] memory a = token.idsOf(alice);
        vm.revertToState(snap);
        vm.prank(bob);
        beacon.reveal(R, SIG_R, 10, bob);
        uint256[] memory b = token.idsOf(alice);
        for (uint256 i; i < 3; ++i) assertEq(a[i], b[i], "same cards whoever delivers the signature");
    }

    function test_reveal_rejectsBadInput() public {
        _buy(alice, 1 ether);
        vm.expectRevert(UN1Beacon.TooEarly.selector);
        beacon.reveal(R, SIG_R, 10, payee);
        _toRoundTime();
        vm.expectRevert(UN1Beacon.BadSignature.selector);
        beacon.reveal(R, SIG_1M, 10, payee);
        vm.expectRevert(UN1Beacon.NothingToReveal.selector);
        beacon.reveal(1_000_000, SIG_1M, 10, payee); // valid signature, no slot in that round
    }

    function test_reveal_cannotSkipAnEarlierRound() public {
        _buy(alice, 1 ether); // round R
        vm.warp(T_BUY + 30);
        _buy(bob, 1 ether); // round R + 10
        (, uint64 later,) = token.slotOf(1);
        assertEq(later, R + 10);
        _toRoundTime();
        assertEq(beacon.reveal(R, SIG_R, 10, payee), 1, "R first, only its slot");
        assertEq(token.pendingCount(bob), 1, "R + 10 waits for its own signature");
    }

    // ---------------------------------------------------------------- bounty (paid from the developer fee)

    /// @dev Nominal bounty: a base once per round plus an amount per slot (when the round's buys paid enough dev fee).
    function test_bounty_baseOncePerRound_plusPerSlot() public {
        uni.mint(address(beacon), 10 ether); // a funded reserve
        _buy(alice, 3 ether);
        vm.mockCall(address(hook), abi.encodeCall(hook.devFeeOf, (R)), abi.encode(1 ether)); // a busy round
        _toRoundTime();
        beacon.reveal(R, SIG_R, 2, payee);
        assertEq(uni.balanceOf(payee), 0.05 ether + 2 * 0.01 ether, "base + 2 slots");
        beacon.reveal(R, SIG_R, 10, payee);
        assertEq(uni.balanceOf(payee), 0.05 ether + 3 * 0.01 ether, "no second base for the same round");
        assertEq(beacon.paidOf(R), 0.08 ether);
    }

    /// @dev Audit K-3: a round never pays more than the dev fee its own buys paid, across all its reveal calls.
    function test_bounty_cappedByTheDevFeeOfTheRoundsBuys() public {
        uni.mint(address(beacon), 10 ether);
        _buy(alice, 3 ether);
        uint256 budget = hook.devFeeOf(R);
        assertGt(budget, 0, "the hook records the dev fee of the buys targeting R");
        _toRoundTime();
        beacon.reveal(R, SIG_R, 2, payee);
        uint256 nominal = 0.05 ether + 2 * 0.01 ether;
        assertEq(uni.balanceOf(payee), budget < nominal ? budget : nominal);
        beacon.reveal(R, SIG_R, 10, payee);
        assertLe(uni.balanceOf(payee), budget, "never more than the round's buys paid");
        assertEq(beacon.paidOf(R), uni.balanceOf(payee));
    }

    /// @dev Audit K-3: opening a slot only to reveal it yourself does not pay: the bounty is at most the dev fee you paid,
    ///      a ninth of the 2.7% fee on the buy alone.
    function test_bounty_selfMadeRound_neverPaysMoreThanItsFees() public {
        uni.mint(address(beacon), 10 ether);
        uint256 before = uni.balanceOf(alice);
        _buy(alice, 1 ether);
        uint256 paid = before - uni.balanceOf(alice); // price + all fees
        _toRoundTime();
        vm.prank(alice);
        beacon.reveal(R, SIG_R, 10, alice);
        uint256 bounty = uni.balanceOf(alice) - (before - paid);
        assertLe(bounty, hook.devFeeOf(R));
        assertLe(bounty * 1000, paid * 3 + 1000, "at most 0.3% of what the buy cost");
    }

    function test_bounty_sellsDoNotFundRounds() public {
        _buy(alice, 5 ether);
        uint256 budget = hook.devFeeOf(R);
        _sell(alice, 2 ether);
        assertEq(hook.devFeeOf(R), budget);
    }

    function test_bounty_comesFromDevFee_andIsCapped() public {
        _buy(alice, 20 ether);
        uint256 reserve = hook.owed(address(beacon));
        assertGt(reserve, 0, "the dev fee tops up the bounty reserve");
        assertEq(hook.owed(DEV), 0, "until the reserve is full");
        _toRoundTime();
        beacon.reveal(R, SIG_R, 64, payee);
        uint256 due = 0.05 ether + 20 * 0.01 ether;
        uint256 budget = hook.devFeeOf(R);
        uint256 cap = reserve < budget ? reserve : budget;
        assertEq(uni.balanceOf(payee), cap < due ? cap : due, "paid what the reserve and the round's budget allow");
    }

    function test_bountyReserve_capThenDev() public {
        assertEq(hook.BOUNTY_RESERVE(), 50 ether);
        // enough volume for more than 50 UNI of dev fee: 0.3% of ~29,000 UNI ≈ 87 UNI
        modifyLiquidityRouter.modifyLiquidity(officialKey, _range(20_000 ether), ZERO_BYTES); // deep enough for 500 UNI
        for (uint256 i; i < 30; ++i) {
            vm.roll(block.number + 1);
            _swap(officialKey, true, -500 ether);
            _swap(officialKey, false, int256(450 ether));
        }
        assertEq(hook.owed(address(beacon)), 50 ether, "reserve capped");
        assertGt(hook.owed(DEV), 0, "the rest goes to the dev");
    }

    // ---------------------------------------------------------------- one-day fallback (EIP-2935)

    function test_fallback_onlyAfterOneDay() public {
        vm.etch(beacon.HISTORY(), address(new HistoryMock()).code);
        _buy(alice, 2 ether);
        _toRoundTime();
        vm.expectRevert(UN1Beacon.TooEarly.selector);
        beacon.revealFallback(R, 10, payee);

        vm.warp(DrandRound.roundTime(R) + 1 days);
        vm.roll(block.number + 7_200);
        assertEq(beacon.revealFallback(R, 10, payee), 2);
        assertEq(token.idCount(alice), 2);
    }

    function test_fallback_needsTheBlockHash() public {
        _buy(alice, 1 ether);
        vm.warp(DrandRound.roundTime(R) + 1 days);
        vm.roll(block.number + 7_200); // beyond 256 blocks and no EIP-2935 history on this chain
        vm.expectRevert(UN1Beacon.NoBlockHash.selector);
        beacon.revealFallback(R, 10, payee);
    }

    // ---------------------------------------------------------------- gas

    function test_reveal_gas() public {
        _buy(alice, 1 ether);
        _buy(bob, 20 ether);
        _toRoundTime();
        uint256 g = gasleft();
        beacon.reveal(R, SIG_R, 1, payee);
        emit log_named_uint("reveal 1 slot (verify + measure + bounty)", g - gasleft());
        g = gasleft();
        beacon.reveal(R, SIG_R, 20, payee);
        emit log_named_uint("reveal 20 more slots", g - gasleft());
    }
}
