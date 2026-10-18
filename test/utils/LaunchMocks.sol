// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

/// @notice Local stand-in for the canonical Universal Router at UN1Hook.ROUTER: it swaps for its caller and, like the
///         real router, reports that caller to hooks through msgSender(). Etched at the router's address before the
///         hook is deployed, so the hook records this code as the router's.
contract MockUniversalRouter is IUnlockCallback {
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;
    address private _locker;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function msgSender() external view returns (address) {
        return _locker;
    }

    /// @dev Exact input (amountSpecified < 0) or exact output (> 0) on `key`; the caller pays and receives.
    function swap(PoolKey calldata key, bool zeroForOne, int256 amountSpecified) external returns (BalanceDelta delta) {
        _locker = msg.sender;
        delta = abi.decode(manager.unlock(abi.encode(msg.sender, key, zeroForOne, amountSpecified)), (BalanceDelta));
        _locker = address(0);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (address payer, PoolKey memory key, bool zeroForOne, int256 amount) = abi.decode(data, (address, PoolKey, bool, int256));
        BalanceDelta d = manager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 a0 = d.amount0();
        int128 a1 = d.amount1();
        if (a0 < 0) key.currency0.settle(manager, payer, uint128(-a0), false);
        if (a1 < 0) key.currency1.settle(manager, payer, uint128(-a1), false);
        if (a0 > 0) key.currency0.take(manager, payer, uint128(a0), false);
        if (a1 > 0) key.currency1.take(manager, payer, uint128(a1), false);
        return abi.encode(d);
    }
}

/// @notice Local stand-in for Chainlink UNI / USD at UN1Seeder.UNI_USD (8 decimals). Fresh by default.
contract MockUsdFeed {
    uint8 public constant decimals = 8;
    int256 public answer;
    uint256 public updatedAt; // 0: always the current block

    constructor(int256 answer_) {
        answer = answer_;
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 at = updatedAt == 0 ? block.timestamp : updatedAt;
        return (1, answer, at, at, 1);
    }
}
