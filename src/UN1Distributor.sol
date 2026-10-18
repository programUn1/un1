// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

interface IUN1TokenRewards {
    function notifyReward(uint256 amount) external;
    function settleClaim(address account) external returns (uint256);
    function earned(address account) external view returns (uint256);
}

interface IUN1HolderVault {
    function claimHolders() external returns (uint256);
}

interface IUN1HookView {
    function feeVault() external view returns (IUN1HolderVault);
    function poolKey() external view returns (PoolKey memory);
    function quoteIsCurrency0() external view returns (bool);
}

/// @title UN1Distributor
/// @notice Holds the halving fee in UNI. `sync` pulls it from the hook's normal-fee vault and splits every new deposit
///  7/8 to the holders (streamed over one day by the token's accumulator) and 1/8 to the permanent-liquidity reserve.
///  No owner.
///  - `claim` pays the caller; `claimFor` pays each listed account to itself (the weekly push)
///  - `deployReserve` turns the reserve into permanent bids: UNI-only liquidity in a band 6%–45% below the token's
///    price, never removable (this contract has no way to remove liquidity). No swap is involved, so there is nothing
///    to sandwich; when the price falls into the band, the pool buys tokens with it. At most one batch per hour.
contract UN1Distributor is IUnlockCallback {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 public constant RESERVE_BATCH = 250 ether; // UNI per deployment
    uint256 public constant RESERVE_INTERVAL = 1 hours;
    int24 public constant BAND_NEAR = 600; // 1.0001^600 ≈ 1.062: the band starts about 6% below the price
    int24 public constant BAND_FAR = 6000; // 1.0001^-6000 ≈ 0.549: and ends about 45% below

    IERC20 public immutable uni;
    IUN1TokenRewards public immutable token;
    IUN1HookView public immutable hook;
    IPoolManager public immutable poolManager;

    uint256 public totalFunded; // UNI handed to the holders' stream
    uint256 public totalClaimed;
    uint256 public reserve; // 1/8, waiting to become permanent liquidity
    uint256 public reserveDeployed;
    uint64 public lastDeploy;
    uint256 public positionCount;

    error NotPoolManager();
    error TooSoon();
    error NothingToDeploy();
    error BadBand();
    error TokenRequired();

    event Synced(uint256 incoming, uint256 holders, uint256 reserve);
    event Claimed(address indexed account, uint256 amount);
    event ReserveDeployed(uint256 indexed position, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 uniUsed);

    constructor(address uni_, address token_, address hook_, address poolManager_) {
        uni = IERC20(uni_);
        token = IUN1TokenRewards(token_);
        hook = IUN1HookView(hook_);
        poolManager = IPoolManager(poolManager_);
    }

    // ================= fees in, holders out =================

    /// @notice Pull the holders' fee from the hook's normal-fee vault and start streaming 7/8 of everything new.
    function sync() external returns (uint256 holders, uint256 toReserve) {
        try hook.feeVault().claimHolders() {} catch {}
        uint256 committed = totalFunded - totalClaimed + reserve;
        uint256 bal = uni.balanceOf(address(this));
        if (bal <= committed) return (0, 0);
        uint256 incoming = bal - committed;
        holders = incoming * 7 / 8;
        toReserve = incoming - holders;
        totalFunded += holders;
        reserve += toReserve;
        if (holders != 0) token.notifyReward(holders);
        emit Synced(incoming, holders, toReserve);
    }

    function claim() external returns (uint256) {
        return _pay(msg.sender);
    }

    /// @notice Pay every listed account whose claimable UNI is at least `minAmount`, to the account itself.
    function claimFor(address[] calldata accounts, uint256 minAmount) external returns (uint256 paid) {
        for (uint256 i; i < accounts.length; ++i) {
            if (token.earned(accounts[i]) >= minAmount) paid += _pay(accounts[i]);
        }
    }

    function _pay(address account) private returns (uint256 amount) {
        amount = token.settleClaim(account);
        if (amount == 0) return 0;
        totalClaimed += amount;
        uni.safeTransfer(account, amount);
        emit Claimed(account, amount);
    }

    // ================= permanent liquidity: bids below the price =================

    /// @notice Place up to RESERVE_BATCH UNI of the reserve as permanent UNI-only liquidity below the token's price.
    function deployReserve() external returns (uint256 used, int24 lower, int24 upper, uint128 liquidity) {
        if (block.timestamp < uint256(lastDeploy) + RESERVE_INTERVAL) revert TooSoon();
        uint256 amount = reserve < RESERVE_BATCH ? reserve : RESERVE_BATCH;
        if (amount <= 2) revert NothingToDeploy();

        bool uni0 = hook.quoteIsCurrency0();
        PoolKey memory key = hook.poolKey();
        (lower, upper) = _bandNow(key, uni0);
        liquidity = _liquidityFor(lower, upper, amount - 2, uni0); // the PoolManager rounds the owed amount up
        lastDeploy = uint64(block.timestamp);
        used = _place(key, lower, upper, liquidity, uni0);
        reserve -= used;
        reserveDeployed += used;
    }

    function _bandNow(PoolKey memory key, bool uni0) private view returns (int24, int24) {
        (, int24 tick,,) = poolManager.getSlot0(key.toId());
        return _band(tick, key.tickSpacing, uni0);
    }

    function _liquidityFor(int24 lower, int24 upper, uint256 budget, bool uni0) private pure returns (uint128) {
        uint160 sa = TickMath.getSqrtPriceAtTick(lower);
        uint160 sb = TickMath.getSqrtPriceAtTick(upper);
        uint256 l = uni0
            ? FullMath.mulDiv(budget, FullMath.mulDiv(sa, sb, 1 << 96), sb - sa)
            : FullMath.mulDiv(budget, 1 << 96, sb - sa);
        return uint128(l);
    }

    function _place(PoolKey memory key, int24 lower, int24 upper, uint128 liquidity, bool uni0) private returns (uint256 used) {
        uint256 position = positionCount++;
        used = abi.decode(poolManager.unlock(abi.encode(key, lower, upper, liquidity, position, uni0)), (uint256));
        emit ReserveDeployed(position, lower, upper, liquidity, used);
    }

    /// @dev UNI-only range: below the price when UNI is currency1, above it (in tick terms) when UNI is currency0.
    function _band(int24 tick, int24 spacing, bool uni0) private pure returns (int24 lower, int24 upper) {
        int24 minT = TickMath.minUsableTick(spacing);
        int24 maxT = TickMath.maxUsableTick(spacing);
        if (uni0) {
            lower = _ceil(tick + BAND_NEAR, spacing);
            upper = _ceil(tick + BAND_FAR, spacing);
            if (upper > maxT) upper = maxT;
        } else {
            upper = _floor(tick - BAND_NEAR, spacing);
            lower = _floor(tick - BAND_FAR, spacing);
            if (lower < minT) lower = minT;
        }
        if (lower >= upper) revert BadBand();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, int24 lower, int24 upper, uint128 liquidity, uint256 position, bool uni0) =
            abi.decode(data, (PoolKey, int24, int24, uint128, uint256, bool));
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(position)
            }),
            ""
        );
        (int128 q, int128 t) = uni0 ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        if (t != 0) revert TokenRequired(); // out of range by construction: UNI only
        uint256 owed = uint256(int256(-q));
        Currency c = Currency.wrap(address(uni));
        poolManager.sync(c);
        uni.safeTransfer(address(poolManager), owed);
        poolManager.settle();
        return abi.encode(owed);
    }

    function _floor(int24 t, int24 s) private pure returns (int24) {
        int24 r = t / s;
        if (t < 0 && t % s != 0) --r;
        return r * s;
    }

    function _ceil(int24 t, int24 s) private pure returns (int24) {
        int24 r = t / s;
        if (t > 0 && t % s != 0) ++r;
        return r * s;
    }
}
