// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

interface IUN1HookKey {
    function poolKey() external view returns (PoolKey memory);
}

interface IUsdFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @title UN1Seeder
/// @notice One-shot launch, a target of the launch graph. Holds the whole supply; called once by the graph deployer
///  with the launch ETH. Everything happens inside one PoolManager unlock, settled by net deltas:
///   1. open the UN1/UNI pool at the chosen price
///   2. the whole supply -> one token-only position
///   3. the dev buy, required: ETH -> UNI on the existing ETH/UNI v4 pool, then UNI -> UN1 on the official pool (the
///      first swap: normal hook fees including the 0.3% platform fee, no opening fee, within the 2% launch-protection cap)
///   4. the bought tokens -> the developer, as plain tokens (the hook deals no slot for the launch buy), as in
///      Programmable's protected initializer
///   5. UNI not spent on the buy (`buyBps` below 100%) -> a single-sided bid below the new price
///  Every position belongs to this contract, which has no way to remove liquidity: they are locked forever.
///  Before anything, the opening price must value the whole supply at USD 15,000 or more (launch protection v1),
///  priced with Chainlink's UNI / USD feed.
contract UN1Seeder is IUnlockCallback {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @notice Chainlink UNI / USD on Ethereum mainnet, and how fresh its answer must be (its heartbeat is one hour).
    IUsdFeed public constant UNI_USD = IUsdFeed(0x553303d460EE0afB37EdFf9bE42922D8FF63220e);
    uint256 public constant MAX_FEED_AGE = 1 hours;
    uint256 public constant MINIMUM_FDV_USD = 15_000;
    /// @dev UN1Hook.LAUNCH_BUY: the hookData that marks the launch buy.
    bytes32 private constant LAUNCH_BUY = keccak256("un1.launch-buy");

    IPoolManager public immutable poolManager;
    IERC20 public immutable uni;
    address public immutable dev; // receives the launch buy and the UNI dust left by rounding
    address public immutable token;
    address public immutable hook;
    /// @notice The graph deployer (the Programmable Graph Factory); it alone calls `ignite`, once.
    address public immutable deployer;

    bool public ignited;

    /// @dev Independent of the pool's currency order, which depends on the token's CREATE2 address and is unknown when
    ///      the launch graph is packed: prices are given as UNI per token, the seeder maps them to pool ticks.
    struct IgniteParams {
        int24 uniPerTokenTick; // opening price: 1.0001^tick UNI per token; a multiple of the tick spacing
        int24 rangeTicks; // the supply sits from the opening price up to 1.0001^rangeTicks times it
        uint256 buyBps; // share of the UNI from the launch ETH spent on the dev buy; the rest becomes a locked bid
        uint256 minUniOut; // slippage floor of ETH -> UNI
        uint256 minTokensOut; // slippage floor of the dev buy
    }

    struct Result {
        uint128 tokenOnlyLiquidity;
        uint128 bidLiquidity;
        uint256 uniFromEth;
        uint256 bought;
        uint256 uniDust;
    }

    error NotDeployer();
    error NotPoolManager();
    error AlreadyIgnited();
    error InvalidParams();
    error InsufficientOutput();
    error PostconditionFailed();
    error InvalidOraclePrice();
    error OpeningValuationTooLow(uint256 usd);

    event Ignited(address indexed token, address indexed hook, uint128 tokenOnly, uint128 bid, uint256 bought, uint256 uniDust);

    constructor(address poolManager_, address uni_, address dev_, address token_, address hook_) {
        poolManager = IPoolManager(poolManager_);
        uni = IERC20(uni_);
        dev = dev_;
        token = token_;
        hook = hook_;
        deployer = msg.sender;
    }

    function ethUniKey() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(address(uni)), 3000, 60, IHooks(address(0)));
    }

    /// @notice Whole dollars the supply is worth at an opening price of 1.0001^tick UNI per token (rounded down).
    function openingFdvUsd(int24 uniPerTokenTick) public view returns (uint256) {
        (uint80 round, int256 answer,, uint256 updated, uint80 answeredIn) = UNI_USD.latestRoundData();
        if (answer <= 0 || round == 0 || answeredIn < round || updated == 0 || updated > block.timestamp
                || block.timestamp - updated > MAX_FEED_AGE) revert InvalidOraclePrice();
        uint8 decimals = UNI_USD.decimals();
        if (decimals > 18) revert InvalidOraclePrice();
        uint256 sqrtPrice = TickMath.getSqrtPriceAtTick(uniPerTokenTick); // sqrt(UNI per token) in Q64.96
        uint256 uniValue = FullMath.mulDiv(IERC20(token).totalSupply(), FullMath.mulDiv(sqrtPrice, sqrtPrice, 1 << 64), 1 << 128);
        return FullMath.mulDiv(uniValue, uint256(answer), 1 ether * 10 ** decimals);
    }

    function ignite(IgniteParams calldata p) external payable returns (Result memory r) {
        if (msg.sender != deployer) revert NotDeployer();
        if (ignited) revert AlreadyIgnited();
        ignited = true;
        // anyone can send ETH to this predictable address before the launch; only the launch ETH must be used up
        uint256 preexisting = address(this).balance - msg.value;
        PoolKey memory key = IUN1HookKey(hook).poolKey();
        if (p.buyBps > 10_000 || p.rangeTicks <= 0 || p.uniPerTokenTick % key.tickSpacing != 0 || p.rangeTicks % key.tickSpacing != 0) {
            revert InvalidParams();
        }
        // the launch buy is required: the hook counts the pool's first swap as the developer's
        if (msg.value == 0 || p.buyBps == 0 || p.minTokensOut == 0) revert InvalidParams();
        uint256 fdv = openingFdvUsd(p.uniPerTokenTick);
        if (fdv < MINIMUM_FDV_USD) revert OpeningValuationTooLow(fdv);
        bool token0 = Currency.unwrap(key.currency0) == token;
        if (!token0 && Currency.unwrap(key.currency1) != token) revert InvalidParams();
        // pool price = currency1 per currency0: UNI per token when the token is currency0, its inverse otherwise.
        // The token-only range lies above the price when the token is currency0, below it when it is currency1.
        int24 open = token0 ? p.uniPerTokenTick : -p.uniPerTokenTick;
        (int24 lower, int24 upper) = token0 ? (open, open + p.rangeTicks) : (open - p.rangeTicks, open);
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(open));

        r = abi.decode(poolManager.unlock(abi.encode(key, token, token0, p, msg.value, lower, upper)), (Result));
        if (r.bought < p.minTokensOut) revert InsufficientOutput();
        // every token not in the pool is rounding dust, far below one token (no card, no weight)
        if (IERC20(token).balanceOf(address(this)) >= 1 ether || address(this).balance != preexisting) revert PostconditionFailed();
        emit Ignited(token, hook, r.tokenOnlyLiquidity, r.bidLiquidity, r.bought, r.uniDust);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, address tok, bool token0, IgniteParams memory p, uint256 eth, int24 lower, int24 upper) =
            abi.decode(data, (PoolKey, address, bool, IgniteParams, uint256, int24, int24));
        Result memory r;

        // 2. the supply -> token-only position
        uint256 supply = IERC20(tok).balanceOf(address(this));
        r.tokenOnlyLiquidity = _tokenOnlyLiquidity(lower, upper, supply, token0);
        _addLiquidity(key, lower, upper, r.tokenOnlyLiquidity, 0);

        // 3. the dev buy, 5. the UNI left as a bid; 4. the bought tokens go to the developer when settling
        if (eth != 0) _devBuy(key, token0, p, eth, r);
        _settle(tok, eth, r);
        return abi.encode(r);
    }

    function _devBuy(PoolKey memory key, bool token0, IgniteParams memory p, uint256 eth, Result memory r) private {
        BalanceDelta d1 = poolManager.swap(
            ethUniKey(),
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -int256(eth), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
        r.uniFromEth = uint256(int256(d1.amount1()));
        if (r.uniFromEth < p.minUniOut) revert InsufficientOutput();
        uint256 buyUni = r.uniFromEth * p.buyBps / 10_000;
        if (buyUni != 0) {
            bool zeroForOne = !token0; // UNI in
            BalanceDelta d2 = poolManager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(buyUni),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                abi.encode(LAUNCH_BUY) // the hook delivers this first swap as plain tokens (no slot)
            );
            r.bought = uint256(int256(token0 ? d2.amount0() : d2.amount1()));
        }
        r.bidLiquidity = _bid(key, token0, r.uniFromEth - buyUni);
    }

    /// @dev Settle by net deltas: ETH in; the supply's tokens in (the token-only position takes them), then the bought
    ///      tokens out to the developer; UNI dust (rounding only) out to the developer.
    function _settle(address tok, uint256 eth, Result memory r) private {
        if (eth != 0) {
            poolManager.sync(Currency.wrap(address(0)));
            poolManager.settle{value: eth}();
        }
        // the PoolManager must hold the tokens before it can pay the developer: pay in what the positions took first
        int256 tokenDelta = poolManager.currencyDelta(address(this), Currency.wrap(tok)) - int256(r.bought);
        if (tokenDelta >= 0) revert PostconditionFailed(); // the supply always owes tokens to its position
        poolManager.sync(Currency.wrap(tok));
        IERC20(tok).safeTransfer(address(poolManager), uint256(-tokenDelta));
        poolManager.settle();
        if (r.bought != 0) poolManager.take(Currency.wrap(tok), dev, r.bought);
        int256 uniDelta = poolManager.currencyDelta(address(this), Currency.wrap(address(uni)));
        if (uniDelta < 0) revert PostconditionFailed();
        if (uniDelta > 0) {
            r.uniDust = uint256(uniDelta);
            poolManager.take(Currency.wrap(address(uni)), dev, r.uniDust);
        }
    }

    function _addLiquidity(PoolKey memory key, int24 lower, int24 upper, uint128 liquidity, uint256 salt) private {
        poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(salt)}),
            ""
        );
    }

    /// @dev Largest single-sided liquidity whose amount (rounded up, as the PoolManager charges it) fits in `amount`;
    ///      `token0` says whether that currency is currency0 (range above the price) or currency1 (below it).
    function _tokenOnlyLiquidity(int24 lower, int24 upper, uint256 amount, bool token0) private pure returns (uint128 l) {
        uint160 sa = TickMath.getSqrtPriceAtTick(lower);
        uint160 sb = TickMath.getSqrtPriceAtTick(upper);
        l = token0
            ? uint128(FullMath.mulDiv(amount, FullMath.mulDiv(sa, sb, 1 << 96), sb - sa))
            : uint128(FullMath.mulDiv(amount, 1 << 96, sb - sa));
        while ((token0 ? SqrtPriceMath.getAmount0Delta(sa, sb, l, true) : SqrtPriceMath.getAmount1Delta(sa, sb, l, true)) > amount) --l;
    }

    /// @dev UNI left after the buy -> one UNI-only range strictly below the token's new price (it takes UNI only).
    function _bid(PoolKey memory key, bool token0, uint256 uniLeft) private returns (uint128 l) {
        if (uniLeft == 0) return 0;
        (, int24 tick,,) = poolManager.getSlot0(key.toId());
        int24 s = key.tickSpacing;
        bool uni0 = !token0;
        (int24 lo, int24 hi) = uni0 ? (_ceil(tick + 1, s), TickMath.maxUsableTick(s)) : (TickMath.minUsableTick(s), _floor(tick, s));
        if (lo >= hi) return 0;
        l = _tokenOnlyLiquidity(lo, hi, uniLeft, uni0);
        if (l != 0) _addLiquidity(key, lo, hi, l, 3);
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

    receive() external payable {}
}
