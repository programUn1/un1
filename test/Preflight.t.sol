// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {UN1Token} from "../src/UN1Token.sol";
import {UN1Hook} from "../src/UN1Hook.sol";
import {UN1Beacon} from "../src/UN1Beacon.sol";
import {UN1Seeder} from "../src/UN1Seeder.sol";
import {Base} from "./utils/Base.sol";
import {noExempt} from "./utils/Exempt.sol";

/// @dev Answers every call with fixed raw bytes (a `token()` getter returning malformed data).
contract RawBeacon {
    bytes private _ret;

    constructor(bytes memory ret) {
        _ret = ret;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return _ret;
    }
}

contract RevertingBeacon {
    function token() external pure returns (address) {
        revert("no");
    }
}

/// @notice Local self-check of Programmable's preflight: each hard invariant that can be verified locally is a test (profile 3.6.0, static baseline 3.3.0).
///  no-direct-callcode-or-selfdestruct · hook-address-permission-mask-match · valid-return-delta-permission-dependencies ·
///  authenticated-enabled-callbacks · complete-enabled-callback-implementation · size limits · initializer permissions.
///  Balanced deltas and the exact router simulation are in ForkRehearsal.t.sol (mainnet fork rehearsal).
contract PreflightTest is Base {
    uint256 constant HOOK_MASK = 0x25cc; // beforeInitialize, afterAddLiquidity, afterRemoveLiquidity, beforeSwap, afterSwap, both swap return deltas
    UN1Seeder seeder;

    function setUp() public override {
        super.setUp();
        seeder = new UN1Seeder(address(manager), address(uni), DEV, address(token), address(hook));
    }

    /// @dev The five launch-graph targets plus the four pre-deployed infrastructure contracts they reference.
    function _targets() internal view returns (address[9] memory t, string[9] memory n) {
        t = [masks, partsData, address(token), address(hook), address(beacon), address(distributor), address(renderer), address(mirror), address(seeder)];
        n = ["UN1MasksData (infra)", "UN1PartsData (infra)", "UN1Token", "UN1Hook", "UN1Beacon (infra)", "UN1Distributor", "UN1Renderer (infra)", "UN1Mirror", "UN1Seeder"];
    }

    /// @dev The same linear disassembly as the Programmable CLI (runtime-immutables.mjs, assertNoDelegatingRuntimeOpcodes).
    function _firstForbidden(bytes memory code) internal pure returns (uint256 pc, uint8 op) {
        while (pc < code.length) {
            op = uint8(code[pc]);
            if (op == 0xf2 || op == 0xf4 || op == 0xff) return (pc, op);
            pc += op >= 0x60 && op <= 0x7f ? op - 0x5f + 1 : 1;
        }
        return (type(uint256).max, 0);
    }

    function test_runtimes_noCallcodeDelegatecallSelfdestruct() public {
        (address[9] memory t, string[9] memory n) = _targets();
        for (uint256 i; i < 9; ++i) {
            (uint256 pc, uint8 op) = _firstForbidden(t[i].code);
            emit log_named_uint(string.concat(n[i], " runtime bytes"), t[i].code.length);
            assertEq(pc, type(uint256).max, string.concat(n[i], ": forbidden opcode ", vm.toString(op), " at ", vm.toString(pc)));
        }
    }

    function test_runtimes_noCborMetadata() public view {
        (address[9] memory t, string[9] memory n) = _targets();
        bytes memory solc = hex"64736f6c6343"; // CBOR text "solc" + version tag, present only when metadata is appended
        for (uint256 i; i < 9; ++i) assertFalse(_contains(t[i].code, solc), string.concat(n[i], " carries CBOR metadata"));
    }

    function test_sizes_withinEip170AndGraphLimits() public {
        (address[9] memory t, string[9] memory n) = _targets();
        string[9] memory art = [
            "UN1MasksData.sol:UN1MasksData", "UN1PartsData.sol:UN1PartsData", "UN1Token.sol:UN1Token", "UN1Hook.sol:UN1Hook",
            "UN1Beacon.sol:UN1Beacon", "UN1Distributor.sol:UN1Distributor", "UN1Renderer.sol:UN1Renderer", "UN1Mirror.sol:UN1Mirror",
            "UN1Seeder.sol:UN1Seeder"
        ];
        uint256 total;
        for (uint256 i; i < 9; ++i) {
            assertLe(t[i].code.length, 24_576, string.concat(n[i], " runtime over EIP-170"));
            uint256 init = vm.getCode(art[i]).length + 5 * 32; // creation code + at most five address arguments
            assertLe(init, 49_152, string.concat(n[i], " init code over EIP-3860"));
            total += init;
        }
        emit log_named_uint("aggregate init code, graph + infrastructure (bytes)", total);
        assertLe(total + 4 * 1_024, 524_288, "graph aggregate limit (init code + initializer calldata)");
    }

    function test_hook_addressMaskMatchesDeclaredPermissions() public view {
        assertEq(uint160(address(hook)) & 0x3fff, HOOK_MASK, "address bits = declared permissions");
        Hooks.Permissions memory p = hook.getHookPermissions();
        uint256 m;
        if (p.beforeInitialize) m |= Hooks.BEFORE_INITIALIZE_FLAG;
        if (p.afterInitialize) m |= Hooks.AFTER_INITIALIZE_FLAG;
        if (p.beforeAddLiquidity) m |= Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
        if (p.afterAddLiquidity) m |= Hooks.AFTER_ADD_LIQUIDITY_FLAG;
        if (p.beforeRemoveLiquidity) m |= Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        if (p.afterRemoveLiquidity) m |= Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
        if (p.beforeSwap) m |= Hooks.BEFORE_SWAP_FLAG;
        if (p.afterSwap) m |= Hooks.AFTER_SWAP_FLAG;
        if (p.beforeDonate) m |= Hooks.BEFORE_DONATE_FLAG;
        if (p.afterDonate) m |= Hooks.AFTER_DONATE_FLAG;
        if (p.beforeSwapReturnDelta) m |= Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        if (p.afterSwapReturnDelta) m |= Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        if (p.afterAddLiquidityReturnDelta) m |= Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG;
        if (p.afterRemoveLiquidityReturnDelta) m |= Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
        assertEq(m, HOOK_MASK, "getHookPermissions = declared mask");
        // return deltas only with their base callbacks
        assertTrue(!p.beforeSwapReturnDelta || p.beforeSwap);
        assertTrue(!p.afterSwapReturnDelta || p.afterSwap);
        assertTrue(!p.afterAddLiquidityReturnDelta && !p.afterRemoveLiquidityReturnDelta);
    }

    function test_hook_enabledCallbacksAuthenticated_disabledNotImplemented() public {
        IPoolManager.SwapParams memory sp = IPoolManager.SwapParams(true, -1, MIN_PRICE_LIMIT);
        IPoolManager.ModifyLiquidityParams memory lp = IPoolManager.ModifyLiquidityParams(-60, 60, 1, 0);
        BalanceDelta z;
        // enabled: only the PoolManager
        vm.expectRevert(UN1Hook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), officialKey, SQRT_PRICE_1_1);
        vm.expectRevert(UN1Hook.NotPoolManager.selector);
        hook.afterAddLiquidity(address(this), officialKey, lp, z, z, "");
        vm.expectRevert(UN1Hook.NotPoolManager.selector);
        hook.afterRemoveLiquidity(address(this), officialKey, lp, z, z, "");
        vm.expectRevert(UN1Hook.NotPoolManager.selector);
        hook.beforeSwap(address(this), officialKey, sp, "");
        vm.expectRevert(UN1Hook.NotPoolManager.selector);
        hook.afterSwap(address(this), officialKey, sp, z, "");
        vm.expectRevert(UN1Hook.NotPoolManager.selector);
        hook.unlockCallback("");
        // disabled: never succeed
        vm.expectRevert(UN1Hook.HookNotImplemented.selector);
        hook.afterInitialize(address(this), officialKey, SQRT_PRICE_1_1, 0);
        vm.expectRevert(UN1Hook.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(this), officialKey, lp, "");
        vm.expectRevert(UN1Hook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(this), officialKey, lp, "");
        vm.expectRevert(UN1Hook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), officialKey, 0, 0, "");
        vm.expectRevert(UN1Hook.HookNotImplemented.selector);
        hook.afterDonate(address(this), officialKey, 0, 0, "");
    }

    function test_hook_boundToTheMainnetPoolManagerAddress() public view {
        assertEq(address(hook.poolManager()), address(manager), "constructor-bound PoolManager (mainnet literal in the pack config)");
    }

    function test_initializers_deployerOnly_once() public {
        vm.prank(alice);
        vm.expectRevert(UN1Token.NotDeployer.selector);
        token.initialize(alice, alice, alice, alice, alice);
        vm.expectRevert(UN1Token.AlreadyInitialized.selector);
        token.initialize(alice, alice, alice, alice, alice);
        vm.prank(alice);
        vm.expectRevert(UN1Hook.NotDeployer.selector);
        hook.initialize(alice, alice);
        vm.expectRevert(UN1Hook.AlreadyInitialized.selector);
        hook.initialize(alice, alice);
        UN1Seeder.IgniteParams memory p;
        vm.prank(alice);
        vm.expectRevert(UN1Seeder.NotDeployer.selector);
        seeder.ignite(p);
    }

    /// @dev The beacon is infrastructure deployed before the launch for the token's predicted address: the initializers
    ///      refuse a missing one, an account without code, or one bound to another token.
    function test_initializers_requireTheBeaconBoundToThisToken() public {
        UN1Token t2 = new UN1Token(address(manager), masks);
        address h2 = address(uint160(HOOK_MASK) | (uint160(0x5556) << 144));
        deployCodeTo("UN1Hook.sol:UN1Hook", abi.encode(manager, address(t2), address(uni), DEV, noExempt()), h2);
        uint256 word = uint160(address(t2));
        address[8] memory wrong = [
            address(beacon), // bound to the main token
            alice, // no code
            address(0),
            address(new RawBeacon(abi.encodePacked(word | (1 << 200)))), // the right address with dirty high bits
            address(new RawBeacon(abi.encodePacked(bytes31(bytes32(word << 8))))), // 31 bytes
            address(new RawBeacon(abi.encode(address(t2), address(t2)))), // 64 bytes
            address(new RawBeacon("")), // empty return data
            address(new RevertingBeacon())
        ];
        for (uint256 i; i < wrong.length; ++i) {
            vm.expectRevert(UN1Token.BadBeacon.selector);
            t2.initialize(h2, address(mirror), wrong[i], address(distributor), address(this));
            vm.expectRevert(UN1Hook.BadBeacon.selector);
            UN1Hook(h2).initialize(address(distributor), wrong[i]);
        }
        assertEq(t2.hook(), address(0), "nothing written by a refused initializer");
        assertEq(t2.totalSupply(), 0);
        UN1Beacon b2 = new UN1Beacon(address(t2), address(uni));
        t2.initialize(h2, address(mirror), address(b2), address(distributor), address(this));
        UN1Hook(h2).initialize(address(distributor), address(b2));
        assertEq(t2.beacon(), address(b2));
        assertEq(address(b2.hook()), h2, "the beacon reads the hook from its token");
    }

    function test_hook_refusesPoolsBeforeInitialize() public {
        UN1Token t2 = new UN1Token(address(manager), masks);
        address h2 = address(uint160(HOOK_MASK) | (uint160(0x5555) << 144));
        deployCodeTo("UN1Hook.sol:UN1Hook", abi.encode(manager, address(t2), address(uni), DEV, noExempt()), h2);
        PoolKey memory k2 = UN1Hook(h2).poolKey();
        vm.expectRevert(); // NotInitialized, wrapped by the PoolManager
        manager.initialize(k2, SQRT_PRICE_1_1);
    }

    function test_sources_noSelfdestruct() public view {
        string[13] memory files = [
            "src/UN1Token.sol", "src/UN1Hook.sol", "src/UN1Mirror.sol", "src/UN1Beacon.sol", "src/UN1Distributor.sol",
            "src/UN1Renderer.sol", "src/UN1Seeder.sol", "src/libraries/Appearance.sol", "src/libraries/Buf.sol",
            "src/libraries/Deal.sol", "src/libraries/DrandBeacon.sol", "src/libraries/DrandRound.sol", "src/libraries/FeeMath.sol"
        ];
        for (uint256 i; i < files.length; ++i) {
            bytes memory s = bytes(vm.readFile(files[i]));
            assertFalse(_contains(s, bytes("selfdestruct")), files[i]);
            assertFalse(_contains(s, bytes("callcode")), files[i]);
            assertFalse(_contains(s, bytes("delegatecall")), files[i]);
        }
    }

    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        for (uint256 i; i + needle.length <= hay.length; ++i) {
            bool ok = true;
            for (uint256 j; j < needle.length; ++j) {
                if (hay[i + j] != needle[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
