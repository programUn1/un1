// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "../utils/Base.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/// @notice Self-audit 2026-10-16 (docs/reviews/self-audit-final.md, SA-1 in docs/03-THREAT-MODEL.md): UN1 held as
///         ERC-6909 claims inside the PoolManager. Claims are not units and never open a slot. A pool without the
///         official hook can trade claims but never pay out the ERC20. Claims turn back into ERC20 only through the
///         official pool: a swap (paying the fee) or an official position held across transactions (no fee; the
///         tokens arrive naked). Every call runs as its own transaction, so no transient allowance carries over.
contract ReviewClaimsThroughLiquidityTest is Base {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 claimId;

    function setUp() public override {
        super.setUp();
        _skipOpening();
        claimId = uint256(uint160(address(token)));
    }

    /// @dev A token-only range just beside the current price and the largest liquidity `amount` tokens pay for.
    function _tokenOnly(PoolKey memory key, uint256 amount) private view returns (IPoolManager.ModifyLiquidityParams memory p) {
        (, int24 tick,,) = manager.getSlot0(key.toId());
        int24 s = key.tickSpacing;
        int24 f = tick / s;
        if (tick < 0 && tick % s != 0) --f;
        f *= s;
        bool token0 = !uniIs0;
        (int24 lo, int24 hi) = token0 ? (f + s, f + 101 * s) : (f - 100 * s, f);
        uint160 sa = TickMath.getSqrtPriceAtTick(lo);
        uint160 sb = TickMath.getSqrtPriceAtTick(hi);
        uint128 l = token0
            ? uint128(FullMath.mulDiv(amount, FullMath.mulDiv(sa, sb, 1 << 96), sb - sa))
            : uint128(FullMath.mulDiv(amount, 1 << 96, sb - sa));
        while ((token0 ? SqrtPriceMath.getAmount0Delta(sa, sb, l, true) : SqrtPriceMath.getAmount1Delta(sa, sb, l, true)) > amount) --l;
        p = IPoolManager.ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: int256(uint256(l)), salt: bytes32(0)});
    }

    function _buy(PoolKey memory key, address who, uint256 tokens, bool claims) private {
        vm.prank(who);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: uniIs0, amountSpecified: int256(tokens), sqrtPriceLimitX96: uniIs0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: claims, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    /// forge-config: default.isolate = true
    function test_Review_claimsReturnAsNakedTokensOnlyThroughAnOfficialPosition() public {
        _buy(officialKey, alice, 5 ether, true);
        assertEq(manager.balanceOf(alice, claimId), 5 ether, "the official buy is kept as claims");
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.pendingCount(alice), 0, "claims are not units");

        // claims pay for an official token-only position; no ERC20 moves
        vm.prank(alice);
        manager.setOperator(address(modifyLiquidityRouter), true);
        IPoolManager.ModifyLiquidityParams memory p = _tokenOnly(officialKey, 5 ether);
        vm.prank(alice);
        modifyLiquidityRouter.modifyLiquidity(officialKey, p, ZERO_BYTES, true, false);
        assertLt(manager.balanceOf(alice, claimId), 0.01 ether, "the claims paid for the position");

        // a later transaction: removing the position pays out the ERC20, without a slot
        p.liquidityDelta = -p.liquidityDelta;
        vm.prank(alice);
        modifyLiquidityRouter.modifyLiquidity(officialKey, p, ZERO_BYTES, false, false);
        uint256 got = token.balanceOf(alice);
        assertGt(got, 4.98 ether);
        assertEq(token.pendingCount(alice), 0, "no slot without an official buy");
        assertEq(token.idCount(alice), 0);
        assertEq(token.nakedCount(alice), got / 1 ether, "the tokens arrive naked");
    }

    /// forge-config: default.isolate = true
    function test_Review_aForeignPoolTradesClaimsButNeverPaysOutTheToken() public {
        PoolKey memory other = officialKey;
        other.hooks = IHooks(address(0));
        manager.initialize(other, SQRT_PRICE_1_1);

        // bob turns ERC20 into claims through an official position held across transactions (no fee)
        token.transfer(bob, 20 ether);
        vm.prank(bob);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        IPoolManager.ModifyLiquidityParams memory p = _tokenOnly(officialKey, 20 ether);
        vm.prank(bob);
        modifyLiquidityRouter.modifyLiquidity(officialKey, p, ZERO_BYTES, false, false);
        p.liquidityDelta = -p.liquidityDelta;
        vm.prank(bob);
        modifyLiquidityRouter.modifyLiquidity(officialKey, p, ZERO_BYTES, false, true);
        uint256 claims = manager.balanceOf(bob, claimId);
        assertGt(claims, 19.9 ether, "the position paid out as claims");

        // the claims seed a pool without the official hook
        vm.prank(bob);
        manager.setOperator(address(modifyLiquidityRouter), true);
        IPoolManager.ModifyLiquidityParams memory q = _tokenOnly(other, claims);
        vm.prank(bob);
        modifyLiquidityRouter.modifyLiquidity(other, q, ZERO_BYTES, true, false);

        // a buy there cannot pay out the ERC20; it can only end as claims, which are not units
        vm.prank(alice);
        vm.expectRevert();
        swapRouter.swap(
            other,
            IPoolManager.SwapParams({zeroForOne: uniIs0, amountSpecified: int256(2 ether), sqrtPriceLimitX96: uniIs0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        _buy(other, alice, 2 ether, true);
        assertEq(manager.balanceOf(alice, claimId), 2 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.pendingCount(alice), 0, "no slot from a foreign pool");
    }
}
