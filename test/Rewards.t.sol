// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UN1Token} from "../src/UN1Token.sol";
import {UN1Distributor} from "../src/UN1Distributor.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Base} from "./utils/Base.sol";

contract SafeLike {} // a contract wallet without the 7702 prefix

/// @notice Rewards: 7/8 to holders (streamed over one day, exact accumulator), 1/8 to the permanent liquidity reserve.
///  The core identity (exact to 1e-18 UNI, no approximation):
///    deposits × 1e18 = Σ holders' accrued (claimed included) + not yet distributed (remaining stream + carry + division remainders)
contract RewardsTest is Base {
    using PoolIdLibrary for PoolKey;

    address safe;

    function setUp() public override {
        super.setUp();
        _skipOpening();
        safe = address(new SafeLike());
    }

    function _accounts() internal view returns (address[] memory a) {
        a = new address[](4);
        a[0] = alice;
        a[1] = bob;
        a[2] = address(this);
        a[3] = safe;
    }

    /// @dev Fees from the launch holder's naked tokens: no cards move, no weight for anyone.
    function _volume(uint256 rounds) internal {
        for (uint256 i; i < rounds; ++i) {
            _swap(officialKey, false, -20 ether);
            _swap(officialKey, true, 20 ether);
        }
    }

    function _conservation() internal view {
        address[] memory a = _accounts();
        uint256 credited = distributor.totalClaimed() * 1e18;
        for (uint256 i; i < a.length; ++i) credited += token.accruedX18(a[i]);
        assertEq(credited + token.undistributedX18(), distributor.totalFunded() * 1e18, "exact conservation");
    }

    function _claim(address who) internal returns (uint256) {
        vm.prank(who);
        return distributor.claim();
    }

    // ---------------------------------------------------------------- 7/8 and 1/8

    function test_sync_splitsSevenEighthsToHolders() public {
        _volume(5);
        uint256 owed = hook.owed(DISTRIBUTOR);
        assertGt(owed, 0);
        (uint256 holders, uint256 reserve) = distributor.sync();
        assertEq(holders, owed * 7 / 8);
        assertEq(reserve, owed - holders);
        assertEq(distributor.totalFunded(), holders);
        assertEq(distributor.reserve(), reserve);
        assertEq(uni.balanceOf(address(distributor)), owed);
        (uint256 h2,) = distributor.sync();
        assertEq(h2, 0, "nothing new, nothing streamed twice");
    }

    // ---------------------------------------------------------------- one-day stream

    function test_singleHolder_linearOverOneDay() public {
        _buy(alice, 4 ether);
        _revealAll("a");
        _volume(5);
        (uint256 funded,) = distributor.sync();

        vm.warp(block.timestamp + 12 hours);
        assertApproxEqAbs(token.earned(alice), funded / 2, 1, "half after half a day");
        _conservation();

        vm.warp(block.timestamp + 12 hours);
        uint256 uniBefore = uni.balanceOf(alice);
        uint256 got = _claim(alice);
        assertEq(uni.balanceOf(alice) - uniBefore, got, "paid what was claimed");
        assertLe(got, funded);
        assertGe(got + 1, funded, "everything after one day, at most 1 wei of dust");
        vm.warp(block.timestamp + 30 days);
        assertEq(token.earned(alice), 0, "the stream is over");
        _conservation();
    }

    function test_twoHolders_proportionalToWeightAndTime() public {
        _buy(alice, 6 ether);
        _buy(bob, 2 ether);
        _revealAll("b");
        uint256 wa = token.weightOf(alice);
        uint256 wb = token.weightOf(bob);
        _volume(5);
        (uint256 funded,) = distributor.sync();
        vm.warp(block.timestamp + 1 days);
        uint256 ea = token.earned(alice);
        uint256 eb = token.earned(bob);
        assertApproxEqAbs(ea, funded * wa / (wa + wb), 2);
        assertApproxEqAbs(eb, funded * wb / (wa + wb), 2);
        _conservation();
    }

    function test_lateJoiner_earnsOnlyFromJoining() public {
        _buy(alice, 4 ether);
        _revealAll("c");
        _volume(5);
        (uint256 funded,) = distributor.sync();
        vm.warp(block.timestamp + 12 hours);
        uint256 aliceHalf = token.earned(alice);
        _buy(bob, 4 ether); // pending slots weigh 1 each from now
        uint256 wa = token.weightOf(alice);
        uint256 wb = token.weightOf(bob);
        vm.warp(block.timestamp + 12 hours);
        assertApproxEqAbs(token.earned(bob), (funded - aliceHalf) * wb / (wa + wb), 2);
        assertApproxEqAbs(token.earned(alice), aliceHalf + (funded - aliceHalf) * wa / (wa + wb), 2);
        _conservation();
    }

    function test_buyAndSellInOneBlock_earnsNothing() public {
        _buy(alice, 4 ether);
        _revealAll("d");
        _volume(5);
        distributor.sync();
        vm.warp(block.timestamp + 1 hours);
        _buy(bob, 10 ether);
        _sell(bob, token.balanceOf(bob));
        assertEq(token.earned(bob), 0);
        assertEq(token.accruedX18(bob), 0, "not even dust: time did not move");
        _conservation();
    }

    function test_settlesBeforeEveryWeightChange() public {
        _buy(alice, 4 ether);
        _revealAll("e");
        _volume(5);
        (uint256 funded,) = distributor.sync();
        vm.warp(block.timestamp + 6 hours);
        uint256 before = token.earned(alice);
        vm.prank(alice);
        token.transfer(bob, 2 ether); // weight leaves alice
        assertEq(token.earned(alice), before, "what alice earned so far stays hers");
        vm.warp(block.timestamp + 18 hours);
        assertLe(token.earned(alice) + token.earned(bob), funded);
        assertGe(token.earned(alice) + token.earned(bob) + 2, funded);
        _conservation();
    }

    // ---------------------------------------------------------------- contract wallets and periods with no holder

    function test_contractWallet_earnsOnlyAfterOptIn() public {
        _buy(alice, 4 ether);
        _revealAll("f");
        vm.prank(alice);
        token.transfer(safe, 2 ether);
        _volume(5);
        (uint256 funded,) = distributor.sync();
        vm.warp(block.timestamp + 12 hours);
        assertEq(token.earned(safe), 0, "no weight before optIn");
        vm.prank(safe);
        token.optIn();
        vm.warp(block.timestamp + 12 hours);
        assertGt(token.earned(safe), 0);
        assertLe(token.earned(alice) + token.earned(safe), funded);
        assertGe(token.earned(alice) + token.earned(safe) + 2, funded);
        _conservation();
    }

    function test_noWeight_isCarried_thenStreamed() public {
        _volume(5); // nobody holds weight yet
        (uint256 first,) = distributor.sync();
        vm.warp(block.timestamp + 1 days);
        _conservation();
        assertEq(token.undistributedX18(), first * 1e18, "the whole first stream is carried");

        _buy(alice, 2 ether);
        _revealAll("g");
        _volume(5);
        (uint256 second,) = distributor.sync();
        vm.warp(block.timestamp + 1 days);
        assertGe(token.earned(alice) + 1, first + second, "carry re-streamed with the next deposit");
        _conservation();
    }

    function test_newDeposit_rollsTheRestOfTheStream() public {
        _buy(alice, 2 ether);
        _revealAll("h");
        _volume(5);
        (uint256 a,) = distributor.sync();
        vm.warp(block.timestamp + 6 hours);
        _volume(5);
        (uint256 b,) = distributor.sync();
        assertEq(token.periodFinish(), block.timestamp + 1 days, "one day from the latest deposit");
        vm.warp(block.timestamp + 1 days);
        assertGe(token.earned(alice) + 1, a + b);
        assertLe(token.earned(alice), a + b);
        _conservation();
    }

    // ---------------------------------------------------------------- claims

    function test_claimFor_paysEachAccountToItself_aboveThreshold() public {
        _buy(alice, 4 ether);
        _buy(bob, 1 ether);
        _revealAll("i");
        _volume(5);
        distributor.sync();
        vm.warp(block.timestamp + 1 days);
        uint256 eb = token.earned(bob);
        uint256 ea = token.earned(alice);
        address[] memory list = new address[](2);
        list[0] = alice;
        list[1] = bob;
        uint256 uniA = uni.balanceOf(alice);
        uint256 uniB = uni.balanceOf(bob);
        distributor.claimFor(list, eb + 1); // bob below the threshold
        assertEq(uni.balanceOf(alice) - uniA, ea);
        assertEq(uni.balanceOf(bob), uniB, "below the threshold: skipped");
        assertEq(token.earned(alice), 0);
        _conservation();
    }

    // ---------------------------------------------------------------- 1/8: permanent bids below the price

    function _fundReserve() internal returns (uint256 reserve) {
        _volume(40);
        (, reserve) = distributor.sync();
    }

    function test_deployReserve_placesUniOnlyBidsBelowThePrice() public {
        uint256 reserve = _fundReserve();
        uint256 pmTokens = token.balanceOf(address(manager));
        (, int24 tick,,) = StateLibrary.getSlot0(manager, officialKey.toId());
        uint256 balBefore = uni.balanceOf(address(distributor));

        (uint256 used, int24 lower, int24 upper, uint128 liquidity) = distributor.deployReserve();

        assertGt(liquidity, 0);
        assertLe(used, reserve < 250 ether ? reserve : 250 ether, "capped batch");
        assertEq(distributor.reserve(), reserve - used);
        assertEq(balBefore - uni.balanceOf(address(distributor)), used, "only UNI left the distributor");
        assertEq(token.balanceOf(address(manager)), pmTokens, "no token needed: out of range");
        if (uniIs0) {
            assertGe(lower, tick + 600, "token price band below: ticks above when UNI is currency0");
        } else {
            assertLe(upper, tick - 600, "band starts at least ~6% below the price");
        }
        uint128 posL = StateLibrary.getPositionLiquidity(
            manager, officialKey.toId(), Position.calculatePositionKey(address(distributor), lower, upper, bytes32(uint256(0)))
        );
        assertEq(posL, liquidity, "the position belongs to the distributor, which cannot remove it");
        assertEq(
            uni.balanceOf(address(distributor)),
            distributor.totalFunded() - distributor.totalClaimed() + distributor.reserve(),
            "accounting still balances"
        );
    }

    function test_deployReserve_hourlyAndNeedsReserve() public {
        vm.expectRevert(UN1Distributor.NothingToDeploy.selector);
        distributor.deployReserve();
        _fundReserve();
        distributor.deployReserve();
        vm.expectRevert(UN1Distributor.TooSoon.selector);
        distributor.deployReserve();
        vm.warp(block.timestamp + 1 hours);
        if (distributor.reserve() > 2) distributor.deployReserve();
    }

    function test_reserve_buysWhenThePriceFalls() public {
        _fundReserve();
        uint256 snap = vm.snapshotState();
        uint256 a = uni.balanceOf(address(this));
        _swap(officialKey, false, -300 ether); // a big sell without the bids
        uint256 without = uni.balanceOf(address(this)) - a;
        vm.revertToState(snap);
        distributor.deployReserve();
        a = uni.balanceOf(address(this));
        _swap(officialKey, false, -300 ether); // the same sell with the bids
        uint256 with_ = uni.balanceOf(address(this)) - a;
        assertGt(with_, without, "the permanent bids bought tokens on the way down");
    }

    function test_onlyDistributor() public {
        vm.expectRevert(UN1Token.NotDistributor.selector);
        token.notifyReward(1);
        vm.expectRevert(UN1Token.NotDistributor.selector);
        token.settleClaim(alice);
    }

    // ---------------------------------------------------------------- fuzzing: exact conservation in any order

    function testFuzz_exactConservation(uint64 seed) public {
        uint256 r = seed;
        for (uint256 step; step < 12; ++step) {
            r = uint256(keccak256(abi.encode(r)));
            uint256 op = r % 7;
            address who = r & 0x100 == 0 ? alice : bob;
            if (op == 0) _buy(who, bound(r >> 16, 0.5 ether, 6 ether));
            else if (op == 1 && token.balanceOf(who) > 0) _sell(who, bound(r >> 16, 1, token.balanceOf(who)));
            else if (op == 2 && token.balanceOf(who) > 0) {
                vm.prank(who);
                token.transfer(who == alice ? bob : alice, bound(r >> 16, 1, token.balanceOf(who)));
            } else if (op == 3) {
                _volume(1);
                distributor.sync();
            } else if (op == 4) {
                vm.warp(block.timestamp + bound(r >> 16, 1, 2 days));
            } else if (op == 5) {
                _claim(who);
            } else {
                _revealAll(bytes32(r));
            }
            _conservation();
        }
    }
}
