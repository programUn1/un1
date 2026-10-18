// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {UN1Token} from "../src/UN1Token.sol";
import {UN1Hook} from "../src/UN1Hook.sol";
import {UN1ProtectionModule} from "../src/UN1ProtectionModule.sol";
import {FeeMath} from "../src/libraries/FeeMath.sol";
import {Base} from "./utils/Base.sol";
import {Fees} from "./utils/Fees.sol";

using Fees for UN1Hook;

/// @notice Programmable launch protection v1, applied to the UNI-quoted pool (docs/01-SPEC.md, 06-PREFLIGHT P-14):
///  - 5 minutes from pool creation; buys only through the canonical Universal Router, which names the buyer
///  - each buyer may buy at most 2% of supply in total; each address may receive at most 2% in total
///  - for 30 seconds a buy pays a total fee falling linearly from 99% to the normal fee; the extra goes to the platform
///  - the launch buy (the pool's first swap) counts as the developer's: no extra fee, the same cap
///  The Seeder side (required launch buy, USD 15,000 opening valuation) is in review/ReviewSeederLocal.t.sol.
contract LaunchProtectionTest is Base {
    address carol = makeAddr("carol");
    uint256 start;

    function setUp() public override {
        super.setUp();
        _fund(carol);
        start = block.timestamp;
        // deep enough for buys up to the 2% cap
        modifyLiquidityRouter.modifyLiquidity(officialKey, _range(20_000 ether), ZERO_BYTES);
    }

    /// @dev The launch buy: the pool's first swap (the Seeder's, in the real launch).
    function _launchBuy(uint256 tokens) internal {
        _swap(officialKey, true, int256(tokens));
    }

    function _hookError(bytes4 callback, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(CustomRevert.WrappedError.selector, address(hook), callback, reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector));
    }

    // ---------------------------------------------------------------- window

    function test_protection_startsWithThePool() public view {
        assertEq(hook.protectionEndsAt(), start + 5 minutes);
        assertEq(token.protectedUntil(), start + 5 minutes);
        assertEq(hook.protectionModule().routerCodeHash(), address(router).codehash, "the router's code at deployment");
        assertEq(address(router), hook.protectionModule().ROUTER());
    }

    function test_protection_cannotBeRestarted() public {
        vm.prank(address(hook));
        vm.expectRevert(UN1Token.AlreadyStarted.selector);
        token.startProtection();
        vm.expectRevert(UN1Token.NotHook.selector);
        token.startProtection();
    }

    // ---------------------------------------------------------------- the launch buy

    function test_launchBuy_countsAsTheDevelopers_withoutOpeningFee() public {
        _launchBuy(150 ether);
        assertEq(hook.boughtDuringProtection(DEV), 150 ether);
        assertEq(hook.openingFeesCollected(), 0, "the developer pays no opening fee");
        assertGt(hook.owed(PLATFORM), 0, "the normal platform fee is still paid");
    }

    function test_launchBuy_isCappedAt2Percent() public {
        vm.expectRevert(_hookError(IHooks.afterSwap.selector,
            abi.encodeWithSelector(UN1Hook.BuyerLimitExceeded.selector, DEV, 250 ether, 200 ether)));
        _launchBuy(250 ether);
    }

    // ---------------------------------------------------------------- who can buy

    function test_buys_onlyThroughTheCanonicalRouter_duringProtection() public {
        _launchBuy(1 ether);
        vm.warp(start + 31);
        vm.expectRevert(_hookError(IHooks.beforeSwap.selector, abi.encodeWithSelector(UN1ProtectionModule.UnsupportedRouter.selector)));
        _buy(alice, 1 ether); // PoolSwapTest is not the canonical router

        _routerBuy(alice, 5 ether);
        assertEq(hook.boughtDuringProtection(alice), 5 ether, "the router names its caller");
        assertEq(token.balanceOf(alice), 5 ether);

        _sell(alice, 2 ether); // sells go through any router
        vm.warp(start + 5 minutes);
        _buy(alice, 1 ether); // protection over
    }

    // ---------------------------------------------------------------- 2% per buyer

    function test_buyerLimit_isCumulative_andSellsDoNotGiveRoomBack() public {
        _launchBuy(1 ether);
        vm.warp(start + 30);
        _routerBuy(alice, 150 ether);
        vm.prank(alice);
        token.transfer(carol, 100 ether); // sending away does not help either
        _sell(carol, 50 ether);
        vm.expectRevert(_hookError(IHooks.afterSwap.selector,
            abi.encodeWithSelector(UN1Hook.BuyerLimitExceeded.selector, alice, 201 ether, 200 ether)));
        _routerBuy(alice, 51 ether);
        _routerBuy(alice, 50 ether); // exactly 2%

        vm.warp(start + 5 minutes);
        _buy(alice, 1 ether);
        assertEq(hook.boughtDuringProtection(alice), 200 ether, "nothing is counted after protection");
    }

    // ---------------------------------------------------------------- 2% per receiving address

    function test_recipientLimit_isCumulative() public {
        token.transfer(bob, 150 ether);
        vm.expectRevert(abi.encodeWithSelector(UN1Token.WalletLimitExceeded.selector, bob, 201 ether, 200 ether));
        token.transfer(bob, 51 ether);

        vm.prank(bob);
        token.transfer(bob, 10 ether); // to itself: not counted
        vm.prank(bob);
        token.transfer(carol, 100 ether); // sending away gives no room back
        vm.expectRevert(abi.encodeWithSelector(UN1Token.WalletLimitExceeded.selector, bob, 201 ether, 200 ether));
        token.transfer(bob, 51 ether);
        token.transfer(bob, 50 ether);
        assertEq(token.receivedDuringProtection(bob), 200 ether);
        assertEq(token.receivedDuringProtection(carol), 100 ether);

        vm.warp(start + 5 minutes);
        token.transfer(bob, 500 ether);
        assertEq(token.receivedDuringProtection(bob), 200 ether, "nothing is counted after protection");
    }

    function test_recipientLimit_countsBuysAndTransfersTogether() public {
        _launchBuy(1 ether);
        vm.warp(start + 30);
        _routerBuy(alice, 150 ether);
        assertEq(token.receivedDuringProtection(alice), 150 ether, "a buy is an inflow");
        vm.expectRevert(abi.encodeWithSelector(UN1Token.WalletLimitExceeded.selector, alice, 210 ether, 200 ether));
        token.transfer(alice, 60 ether);
    }

    function test_recipientLimit_ignoresThePoolManager() public view {
        // the setUp moved thousands of tokens into the PoolManager as liquidity
        assertEq(token.receivedDuringProtection(address(manager)), 0);
    }

    // ---------------------------------------------------------------- opening fee

    function test_openingFee_fallsLinearlyFrom99Percent() public {
        uint256 normal = hook.totalFee();
        assertEq(normal, 27_000);
        assertEq(hook.buyFee(alice), 990_000, "99% at the pool's first second");
        vm.warp(start + 15);
        assertEq(hook.buyFee(alice), normal + (990_000 - normal) / 2);
        vm.warp(start + 29);
        assertEq(hook.buyFee(alice), normal + (990_000 - normal) / 30);
        vm.warp(start + 30);
        assertEq(hook.buyFee(alice), normal);
        assertEq(hook.openingFee(alice), 0);
    }

    function test_openingFee_developerPaysNone() public view {
        assertEq(hook.buyFee(DEV), hook.totalFee());
    }

    function test_openingFee_goesToThePlatform_normalFeeSplitAsUsual() public {
        _launchBuy(1 ether);
        uint256 platformBefore = hook.owed(PLATFORM);
        uint256 holdersBefore = hook.owed(DISTRIBUTOR);
        vm.warp(start + 15);
        uint256 pips = hook.buyFee(alice);
        vm.prank(alice);
        router.swap(officialKey, uniIs0, -10 ether); // exact input of 10 UNI
        uint256 fee = FeeMath.onGross(10 ether, pips);
        uint256 normalFee = FeeMath.onGross(10 ether, hook.totalFee());
        uint256 platform = FeeMath.share(10 ether, normalFee, hook.PLATFORM_FEE());
        uint256 dev = FeeMath.share(10 ether, normalFee - platform, hook.DEV_FEE());
        assertEq(hook.openingFeesCollected(), fee - normalFee, "the extra above the normal fee");
        assertEq(hook.owed(PLATFORM) - platformBefore, platform + fee - normalFee, "platform: 0.3% plus the opening fee");
        assertEq(hook.owed(DISTRIBUTOR) - holdersBefore, normalFee - platform - dev, "holders: from the normal fee only");
    }

    function test_openingFee_onExactOutputBuys() public {
        _launchBuy(1 ether);
        vm.warp(start + 10);
        uint256 uniBefore = uni.balanceOf(alice);
        _routerBuy(alice, 1 ether); // exact output: the fee is taken on the UNI leg after the swap
        uint256 paid = uniBefore - uni.balanceOf(alice);
        assertGt(hook.openingFeesCollected(), 0);
        assertGt(paid, 2 ether, "about two thirds of the payment is opening fee at second 10");
    }
}
