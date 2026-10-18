// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "../utils/Base.sol";
import {UN1Token} from "../../src/UN1Token.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

/// @dev Local integration probe: the same locker owns all positions and pays with its own mock balances.
contract ReviewNetSettlementProbe is IUnlockCallback {
    using CurrencySettler for Currency;
    using TransientStateLibrary for IPoolManager;

    IPoolManager private immutable manager;
    address private immutable tokenAddress;
    PoolKey private official;
    PoolKey private foreign;
    uint256 public foreignBought;
    uint256 public foreignRemoved;

    constructor(IPoolManager manager_, address token_, PoolKey memory official_, PoolKey memory foreign_) {
        manager = manager_;
        tokenAddress = token_;
        official = official_;
        foreign = foreign_;
    }

    function exercise(bool includeClosedOfficialPosition) external {
        manager.unlock(abi.encode(includeClosedOfficialPosition));
    }

    function _change(PoolKey memory key, int256 liquidity) private returns (BalanceDelta delta) {
        (delta,) = manager.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams({
            tickLower: -6000, tickUpper: 6000, liquidityDelta: liquidity, salt: bytes32(0)
        }), "");
    }

    function _settle(Currency currency) private {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) currency.settle(manager, address(this), uint256(-delta), false);
        if (delta > 0) currency.take(manager, address(this), uint256(delta), false);
    }

    function _settleBoth() private {
        _settle(official.currency0);
        _settle(official.currency1);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        if (abi.decode(data, (bool))) {
            // Flash accounting nets these two operations, but the token records both gross allowances.
            _change(official, 100 ether);
            _change(official, -100 ether);
        }
        _change(foreign, 10 ether);
        _settleBoth();

        bool uni0 = Currency.unwrap(foreign.currency0) != tokenAddress;
        BalanceDelta traded = manager.swap(foreign, IPoolManager.SwapParams({
            zeroForOne: uni0,
            amountSpecified: -int256(0.1 ether),
            sqrtPriceLimitX96: uni0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        }), "");
        foreignBought = uint256(int256(uni0 ? traded.amount1() : traded.amount0()));
        _settleBoth();

        BalanceDelta removed = _change(foreign, -5 ether);
        foreignRemoved = uint256(int256(uni0 ? removed.amount1() : removed.amount0()));
        _settleBoth();
        return "";
    }
}

/// @notice Review R-02 (docs/reviews/gpt-review.md). The reproduction asserted the bug; after the fix (2026-10-15) the
///         token keeps only the net of the two directions, so a closed official position leaves nothing to use.
contract ReviewAllowanceIsolationTest is Base {
    function test_Review_closedOfficialPositionLeavesNoAllowanceForAnotherPool() public {
        _skipOpening();
        PoolKey memory other = officialKey;
        other.hooks = IHooks(address(0));
        manager.initialize(other, SQRT_PRICE_1_1);
        ReviewNetSettlementProbe probe = new ReviewNetSettlementProbe(manager, address(token), officialKey, other);
        token.transfer(address(probe), 100 ether);
        uni.mint(address(probe), 100 ether);

        vm.expectRevert(UN1Token.PoolTransferNotAuthorized.selector);
        probe.exercise(false);
        // adding and removing the same official position first no longer helps
        vm.expectRevert(UN1Token.PoolTransferNotAuthorized.selector);
        probe.exercise(true);
        assertEq(probe.foreignBought(), 0);
        assertEq(probe.foreignRemoved(), 0);
    }
}
