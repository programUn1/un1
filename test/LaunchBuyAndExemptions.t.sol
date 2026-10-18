// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {UN1Hook} from "../src/UN1Hook.sol";
import {Base} from "./utils/Base.sol";

/// @notice 2026-10-18: the launch buy goes to the developer as plain tokens (marked LAUNCH_BUY, only on the pool's
///  first swap), and up to six wallets besides the developer are exempt from the opening fee, fixed in the hook's
///  constructor (launch protection v1: "the developer and up to six distinct additional wallets"). Exempt wallets keep
///  the 2% caps; sell fees never change.
contract LaunchBuyAndExemptionsTest is Base {
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    uint256 start;

    function _exempt() internal view override returns (address[6] memory e) {
        e[0] = carol;
        e[3] = dave; // zero slots in between are unused
    }

    function setUp() public override {
        super.setUp();
        _fund(carol);
        _fund(dave);
        start = block.timestamp;
        modifyLiquidityRouter.modifyLiquidity(officialKey, _range(20_000 ether), ZERO_BYTES);
    }

    function _swapWith(bytes memory hookData, int256 tokensOut) internal {
        bool zeroForOne = uniIs0; // a buy pays UNI in
        swapRouter.swap(
            officialKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: tokensOut,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    function _hookError(bytes4 callback, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(CustomRevert.WrappedError.selector, address(hook), callback, reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector));
    }

    // ---------------------------------------------------------------- the launch buy: plain tokens

    function test_launchBuy_markedFirstSwap_deliversPlainTokens() public {
        uint256 slots = token.slotCount();
        _swapWith(abi.encode(hook.LAUNCH_BUY()), 150 ether);
        assertEq(token.slotCount(), slots, "the marked first swap opens no slot");
        assertEq(token.drawCreditOf(address(this)), 0, "and leaves no draw credit");
        assertEq(hook.boughtDuringProtection(DEV), 150 ether, "still the developer's, within 2%");
        assertEq(hook.openingFeesCollected(), 0);
    }

    function test_launchBuy_unmarkedFirstSwap_drawsAsUsual() public {
        uint256 slots = token.slotCount();
        _swapWith("", 3 ether);
        assertEq(token.slotCount(), slots + 3, "without the mark the first swap deals as any buy");
    }

    function test_launchBuy_markIsIgnoredAfterTheFirstSwap() public {
        _swapWith(abi.encode(hook.LAUNCH_BUY()), 1 ether);
        _skipOpening();
        uint256 slots = token.slotCount();
        _swapWith(abi.encode(hook.LAUNCH_BUY()), 3 ether);
        assertEq(token.slotCount(), slots + 3, "a later buy cannot skip its draw");
        _swapWith(abi.encodePacked(hook.LAUNCH_BUY(), uint256(1)), 2 ether);
        assertEq(token.slotCount(), slots + 5);
    }

    // ---------------------------------------------------------------- exempt wallets

    function test_exempt_list_asDeployed() public view {
        address[6] memory e = hook.exemptWallets();
        assertEq(e[0], carol);
        assertEq(e[3], dave);
        assertEq(e[1], address(0));
        assertTrue(hook.isExempt(carol) && hook.isExempt(dave) && hook.isExempt(DEV));
        assertFalse(hook.isExempt(alice));
        assertFalse(hook.isExempt(address(0)), "an empty slot exempts nobody");
    }

    function test_exempt_paysNoOpeningFee_othersDo() public {
        _swapWith(abi.encode(hook.LAUNCH_BUY()), 1 ether);
        vm.warp(start + 5);
        assertEq(hook.buyFee(carol), hook.totalFee(), "exempt: the normal fee");
        assertGt(hook.buyFee(alice), hook.totalFee(), "not exempt: the opening fee");
        _routerBuy(carol, 10 ether);
        _routerBuy(dave, 10 ether);
        assertEq(hook.openingFeesCollected(), 0, "exempt buys pay no opening fee");
        _routerBuy(alice, 1 ether);
        assertGt(hook.openingFeesCollected(), 0, "a buyer outside the list pays it");
    }

    function test_exempt_keepsTheBuyerCap() public {
        _swapWith(abi.encode(hook.LAUNCH_BUY()), 1 ether);
        vm.warp(start + 5);
        _routerBuy(carol, 200 ether);
        vm.expectRevert(_hookError(IHooks.afterSwap.selector,
            abi.encodeWithSelector(UN1Hook.BuyerLimitExceeded.selector, carol, 201 ether, 200 ether)));
        _routerBuy(carol, 1 ether);
    }

    function test_exempt_constructorRejectsBadLists() public {
        address[6] memory e;
        address[5] memory bad = [DEV, address(token), address(manager), hook.ROUTER(), carol];
        for (uint256 i; i < 4; ++i) {
            e[2] = bad[i];
            vm.expectRevert(UN1Hook.InvalidExemption.selector);
            new UN1Hook(manager, address(token), address(uni), DEV, e);
        }
        e[2] = carol;
        e[5] = carol; // listed twice
        vm.expectRevert(UN1Hook.InvalidExemption.selector);
        new UN1Hook(manager, address(token), address(uni), DEV, e);
    }
}
