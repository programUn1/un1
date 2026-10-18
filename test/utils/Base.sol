// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {UN1Token} from "../../src/UN1Token.sol";
import {UN1Hook} from "../../src/UN1Hook.sol";
import {UN1Mirror} from "../../src/UN1Mirror.sol";
import {UN1Beacon} from "../../src/UN1Beacon.sol";
import {UN1Distributor} from "../../src/UN1Distributor.sol";
import {UN1Renderer} from "../../src/UN1Renderer.sol";
import {UN1MasksData} from "../../src/data/UN1MasksData.sol";
import {UN1PartsData} from "../../src/data/UN1PartsData.sol";
import {MockUniversalRouter, MockUsdFeed} from "./LaunchMocks.sol";
import {noExempt} from "./Exempt.sol";

/// @notice Local PoolManager + UNI mock + the UN1 contracts. The test contract plays the launch holder (it owns the
///  naked initial supply and seeds the official pool). `_fulfill` impersonates the beacon to reveal with chosen
///  randomness; Reveal.t.sol goes through the real UN1Beacon with real drand signatures.
abstract contract Base is Deployers {
    uint160 constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    address constant DEV = address(0xDE5);
    address constant PLATFORM = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;
    address constant UNI_USD_FEED = 0x553303d460EE0afB37EdFf9bE42922D8FF63220e; // UN1Seeder.UNI_USD

    MockERC20 uni;
    UN1Token token;
    UN1Hook hook;
    UN1Mirror mirror;
    UN1Beacon beacon;
    UN1Distributor distributor;
    UN1Renderer renderer;
    address partsData;
    address DISTRIBUTOR;
    address masks;
    PoolKey officialKey;
    bool uniIs0; // cached: a view call inside helpers would consume vm.prank / vm.expectRevert

    MockUniversalRouter router; // at UN1Hook.ROUTER
    MockUsdFeed uniUsd; // at UN1Seeder.UNI_USD, USD 20 per UNI
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function _startTime() internal pure virtual returns (uint256) {
        return 1_760_000_000;
    }

    /// @dev The hook's opening-fee exemptions besides the developer (none unless a test needs them).
    function _exempt() internal view virtual returns (address[6] memory) {
        return noExempt();
    }

    function setUp() public virtual {
        vm.warp(_startTime());
        deployFreshManagerAndRouters();
        _etchLaunchEnvironment();
        uni = new MockERC20("Uniswap", "UNI", 18);
        uni.mint(address(this), 1_000_000 ether);

        // public infrastructure first (the beacon is bound to the token's predicted address), then the launch graph
        // order: constructors only reference earlier targets; mutual links are set by initialize
        masks = address(new UN1MasksData());
        partsData = address(new UN1PartsData());
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        beacon = new UN1Beacon(predicted, address(uni));
        token = new UN1Token(address(manager), masks);
        require(address(token) == predicted, "predicted token address");
        address hookAddr = address(FLAGS | (uint160(0x4444) << 144));
        vm.setNonce(hookAddr, 1); // a new contract starts at nonce 1 (EIP-161): its CREATE children are the real ones
        deployCodeTo("UN1Hook.sol:UN1Hook", abi.encode(manager, address(token), address(uni), DEV, _exempt()), hookAddr);
        hook = UN1Hook(hookAddr);
        distributor = new UN1Distributor(address(uni), address(token), hookAddr, address(manager));
        renderer = new UN1Renderer(partsData);
        mirror = new UN1Mirror(address(token), address(renderer));
        hook.initialize(address(distributor), address(beacon));
        token.initialize(hookAddr, address(mirror), address(beacon), address(distributor), address(this));
        DISTRIBUTOR = address(distributor);

        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        uni.approve(address(swapRouter), type(uint256).max);
        uni.approve(address(modifyLiquidityRouter), type(uint256).max);

        officialKey = hook.poolKey();
        uniIs0 = hook.quoteIsCurrency0();
        manager.initialize(officialKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(officialKey, _range(1_000 ether), ZERO_BYTES);

        _fund(alice);
        _fund(bob);
    }

    function _fund(address who) internal {
        uni.mint(who, 10_000 ether);
        vm.startPrank(who);
        uni.approve(address(swapRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        uni.approve(address(router), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev The canonical router and the UNI / USD feed exist on mainnet; locally, stand-ins at the same addresses,
    ///      in place before the hook is deployed (it records the router's code).
    function _etchLaunchEnvironment() internal {
        deployCodeTo("LaunchMocks.sol:MockUniversalRouter", abi.encode(manager), hookRouter());
        router = MockUniversalRouter(hookRouter());
        deployCodeTo("LaunchMocks.sol:MockUsdFeed", abi.encode(int256(20e8)), UNI_USD_FEED);
        uniUsd = MockUsdFeed(UNI_USD_FEED);
    }

    function hookRouter() internal pure returns (address) {
        return 0xd92A36B0000531EF3063dEd4De20A0783308446C; // UN1Hook.ROUTER
    }

    /// @dev A buy through the canonical router, as during launch protection; exact output of `tokens`.
    function _routerBuy(address who, uint256 tokens) internal returns (BalanceDelta) {
        vm.prank(who);
        return router.swap(officialKey, uniIs0, int256(tokens));
    }

    /// @dev Data contract in the UN1 layout: STOP ‖ (PUSH32 ‖ 32 data bytes) per chunk (see gen_data_contracts.py).
    function _deployMasks(bytes memory data) internal returns (address d) {
        bytes memory code = hex"00";
        for (uint256 j; j < data.length; j += 32) {
            bytes memory chunk = new bytes(32);
            for (uint256 k; k < 32 && j + k < data.length; ++k) chunk[k] = data[j + k];
            code = abi.encodePacked(code, hex"7f", chunk);
        }
        bytes memory init = abi.encodePacked(hex"61", uint16(code.length), hex"80600c6000396000f3", code);
        assembly {
            d := create(0, add(init, 0x20), mload(init))
        }
        require(d != address(0), "masks");
    }

    function _range(int256 liquidity) internal pure returns (IPoolManager.ModifyLiquidityParams memory) {
        return IPoolManager.ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: liquidity, salt: 0});
    }

    function _swap(PoolKey memory key, bool buy, int256 amountSpecified) internal returns (BalanceDelta) {
        bool zeroForOne = buy == uniIs0;
        return swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function _buy(address who, uint256 tokens) internal {
        vm.prank(who);
        _swap(officialKey, true, int256(tokens));
    }

    function _sell(address who, uint256 tokens) internal {
        vm.prank(who);
        _swap(officialKey, false, -int256(tokens));
    }

    /// @dev Past launch protection (5 minutes from pool creation).
    function _skipOpening() internal {
        vm.warp(block.timestamp + 5 minutes);
    }

    /// @dev Reveal every pending slot, bucket by bucket, with randomness derived from `salt`.
    function _revealAll(bytes32 salt) internal {
        uint256 n = token.slotCount();
        for (uint256 i = token.slotHead(); i < n; ++i) {
            (, uint64 round, bool alive) = token.slotOf(i);
            if (!alive) continue;
            _fulfill(round, keccak256(abi.encode(salt, round)), type(uint256).max);
        }
    }

    function _fulfill(uint64 round, bytes32 randomness, uint256 max) internal returns (uint256) {
        vm.prank(address(beacon));
        return token.fulfill(round, randomness, max);
    }

    /// @dev Global invariants: every id is in exactly one place; units never exceed whole tokens.
    function _checkInvariants(address[] memory holders) internal view {
        uint256 owned;
        uint256 pending;
        for (uint256 i; i < holders.length; ++i) {
            uint256 ids = token.idCount(holders[i]);
            uint256 p = token.pendingCount(holders[i]);
            assertLe(ids + p, token.balanceOf(holders[i]) / 1 ether, "units <= whole tokens");
            owned += ids;
            pending += p;
        }
        assertEq(owned + token.poolCount() + token.retiredCount(), 10_000, "ids conserved");
        assertLe(owned + pending, token.totalSupply() / 1 ether, "cards + slots <= supply");
        // the ownership graph, not only the counts (review R-01): every listed id points back to its holder, once
        uint256[40] memory seen;
        for (uint256 i; i < holders.length; ++i) {
            uint256[] memory ids = token.idsOf(holders[i]);
            assertEq(ids.length, token.idCount(holders[i]), "list length = count");
            for (uint256 j; j < ids.length; ++j) {
                uint256 b = ids[j] - 1;
                assertEq(token.ownerOfId(ids[j]), holders[i], "a listed id points back to its holder");
                assertEq((seen[b >> 8] >> (b & 255)) & 1, 0, "an id is listed once");
                seen[b >> 8] |= 1 << (b & 255);
            }
        }
    }
}
