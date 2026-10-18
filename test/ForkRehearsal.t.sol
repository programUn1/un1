// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {UN1Token} from "../src/UN1Token.sol";
import {UN1Hook} from "../src/UN1Hook.sol";
import {UN1Beacon} from "../src/UN1Beacon.sol";
import {UN1Seeder} from "../src/UN1Seeder.sol";
import {noExempt} from "./utils/Exempt.sol";
import {Fees} from "./utils/Fees.sol";

using Fees for UN1Hook;

/// @dev Stand-in for the Programmable Graph Factory: CREATE2 deployer and initializer caller. Every UN1 constructor
///  records msg.sender as its deployer, so only this contract can run the initializers, exactly as in the real graph.
contract GraphFactoryRehearsal {
    function deploy(bytes memory initCode, bytes32 salt) external returns (address a) {
        assembly {
            a := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(a != address(0), "create2");
    }

    function predict(bytes memory initCode, bytes32 salt) public view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(initCode))))));
    }

    /// @dev Same idea as the CLI's deterministic-hook-permission-grind-v1: walk salts until the address bits match.
    function grindMask(bytes memory initCode, uint160 mask, uint256 start) external view returns (bytes32 salt) {
        bytes32 h = keccak256(initCode);
        for (uint256 i = start;; ++i) {
            salt = bytes32(i);
            address a = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, h)))));
            if (uint160(a) & 0x3fff == mask) return salt;
        }
    }

    function grindBelow(bytes memory initCode, address bound, bool below, uint256 start) external view returns (bytes32 salt) {
        bytes32 h = keccak256(initCode);
        for (uint256 i = start;; ++i) {
            salt = bytes32(i);
            address a = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, h)))));
            if ((a < bound) == below) return salt;
        }
    }

    function call(address target, bytes calldata data) external payable returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call{value: msg.value}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    receive() external payable {}
}

/// @dev ProgrammableCreate2GraphDeployerV1 (mainnet 0xB012…A887, verified source): deploys every target with CREATE2,
///  then calls every initializer itself, in target order, inside one transaction.
interface IGraphDeployer {
    struct GraphAuthorization {
        bytes32 routeNamespace;
        bytes32 routeNonce;
        bytes32 topologyHash;
        bytes32 graphCommitment;
        address authorizedLauncher;
        uint256 totalValue;
    }

    struct Target {
        bytes32 targetIdHash;
        bytes32 applicantSalt;
        uint256 deploymentValue;
        uint256 initializerValue;
        bytes initCode;
        bytes initializerCalldata;
    }

    function deployGraph(GraphAuthorization calldata authorization, Target[] calldata targets)
        external
        payable
        returns (address[] memory, bytes32[] memory, bytes[] memory, bytes32);
    function computeGraphCommitment(GraphAuthorization calldata authorization, Target[] calldata targets)
        external
        view
        returns (bytes32 commitment, uint256 targetValueSum);
    function effectiveTargetSalt(GraphAuthorization calldata authorization, bytes32 targetIdHash, bytes32 applicantSalt)
        external
        view
        returns (bytes32);
}

interface IUniversalRouterR {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2R {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

struct ExactInputSingle {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

/// @notice Mainnet-fork launch helpers shared by the rehearsal and the edge-case tests: the four infrastructure
///  contracts through the real CREATE2 proxy, the five graph targets through a stand-in factory, ignite, router trades.
abstract contract ForkGraph is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    /// @dev The canonical Universal Router (launch protection admits only it for buys) and the older deployment.
    IUniversalRouterR constant ROUTER = IUniversalRouterR(0xd92A36B0000531EF3063dEd4De20A0783308446C);
    IUniversalRouterR constant OLDER_ROUTER = IUniversalRouterR(0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af);
    address constant PLATFORM = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;
    address constant DEV = address(0xDE5);
    uint160 constant HOOK_MASK = 0x25cc;
    /// @dev Deterministic deployment proxy (calldata = salt ++ initCode, returns the 20-byte CREATE2 address).
    address constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 constant INFRA_SALT = keccak256("UN1.infrastructure.v1");

    bool forked;
    /// @dev The launch transaction without the router must stay under this. The router's own cost in the 28 finalized
    ///      Ethereum Custom Launches (top-level gas minus the factory frame, intrinsic gas and calldata, read with
    ///      debug_traceTransaction) was 0.61 - 1.05 million gas: with the largest, this leaves about 0.2 million under the
    ///      EIP-7825 cap of 16,777,216. Gas-report runs (isolation: every call as its own transaction) measure about one
    ///      million more than the real transaction and stay under it too.
    uint256 constant LAUNCH_GAS_BUDGET = 15_500_000;
    address alice = makeAddr("alice");

    struct Graph {
        GraphFactoryRehearsal factory;
        address masks;
        address parts;
        UN1Token token;
        UN1Hook hook;
        address beacon;
        address distributor;
        address renderer;
        address mirror;
        UN1Seeder seeder;
    }

    modifier onlyFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function setUp() public {
        string memory url = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        forked = true;
        vm.createSelectFork(url, vm.parseJsonUint(vm.readFile("test/fixtures/fork.json"), ".block"));
    }

    function _code(string memory artifact, bytes memory args) internal view returns (bytes memory) {
        return abi.encodePacked(vm.getCode(artifact), args);
    }

    /// @dev Launch transaction estimate: execution of the graph CREATE2 deployments, initializers and ignite, plus the
    ///      calldata that carries the init code and initializer calldata (16 gas per nonzero byte, 4 per zero byte).
    ///      The real factory (ProgrammableCreate2GraphDeployerV1, verified source) also CREATE2-deploys every target and
    ///      then calls each initializer itself, so `msg.sender` is the factory in both phases, as here.
    uint256 launchGas;

    function _calldataGas(bytes memory data) internal pure returns (uint256 g) {
        for (uint256 i; i < data.length; ++i) g += data[i] == 0 ? 4 : 16;
    }

    function _deploy(GraphFactoryRehearsal f, bytes memory code, bytes32 salt) internal returns (address a) {
        uint256 g0 = gasleft();
        a = f.deploy(code, salt);
        uint256 used = g0 - gasleft(); // measured before `_calldataGas` runs (operand evaluation order)
        launchGas += used + _calldataGas(code);
    }

    /// @dev One pre-launch transaction to the mainnet CREATE2 proxy; returns the deployed address and its gas.
    function _infra(bytes memory initCode) internal returns (address a, uint256 gasUsed) {
        a = vm.computeCreate2Address(INFRA_SALT, keccak256(initCode), CREATE2_PROXY);
        if (a.code.length != 0) return (a, 0); // already deployed by anyone: same code, same address
        uint256 g0 = gasleft();
        (bool ok, bytes memory ret) = CREATE2_PROXY.call(abi.encodePacked(INFRA_SALT, initCode));
        gasUsed = g0 - gasleft();
        require(ok && ret.length == 20 && address(bytes20(ret)) == a, "infrastructure deployment failed");
    }

    /// @dev Pre-launch: the five public infrastructure contracts (separate transactions, referenced by address; the
    ///      beacon and the mirror are bound to the token's predicted address). Launch: the four graph targets in
    ///      topological order (the hook creates its fee vault, protection module and opening-tax vault), then the
    ///      initializers.
    function _deployGraph(bool tokenBelowUni, uint256 seed) internal returns (Graph memory g) {
        (g.masks,) = _infra(_code("UN1MasksData.sol:UN1MasksData", ""));
        (g.parts,) = _infra(_code("UN1PartsData.sol:UN1PartsData", ""));
        (g.renderer,) = _infra(_code("UN1Renderer.sol:UN1Renderer", abi.encode(g.parts)));
        g.factory = new GraphFactoryRehearsal();
        bytes memory tokenCode = _code("UN1Token.sol:UN1Token", abi.encode(PM, g.masks));
        bytes32 tokenSalt = g.factory.grindBelow(tokenCode, UNI, tokenBelowUni, seed << 32);
        address predictedToken = g.factory.predict(tokenCode, tokenSalt);
        (g.beacon,) = _infra(_code("UN1Beacon.sol:UN1Beacon", abi.encode(predictedToken, UNI)));
        (g.mirror,) = _infra(_code("UN1Mirror.sol:UN1Mirror", abi.encode(predictedToken, g.renderer)));
        launchGas = 0;
        g.token = UN1Token(_deploy(g.factory, tokenCode, tokenSalt));
        bytes memory hookCode = _code("UN1Hook.sol:UN1Hook", abi.encode(PM, address(g.token), UNI, DEV, noExempt()));
        bytes32 hookSalt = g.factory.grindMask(hookCode, HOOK_MASK, seed << 32); // offline in the real CLI
        g.hook = UN1Hook(_deploy(g.factory, hookCode, hookSalt));
        g.distributor =
            _deploy(g.factory, _code("UN1Distributor.sol:UN1Distributor", abi.encode(UNI, address(g.token), address(g.hook), PM)), bytes32(seed));
        g.seeder = UN1Seeder(
            payable(_deploy(g.factory, _code("UN1Seeder.sol:UN1Seeder", abi.encode(PM, UNI, DEV, address(g.token), address(g.hook))), bytes32(seed)))
        );
        // initializers, in topological order (token, hook, then the seeder)
        bytes memory tokenInit = abi.encodeCall(UN1Token.initialize, (address(g.hook), g.mirror, g.beacon, g.distributor, address(g.seeder)));
        bytes memory hookInit = abi.encodeCall(UN1Hook.initialize, (g.distributor, g.beacon));
        uint256 g0 = gasleft();
        g.factory.call(address(g.token), tokenInit);
        g.factory.call(address(g.hook), hookInit);
        uint256 used = g0 - gasleft();
        launchGas += used + _calldataGas(tokenInit) + _calldataGas(hookInit);
    }

    function _ignite(Graph memory g, uint256 devEth) internal returns (UN1Seeder.Result memory r) {
        UN1Seeder.IgniteParams memory p = _igniteParams();
        vm.deal(address(this), devEth);
        bytes memory igniteCall = abi.encodeCall(UN1Seeder.ignite, (p));
        uint256 g0 = gasleft();
        bytes memory ret = g.factory.call{value: devEth}(address(g.seeder), igniteCall);
        uint256 used = g0 - gasleft();
        emit log_named_uint("ignite gas", used);
        launchGas += used + _calldataGas(igniteCall) + 21_000;
        emit log_named_uint("launch transaction gas (4 deployments + initializers + ignite + calldata)", launchGas);
        // EIP-7825 caps one transaction at 2^24 = 16,777,216 gas; keep room for the Router's permit and stamping
        assertLe(launchGas, LAUNCH_GAS_BUDGET, "launch fits under the EIP-7825 per-transaction cap with room for the router");
        r = abi.decode(ret, (UN1Seeder.Result));
    }

    /// @dev 0.25 UNI per token: about USD 18,500 for the supply at the fork block (launch protection asks for 15,000).
    function _igniteParams() internal pure returns (UN1Seeder.IgniteParams memory) {
        return UN1Seeder.IgniteParams({
            uniPerTokenTick: -13_860, // 1.0001^-13860 ≈ 0.25 UNI per token
            rangeTicks: 46_080, // up to about 25 UNI per token
            buyBps: 5_000,
            minUniOut: 1,
            minTokensOut: 1
        });
    }

    function _routerTrade(Graph memory g, address who, bool buy, uint128 amountIn) internal {
        PoolKey memory key = g.hook.poolKey();
        bool zeroForOne = buy == g.hook.quoteIsCurrency0();
        (Currency cin, Currency cout) = buy
            ? (Currency.wrap(UNI), Currency.wrap(address(g.token)))
            : (Currency.wrap(address(g.token)), Currency.wrap(UNI));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingle(key, zeroForOne, amountIn, 0, ""));
        params[1] = abi.encode(cin, uint256(amountIn));
        params[2] = abi.encode(cout, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f)), params);
        vm.prank(who);
        ROUTER.execute(hex"10", inputs, block.timestamp + 60);
    }

}

/// @notice Launch rehearsal (mainnet fork, read only, nothing broadcast): the whole launch replayed under Programmable's graph rules.
///  Infrastructure first through the CREATE2 proxy (the beacon bound to the predicted token) → the five targets by CREATE2 in topological order → the hook address mined for permission bits 0x25cc → the
///  initializers in order (deployer only) → the Seeder launches on the real PoolManager → real Universal Router trades. Covers the hard invariants
///  balanced-pool-manager-deltas-when-executed and exact-router-launch-simulation: a stand-in factory in four combinations (launch buy 0.05 / 0.2 ETH ×
///  token before / after UNI), launches that must fail (no launch buy, a launch buy above 2%), and the real mainnet Graph Factory (where a launch without the buy fails too).
contract ForkRehearsalTest is ForkGraph {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function _rehearse(bool tokenBelowUni, uint256 devEth, uint256 seed) internal {
        Graph memory g = _deployGraph(tokenBelowUni, seed);
        assertEq(g.token.deployer(), address(g.factory), "constructors record the graph deployer");
        UN1Seeder.Result memory r = _ignite(g, devEth);
        assertGt(r.tokenOnlyLiquidity, 0);
        if (devEth != 0) {
            assertGt(r.bought, 0);
            assertGt(r.bidLiquidity, 0, "the UNI not spent on the buy is a locked bid");
            assertLt(r.uniDust, 0.001 ether, "only rounding dust of UNI goes to the dev");
            assertEq(IERC20(address(g.token)).balanceOf(DEV), r.bought, "the launch buy goes to the developer");
            emit log_named_uint("UNI dust to dev", r.uniDust);
        }
        _afterLaunch(g, tokenBelowUni, devEth);
    }

    /// @dev Launch postconditions (balanced deltas: the unlock settled, nothing owed), then real router trades.
    function _afterLaunch(Graph memory g, bool tokenBelowUni, uint256) internal {
        assertEq(address(g.token) < UNI, tokenBelowUni, "pool ordering as requested");
        assertEq(uint160(address(g.hook)) & 0x3fff, HOOK_MASK, "hook address bits");
        (uint160 sqrtP,,,) = PM.getSlot0(g.hook.poolKey().toId());
        assertGt(sqrtP, 0, "pool initialized");
        assertLt(IERC20(address(g.token)).balanceOf(address(g.seeder)), 1 ether, "the Seeder keeps only rounding dust");
        assertEq(g.token.pendingCount(address(g.seeder)) + g.token.idCount(address(g.seeder)), 0, "no card dealt to the launch");
        assertEq(g.token.pendingCount(DEV) + g.token.idCount(DEV), 0, "the developer's launch buy is plain tokens");
        assertEq(g.token.slotCount(), 0);
        assertEq(g.token.poolCount(), 10_000);
        assertGt(g.hook.owed(PLATFORM), 0, "platform fee on the first buy");
        assertEq(g.hook.swapCount(), 1, "the launch buy");
        assertGt(g.hook.boughtDuringProtection(DEV), 0, "counted as the developer's");
        assertLe(g.hook.boughtDuringProtection(DEV), g.hook.BUYER_LIMIT());
        assertEq(g.hook.openingFeesCollected(), 0, "no opening fee on the launch buy");
        assertEq(g.hook.protectionEndsAt(), block.timestamp + 5 minutes);

        // router simulation after the launch
        vm.warp(block.timestamp + 5 minutes); // past launch protection
        deal(UNI, alice, 100 ether);
        vm.startPrank(alice);
        IERC20(UNI).approve(PERMIT2, type(uint256).max);
        IPermit2R(PERMIT2).approve(UNI, address(ROUTER), type(uint160).max, type(uint48).max);
        IERC20(address(g.token)).approve(PERMIT2, type(uint256).max);
        IPermit2R(PERMIT2).approve(address(g.token), address(ROUTER), type(uint160).max, type(uint48).max);
        vm.stopPrank();
        _routerTrade(g, alice, true, 10 ether);
        uint256 got = IERC20(address(g.token)).balanceOf(alice);
        assertGt(got, 0, "router buy");
        assertEq(g.token.pendingCount(alice), got / 1 ether);
        uint256 uniBefore = IERC20(UNI).balanceOf(alice);
        _routerTrade(g, alice, false, uint128(got / 2));
        assertGt(IERC20(UNI).balanceOf(alice), uniBefore, "router sell");
        emit log_named_uint("tokens for 10 UNI after launch", got);
    }

    /// @dev The Seeder refuses a launch without the dev buy (launch protection counts the first swap as the developer's).
    function test_rehearsal_noDevBuy_reverts() public onlyFork {
        Graph memory g = _deployGraph(false, 1);
        UN1Seeder.IgniteParams memory p = _igniteParams();
        vm.expectRevert(UN1Seeder.InvalidParams.selector);
        g.factory.call(address(g.seeder), abi.encodeCall(UN1Seeder.ignite, (p)));
    }

    /// @dev A dev buy above 2% of the supply reverts the launch (1 ETH buys far more than 200 tokens at 0.25 UNI).
    function test_rehearsal_devBuyAbove2Percent_reverts() public onlyFork {
        Graph memory g = _deployGraph(true, 2);
        UN1Seeder.IgniteParams memory p = _igniteParams();
        vm.deal(address(this), 1 ether);
        vm.expectRevert();
        g.factory.call{value: 1 ether}(address(g.seeder), abi.encodeCall(UN1Seeder.ignite, (p)));
    }

    function test_rehearsal_smallDevBuy_tokenAboveUni() public onlyFork {
        _rehearse(false, 0.05 ether, 3);
    }

    function test_rehearsal_smallDevBuy_tokenBelowUni() public onlyFork {
        _rehearse(true, 0.05 ether, 4);
    }

    function test_rehearsal_defaultDevBuy_tokenAboveUni() public onlyFork {
        _rehearse(false, 0.2 ether, 5);
    }

    function test_rehearsal_defaultDevBuy_tokenBelowUni() public onlyFork {
        _rehearse(true, 0.2 ether, 6);
    }

    function _checkInfraEntry(string memory json, uint256 i, address a, uint256 gasUsed) internal {
        string memory p = string.concat(".contracts[", vm.toString(i), "]");
        assertEq(a, vm.parseJsonAddress(json, string.concat(p, ".address")), string.concat(p, ".address"));
        assertEq(a.codehash, vm.parseJsonBytes32(json, string.concat(p, ".runtimeCodeHash")), string.concat(p, ".runtimeCodeHash"));
        emit log_named_uint(string.concat("pre-launch deployment gas ", vm.parseJsonString(json, string.concat(p, ".name"))), gasUsed);
        assertLe(gasUsed, 1 << 24);
    }

    /// @dev The addresses and runtime hashes that launch/make_config.py wrote for the graph literals are what the real
    ///      proxy produces on mainnet state, and every pre-launch transaction fits under the EIP-7825 cap.
    function test_infrastructure_matchesLaunchBuild() public onlyFork {
        string memory json = vm.readFile("launch-build/infrastructure.json");
        assertEq(vm.parseJsonAddress(json, ".deployer"), CREATE2_PROXY);
        assertEq(vm.parseJsonBytes32(json, ".salt"), INFRA_SALT);
        address token = vm.parseJsonAddress(json, ".tokenPrediction.address");
        address[5] memory a;
        uint256[5] memory gasUsed;
        (a[0], gasUsed[0]) = _infra(_code("UN1MasksData.sol:UN1MasksData", ""));
        (a[1], gasUsed[1]) = _infra(_code("UN1PartsData.sol:UN1PartsData", ""));
        (a[2], gasUsed[2]) = _infra(_code("UN1Renderer.sol:UN1Renderer", abi.encode(a[1])));
        (a[3], gasUsed[3]) = _infra(_code("UN1Beacon.sol:UN1Beacon", abi.encode(token, UNI)));
        (a[4], gasUsed[4]) = _infra(_code("UN1Mirror.sol:UN1Mirror", abi.encode(token, a[2])));
        for (uint256 i; i < 5; ++i) _checkInfraEntry(json, i, a[i], gasUsed[i]);
        (address masks, address parts, address renderer, address beacon) = (a[0], a[1], a[2], a[3]);
        // a second deployment of the same code is refused by CREATE2 (the proxy reverts) instead of producing a different
        // address; a collision burns the gas it was given, so cap it
        (bool ok,) = CREATE2_PROXY.call{gas: 5_000_000}(abi.encodePacked(INFRA_SALT, _code("UN1MasksData.sol:UN1MasksData", "")));
        assertFalse(ok);
        // the token constructor accepts the deployed masks (it checks length and sha256), and the renderer points at the parts
        assertEq(new UN1Token(address(PM), masks).masks(), masks);
        (, bytes memory p0) = renderer.staticcall(abi.encodeWithSignature("parts()"));
        assertEq(abi.decode(p0, (address)), parts);
        assertEq(address(UN1Beacon(beacon).token()), token, "the beacon is bound to the predicted token");
        assertEq(address(UN1Beacon(beacon).uni()), UNI);
        (, bytes memory t4) = a[4].staticcall(abi.encodeWithSignature("token()"));
        assertEq(abi.decode(t4, (address)), token, "the mirror is bound to the predicted token");
        (, bytes memory r4) = a[4].staticcall(abi.encodeWithSignature("renderer()"));
        assertEq(abi.decode(r4, (address)), renderer);
    }

    /// @dev launch/make_config.py predicts the token's address the way the CLI does (launch/cli_predict.py, from the
    ///      CLI 4.1.6 source) and binds the beacon to it. The salt formula is checked against the real factory, the init
    ///      code against this build. The route namespace (a hash of the source bundle) is the CLI's alone: `lint.py`
    ///      recomputes it from the files, and the packed request must show the same token (06-PREFLIGHT §8).
    function test_launchBuild_tokenPredictionMatchesTheFactory() public onlyFork {
        string memory json = vm.readFile("launch-build/infrastructure.json");
        IGraphDeployer.GraphAuthorization memory auth;
        auth.routeNamespace = vm.parseJsonBytes32(json, ".tokenPrediction.routeNamespace");
        auth.routeNonce = vm.parseJsonBytes32(json, ".tokenPrediction.nonce");
        auth.authorizedLauncher = vm.parseJsonAddress(json, ".tokenPrediction.router");
        bytes32 idHash = vm.parseJsonBytes32(json, ".tokenPrediction.targetIdHash");
        assertEq(idHash, _targetIdHash("un1-token"), "target id framing");
        assertEq(vm.parseJsonAddress(json, ".tokenPrediction.graphFactory"), address(FACTORY));
        bytes32 salt = FACTORY.effectiveTargetSalt(auth, idHash, vm.parseJsonBytes32(json, ".tokenPrediction.applicantSalt"));
        assertEq(salt, vm.parseJsonBytes32(json, ".tokenPrediction.effectiveSalt"), "the factory's own salt formula");
        address masks = vm.parseJsonAddress(json, ".contracts[0].address");
        bytes32 codeHash = keccak256(_code("UN1Token.sol:UN1Token", abi.encode(PM, masks)));
        assertEq(codeHash, vm.parseJsonBytes32(json, ".tokenPrediction.initCodeHash"), "token init code = this build");
        address token = vm.computeCreate2Address(salt, codeHash, address(FACTORY));
        assertEq(token, vm.parseJsonAddress(json, ".tokenPrediction.address"));
        assertEq(token.code.length, 0, "nothing deployed there yet");
    }

    /// @dev The hook's address the way the CLI finds it (permission grind over the init code that carries the predicted
    ///      token), checked with the real factory's salt formula, and its three CREATE children, whose addresses are the
    ///      hook's immutable literals in the launch config.
    function test_launchBuild_hookPredictionMatchesTheFactory() public onlyFork {
        string memory json = vm.readFile("launch-build/infrastructure.json");
        IGraphDeployer.GraphAuthorization memory auth;
        auth.routeNamespace = vm.parseJsonBytes32(json, ".hookPrediction.routeNamespace");
        auth.routeNonce = vm.parseJsonBytes32(json, ".hookPrediction.nonce");
        auth.authorizedLauncher = vm.parseJsonAddress(json, ".hookPrediction.router");
        assertEq(auth.routeNamespace, vm.parseJsonBytes32(json, ".tokenPrediction.routeNamespace"), "one route for the graph");
        bytes32 idHash = _targetIdHash("un1-hook");
        assertEq(idHash, vm.parseJsonBytes32(json, ".hookPrediction.targetIdHash"));
        bytes32 salt = FACTORY.effectiveTargetSalt(auth, idHash, vm.parseJsonBytes32(json, ".hookPrediction.applicantSalt"));
        assertEq(salt, vm.parseJsonBytes32(json, ".hookPrediction.effectiveSalt"), "the factory's own salt formula");
        address token = vm.parseJsonAddress(json, ".tokenPrediction.address");
        assertEq(vm.parseJsonAddress(json, ".hookPrediction.constructorArguments[1]"), token, "the hook is built for the token");
        address[6] memory exempt;
        for (uint256 i; i < 6; ++i) {
            exempt[i] = vm.parseJsonAddress(json, string.concat(".hookPrediction.constructorArguments[4][", vm.toString(i), "]"));
        }
        address dev = vm.parseJsonAddress(json, ".hookPrediction.constructorArguments[3]");
        bytes32 codeHash = keccak256(_code("UN1Hook.sol:UN1Hook", abi.encode(PM, token, UNI, dev, exempt)));
        assertEq(codeHash, vm.parseJsonBytes32(json, ".hookPrediction.initCodeHash"), "hook init code = this build");
        address hook = vm.computeCreate2Address(salt, codeHash, address(FACTORY));
        assertEq(hook, vm.parseJsonAddress(json, ".hookPrediction.address"));
        assertEq(uint160(hook) & 0x3fff, HOOK_MASK, "permission bits");
        assertEq(vm.parseJsonAddress(json, ".hookPrediction.children.feeVault"), vm.computeCreateAddress(hook, 1));
        assertEq(vm.parseJsonAddress(json, ".hookPrediction.children.protectionModule"), vm.computeCreateAddress(hook, 2));
        assertEq(vm.parseJsonAddress(json, ".hookPrediction.children.openingTaxVault"), vm.computeCreateAddress(hook, 3));
    }

    // ---------------- the real Programmable Graph Factory ----------------

    IGraphDeployer constant FACTORY = IGraphDeployer(0xB012e4A8F2c5FC4E8E4faCA9D5Ad6FfF13FBA887);
    bytes32 constant TARGET_SALT_TYPEHASH = keccak256(
        "ProgrammableCreate2GraphTargetSaltV1(uint256 chainId,address factory,bytes32 routeNamespace,bytes32 routeNonce,bytes32 targetIdHash,bytes32 applicantSalt,address authorizedLauncher)"
    );

    function _predict(IGraphDeployer.GraphAuthorization memory auth, bytes32 idHash, bytes32 applicantSalt, bytes32 codeHash)
        internal
        pure
        returns (address)
    {
        bytes32 salt = keccak256(
            abi.encode(
                TARGET_SALT_TYPEHASH, 1, address(FACTORY), auth.routeNamespace, auth.routeNonce, idHash, applicantSalt, auth.authorizedLauncher
            )
        );
        return vm.computeCreate2Address(salt, codeHash, address(FACTORY));
    }

    /// @dev mode 0: address below / above UNI as asked; mode 1: low 14 bits = the hook permission mask.
    function _grind(IGraphDeployer.GraphAuthorization memory auth, IGraphDeployer.Target memory t, uint256 mode, bool below)
        internal
        pure
        returns (address a)
    {
        bytes32 h = keccak256(t.initCode);
        uint256 free;
        assembly ("memory-safe") {
            free := mload(0x40)
        }
        for (uint256 i;; ++i) {
            a = _predict(auth, t.targetIdHash, bytes32(i), h);
            assembly ("memory-safe") {
                mstore(0x40, free) // nothing from a try is kept: reuse its memory (a long search must not run out)
            }
            if (mode == 0 ? (a < UNI) == below : uint160(a) & 0x3fff == HOOK_MASK) {
                t.applicantSalt = bytes32(i);
                return a;
            }
        }
    }

    /// @dev The CLI's target id hash (graph.mjs framedKeccak).
    function _targetIdHash(string memory id) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("programmable.create2-graph-target-id.v1", bytes1(0), uint32(bytes(id).length), id));
    }

    function _target(IGraphDeployer.GraphAuthorization memory auth, string memory id, bytes memory initCode, uint256 n)
        internal
        pure
        returns (IGraphDeployer.Target memory t, address a)
    {
        t.targetIdHash = _targetIdHash(id);
        t.applicantSalt = bytes32(n);
        t.initCode = initCode;
        a = _predict(auth, t.targetIdHash, t.applicantSalt, keccak256(initCode));
    }

    /// @dev The whole launch as one `deployGraph` call on the real mainnet factory, with this contract as the authorized
    ///      launcher (on mainnet the Programmable router is the launcher and checks the signed permit first). The beacon
    ///      is infrastructure bound to the predicted token address.
    function _realLaunch(bool tokenBelowUni, uint256 devEth) internal returns (Graph memory g, uint256 txGas) {
        bool ok;
        (g, txGas, ok) = _realLaunchWith(tokenBelowUni, devEth, address(0));
        assertTrue(ok, "deployGraph");
        assertGt(address(g.token).code.length, 0, "predicted token address");
        assertGt(address(g.hook).code.length, 0, "predicted hook address");
        assertGt(address(g.seeder).code.length, 0, "predicted seeder address");
        emit log_named_uint("real factory launch transaction gas (without the router)", txGas);
    }

    /// @dev `boundTo` binds the beacon to another address instead (0 = the predicted token).
    function _realLaunchWith(bool tokenBelowUni, uint256 devEth, address boundTo)
        internal
        returns (Graph memory g, uint256 txGas, bool ok)
    {
        (g.masks,) = _infra(_code("UN1MasksData.sol:UN1MasksData", ""));
        (g.parts,) = _infra(_code("UN1PartsData.sol:UN1PartsData", ""));
        (g.renderer,) = _infra(_code("UN1Renderer.sol:UN1Renderer", abi.encode(g.parts)));
        IGraphDeployer.GraphAuthorization memory auth = IGraphDeployer.GraphAuthorization({
            routeNamespace: keccak256("UN1 rehearsal namespace"),
            routeNonce: keccak256(abi.encode("UN1 rehearsal nonce", tokenBelowUni, devEth)),
            topologyHash: keccak256("UN1 rehearsal topology"),
            graphCommitment: bytes32(0),
            authorizedLauncher: address(this),
            totalValue: devEth
        });
        IGraphDeployer.Target[] memory t = new IGraphDeployer.Target[](4);
        address a;
        t[0].targetIdHash = _targetIdHash("un1-token");
        t[0].initCode = _code("UN1Token.sol:UN1Token", abi.encode(PM, g.masks));
        g.token = UN1Token(_grind(auth, t[0], 0, tokenBelowUni));
        // pre-launch: the beacon and the mirror, bound to the token's predicted address
        (g.beacon,) = _infra(_code("UN1Beacon.sol:UN1Beacon", abi.encode(boundTo == address(0) ? address(g.token) : boundTo, UNI)));
        (g.mirror,) = _infra(_code("UN1Mirror.sol:UN1Mirror", abi.encode(address(g.token), g.renderer)));
        t[1].targetIdHash = _targetIdHash("un1-hook");
        t[1].initCode = _code("UN1Hook.sol:UN1Hook", abi.encode(PM, address(g.token), UNI, DEV, noExempt()));
        g.hook = UN1Hook(_grind(auth, t[1], 1, false));
        (t[2], g.distributor) =
            _target(auth, "un1-distributor", _code("UN1Distributor.sol:UN1Distributor", abi.encode(UNI, address(g.token), address(g.hook), PM)), 4);
        (t[3], a) = _target(auth, "un1-seeder", _code("UN1Seeder.sol:UN1Seeder", abi.encode(PM, UNI, DEV, address(g.token), address(g.hook))), 6);
        g.seeder = UN1Seeder(payable(a));
        t[0].initializerCalldata = abi.encodeCall(UN1Token.initialize, (address(g.hook), g.mirror, g.beacon, g.distributor, address(g.seeder)));
        t[1].initializerCalldata = abi.encodeCall(UN1Hook.initialize, (g.distributor, g.beacon));
        t[3].initializerCalldata = abi.encodeCall(
            UN1Seeder.ignite,
            (
                _igniteParams()
            )
        );
        t[3].initializerValue = devEth;
        // the salt formula used for the predictions above is the factory's own
        bytes32 effective = FACTORY.effectiveTargetSalt(auth, t[0].targetIdHash, t[0].applicantSalt);
        assertEq(vm.computeCreate2Address(effective, keccak256(t[0].initCode), address(FACTORY)), address(g.token), "salt formula");
        (auth.graphCommitment,) = FACTORY.computeGraphCommitment(auth, t);
        vm.deal(address(this), devEth);
        (ok, txGas) = _callFactory(abi.encodeCall(IGraphDeployer.deployGraph, (auth, t)), devEth);
    }

    /// @dev Raw call, return data left in the return buffer: only the factory's own execution is measured, not the
    ///      memory this test contract has already grown.
    function _callFactory(bytes memory data, uint256 value) internal returns (bool ok, uint256 txGas) {
        uint256 calldataGas = _calldataGas(data);
        address factory = address(FACTORY);
        uint256 g0 = gasleft();
        assembly {
            ok := call(gas(), factory, value, add(data, 0x20), mload(data), 0, 0)
        }
        uint256 used = g0 - gasleft();
        txGas = used + calldataGas + 21_000;
        emit log_named_uint("real factory deployGraph: execution gas", used);
        emit log_named_uint("real factory deployGraph: calldata gas", calldataGas);
    }

    function test_realFactory_launch_tokenAboveUni_devBuy() public onlyFork {
        (Graph memory g, uint256 txGas) = _realLaunch(false, 0.2 ether);
        assertEq(g.token.deployer(), address(FACTORY), "the real factory is msg.sender in constructors and initializers");
        assertLe(txGas, LAUNCH_GAS_BUDGET, "launch fits under the EIP-7825 per-transaction cap with room for the router");
        _afterLaunch(g, false, 0.2 ether);
    }

    function test_realFactory_launch_tokenBelowUni_smallDevBuy() public onlyFork {
        (Graph memory g, uint256 txGas) = _realLaunch(true, 0.05 ether);
        assertEq(g.token.deployer(), address(FACTORY));
        assertLe(txGas, LAUNCH_GAS_BUDGET);
        _afterLaunch(g, true, 0.05 ether);
    }

    function test_realFactory_launchRevertsWithoutADevBuy() public onlyFork {
        (Graph memory g,, bool ok) = _realLaunchWith(true, 0, address(0));
        assertFalse(ok, "deployGraph reverts");
        assertEq(address(g.token).code.length, 0, "nothing deployed");
    }

    /// @dev A beacon bound to any other address (source changed after it was deployed, another nonce or wallet) makes the
    ///      token's initializer revert, and with it the whole launch: it can never go live with a beacon that cannot reveal.
    function test_realFactory_launchRevertsWithABeaconBoundElsewhere() public onlyFork {
        (Graph memory g,, bool ok) = _realLaunchWith(false, 0.2 ether, address(0xBEEF));
        assertFalse(ok, "deployGraph reverts");
        assertEq(address(g.token).code.length, 0, "nothing deployed");
        assertEq(address(UN1Beacon(g.beacon).token()), address(0xBEEF));
    }

    function test_realFactory_onlyTheAuthorizedLauncher() public onlyFork {
        IGraphDeployer.GraphAuthorization memory auth = IGraphDeployer.GraphAuthorization({
            routeNamespace: keccak256("ns"),
            routeNonce: keccak256("n"),
            topologyHash: keccak256("t"),
            graphCommitment: keccak256("c"),
            authorizedLauncher: alice,
            totalValue: 0
        });
        IGraphDeployer.Target[] memory t = new IGraphDeployer.Target[](1);
        t[0].targetIdHash = keccak256("x");
        t[0].initCode = hex"00";
        vm.expectRevert();
        FACTORY.deployGraph(auth, t);
    }

    function test_rehearsal_initializersAreDeployerOnly() public onlyFork {
        Graph memory g = _deployGraph(false, 7);
        UN1Seeder.IgniteParams memory p;
        vm.expectRevert(UN1Seeder.NotDeployer.selector);
        g.seeder.ignite(p); // not the factory
        vm.expectRevert(UN1Token.NotDeployer.selector);
        g.token.initialize(alice, alice, alice, alice, alice);
        vm.expectRevert(UN1Hook.NotDeployer.selector);
        g.hook.initialize(alice, alice);
    }
}
