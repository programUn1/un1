// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
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
import {UN1FeeVault} from "./UN1FeeVault.sol";
import {UN1ProtectionModule} from "./UN1ProtectionModule.sol";
import {UN1OpeningTaxVault} from "./UN1OpeningTaxVault.sol";

interface IBalanceOf {
    function balanceOf(address account) external view returns (uint256);
}

interface IUN1Token {
    function authorize(uint256 amountIn, uint256 amountOut, uint256 draw) external;
    function authorizeLiquidity(uint256 amountIn, uint256 amountOut) external;
    function composeCount() external view returns (uint256);
    function startProtection() external;
}

/// @title UN1Hook
/// @notice The one permanent hook of the UN1/UNI pool. Immutable, no owner. Its constructor creates, in this order (as
///  Programmable's launch protection v1 does): the normal-fee vault (CREATE child 1), the protection module (child 2) and
///  the opening-tax vault (child 3).
///  - every swap pays a fee in UNI: platform 0.3% + dev 0.3% + halving fee (2.1%, halved every 2,100 composes). The hook
///    mints it as UNI claims to the normal-fee vault, which pays each part only to its fixed recipient
///  - reveal bounties come out of the dev fee: it first tops up a capped reserve for the beacon, the rest goes to the dev;
///    the dev fee of the buys is recorded per drand round, and the beacon pays a round no more than its buys paid
///  - the token may enter or leave the PoolManager only for the exact amounts this hook authorizes (rule ②)
///  - only buys authorize a draw, so only official-pool buys deal new cards (rule ①); liquidity moves naked tokens
///  - launch protection (Programmable launch protection v1, with UNI as the quote): for 5 minutes after the pool is
///    created, buys go through the canonical Universal Router and each buyer (the router's msgSender, authenticated by
///    the protection module) may buy at most 2% of supply in total; the token caps what each address receives the same
///    way. For the first 30 seconds a buy pays a total fee that starts at 99% and falls linearly to the normal fee; the
///    extra is minted to the opening-tax vault, payable only to the platform treasury. The developer and up to six
///    wallets fixed in the module pay no opening tax (the same 2% limits). The launch buy (the pool's first swap, made by
///    the Seeder for the developer) counts as the developer's; marked LAUNCH_BUY, its tokens reach the developer as
///    plain tokens, with no slot (the launch deals no card).
contract UN1Hook is IHooks {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    // ---------------- constants ----------------
    uint256 public constant PLATFORM_FEE = 3_000; // 0.30%, fixed by Programmable
    uint256 public constant DEV_FEE = 3_000; // 0.30%
    uint256 public constant HALVING_FEE = 21_000; // 2.10% in epoch 1
    uint256 public constant EPOCH = 2_100; // composes per epoch
    uint256 public constant PROTECTION = 5 minutes; // launch protection window, from pool creation
    uint256 public constant BUYER_LIMIT = 200 ether; // 2% of 10,000, per buyer over the protection window
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
    /// @notice Normal fees (platform, developer, bounty, holders), each payable only to its recipient. CREATE child 1.
    UN1FeeVault public immutable feeVault;
    /// @notice Buyer authentication, opening tax and its exemptions. CREATE child 2.
    UN1ProtectionModule public immutable protectionModule;
    /// @notice Opening taxes, payable only to the platform treasury. CREATE child 3.
    UN1OpeningTaxVault public immutable openingTaxVault;

    // ---------------- state ----------------
    // set once by `initialize` (they are deployed after the hook, which they reference)
    address public distributor;
    address public beacon;
    PoolId public poolId;
    uint40 public launchedAt;
    uint64 public swapCount;
    /// @notice Dev fee (UNI) paid by the buys whose slots target `round`: the most the beacon pays for revealing it.
    mapping(uint64 round => uint256 amount) public devFeeOf;
    /// @notice Tokens each buyer bought during the protection window (sells do not give room back).
    mapping(address buyer => uint256 amount) public boughtDuringProtection;

    uint256 private constant T_PIPS = uint256(keccak256("un1.hook.pips"));
    uint256 private constant T_NORMAL = uint256(keccak256("un1.hook.normal-pips"));
    uint256 private constant T_BUYER = uint256(keccak256("un1.hook.buyer"));

    error NotPoolManager();
    error HookNotImplemented();
    error WrongPool();
    error PartialQuoteFill();
    error BuyerLimitExceeded(address buyer, uint256 bought, uint256 limit);
    error NotDeployer();
    error AlreadyInitialized();
    error NotInitialized();
    error BadBeacon();

    event FeeTaken(bool buy, uint256 gross, uint256 platform, uint256 dev, uint256 holders);
    event OpeningFeeTaken(address indexed buyer, uint256 gross, uint256 amount);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param exempt Wallets exempt from the opening tax besides the developer; the module checks them as the reference
    ///        module does (zero entries are unused; no duplicates; never the developer, the hook, the token, the
    ///        PoolManager or the router).
    constructor(IPoolManager poolManager_, address token_, address uni_, address devRecipient_, address[6] memory exempt) {
        poolManager = poolManager_;
        token = token_;
        uni = uni_;
        devRecipient = devRecipient_;
        deployer = msg.sender;
        feeVault = new UN1FeeVault(poolManager_, uni_, devRecipient_);
        protectionModule = new UN1ProtectionModule(token_, address(poolManager_), devRecipient_, exempt);
        openingTaxVault = new UN1OpeningTaxVault(poolManager_, uni_);
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

    /// @notice Wire the fee recipients, here and in the normal-fee vault. Deployer only, once, before the pool exists.
    ///         The beacon (public infrastructure deployed before the launch) must be bound to this hook's token.
    function initialize(address distributor_, address beacon_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (distributor != address(0)) revert AlreadyInitialized();
        (bool ok, bytes memory ret) = beacon_.staticcall(abi.encodeWithSignature("token()"));
        if (!ok || ret.length != 32 || abi.decode(ret, (uint256)) != uint160(token)) revert BadBeacon();
        distributor = distributor_;
        beacon = beacon_;
        feeVault.bind(distributor_, beacon_);
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

    /// @notice Opening tax a buy by `buyer` pays now, in pips (the protection module's rule; exempt wallets pay none).
    function openingFee(address buyer) public view returns (uint256) {
        return protectionModule.openingTax(buyer, totalFee());
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
            // the pool's first swap is the launch buy, atomic with pool creation and required by the Seeder
            address buyer = protectionModule.protectedBuyer(sender, swapCount == 0);
            _tstore(T_BUYER, uint160(buyer));
            pips += protectionModule.openingTax(buyer, normal);
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

    /// @dev Mint the fee as UNI claims to the vaults, so a swap never depends on a recipient. An opening tax is the part
    ///      above the normal fee of the same gross amount: it goes to the opening-tax vault (platform treasury only), and
    ///      the normal fee is split as usual into the normal-fee vault's ledgers.
    function _accrue(bool buy, uint256 gross, uint256 fee) private {
        if (fee == 0) return;
        uint256 normal = _tload(T_NORMAL);
        uint256 id = uint256(uint160(uni));
        if (_tload(T_PIPS) > normal) {
            uint256 normalFee = Math.min(fee, Math.mulDiv(gross, normal, FeeMath.ONE));
            uint256 extra = fee - normalFee;
            poolManager.mint(address(openingTaxVault), id, extra);
            openingTaxVault.recordTax(extra);
            emit OpeningFeeTaken(address(uint160(_tload(T_BUYER))), gross, extra);
            fee = normalFee;
            if (fee == 0) return;
        }
        uint256 platform = FeeMath.share(gross, fee, PLATFORM_FEE);
        uint256 dev = FeeMath.share(gross, fee - platform, DEV_FEE);
        uint256 holders = fee - platform - dev;
        if (buy) devFeeOf[DrandRound.target(block.timestamp)] += dev; // the round the token targets for this buy
        // the reserve is what the beacon can still claim plus the UNI it already holds
        uint256 reserve = feeVault.bountyAccrued() + IBalanceOf(uni).balanceOf(beacon);
        uint256 topUp;
        if (reserve < BOUNTY_RESERVE) {
            topUp = BOUNTY_RESERVE - reserve;
            if (topUp > dev) topUp = dev;
        }
        poolManager.mint(address(feeVault), id, fee);
        feeVault.recordFees(platform, dev - topUp, topUp, holders);
        emit FeeTaken(buy, gross, platform, dev - topUp, holders);
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
