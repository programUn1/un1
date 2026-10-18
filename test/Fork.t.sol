// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {UN1Token} from "../src/UN1Token.sol";
import {UN1Hook} from "../src/UN1Hook.sol";
import {UN1Mirror} from "../src/UN1Mirror.sol";
import {UN1Beacon} from "../src/UN1Beacon.sol";
import {UN1Distributor} from "../src/UN1Distributor.sol";
import {UN1Renderer} from "../src/UN1Renderer.sol";
import {UN1Seeder} from "../src/UN1Seeder.sol";
import {UN1MasksData} from "../src/data/UN1MasksData.sol";
import {UN1PartsData} from "../src/data/UN1PartsData.sol";
import {noExempt} from "./utils/Exempt.sol";
import {Fees} from "./utils/Fees.sol";

using Fees for UN1Hook;

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @dev Universal Router V4 swap parameters as deployed (no per-hop price fields) and as on v4-periphery main.
struct ExactInputSingleV1 {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

struct ExactInputSingleV2 {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    uint256 minHopPriceX36;
    bytes hookData;
}

struct PathKey {
    Currency intermediateCurrency;
    uint24 fee;
    int24 tickSpacing;
    IHooks hooks;
    bytes hookData;
}

/// @dev The canonical router's multi-hop input: its v4 periphery has per-hop slippage bounds (empty = none).
struct ExactInputCanonical {
    Currency currencyIn;
    PathKey[] path;
    uint256[] maxHopSlippage;
    uint128 amountIn;
    uint128 amountOutMinimum;
}

/// @notice An Ethereum mainnet fork, simulated locally: nothing is broadcast, no real ETH, no private key.
///  Real contracts: the v4 PoolManager, UNI, the ETH/UNI 0.3% pool, Permit2, the Universal Router, EIP-2935, the EIP-2537 precompiles.
///  The fork block and the drand signature are pinned in test/fixtures/fork.json, so every run is reproducible.
contract ForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IERC20 constant UNI = IERC20(0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984);
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    /// @dev The canonical Universal Router: the only one launch protection admits for buys, and the website's.
    IUniversalRouter constant ROUTER = IUniversalRouter(0xd92A36B0000531EF3063dEd4De20A0783308446C);
    address constant HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935;
    address constant PLATFORM = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;
    address constant DEV = address(0xDE5);
    uint160 constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    UN1Token token;
    UN1Hook hook;
    UN1Mirror mirror;
    UN1Beacon beacon;
    UN1Distributor distributor;
    UN1Renderer renderer;
    UN1Seeder seeder;
    PoolKey key;
    bool uniIs0;
    UN1Seeder.Result launch;

    uint256 forkBlock;
    uint256 tBuy;
    uint64 round;
    bytes signature;

    address alice = makeAddr("alice");
    bool forked;

    /// @dev Without ETH_RPC_URL (plain `forge test`) the fork tests are skipped, not failed.
    modifier onlyFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function setUp() public {
        string memory url = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        forked = true;
        string memory f = vm.readFile("test/fixtures/fork.json");
        forkBlock = vm.parseJsonUint(f, ".block");
        tBuy = vm.parseJsonUint(f, ".tBuy");
        round = uint64(vm.parseJsonUint(f, ".round"));
        signature = vm.parseJsonBytes(f, ".signature");
        vm.createSelectFork(url, forkBlock);

        // infrastructure first (the beacon is bound to the token's predicted address), then the launch graph:
        // constructors reference earlier targets only; initialize wires the rest; ignite runs last
        address masks = address(new UN1MasksData());
        address parts = address(new UN1PartsData());
        beacon = new UN1Beacon(vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1), address(UNI));
        token = new UN1Token(address(PM), masks);
        require(address(beacon.token()) == address(token), "predicted token address");
        address hookAddr = address(FLAGS | (uint160(0x4444) << 144));
        deployCodeTo("UN1Hook.sol:UN1Hook", abi.encode(PM, address(token), address(UNI), DEV, noExempt()), hookAddr);
        hook = UN1Hook(hookAddr);
        distributor = new UN1Distributor(address(UNI), address(token), hookAddr, address(PM));
        renderer = new UN1Renderer(parts);
        mirror = new UN1Mirror(address(token), address(renderer));
        seeder = new UN1Seeder(address(PM), address(UNI), DEV, address(token), hookAddr);
        hook.initialize(address(distributor), address(beacon));
        token.initialize(hookAddr, address(mirror), address(beacon), address(distributor), address(seeder));
        key = hook.poolKey();
        uniIs0 = hook.quoteIsCurrency0();

        // open at 0.25 UNI per token (about USD 18,500 for the supply at this block, above the USD 15,000 floor of
        // launch protection); the supply sits from there up to 25 UNI per token
        UN1Seeder.IgniteParams memory p = UN1Seeder.IgniteParams({
            uniPerTokenTick: -13_860, // 1.0001^-13860 ≈ 0.25 UNI per token
            rangeTicks: 46_080, // up to about 25 UNI per token
            buyBps: 5_000,
            minUniOut: 1,
            minTokensOut: 1
        });
        vm.deal(address(this), 1 ether);
        launch = seeder.ignite{value: 0.2 ether}(p);
    }

    function _data(bytes memory data) internal returns (address d) {
        bytes memory code = abi.encodePacked(hex"00", data);
        bytes memory init = abi.encodePacked(hex"61", uint16(code.length), hex"80600c6000396000f3", code);
        assembly {
            d := create(0, add(init, 0x20), mload(init))
        }
        require(d != address(0), "data");
    }

    // ---------------------------------------------------------------- helpers: Universal Router

    function _fundUni(address who, uint256 amount) internal {
        deal(address(UNI), who, amount);
        vm.startPrank(who);
        UNI.approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(address(UNI), address(ROUTER), type(uint160).max, type(uint48).max);
        IERC20(address(token)).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(address(token), address(ROUTER), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    /// @dev V4_SWAP: SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL. Tries the deployed struct first, then the newer one.
    function _routerSingle(address who, bool buy, uint128 amountIn) internal returns (bool v1, uint256 gasUsed) {
        bool zeroForOne = buy == uniIs0;
        (Currency cin, Currency cout) = buy ? (Currency.wrap(address(UNI)), Currency.wrap(address(token))) : (Currency.wrap(address(token)), Currency.wrap(address(UNI)));
        bytes[] memory params = new bytes[](3);
        params[1] = abi.encode(cin, uint256(amountIn));
        params[2] = abi.encode(cout, uint256(0));
        bytes memory actions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));
        bytes[] memory inputs = new bytes[](1);

        params[0] = abi.encode(ExactInputSingleV1(key, zeroForOne, amountIn, 0, ""));
        inputs[0] = abi.encode(actions, params);
        uint256 g = gasleft();
        vm.prank(who);
        try ROUTER.execute(hex"10", inputs, block.timestamp + 60) {
            return (true, g - gasleft());
        } catch {}
        params[0] = abi.encode(ExactInputSingleV2(key, zeroForOne, amountIn, 0, 0, ""));
        inputs[0] = abi.encode(actions, params);
        g = gasleft();
        vm.prank(who);
        ROUTER.execute(hex"10", inputs, block.timestamp + 60);
        return (false, g - gasleft());
    }

    // ---------------------------------------------------------------- launch

    function test_fork_launch_oneTransaction() public onlyFork {
        assertGt(launch.tokenOnlyLiquidity, 0, "supply in the pool");
        assertGt(launch.uniFromEth, 0, "ETH -> UNI on the real ETH/UNI pool");
        assertGt(launch.bought, 0, "dev buy");
        assertGt(launch.bidLiquidity, 0, "the UNI not spent on the buy is a locked bid");
        assertGt(hook.owed(PLATFORM), 0, "the 0.3% platform fee is charged on the first buy");
        assertEq(hook.swapCount(), 1);
        assertEq(token.balanceOf(DEV), launch.bought, "the launch buy goes to the developer");
        assertEq(token.pendingCount(DEV) + token.idCount(DEV), 0, "as plain tokens: the launch deals no card");
        assertLt(token.balanceOf(address(seeder)), 1 ether, "the Seeder keeps only rounding dust");
        assertEq(token.pendingCount(address(seeder)), 0, "no card dealt to the launch");
        assertEq(token.idCount(address(seeder)), 0);
        assertEq(token.slotCount(), 0);
        assertEq(token.poolCount(), 10_000, "all ids in superposition");
        assertGe(token.balanceOf(address(PM)) + launch.bought, 10_000 ether - 1 ether, "the rest of the supply is in the PoolManager");
        assertEq(address(seeder).balance, 0);
        emit log_named_uint("fork block", forkBlock);
        emit log_named_uint("UNI from 0.2 ETH", launch.uniFromEth);
        emit log_named_uint("dev buy, tokens", launch.bought);
        emit log_named_uint("platform fee on the first buy (UNI)", hook.owed(PLATFORM));
        emit log_named_uint("UNI dust to dev", launch.uniDust);
    }

    function test_fork_launch_onlyOnce_onlyDeployer() public onlyFork {
        UN1Seeder.IgniteParams memory p;
        vm.expectRevert(UN1Seeder.AlreadyIgnited.selector);
        seeder.ignite(p);
        vm.prank(alice);
        vm.expectRevert(UN1Seeder.NotDeployer.selector);
        seeder.ignite(p);
    }

    // ---------------------------------------------------------------- Universal Router (real)

    function test_fork_universalRouter_buyAndSell() public onlyFork {
        assertGt(address(ROUTER).code.length, 0, "router deployed at this block");
        vm.warp(tBuy);
        _fundUni(alice, 100 ether);
        (bool v1, uint256 gasBuy) = _routerSingle(alice, true, 20 ether);
        uint256 got = token.balanceOf(alice);
        assertGt(got, 1 ether, "bought through the Universal Router");
        assertEq(token.pendingCount(alice), got / 1 ether, "slots dealt to the buyer");
        emit log_named_string("deployed ExactInputSingleParams", v1 ? "without minHopPriceX36" : "with minHopPriceX36");
        emit log_named_uint("router buy gas", gasBuy);
        emit log_named_uint("tokens for 20 UNI", got);

        uint256 uniBefore = UNI.balanceOf(alice);
        (, uint256 gasSell) = _routerSingle(alice, false, uint128(got / 2));
        assertGt(UNI.balanceOf(alice), uniBefore, "sold through the Universal Router");
        emit log_named_uint("router sell gas", gasSell);
    }

    function test_fork_universalRouter_multiHop_ETH_UNI_UN1() public onlyFork {
        vm.warp(tBuy);
        vm.deal(alice, 1 ether);
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey(Currency.wrap(address(UNI)), 3000, 60, IHooks(address(0)), "");
        path[1] = PathKey(Currency.wrap(address(token)), 0, 60, IHooks(address(hook)), "");
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputCanonical(Currency.wrap(address(0)), path, new uint256[](0), 0.05 ether, 0));
        params[1] = abi.encode(Currency.wrap(address(0)), uint256(0.05 ether));
        params[2] = abi.encode(Currency.wrap(address(token)), uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(uint8(0x07), uint8(0x0c), uint8(0x0f)), params);
        uint256 g = gasleft();
        vm.prank(alice);
        ROUTER.execute{value: 0.05 ether}(hex"10", inputs, block.timestamp + 60);
        emit log_named_uint("router ETH -> UNI -> UN1 gas", g - gasleft());
        emit log_named_uint("tokens for 0.05 ETH", token.balanceOf(alice));
        assertGt(token.balanceOf(alice), 0, "multi-hop through the official pool");
        assertEq(token.pendingCount(alice), token.balanceOf(alice) / 1 ether);
    }

    // ---------------------------------------------------------------- mainnet precompiles and system contracts

    function test_fork_revealWithRealDrand_onMainnetPrecompiles() public onlyFork {
        vm.warp(tBuy);
        _fundUni(alice, 100 ether);
        _routerSingle(alice, true, 20 ether);
        (, uint64 r,) = token.slotOf(0);
        assertEq(r, round, "the slot targets the pinned round");
        vm.warp(vm.parseJsonUint(vm.readFile("test/fixtures/fork.json"), ".roundTime"));
        uint256 g = gasleft();
        uint256 done = beacon.reveal(round, signature, 64, alice);
        emit log_named_uint("reveal 64 slots gas (real signature, mainnet precompiles)", g - gasleft());
        assertEq(done, 64, "at most 64 per call");
        uint256 calls = 1;
        while (token.pendingCount(alice) != 0) {
            beacon.reveal(round, signature, 64, alice);
            ++calls;
        }
        emit log_named_uint("reveal calls for all slots", calls);
        emit log_named_uint("cards revealed", token.idCount(alice));
        assertEq(token.idCount(alice), token.balanceOf(alice) / 1 ether);
        string memory uri = mirror.tokenURI(token.idsOf(alice)[0]);
        assertGt(bytes(uri).length, 1000, "tokenURI renders on the fork");
    }

    function test_fork_eip2935_history() public onlyFork {
        assertGt(HISTORY.code.length, 0, "EIP-2935 history contract on mainnet");
        (bool ok, bytes memory out) = HISTORY.staticcall(abi.encode(block.number - 1000));
        assertTrue(ok && out.length == 32);
        assertTrue(abi.decode(out, (bytes32)) != bytes32(0), "returns a real block hash 1,000 blocks back");
    }

    // ---------------------------------------------------------------- rewards and the permanent bid

    function test_fork_feesToHolders_andPermanentBids() public onlyFork {
        vm.warp(tBuy);
        _fundUni(alice, 500 ether);
        _routerSingle(alice, true, 200 ether);
        _routerSingle(alice, false, uint128(token.balanceOf(alice) / 2));
        (uint256 holders, uint256 reserve) = distributor.sync();
        assertGt(holders, 0);
        assertEq(holders, (holders + reserve) * 7 / 8, "7/8 : 1/8");
        (uint256 used,,, uint128 liquidity) = distributor.deployReserve();
        assertGt(liquidity, 0, "permanent bids placed on the real PoolManager");
        emit log_named_uint("holders' stream (UNI)", holders);
        emit log_named_uint("reserve deployed as bids (UNI)", used);
    }
}
