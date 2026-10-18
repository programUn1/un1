// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC6909Claims} from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {UN1Token} from "../src/UN1Token.sol";
import {UN1Beacon} from "../src/UN1Beacon.sol";
import {UN1Mirror} from "../src/UN1Mirror.sol";
import {ForkGraph, IPermit2R} from "./ForkRehearsal.t.sol";
import {ExactInputCanonical, PathKey} from "./Fork.t.sol";

interface IV4Quoter {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    struct QuoteExactParams {
        Currency exactCurrency;
        PathKey[] path;
        uint128 exactAmount;
    }

    function quoteExactInputSingle(QuoteExactSingleParams memory params) external returns (uint256 amountOut, uint256 gasEstimate);
    function quoteExactInput(QuoteExactParams memory params) external returns (uint256 amountOut, uint256 gasEstimate);
}

interface IAllowanceTransfer {
    function transferFrom(address from, address to, uint160 amount, address token) external;
}

interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce) external returns (address proxy);
}

interface ISafe {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
    function nonce() external view returns (uint256);
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 _nonce
    ) external view returns (bytes32);
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool success);
}

/// @dev A custom PoolManager locker, the way an aggregator executor talks to v4 directly.
contract Locker is IUnlockCallback {
    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;

    enum Mode {
        SettleFirstSell, // pay UN1 into the PoolManager before swapping
        SettleFirstBuy, // pay UNI first, swap, take UN1
        BuyAsClaims, // pay UNI, swap, keep UN1 as ERC-6909 claims
        RedeemClaims, // burn UN1 claims and take the ERC20
        SellClaims // swap UN1 → UNI paying with UN1 claims
    }

    PoolKey public key;
    address public token;

    constructor(PoolKey memory key_, address token_) {
        key = key_;
        token = token_;
    }

    function run(Mode mode, uint256 amount) external returns (uint256 out) {
        out = abi.decode(PM.unlock(abi.encode(mode, amount)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(PM), "only PM");
        (Mode mode, uint256 amount) = abi.decode(data, (Mode, uint256));
        PoolKey memory k = key;
        bool uniIs0 = Currency.unwrap(k.currency0) == UNI;
        uint256 out;
        if (mode == Mode.SettleFirstSell) {
            PM.sync(Currency.wrap(token));
            IERC20(token).transfer(address(PM), amount); // reverts: no hook allowance yet
            PM.settle();
        } else if (mode == Mode.SettleFirstBuy || mode == Mode.BuyAsClaims) {
            PM.sync(Currency.wrap(UNI));
            IERC20(UNI).transfer(address(PM), amount);
            PM.settle();
            out = _swap(k, uniIs0, amount);
            if (mode == Mode.SettleFirstBuy) PM.take(Currency.wrap(token), address(this), out);
            else PM.mint(address(this), uint256(uint160(token)), out);
        } else if (mode == Mode.RedeemClaims) {
            PM.burn(address(this), uint256(uint160(token)), amount);
            PM.take(Currency.wrap(token), address(this), amount); // reverts: no hook allowance
        } else {
            out = _swap(k, !uniIs0, amount);
            PM.burn(address(this), uint256(uint160(token)), amount);
            PM.take(Currency.wrap(UNI), address(this), out);
        }
        return abi.encode(out);
    }

    /// @dev Exact-in swap; returns the positive output amount.
    function _swap(PoolKey memory k, bool zeroForOne, uint256 amountIn) internal returns (uint256) {
        BalanceDelta d = PM.swap(
            k,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 o = zeroForOne ? d.amount1() : d.amount0();
        return uint256(uint128(o));
    }
}

/// @notice The rest (mainnet fork, read only, nothing broadcast): V4Quoter quotes, aggregator-style routing and direct PoolManager calls, a real Safe, real EIP-7702
///  delegation, UniswapX-style Permit2 pulls.
contract ForkEdgeTest is ForkGraph {
    IV4Quoter constant QUOTER = IV4Quoter(0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203);
    address constant COW_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41; // GPv2Settlement
    address constant ONEINCH_V6 = 0x111111125421cA6dc452d289314280a0f8842A65; // AggregationRouterV6
    address constant UNISWAPX_REACTOR = 0x00000011F84B9aa48e5f8aA8B9897600006289Be; // V2DutchOrderReactor
    ISafeProxyFactory constant SAFE_FACTORY = ISafeProxyFactory(0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67);
    address constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a; // Safe 1.4.1
    address constant SAFE_FALLBACK = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99; // CompatibilityFallbackHandler 1.4.1
    address constant DELEGATOR_7702 = 0x63c0c19a282a1B52b07dD5a65b58948A07DAE32B; // EIP7702StatelessDeleGator (MetaMask)
    uint256 constant W1 = 10_000;

    Graph g;

    /// @dev Launch, then move past the opening cap to the buy time the drand fixture was pinned for.
    function _launch() internal {
        g = _deployGraph(false, 11);
        _ignite(g, 0.2 ether);
        vm.warp(vm.parseJsonUint(vm.readFile("test/fixtures/fork.json"), ".tBuy"));
    }

    function _approveRouter(address who, address tokenAddr) internal {
        vm.startPrank(who);
        IERC20(tokenAddr).approve(PERMIT2, type(uint256).max);
        IPermit2R(PERMIT2).approve(tokenAddr, address(ROUTER), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _fund(address who, uint256 uniAmount) internal {
        deal(UNI, who, uniAmount);
        _approveRouter(who, UNI);
        _approveRouter(who, address(g.token));
    }

    /// @dev Reveal every pending slot of the pinned round with its real drand signature.
    function _revealAll() internal {
        string memory fx = vm.readFile("test/fixtures/fork.json");
        uint64 round = uint64(vm.parseJsonUint(fx, ".round"));
        bytes memory sig = vm.parseJsonBytes(fx, ".signature");
        vm.warp(vm.parseJsonUint(fx, ".roundTime"));
        for (uint256 i; i < 16; ++i) {
            try UN1Beacon(g.beacon).reveal(round, sig, 64, address(this)) {}
            catch {
                break; // NothingToReveal: every slot of the round is measured
            }
        }
    }

    // ---------------------------------------------------------------- V4Quoter (the website's quotes)

    function test_quoter_singleHop_matchesTheRouter() public onlyFork {
        _launch();
        _fund(alice, 100 ether);
        PoolKey memory key = g.hook.poolKey();
        bool uniIs0 = g.hook.quoteIsCurrency0();
        (uint256 q,) = QUOTER.quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams(key, uniIs0, 10 ether, ""));
        _routerTrade(g, alice, true, 10 ether);
        uint256 got = IERC20(address(g.token)).balanceOf(alice);
        emit log_named_uint("quote: tokens for 10 UNI", q);
        assertEq(got, q, "buy quote is exact");

        (uint256 qs,) = QUOTER.quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams(key, !uniIs0, uint128(5 ether), ""));
        uint256 uniBefore = IERC20(UNI).balanceOf(alice);
        _routerTrade(g, alice, false, 5 ether);
        assertEq(IERC20(UNI).balanceOf(alice) - uniBefore, qs, "sell quote is exact");
    }

    function test_quoter_multiHop_ETH_matchesTheRouter() public onlyFork {
        _launch();
        PoolKey memory key = g.hook.poolKey();
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey(Currency.wrap(UNI), 3000, 60, IHooks(address(0)), "");
        path[1] = PathKey(Currency.wrap(address(g.token)), key.fee, key.tickSpacing, key.hooks, "");
        (uint256 q,) = QUOTER.quoteExactInput(IV4Quoter.QuoteExactParams(Currency.wrap(address(0)), path, 0.05 ether));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputCanonical(Currency.wrap(address(0)), path, new uint256[](0), 0.05 ether, uint128(q * 99 / 100)));
        params[1] = abi.encode(Currency.wrap(address(0)), uint256(0.05 ether));
        params[2] = abi.encode(Currency.wrap(address(g.token)), uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(uint8(0x07), uint8(0x0c), uint8(0x0f)), params);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        ROUTER.execute{value: 0.05 ether}(hex"10", inputs, block.timestamp + 60);
        emit log_named_uint("quote: tokens for 0.05 ETH", q);
        assertEq(IERC20(address(g.token)).balanceOf(alice), q, "multi-hop quote is exact");
    }

    // ---------------------------------------------------------------- aggregators

    /// @dev CoW and 1inch settle through the official pool into their own contract, then forward the tokens: the
    ///      contract holds the pending slots without weight, and the slots follow the tokens to the user.
    function _intermediary(address via) internal {
        _launch();
        _fund(via, 50 ether);
        _routerTrade(g, via, true, 20 ether);
        uint256 bal = IERC20(address(g.token)).balanceOf(via);
        uint256 slots = g.token.pendingCount(via);
        assertEq(slots, bal / 1 ether, "the intermediary receives the slots");
        assertEq(g.token.weightOf(via), 0, "a contract earns nothing without optIn");
        vm.prank(via);
        IERC20(address(g.token)).transfer(alice, bal);
        assertEq(g.token.pendingCount(via), 0);
        assertEq(g.token.pendingCount(alice), slots, "the slots follow the tokens to the user");
        assertEq(g.token.weightOf(alice), slots * W1, "the user is weighted");
        _revealAll();
        assertEq(g.token.idCount(alice), slots, "measured for the user");
    }

    function test_aggregator_cowSettlement_forwardsSlots() public onlyFork {
        _intermediary(COW_SETTLEMENT);
    }

    function test_aggregator_oneInchRouter_forwardsSlots() public onlyFork {
        _intermediary(ONEINCH_V6);
    }

    function test_uniswapX_permit2Pull_movesCardsAsTheyAre() public onlyFork {
        _launch();
        _fund(alice, 50 ether);
        _routerTrade(g, alice, true, 20 ether);
        _revealAll();
        uint256 before = g.token.idCount(alice);
        address filler = makeAddr("filler");
        vm.prank(alice);
        IPermit2R(PERMIT2).approve(address(g.token), UNISWAPX_REACTOR, type(uint160).max, type(uint48).max);
        vm.prank(UNISWAPX_REACTOR);
        IAllowanceTransfer(PERMIT2).transferFrom(alice, filler, 3 ether, address(g.token));
        assertEq(g.token.idCount(filler), 3, "three cards pulled through Permit2");
        assertEq(g.token.idCount(alice), before - 3);
        uint256 id = g.token.idsOf(filler)[0];
        (address owner,,, uint64 look) = g.token.cardOf(id);
        assertEq(owner, filler);
        assertGt(look, 0, "an old card keeps its phase");
    }

    /// @dev Executors that pay UN1 into the PoolManager before the swap fail: the hook grants the allowance only
    ///      inside the swap. Paying UNI first works.
    /// @dev Inside ONE transaction the allowance the hook granted for a buy that was kept as claims is still there:
    ///      the claims can be withdrawn and open the same slots the buy would have. Bounded by what was bought (and
    ///      paid for) in the official pool in that transaction.
    function test_directLocker_claimsRedeemedInTheSameTransaction() public onlyFork {
        _launch();
        Locker l = new Locker(g.hook.poolKey(), address(g.token));
        deal(UNI, address(l), 30 ether);
        uint256 out = l.run(Locker.Mode.BuyAsClaims, 10 ether);
        l.run(Locker.Mode.RedeemClaims, out);
        assertEq(IERC20(address(g.token)).balanceOf(address(l)), out);
        assertEq(g.token.pendingCount(address(l)), out / 1 ether, "the same slots as a plain buy");
    }

    function test_directLocker_settleFirst() public onlyFork {
        _launch();
        Locker l = new Locker(g.hook.poolKey(), address(g.token));
        deal(UNI, address(l), 30 ether);
        uint256 out = l.run(Locker.Mode.SettleFirstBuy, 10 ether);
        assertEq(IERC20(address(g.token)).balanceOf(address(l)), out, "UNI paid first: buy works");
        assertEq(g.token.pendingCount(address(l)), out / 1 ether, "and opens slots");
        vm.expectRevert();
        l.run(Locker.Mode.SettleFirstSell, 1 ether);
    }

    /// @dev UN1 kept as ERC-6909 claims opens no slot and, in a later transaction, cannot be withdrawn directly as
    ///      ERC20; it can be sold into the official pool (or pay for an official position that a later transaction
    ///      removes as naked tokens, see review/ReviewClaimsThroughLiquidity). `isolate` runs every call as its own
    ///      transaction, so the hook's transient allowance from the buy is gone, as on mainnet.
    /// forge-config: default.isolate = true
    function test_directLocker_erc6909Claims() public onlyFork {
        _launch();
        Locker l = new Locker(g.hook.poolKey(), address(g.token));
        deal(UNI, address(l), 30 ether);
        uint256 out = l.run(Locker.Mode.BuyAsClaims, 10 ether);
        assertEq(IERC6909Claims(address(PM)).balanceOf(address(l), uint256(uint160(address(g.token)))), out);
        assertEq(g.token.pendingCount(address(l)), 0, "claims are not units");
        vm.expectRevert();
        l.run(Locker.Mode.RedeemClaims, out);
        uint256 uniBefore = IERC20(UNI).balanceOf(address(l));
        l.run(Locker.Mode.SellClaims, out);
        assertGt(IERC20(UNI).balanceOf(address(l)), uniBefore, "claims sell into the official pool");
    }

    // ---------------------------------------------------------------- wallets

    function test_realSafe_holdsCards_thenOptsIn_andMovesACard() public onlyFork {
        _launch();
        _fund(alice, 50 ether);
        _routerTrade(g, alice, true, 20 ether);
        _revealAll();
        (address owner, uint256 pk) = makeAddrAndKey("safe-owner");
        address[] memory owners = new address[](1);
        owners[0] = owner;
        bytes memory setup = abi.encodeCall(ISafe.setup, (owners, 1, address(0), "", SAFE_FALLBACK, address(0), 0, payable(address(0))));
        ISafe safe = ISafe(SAFE_FACTORY.createProxyWithNonce(SAFE_SINGLETON, setup, 1));

        vm.prank(alice);
        IERC20(address(g.token)).transfer(address(safe), 2 ether);
        assertEq(g.token.idCount(address(safe)), 2, "a Safe holds cards");
        assertFalse(g.token.isWeighted(address(safe)));
        assertEq(g.token.weightOf(address(safe)), 0);

        _exec(safe, pk, address(g.token), abi.encodeCall(UN1Token.optIn, ()));
        assertTrue(g.token.isWeighted(address(safe)), "optIn through execTransaction");
        assertGt(g.token.weightOf(address(safe)), 0);

        uint256 id = g.token.idsOf(address(safe))[1];
        _exec(safe, pk, g.mirror, abi.encodeCall(UN1Mirror.transferFrom, (address(safe), alice, id)));
        assertEq(g.token.ownerOfId(id), alice, "the Safe moves a named card through the mirror");
        assertEq(g.token.idCount(address(safe)), 1);
    }

    function _exec(ISafe safe, uint256 pk, address to, bytes memory data) internal {
        bytes memory sig = _sign(safe, pk, to, data);
        assertTrue(safe.execTransaction(to, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), sig));
    }

    function _sign(ISafe safe, uint256 pk, address to, bytes memory data) internal view returns (bytes memory) {
        // encoded by hand: ten arguments overflow the legacy code generator's stack
        bytes memory q = abi.encodeWithSelector(ISafe.getTransactionHash.selector, to, 0, data, 0, 0, 0, 0, address(0), address(0), safe.nonce());
        (, bytes memory ret) = address(safe).staticcall(q);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, abi.decode(ret, (bytes32)));
        return abi.encodePacked(r, s, v);
    }

    function test_real7702Delegation_isWeightedAutomatically() public onlyFork {
        _launch();
        _fund(alice, 50 ether);
        _routerTrade(g, alice, true, 20 ether);
        _revealAll();
        (address bob, uint256 pk) = makeAddrAndKey("bob-7702");
        // the authorization applies to the next call, before it executes (as in a type-4 transaction)
        vm.signAndAttachDelegation(DELEGATOR_7702, pk);
        vm.prank(alice);
        IERC20(address(g.token)).transfer(bob, 1 ether);
        assertEq(bob.code.length, 23, "delegation designator 0xef0100 || implementation");
        assertEq(bytes3(bob.code), bytes3(0xef0100));
        assertEq(g.token.idCount(bob), 1);
        assertTrue(g.token.isWeighted(bob), "an EIP-7702 account earns without optIn");
        assertGt(g.token.weightOf(bob), 0);
    }
}
