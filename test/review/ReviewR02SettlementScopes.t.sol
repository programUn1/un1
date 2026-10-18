// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "../utils/Base.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

// Each ordinary executor has its own v4 delta, balances and settlement calls.
contract R02SettlementActor {
    using CurrencySettler for Currency;
    using TransientStateLibrary for IPoolManager;

    IPoolManager private immutable manager;
    PoolKey private key;
    bool private immutable uni0;

    constructor(IPoolManager pm, PoolKey memory pool, bool quote0) {
        manager = pm;
        key = pool;
        uni0 = quote0;
    }

    function trade(bool buy, uint256 tokenAmount) external {
        bool zeroForOne = buy == uni0;
        manager.swap(key, IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: buy ? int256(tokenAmount) : -int256(tokenAmount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        }), "");
    }

    function settleAll() external {
        _settle(key.currency0);
        _settle(key.currency1);
    }

    function _settle(Currency currency) private {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) currency.settle(manager, address(this), uint256(-delta), false);
        if (delta > 0) currency.take(manager, address(this), uint256(delta), false);
    }
}

contract R02SettlementCoordinator is IUnlockCallback {
    IPoolManager private immutable manager;
    R02SettlementActor public immutable buyer;
    R02SettlementActor public immutable seller;

    constructor(IPoolManager pm, PoolKey memory pool, bool quote0) {
        manager = pm;
        buyer = new R02SettlementActor(pm, pool, quote0);
        seller = new R02SettlementActor(pm, pool, quote0);
    }

    function run(uint8 mode) external {
        manager.unlock(abi.encode(mode));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(manager));
        uint8 mode = abi.decode(raw, (uint8));
        buyer.trade(true, 2 ether);
        if (mode == 0) buyer.settleAll();
        if (mode == 3) {
            buyer.trade(false, 1 ether);
            buyer.settleAll();
        } else {
            seller.trade(false, 2 ether);
            if (mode == 2) buyer.settleAll();
            seller.settleAll();
            if (mode == 1) buyer.settleAll();
        }
        return "";
    }
}

/// @notice Second review F2-01 (docs/reviews/gpt-review-2.md), the reproduction from its appendix A. Netting every
///         allowance of a transaction (the first R-02 fix) broke two executors that settle opposite official swaps
///         separately in one unlock. After the second fix only liquidity allowances net out; all four flows work.
contract ReviewR02SettlementScopesTest is Base {
    using TransientStateLibrary for IPoolManager;

    R02SettlementCoordinator private coordinator;

    function setUp() public override {
        super.setUp();
        _skipOpening();
        coordinator = new R02SettlementCoordinator(manager, officialKey, uniIs0);
        uni.mint(address(coordinator.buyer()), 100 ether);
        token.transfer(address(coordinator.seller()), 20 ether);
    }

    function _assertTwoSettled() private view {
        assertEq(token.balanceOf(address(coordinator.buyer())), 2 ether);
        assertEq(token.pendingCount(address(coordinator.buyer())), 2);
        assertEq(token.balanceOf(address(coordinator.seller())), 18 ether);
        assertGt(uni.balanceOf(address(coordinator.seller())), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_control_immediateIndependentSettlements_work() public {
        coordinator.run(0);
        _assertTwoSettled();
    }

    function test_deferredIndependentSettlements_sellerFirst_work() public {
        coordinator.run(1);
        _assertTwoSettled();
    }

    function test_deferredIndependentSettlements_buyerFirst_work() public {
        coordinator.run(2);
        _assertTwoSettled();
    }

    function test_control_singleExecutorNetSettlement_works() public {
        coordinator.run(3);
        assertEq(token.balanceOf(address(coordinator.buyer())), 1 ether);
        assertEq(token.pendingCount(address(coordinator.buyer())), 1);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }
}
