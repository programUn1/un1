// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {UN1Seeder} from "../src/UN1Seeder.sol";
import {ForkGraph, IPermit2R, IUniversalRouterR, ExactInputSingle} from "./ForkRehearsal.t.sol";
import {PathKey, ExactInputCanonical} from "./Fork.t.sol";

/// @notice Launch protection on a mainnet fork (read-only, nothing broadcast): the real canonical Universal Router
///  (0xd92A…446C) names the buyer; the older router (0x66a9…A8Af) cannot buy during protection; the opening fee, the
///  2% buyer cap and the USD 15,000 opening valuation against the real Chainlink UNI / USD feed.
contract ForkProtectionTest is ForkGraph {
    IUniversalRouterR constant CANONICAL = ROUTER;

    Graph g;
    uint256 t0;

    function _launch() internal {
        g = _deployGraph(false, 21);
        _ignite(g, 0.2 ether);
        t0 = block.timestamp;
        _approve(alice, address(CANONICAL));
        _approve(alice, address(OLDER_ROUTER));
        deal(UNI, alice, 1_000 ether);
    }

    function _approve(address who, address router) internal {
        vm.startPrank(who);
        IERC20(UNI).approve(PERMIT2, type(uint256).max);
        IPermit2R(PERMIT2).approve(UNI, router, type(uint160).max, type(uint48).max);
        IERC20(address(g.token)).approve(PERMIT2, type(uint256).max);
        IPermit2R(PERMIT2).approve(address(g.token), router, type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    error V4TooLittleReceived(uint256 minAmountOutReceived, uint256 amountReceived);

    /// @dev The V4_SWAP input of one exact-input swap (a buy pays UNI; a sell pays tokens), as the website sends it.
    function _single(bool buy, uint128 amountIn, uint128 minOut) internal view returns (bytes[] memory inputs) {
        PoolKey memory key = g.hook.poolKey();
        bool zeroForOne = buy == g.hook.quoteIsCurrency0();
        (Currency cin, Currency cout) = buy
            ? (Currency.wrap(UNI), Currency.wrap(address(g.token)))
            : (Currency.wrap(address(g.token)), Currency.wrap(UNI));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingle(key, zeroForOne, amountIn, minOut, ""));
        params[1] = abi.encode(cin, uint256(amountIn));
        params[2] = abi.encode(cout, uint256(0));
        inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f)), params);
    }

    /// @dev The pool reads happen first, so `reverts` applies to the router call itself.
    function _trade(IUniversalRouterR router, address who, bool buy, uint128 amountIn, bool reverts) internal {
        bytes[] memory inputs = _single(buy, amountIn, 0);
        if (reverts) vm.expectRevert();
        vm.prank(who);
        router.execute(hex"10", inputs, block.timestamp + 60);
    }

    function _buyCanonical(address who, uint128 uniIn) internal {
        _trade(CANONICAL, who, true, uniIn, false);
    }

    function test_fork_protection_canonicalRouterNamesTheBuyer_andTheOpeningFeeGoesToThePlatform() public onlyFork {
        _launch();
        vm.warp(t0 + 10);
        uint256 pips = g.hook.buyFee(alice);
        assertEq(pips, g.hook.totalFee() + (990_000 - g.hook.totalFee()) * 20 / 30, "two thirds of the way from 99%");
        uint256 platformBefore = g.hook.owed(PLATFORM);
        _buyCanonical(alice, 10 ether);
        uint256 got = IERC20(address(g.token)).balanceOf(alice);
        assertGt(got, 0);
        assertEq(g.hook.boughtDuringProtection(alice), got, "the buyer is the router's caller");
        assertEq(g.token.receivedDuringProtection(alice), got);
        assertGt(g.hook.openingFeesCollected(), 6 ether, "about 6.4 of the 10 UNI is opening fee at second 10");
        assertEq(g.hook.owed(PLATFORM) - platformBefore, 0.03 ether + g.hook.openingFeesCollected());
        emit log_named_uint("tokens for 10 UNI at second 10", got);
    }

    function test_fork_protection_olderRouterCannotBuy_untilProtectionEnds() public onlyFork {
        _launch();
        vm.warp(t0 + 31);
        _trade(OLDER_ROUTER, alice, true, 1 ether, true);
        _buyCanonical(alice, 1 ether);
        uint256 got = IERC20(address(g.token)).balanceOf(alice);
        _trade(OLDER_ROUTER, alice, false, uint128(got / 2), false); // sells through any router
        vm.warp(t0 + 5 minutes);
        _trade(OLDER_ROUTER, alice, true, 1 ether, false);
    }

    function test_fork_protection_multiHop_ETH_UNI_UN1_throughTheCanonicalRouter() public onlyFork {
        _launch();
        vm.warp(t0 + 31);
        PoolKey memory key = g.hook.poolKey();
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey(Currency.wrap(UNI), 3000, 60, IHooks(address(0)), "");
        path[1] = PathKey(Currency.wrap(address(g.token)), key.fee, key.tickSpacing, key.hooks, "");
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputCanonical(Currency.wrap(address(0)), path, new uint256[](0), 0.01 ether, 1));
        params[1] = abi.encode(Currency.wrap(address(0)), uint256(0.01 ether));
        params[2] = abi.encode(Currency.wrap(address(g.token)), uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(uint8(0x07), uint8(0x0c), uint8(0x0f)), params);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        CANONICAL.execute{value: 0.01 ether}(hex"10", inputs, block.timestamp + 60);
        uint256 got = IERC20(address(g.token)).balanceOf(alice);
        assertGt(got, 0, "ETH -> UNI -> UN1");
        assertEq(g.hook.boughtDuringProtection(alice), got);
    }

    function test_fork_protection_buyerLimitWithTheRealRouter() public onlyFork {
        _launch();
        vm.warp(t0 + 31);
        _trade(CANONICAL, alice, true, 300 ether, true); // about 300 UNI buys far more than 200 tokens here
        _buyCanonical(alice, 20 ether);
        assertLe(g.hook.boughtDuringProtection(alice), g.hook.BUYER_LIMIT());
    }

    /// @dev The V4 quoter cannot quote a buy during protection (only the canonical router may buy). The website
    ///      quotes by simulating the router call with an impossible minimum: the swap runs with the real buyer, and
    ///      the router reverts with what it would have received, before anything is paid.
    function test_fork_protection_routerSimulationQuotesTheBuy() public onlyFork {
        _launch();
        vm.warp(t0 + 10);
        bytes[] memory probe = _single(true, 10 ether, type(uint128).max);
        uint256 quoted;
        vm.prank(alice);
        try CANONICAL.execute(hex"10", probe, block.timestamp + 60) {
            revert("the simulation must revert");
        } catch (bytes memory err) {
            assertEq(bytes4(err), V4TooLittleReceived.selector, "the router's own error, not wrapped");
            (, quoted) = abi.decode(_tail(err), (uint256, uint256));
        }
        assertEq(IERC20(UNI).balanceOf(alice), 1_000 ether, "nothing was paid");
        _buyCanonical(alice, 10 ether);
        assertEq(IERC20(address(g.token)).balanceOf(alice), quoted, "the simulation quoted the buy exactly");
    }

    function _tail(bytes memory err) internal pure returns (bytes memory out) {
        out = new bytes(err.length - 4);
        for (uint256 i; i < out.length; ++i) out[i] = err[i + 4];
    }

    function test_fork_protection_openingValuationAgainstChainlink() public onlyFork {
        g = _deployGraph(false, 22);
        uint256 usd = g.seeder.openingFdvUsd(-13_860);
        emit log_named_uint("opening valuation at 0.25 UNI per token (USD)", usd);
        assertGt(usd, 15_000);
        assertLt(g.seeder.openingFdvUsd(-23_040), 15_000, "0.1 UNI per token is below the floor at this block");
        UN1Seeder.IgniteParams memory p = _igniteParams();
        p.uniPerTokenTick = -23_040;
        vm.deal(address(this), 0.2 ether);
        vm.expectRevert();
        g.factory.call{value: 0.2 ether}(address(g.seeder), abi.encodeCall(UN1Seeder.ignite, (p)));
    }
}
