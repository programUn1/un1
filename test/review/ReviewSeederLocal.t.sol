// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {UN1Token} from "../../src/UN1Token.sol";
import {UN1Hook} from "../../src/UN1Hook.sol";
import {UN1Mirror} from "../../src/UN1Mirror.sol";
import {UN1Beacon} from "../../src/UN1Beacon.sol";
import {UN1Distributor} from "../../src/UN1Distributor.sol";
import {UN1Renderer} from "../../src/UN1Renderer.sol";
import {UN1Seeder} from "../../src/UN1Seeder.sol";
import {UN1MasksData} from "../../src/data/UN1MasksData.sol";
import {UN1PartsData} from "../../src/data/UN1PartsData.sol";
import {Base} from "../utils/Base.sol";
import {noExempt} from "../utils/Exempt.sol";
import {Fees} from "../utils/Fees.sol";

using Fees for UN1Hook;

/// @notice Normal launch rehearsals without a fork. The test is the deployer; ETH/UNI liquidity is local.
contract ReviewSeederLocalTest is Base {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    UN1Seeder private seeder;

    function setUp() public override {
        vm.warp(_startTime());
        deployFreshManagerAndRouters();
        _etchLaunchEnvironment();
        vm.deal(address(this), 10_000 ether);
    }

    function _deployLocalGraph(bool tokenBelowUni) private {
        address uniAddress = tokenBelowUni ? address(type(uint160).max - 0x10000) : address(uint160(0x10000));
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Uniswap", "UNI", uint8(18)), uniAddress);
        uni = MockERC20(uniAddress);
        uni.mint(address(this), 1_000_000 ether);

        masks = address(new UN1MasksData());
        partsData = address(new UN1PartsData());
        token = new UN1Token(address(manager), masks);
        address hookAddress = address(FLAGS | (uint160(0x4444) << 144));
        deployCodeTo("UN1Hook.sol:UN1Hook", abi.encode(manager, address(token), address(uni), DEV, noExempt()), hookAddress);
        hook = UN1Hook(hookAddress);
        beacon = new UN1Beacon(address(token), address(uni));
        distributor = new UN1Distributor(address(uni), address(token), hookAddress, address(manager));
        renderer = new UN1Renderer(partsData);
        mirror = new UN1Mirror(address(token), address(renderer));
        seeder = new UN1Seeder(address(manager), address(uni), DEV, address(token), hookAddress);
        hook.initialize(address(distributor), address(beacon));
        token.initialize(hookAddress, address(mirror), address(beacon), address(distributor), address(seeder));
        officialKey = hook.poolKey();
        uniIs0 = hook.quoteIsCurrency0();
        assertEq(address(token) < address(uni), tokenBelowUni, "requested pool currency order");
        assertEq(token.balanceOf(address(seeder)), 10_000 ether, "supply starts in Seeder");

        // Seed our own 0.3% ETH/UNI pool at 1:1. This is sufficient for a normal two-hop launch.
        PoolKey memory ethUni = seeder.ethUniKey();
        uni.approve(address(modifyLiquidityRouter), type(uint256).max);
        manager.initialize(ethUni, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity{value: 3_000 ether}(ethUni, _range(10_000 ether), ZERO_BYTES);
    }

    function _params() private pure returns (UN1Seeder.IgniteParams memory) {
        return UN1Seeder.IgniteParams({
            uniPerTokenTick: -23_040,
            rangeTicks: 46_080,
            buyBps: 5_000,
            minUniOut: 9 ether,
            minTokensOut: 40 ether
        });
    }

    function _assertLockedPositions(UN1Seeder.Result memory r) private view {
        // These launch parameters produce the same symmetric range in both currency orders.
        int24 lower = -23_040;
        int24 upper = 23_040;
        (uint128 supplyPosition,,) = manager.getPositionInfo(
            officialKey.toId(), address(seeder), lower, upper, bytes32(0)
        );
        assertEq(supplyPosition, r.tokenOnlyLiquidity, "supply LP belongs to Seeder");
        assertGt(supplyPosition, 0);
        assertGt(r.bidLiquidity, 0, "the UNI not spent on the buy becomes a bid");
        (uint128 devPosition,,) = manager.getPositionInfo(officialKey.toId(), DEV, lower, upper, bytes32(0));
        assertEq(devPosition, 0, "developer does not own the supply position");
    }

    /// @dev The launch buy reaches the developer as plain tokens: no slot, no card, no weight anywhere.
    function _assertLaunchUnits(uint256 bought) private view {
        assertEq(token.balanceOf(DEV), bought, "developer holds exactly the launch buy");
        assertEq(token.balanceOf(address(this)), 0, "deployer holds no UN1");
        assertEq(token.idCount(address(seeder)), 0);
        assertEq(token.pendingCount(address(seeder)), 0);
        assertEq(token.idCount(DEV) + token.pendingCount(DEV), 0, "plain tokens: no slot, no card");
        assertEq(token.idCount(address(this)) + token.pendingCount(address(this)), 0);
        assertEq(token.slotCount(), 0, "the launch buy opens no slots");
        assertEq(token.drawCreditOf(DEV), 0, "and leaves no draw credit");
        assertEq(token.totalWeight(), 0);
        assertEq(token.poolCount(), 10_000);
        assertEq(token.retiredCount(), 0);
    }

    function _rehearse(bool tokenBelowUni) private {
        _deployLocalGraph(tokenBelowUni);
        uint256 pmEthBefore = address(manager).balance;
        uint256 pmUniBefore = uni.balanceOf(address(manager));
        UN1Seeder.Result memory r = seeder.ignite{value: 10 ether}(_params());
        assertTrue(seeder.ignited());
        assertGe(r.uniFromEth, 9 ether);
        assertGe(r.bought, 40 ether, "normal first buy exceeds the public opening cap");
        assertEq(hook.swapCount(), 1, "one official first buy");
        assertGt(hook.owed(PLATFORM), 0, "first buy pays platform fees");
        assertLt(r.uniDust, 0.001 ether);
        assertEq(uni.balanceOf(DEV), r.uniDust, "developer receives only reported UNI dust");
        assertEq(address(seeder).balance, 0);
        assertEq(uni.balanceOf(address(seeder)), 0);
        uint256 tokenDust = token.balanceOf(address(seeder));
        assertLt(tokenDust, 1 ether);
        assertEq(token.balanceOf(address(manager)) + tokenDust + r.bought, 10_000 ether, "supply pooled except the launch buy and dust");
        assertEq(address(manager).balance, pmEthBefore + 10 ether, "launch ETH is fully settled");
        assertEq(uni.balanceOf(address(manager)) + r.uniDust, pmUniBefore, "UNI stays inside PoolManager except dust");
        assertEq(manager.currencyDelta(address(seeder), Currency.wrap(address(0))), 0);
        assertEq(manager.currencyDelta(address(seeder), Currency.wrap(address(uni))), 0);
        assertEq(manager.currencyDelta(address(seeder), Currency.wrap(address(token))), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0, "unlock settles every currency delta");
        _assertLockedPositions(r);
        _assertLaunchUnits(r.bought);

        UN1Seeder.IgniteParams memory p = _params();
        vm.expectRevert(UN1Seeder.AlreadyIgnited.selector);
        seeder.ignite{value: 10 ether}(p);
        assertEq(hook.swapCount(), 1, "repeated launch does not swap again");
        _assertLaunchUnits(r.bought);
    }

    function test_review_localIgnite_tokenBeforeUni() public { _rehearse(true); }
    function test_review_localIgnite_tokenAfterUni() public { _rehearse(false); }

    // ---------------------------------------------------------------- launch protection v1 (Seeder side)

    function test_protection_launchBuyIsRequired() public {
        _deployLocalGraph(false);
        UN1Seeder.IgniteParams memory p = _params();
        vm.expectRevert(UN1Seeder.InvalidParams.selector);
        seeder.ignite(p); // no ETH: no launch buy
        p.minTokensOut = 0;
        vm.expectRevert(UN1Seeder.InvalidParams.selector);
        seeder.ignite{value: 10 ether}(p);
        p = _params();
        p.buyBps = 0;
        vm.expectRevert(UN1Seeder.InvalidParams.selector);
        seeder.ignite{value: 10 ether}(p);
    }

    function test_protection_launchBuyCountsAsTheDevelopers() public {
        _deployLocalGraph(false);
        UN1Seeder.Result memory r = seeder.ignite{value: 10 ether}(_params());
        assertEq(hook.boughtDuringProtection(DEV), r.bought, "within the developer's 2%");
        assertEq(hook.openingFeesCollected(), 0, "no opening fee on the launch buy");
        assertEq(token.receivedDuringProtection(DEV), r.bought, "the developer's 2% as a recipient too");
        assertEq(token.receivedDuringProtection(address(seeder)), 0);
        assertEq(hook.protectionEndsAt(), block.timestamp + 5 minutes);
    }

    function test_launchBuy_allUni_noBid() public {
        _deployLocalGraph(true);
        UN1Seeder.IgniteParams memory p = _params();
        p.buyBps = 10_000;
        p.minTokensOut = 80 ether;
        UN1Seeder.Result memory r = seeder.ignite{value: 10 ether}(p);
        assertEq(r.bidLiquidity, 0, "every UNI bought tokens: nothing left for a bid");
        assertLt(r.uniDust, 0.001 ether);
        _assertLaunchUnits(r.bought);
        assertEq(token.balanceOf(address(manager)) + token.balanceOf(address(seeder)) + r.bought, 10_000 ether);
    }

    function test_protection_launchBuyAbove2PercentReverts() public {
        _deployLocalGraph(false);
        UN1Seeder.IgniteParams memory p = _params();
        p.buyBps = 10_000; // all of about 99 UNI at 0.1 UNI per token: far more than 200 tokens
        vm.expectRevert();
        seeder.ignite{value: 100 ether}(p);
    }

    function test_protection_openingValuationFloor() public {
        _deployLocalGraph(false);
        // 10,000 tokens at 1.0001^-23040 = 0.09987 UNI each, UNI at USD 20: USD 19,974
        assertEq(seeder.openingFdvUsd(-23_040), 19_974);
        uniUsd.set(1e8, 0); // UNI at USD 1: USD 998
        UN1Seeder.IgniteParams memory p = _params();
        vm.expectRevert(abi.encodeWithSelector(UN1Seeder.OpeningValuationTooLow.selector, 998));
        seeder.ignite{value: 10 ether}(p);
        uniUsd.set(15.02e8, 0);
        assertGe(seeder.openingFdvUsd(-23_040), 15_000, "just above the floor");
        seeder.ignite{value: 10 ether}(p);
    }

    function test_protection_staleOrBrokenPriceReverts() public {
        _deployLocalGraph(false);
        UN1Seeder.IgniteParams memory p = _params();
        uniUsd.set(20e8, block.timestamp - 1 hours - 1);
        vm.expectRevert(UN1Seeder.InvalidOraclePrice.selector);
        seeder.ignite{value: 10 ether}(p);
        uniUsd.set(0, 0);
        vm.expectRevert(UN1Seeder.InvalidOraclePrice.selector);
        seeder.ignite{value: 10 ether}(p);
        uniUsd.set(20e8, block.timestamp - 1 hours); // exactly one heartbeat old is fine
        seeder.ignite{value: 10 ether}(p);
    }
}
