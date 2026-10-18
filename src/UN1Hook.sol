// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FeeMath} from "./libraries/FeeMath.sol";
import {DrandRound} from "./libraries/DrandRound.sol";

interface IBalanceOf {
    function balanceOf(address account) external view returns (uint256);
}

interface IUN1Token {
    function authorize(uint256 amountIn, uint256 amountOut, uint256 draw) external;
    function authorizeLiquidity(uint256 amountIn, uint256 amountOut) external;
    function composeCount() external view returns (uint256);
    function startProtection() external;
}

/// @dev The Universal Router reports the account that called it (the v4 locker) to hooks.
interface IMsgSender {
    function msgSender() external view returns (address);
}

/// @title UN1Hook
/// @notice The one permanent hook of the UN1/UNI pool. Immutable, no owner.
///  - every swap pays a fee in UNI: platform 0.3% + dev 0.3% + halving fee (2.1%, halved every 2,100 composes)
///  - fees stay in the PoolManager as UNI claims owned by this hook; anyone can pay them out, only to fixed recipients
///  - reveal bounties come out of the dev fee: it first tops up a capped reserve for the beacon, the rest goes to the dev;
///    the dev fee of the buys is recorded per drand round, and the beacon pays a round no more than its buys paid
///  - the token may enter or leave the PoolManager only for the exact amounts this hook authorizes (rule ②)
///  - only buys authorize a draw, so only official-pool buys deal new cards (rule ①); liquidity moves naked tokens
///  - launch protection (Programmable launch protection v1, with UNI as the quote): for 5 minutes after the pool is
///    created, buys go through the canonical Universal Router and each buyer (the router's msgSender) may buy at most
///    2% of supply in total; the token caps what each address receives the same way. For the first 30 seconds a buy
///    pays a total fee that starts at 99% and falls linearly to the normal fee; the extra goes to the platform
///    treasury. The developer and up to six wallets fixed at deployment pay no extra fee (the same 2% cap). The launch
///    buy (the pool's first swap, made by the Seeder for the developer) counts as the developer's; marked LAUNCH_BUY,
///    its tokens reach the developer as plain tokens, with no slot (the launch deals no card).
contract UN1Hook is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    // ---------------- constants ----------------
    uint256 public constant PLATFORM_FEE = 3_000; // 0.30%, fixed by Programmable
    uint256 public constant DEV_FEE = 3_000; // 0.30%
    uint256 public constant HALVING_FEE = 21_000; // 2.10% in epoch 1
    uint256 public constant EPOCH = 2_100; // composes per epoch
    uint256 public constant PROTECTION = 5 minutes; // launch protection window, from pool creation
    uint256 public constant OPENING_FEE_WINDOW = 30 seconds;
    uint256 public constant OPENING_TOTAL_FEE = 990_000; // pips: 99% of a buy at the pool's first second
    uint256 public constant BUYER_LIMIT = 200 ether; // 2% of 10,000, per buyer over the protection window
    /// @notice The canonical Universal Router (Uniswap, mainnet). During protection it is the only way to buy.
    address public constant ROUTER = 0xd92A36B0000531EF3063dEd4De20A0783308446C;
    uint24 public constant LP_FEE = 0;
    int24 public constant TICK_SPACING = 60;
    address public constant PLATFORM_RECIPIENT = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;
    uint256 public constant BOUNTY_RESERVE = 50 ether; // UNI kept for reveal bounties, topped up from the dev fee
    /// @notice hookData of the Seeder's launch buy: on the pool's first swap (always the Seeder's, atomic with pool
    ///         creation) it delivers the bought tokens without a draw. Ignored on every later swap.
    bytes32 public constant LAUNCH_BUY = keccak256("un1.launch-buy");

    // ---------------- wiring ----------------
    IPoolManager public immutable poolManager;
    address public immutable token;
    address public immutable uni;
    address public immutable devRecipient;
    /// @notice The graph deployer (the Programmable Graph Factory); it alone calls `initialize`, once.
    address public immutable deployer;
    /// @notice The router's code when this hook was deployed (in the launch transaction): buys during protection must
    ///         come from that exact code.
    bytes32 public immutable routerCodeHash;
    /// @dev Wallets exempt from the opening fee besides the developer (launch protection v1 allows six); 0 = unused.
    address private immutable exempt0;
    address private immutable exempt1;
    address private immutable exempt2;
    address private immutable exempt3;
    address private immutable exempt4;
    address private immutable exempt5;

    // ---------------- state ----------------
    // set once by `initialize` (they are deployed after the hook, which they reference)
    address public distributor;
    address public beacon;
    PoolId public poolId;
    uint40 public launchedAt;
    uint64 public swapCount;
    mapping(address recipient => uint256 amount) public owed; // UNI claims held here for each recipient
    /// @notice Dev fee (UNI) paid by the buys whose slots target `round`: the most the beacon pays for revealing it.
    mapping(uint64 round => uint256 amount) public devFeeOf;
    /// @notice Tokens each buyer bought during the protection window (sells do not give room back).
    mapping(address buyer => uint256 amount) public boughtDuringProtection;
    /// @notice UNI of opening fees, owed to the platform treasury on top of its 0.3% (included in `owed`).
    uint256 public openingFeesCollected;

    uint256 private constant T_PIPS = uint256(keccak256("un1.hook.pips"));
    uint256 private constant T_NORMAL = uint256(keccak256("un1.hook.normal-pips"));
    uint256 private constant T_BUYER = uint256(keccak256("un1.hook.buyer"));

    error NotPoolManager();
    error HookNotImplemented();
    error WrongPool();
    error PartialQuoteFill();
    error UnsupportedRouter();
    error InvalidBuyer();
    error BuyerLimitExceeded(address buyer, uint256 bought, uint256 limit);
    error UnknownRecipient();
    error NothingToCollect();
    error NotDeployer();
    error AlreadyInitialized();
    error NotInitialized();
    error BadBeacon();
    error InvalidExemption();

    event FeeTaken(bool buy, uint256 gross, uint256 platform, uint256 dev, uint256 holders);
    event OpeningFeeTaken(address indexed buyer, uint256 gross, uint256 amount);
    event Collected(address indexed recipient, uint256 amount);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param exempt Wallets exempt from the opening fee besides the developer, as the reference module checks them:
    ///        zero entries are unused; no duplicates; never the developer, the token, the PoolManager or the router.
    constructor(IPoolManager poolManager_, address token_, address uni_, address devRecipient_, address[6] memory exempt) {
        for (uint256 i; i < 6; ++i) {
            address w = exempt[i];
            if (w == address(0)) continue;
            if (w == devRecipient_ || w == token_ || w == address(poolManager_) || w == ROUTER) revert InvalidExemption();
            for (uint256 j; j < i; ++j) {
                if (w == exempt[j]) revert InvalidExemption();
            }
        }
        poolManager = poolManager_;
        token = token_;
        uni = uni_;
        devRecipient = devRecipient_;
        deployer = msg.sender;
        routerCodeHash = ROUTER.codehash;
        (exempt0, exempt1, exempt2, exempt3, exempt4, exempt5) = (exempt[0], exempt[1], exempt[2], exempt[3], exempt[4], exempt[5]);
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Wire the fee recipients. Deployer only, once, before the pool exists. The beacon (public infrastructure
    ///         deployed before the launch) must be bound to this hook's token.
    function initialize(address distributor_, address beacon_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (distributor != address(0)) revert AlreadyInitialized();
        (bool ok, bytes memory ret) = beacon_.staticcall(abi.encodeWithSignature("token()"));
        if (!ok || ret.length != 32 || abi.decode(ret, (uint256)) != uint160(token)) revert BadBeacon();
        distributor = distributor_;
        beacon = beacon_;
    }

    // ================= views =================

    function poolKey() public view returns (PoolKey memory) {
        (address c0, address c1) = quoteIsCurrency0() ? (uni, token) : (token, uni);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
    }

    /// @notice Whether UNI is currency0 of the pool. Computed, not stored: the launch graph binds immutables only to
    ///         literals or target addresses, and this depends on the token's CREATE2 address.
    function quoteIsCurrency0() public view returns (bool) {
        return uni < token;
    }

    /// @notice The halving fee of the current epoch, in pips.
    function halvingFee() public view returns (uint256) {
        uint256 epoch = IUN1Token(token).composeCount() / EPOCH;
        return epoch >= 32 ? 0 : HALVING_FEE >> epoch;
    }

    /// @notice Total fee per swap, in pips, outside the opening seconds.
    function totalFee() public view returns (uint256) {
        return PLATFORM_FEE + DEV_FEE + halvingFee();
    }

    /// @notice When launch protection ends (0 before the pool exists).
    function protectionEndsAt() public view returns (uint256) {
        return launchedAt == 0 ? 0 : uint256(launchedAt) + PROTECTION;
    }

    /// @notice The six wallet slots exempt from the opening fee besides the developer (0 = unused).
    function exemptWallets() external view returns (address[6] memory) {
        return [exempt0, exempt1, exempt2, exempt3, exempt4, exempt5];
    }

    /// @notice Whether `wallet` pays no opening fee: the developer and the exempt wallets.
    function isExempt(address wallet) public view returns (bool) {
        return wallet != address(0)
            && (wallet == devRecipient || wallet == exempt0 || wallet == exempt1 || wallet == exempt2 || wallet == exempt3
                || wallet == exempt4 || wallet == exempt5);
    }

    /// @notice Extra fee a buy by `buyer` pays now, in pips: (99% minus the normal fee) at the pool's first second,
    ///         falling linearly to 0 over 30 seconds. The developer and the exempt wallets pay none.
    function openingFee(address buyer) public view returns (uint256) {
        uint256 start = launchedAt;
        if (start == 0 || block.timestamp >= start + OPENING_FEE_WINDOW || isExempt(buyer)) return 0;
        return Math.mulDiv(OPENING_TOTAL_FEE - totalFee(), start + OPENING_FEE_WINDOW - block.timestamp, OPENING_FEE_WINDOW);
    }

    /// @notice Total fee of a buy by `buyer` now, in pips.
    function buyFee(address buyer) external view returns (uint256) {
        return totalFee() + openingFee(buyer);
    }

    // ================= initialize =================

    function beforeInitialize(address, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (distributor == address(0)) revert NotInitialized();
        PoolKey memory k = poolKey();
        if (
            PoolId.unwrap(poolId) != 0 || Currency.unwrap(key.currency0) != Currency.unwrap(k.currency0)
                || Currency.unwrap(key.currency1) != Currency.unwrap(k.currency1) || key.fee != LP_FEE
                || key.tickSpacing != TICK_SPACING
        ) revert WrongPool();
        poolId = key.toId();
        launchedAt = uint40(block.timestamp);
        IUN1Token(token).startProtection(); // from now on the token also caps what each address receives
        return IHooks.beforeInitialize.selector;
    }

    // ================= swap =================

    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
        uint256 normal = totalFee();
        uint256 pips = normal;
        if (_isBuy(params) && block.timestamp < uint256(launchedAt) + PROTECTION) {
            address buyer = _buyer(sender);
            _tstore(T_BUYER, uint160(buyer));
            pips += openingFee(buyer);
        }
        _tstore(T_PIPS, pips);
        _tstore(T_NORMAL, normal);

        if (!_quoteSpecified(params)) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        (uint256 gross, uint256 fee) = _feeOnSpecified(params, pips);
        _accrue(_isBuy(params), gross, fee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        (int128 q, int128 t) = quoteIsCurrency0() ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        int128 hookFee = _feeAfter(params, _abs(q));

        uint256 tokenAmount = _abs(t);
        if (_isBuy(params)) {
            if (block.timestamp < uint256(launchedAt) + PROTECTION) {
                address buyer = address(uint160(_tload(T_BUYER)));
                uint256 bought = boughtDuringProtection[buyer] + tokenAmount;
                if (bought > BUYER_LIMIT) revert BuyerLimitExceeded(buyer, bought, BUYER_LIMIT);
                boughtDuringProtection[buyer] = bought;
            }
            // the Seeder's launch buy goes to the developer as plain tokens: dealing its slots would not fit the launch
            // transaction (EIP-7825), and the launch deals no card
            bool launchBuy = swapCount == 0 && hookData.length == 32 && bytes32(hookData) == LAUNCH_BUY;
            IUN1Token(token).authorize(0, tokenAmount, launchBuy ? 0 : tokenAmount);
        } else {
            IUN1Token(token).authorize(tokenAmount, 0, 0);
        }
        swapCount++;
        return (IHooks.afterSwap.selector, hookFee);
    }

    /// @dev UNI specified: the fee was taken in beforeSwap on the requested amount, so the pool must have moved exactly
    ///      that amount. UNI unspecified: take the fee now from the UNI leg.
    function _feeAfter(IPoolManager.SwapParams calldata params, uint256 quoteAmount) private returns (int128) {
        uint256 pips = _tload(T_PIPS);
        bool exactIn = params.amountSpecified < 0;
        if (_quoteSpecified(params)) {
            (uint256 g, uint256 f) = _feeOnSpecified(params, pips);
            if (quoteAmount != (exactIn ? g - f : g)) revert PartialQuoteFill();
            return 0;
        }
        uint256 fee = exactIn ? FeeMath.onGross(quoteAmount, pips) : FeeMath.onNet(quoteAmount, pips);
        _accrue(_isBuy(params), exactIn ? quoteAmount : quoteAmount + fee, fee);
        return fee.toInt128();
    }

    // ================= liquidity: naked tokens only, never a draw =================

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BalanceDelta) {
        _authorizeLiquidity(key, delta);
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BalanceDelta) {
        _authorizeLiquidity(key, delta);
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _authorizeLiquidity(PoolKey calldata key, BalanceDelta delta) private {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
        int128 t = quoteIsCurrency0() ? delta.amount1() : delta.amount0();
        if (t < 0) IUN1Token(token).authorizeLiquidity(_abs(t), 0);
        else if (t > 0) IUN1Token(token).authorizeLiquidity(0, _abs(t));
    }

    // ================= fees =================

    /// @dev UNI is the specified side iff (currency0 is specified) == (UNI is currency0); currency0 is specified iff
    ///      exactInput == zeroForOne.
    function _quoteSpecified(IPoolManager.SwapParams calldata p) private view returns (bool) {
        return ((p.amountSpecified < 0) == p.zeroForOne) == quoteIsCurrency0();
    }

    /// @dev A buy pays UNI into the pool: zeroForOne when UNI is currency0.
    function _isBuy(IPoolManager.SwapParams calldata p) private view returns (bool) {
        return p.zeroForOne == quoteIsCurrency0();
    }

    function _feeOnSpecified(IPoolManager.SwapParams calldata p, uint256 pips) private pure returns (uint256 gross, uint256 fee) {
        bool exactIn = p.amountSpecified < 0;
        uint256 requested = exactIn ? uint256(-p.amountSpecified) : uint256(p.amountSpecified);
        fee = exactIn ? FeeMath.onGross(requested, pips) : FeeMath.onNet(requested, pips);
        gross = exactIn ? requested : requested + fee;
    }

    /// @dev Who is buying, during protection. The pool's first swap is the launch buy, atomic with pool creation and
    ///      required by the Seeder: it counts as the developer's. Every other buy must come from the canonical router,
    ///      which names its caller.
    function _buyer(address sender) private view returns (address buyer) {
        if (swapCount == 0) return devRecipient;
        if (sender != ROUTER || sender.codehash != routerCodeHash) revert UnsupportedRouter();
        buyer = IMsgSender(sender).msgSender();
        if (buyer == address(0) || buyer == ROUTER || buyer == address(this) || buyer == address(poolManager)) {
            revert InvalidBuyer();
        }
    }

    /// @dev Keep the fee in the PoolManager as UNI claims owned by this hook, so a swap never depends on a recipient.
    ///      An opening fee is the part above the normal fee of the same gross amount: it goes to the platform treasury,
    ///      and the normal fee is split as usual.
    function _accrue(bool buy, uint256 gross, uint256 fee) private {
        if (fee == 0) return;
        uint256 normal = _tload(T_NORMAL);
        if (_tload(T_PIPS) > normal) {
            uint256 normalFee = Math.min(fee, Math.mulDiv(gross, normal, FeeMath.ONE));
            uint256 extra = fee - normalFee;
            poolManager.mint(address(this), uint256(uint160(uni)), extra);
            owed[PLATFORM_RECIPIENT] += extra;
            openingFeesCollected += extra;
            emit OpeningFeeTaken(address(uint160(_tload(T_BUYER))), gross, extra);
            fee = normalFee;
            if (fee == 0) return;
        }
        uint256 platform = FeeMath.share(gross, fee, PLATFORM_FEE);
        uint256 dev = FeeMath.share(gross, fee - platform, DEV_FEE);
        uint256 holders = fee - platform - dev;
        if (buy) devFeeOf[DrandRound.target(block.timestamp)] += dev; // the round the token targets for this buy
        poolManager.mint(address(this), uint256(uint160(uni)), fee);
        owed[PLATFORM_RECIPIENT] += platform;
        // the reserve is what the beacon can still collect plus the UNI it already holds
        uint256 reserve = owed[beacon] + IBalanceOf(uni).balanceOf(beacon);
        if (reserve < BOUNTY_RESERVE) {
            uint256 topUp = BOUNTY_RESERVE - reserve;
            if (topUp > dev) topUp = dev;
            owed[beacon] += topUp;
            dev -= topUp;
        }
        owed[devRecipient] += dev;
        owed[distributor] += holders;
        emit FeeTaken(buy, gross, platform, dev, holders);
    }

    /// @notice Pay out everything accrued for `recipient` (platform, dev, distributor or beacon) as UNI. Anyone can call.
    function collect(address recipient) external {
        if (recipient != PLATFORM_RECIPIENT && recipient != devRecipient && recipient != distributor && recipient != beacon) {
            revert UnknownRecipient();
        }
        uint256 amount = owed[recipient];
        if (amount == 0) revert NothingToCollect();
        owed[recipient] = 0;
        poolManager.unlock(abi.encode(recipient, amount));
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (address recipient, uint256 amount) = abi.decode(data, (address, uint256));
        poolManager.burn(address(this), uint256(uint160(uni)), amount);
        poolManager.take(Currency.wrap(uni), recipient, amount);
        emit Collected(recipient, amount);
        return "";
    }

    // ================= helpers =================

    function _abs(int128 x) private pure returns (uint256) {
        return x < 0 ? uint256(-int256(x)) : uint256(int256(x));
    }

    function _tstore(uint256 slot, uint256 v) private {
        assembly ("memory-safe") {
            tstore(slot, v)
        }
    }

    function _tload(uint256 slot) private view returns (uint256 v) {
        assembly ("memory-safe") {
            v := tload(slot)
        }
    }

    // ================= unused callbacks =================

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
