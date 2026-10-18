// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {UN1Token} from "../src/UN1Token.sol";
import {UN1Hook} from "../src/UN1Hook.sol";
import {FeeMath} from "../src/libraries/FeeMath.sol";
import {Base} from "./utils/Base.sol";

/// @notice Only through the hook.
///  ① only official-pool buys deal new cards (draw); removing liquidity and transfers never do.
///  ② the token enters or leaves the PoolManager only with an allowance the official hook gave in the same transaction: other v4 pools and direct transfers fail.
///  Also: fees in UNI (four directions), fee claims, permissions. Launch protection is in LaunchProtection.t.sol.
contract OnlyHookTest is Base {
    function _uniClaims() internal view returns (uint256) {
        return manager.balanceOf(address(hook), uint256(uint160(address(uni))));
    }

    function _assertSplit(uint256 gross, uint256 fee) internal view {
        uint256 platform = FeeMath.share(gross, fee, hook.PLATFORM_FEE());
        uint256 dev = FeeMath.share(gross, fee - platform, hook.DEV_FEE());
        assertEq(hook.owed(PLATFORM), platform, "platform share");
        assertEq(hook.owed(DEV) + hook.owed(address(beacon)), dev, "dev share (bounty reserve first)");
        assertEq(hook.owed(DISTRIBUTOR), fee - platform - dev, "holders share");
        assertEq(_uniClaims(), fee, "claims back the fee");
    }

    // ---------------------------------------------------------------- official pool: UNI fees in all four directions

    function test_buyExactIn_paysFeeInUni() public {
        _skipOpening();
        uint256 uniBefore = uni.balanceOf(address(this));
        _swap(officialKey, true, -100 ether);
        assertEq(uniBefore - uni.balanceOf(address(this)), 100 ether, "pays exactly the input");
        _assertSplit(100 ether, FeeMath.onGross(100 ether, hook.totalFee()));
        assertEq(hook.owed(PLATFORM), 0.3 ether);
        assertEq(hook.owed(address(beacon)), 0.3 ether, "dev fee fills the bounty reserve first");
        assertEq(hook.owed(DEV), 0);
        assertEq(hook.owed(DISTRIBUTOR), 2.1 ether);
    }

    function test_buyExactOut_paysFeeInUni() public {
        _skipOpening();
        uint256 tokBefore = token.balanceOf(address(this));
        uint256 uniBefore = uni.balanceOf(address(this));
        _swap(officialKey, true, 10 ether);
        assertEq(token.balanceOf(address(this)) - tokBefore, 10 ether, "receives exactly the output");
        uint256 paid = uniBefore - uni.balanceOf(address(this));
        uint256 fee = _uniClaims();
        assertGt(fee, 0);
        _assertSplit(paid, fee);
        // fee / gross == 2.7% (rounded up on the net)
        assertApproxEqRel(fee * 1e18 / paid, 0.027 ether, 1e12);
    }

    function test_sellExactIn_paysFeeInUni() public {
        _skipOpening();
        uint256 uniBefore = uni.balanceOf(address(this));
        _swap(officialKey, false, -10 ether);
        uint256 received = uni.balanceOf(address(this)) - uniBefore;
        uint256 fee = _uniClaims();
        _assertSplit(received + fee, fee);
        assertEq(fee, FeeMath.onGross(received + fee, hook.totalFee()));
    }

    function test_sellExactOut_paysFeeInUni() public {
        _skipOpening();
        uint256 uniBefore = uni.balanceOf(address(this));
        _swap(officialKey, false, 5 ether);
        assertEq(uni.balanceOf(address(this)) - uniBefore, 5 ether, "receives exactly the UNI asked for");
        uint256 fee = _uniClaims();
        _assertSplit(5 ether + fee, fee);
    }

    function test_collect_paysOnlyFixedRecipients() public {
        _skipOpening();
        _swap(officialKey, true, -100 ether);
        hook.collect(PLATFORM);
        hook.collect(address(beacon));
        hook.collect(DISTRIBUTOR);
        assertEq(uni.balanceOf(PLATFORM), 0.3 ether);
        assertEq(uni.balanceOf(address(beacon)), 0.3 ether);
        assertEq(uni.balanceOf(DISTRIBUTOR), 2.1 ether);
        assertEq(_uniClaims(), 0);
        vm.expectRevert(UN1Hook.UnknownRecipient.selector);
        hook.collect(alice);
        vm.expectRevert(UN1Hook.NothingToCollect.selector);
        hook.collect(PLATFORM);
    }

    // ---------------------------------------------------------------- rule ①: only official-pool buys deal new cards

    function test_officialBuy_opensPendingSlotsForRecipient() public {
        _skipOpening();
        vm.prank(alice);
        _swap(officialKey, true, 3 ether);
        assertEq(token.balanceOf(alice), 3 ether);
        assertEq(token.pendingCount(alice), 3, "3 whole tokens bought, 3 slots");
    }

    function test_fractionalBuys_openSlotOnlyWhenCrossingWholeToken() public {
        _skipOpening();
        vm.startPrank(alice);
        _swap(officialKey, true, 0.6 ether);
        assertEq(token.pendingCount(alice), 0);
        _swap(officialKey, true, 0.6 ether);
        assertEq(token.pendingCount(alice), 1, "1.2 tokens, 1 slot");
        vm.stopPrank();
    }

    function test_removeLiquidity_givesNakedTokens() public {
        uint256 before = token.pendingCount(address(this));
        uint256 tokBefore = token.balanceOf(address(this));
        modifyLiquidityRouter.modifyLiquidity(officialKey, _range(-100 ether), ZERO_BYTES);
        assertGt(token.balanceOf(address(this)), tokBefore, "tokens came back");
        assertEq(token.pendingCount(address(this)), before, "no new cards from liquidity");
    }

    function test_walletTransfer_noDraw() public {
        token.transfer(alice, 5 ether);
        assertEq(token.balanceOf(alice), 5 ether);
        assertEq(token.pendingCount(alice), 0);
    }

    // ---------------------------------------------------------------- rule ②: no other way into the PoolManager

    function test_directTransferToPoolManager_reverts() public {
        vm.expectRevert(UN1Token.PoolTransferNotAuthorized.selector);
        token.transfer(address(manager), 1);
    }

    function test_foreignPool_cannotTakeLiquidity() public {
        PoolKey memory foreign = PoolKey(officialKey.currency0, officialKey.currency1, 3000, 60, IHooks(address(0)));
        manager.initialize(foreign, SQRT_PRICE_1_1);
        vm.expectRevert(UN1Token.PoolTransferNotAuthorized.selector);
        modifyLiquidityRouter.modifyLiquidity(foreign, _range(1 ether), ZERO_BYTES);
    }

    function test_foreignPool_uniOnlyLiquidity_cannotSwapToken() public {
        PoolKey memory foreign = PoolKey(officialKey.currency0, officialKey.currency1, 3000, 60, IHooks(address(0)));
        manager.initialize(foreign, SQRT_PRICE_1_1);
        // a range that holds only UNI: no token transfer needed to add it
        IPoolManager.ModifyLiquidityParams memory p = uniIs0
            ? IPoolManager.ModifyLiquidityParams({tickLower: 600, tickUpper: 1200, liquidityDelta: 100 ether, salt: 0})
            : IPoolManager.ModifyLiquidityParams({tickLower: -1200, tickUpper: -600, liquidityDelta: 100 ether, salt: 0});
        modifyLiquidityRouter.modifyLiquidity(foreign, p, ZERO_BYTES);
        // selling the token there needs the token to enter the PoolManager: refused
        vm.expectRevert(UN1Token.PoolTransferNotAuthorized.selector);
        _swap(foreign, false, -1 ether);
    }

    function test_secondPoolWithOurHook_reverts() public {
        PoolKey memory clone = PoolKey(officialKey.currency0, officialKey.currency1, 3000, 60, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(clone, SQRT_PRICE_1_1);
    }

    // ---------------------------------------------------------------- permissions

    function test_permissions() public {
        vm.expectRevert(UN1Token.NotHook.selector);
        token.authorize(0, 1 ether, 1 ether);

        IPoolManager.SwapParams memory sp = IPoolManager.SwapParams(true, -1, MIN_PRICE_LIMIT);
        vm.expectRevert(UN1Hook.NotPoolManager.selector);
        hook.beforeSwap(address(this), officialKey, sp, ZERO_BYTES);

        vm.expectRevert(UN1Hook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(alice, 1 ether));
    }

    function test_halvingFee_epoch1() public view {
        assertEq(hook.halvingFee(), 21_000);
        assertEq(hook.totalFee(), 27_000);
    }
}
