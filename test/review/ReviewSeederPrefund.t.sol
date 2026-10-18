// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
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

/// @notice Self-audit SA-2 (docs/reviews/self-audit-final.md): the Seeder's address is known before the launch, and
///         anyone can send ETH to it. The postcondition used to require a zero ETH balance, so one wei sent in advance
///         reverted the whole launch. It now requires only that the launch ETH is used up.
contract ReviewSeederPrefundTest is Base {
    UN1Seeder private seeder;

    function setUp() public override {
        vm.warp(_startTime());
        deployFreshManagerAndRouters();
        _etchLaunchEnvironment();
        vm.deal(address(this), 10_000 ether);
    }

    function _graph(uint256 prefund) private {
        address uniAddress = address(uint160(0x10000));
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
        // a stranger funds the address the launch graph will deploy the Seeder at
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.deal(predicted, prefund);
        seeder = new UN1Seeder(address(manager), address(uni), DEV, address(token), hookAddress);
        assertEq(address(seeder), predicted, "predicted Seeder address");
        hook.initialize(address(distributor), address(beacon));
        token.initialize(hookAddress, address(mirror), address(beacon), address(distributor), address(seeder));
        PoolKey memory ethUni = seeder.ethUniKey();
        uni.approve(address(modifyLiquidityRouter), type(uint256).max);
        manager.initialize(ethUni, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity{value: 3_000 ether}(ethUni, _range(10_000 ether), ZERO_BYTES);
    }

    function _params() private pure returns (UN1Seeder.IgniteParams memory) {
        return UN1Seeder.IgniteParams({uniPerTokenTick: -23_040, rangeTicks: 46_080, buyBps: 5_000, minUniOut: 9 ether, minTokensOut: 40 ether});
    }

    function test_Review_ethSentToTheSeederAddressBeforehandDoesNotBlockTheLaunch() public {
        _graph(1);
        uint256 pmEthBefore = address(manager).balance;
        seeder.ignite{value: 10 ether}(_params());
        assertTrue(seeder.ignited());
        assertEq(address(seeder).balance, 1, "the stranger's wei stays; nothing else is left");
        assertEq(address(manager).balance, pmEthBefore + 10 ether, "the launch ETH is fully settled");
        assertLt(token.balanceOf(address(seeder)), 1 ether);
    }

    function test_Review_aLargerPrefundStaysUntouched() public {
        _graph(1 ether);
        seeder.ignite{value: 10 ether}(_params());
        assertEq(address(seeder).balance, 1 ether, "only what was there before the launch remains");
    }
}
