// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {UN1Token} from "../../src/UN1Token.sol";
import {UN1Hook} from "../../src/UN1Hook.sol";
import {UN1Mirror} from "../../src/UN1Mirror.sol";
import {UN1Beacon} from "../../src/UN1Beacon.sol";
import {UN1Distributor} from "../../src/UN1Distributor.sol";
import {UN1Renderer} from "../../src/UN1Renderer.sol";
import {UN1MasksData} from "../../src/data/UN1MasksData.sol";
import {UN1PartsData} from "../../src/data/UN1PartsData.sol";
import {FeeMath} from "../../src/libraries/FeeMath.sol";
import {Base} from "../utils/Base.sol";
import {Test} from "forge-std/Test.sol";
import {noExempt} from "../utils/Exempt.sol";

/// @notice Normal swaps against the real local PoolManager, with both possible currency orders.
///         No RPC, storage edits, production changes, or transaction broadcasting is used.
abstract contract ReviewFeeOrdersBase is Base {
    function _uniFirst() internal pure virtual returns (bool);

    function setUp() public override {
        vm.warp(_startTime());
        deployFreshManagerAndRouters();
        address uniAddress = _uniFirst() ? address(uint160(0x10000)) : address(type(uint160).max - 0x10000);
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
        hook.initialize(address(distributor), address(beacon));
        token.initialize(hookAddress, address(mirror), address(beacon), address(distributor), address(this));
        DISTRIBUTOR = address(distributor);

        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        uni.approve(address(swapRouter), type(uint256).max);
        uni.approve(address(modifyLiquidityRouter), type(uint256).max);
        officialKey = hook.poolKey();
        uniIs0 = hook.quoteIsCurrency0();
        assertEq(uniIs0, _uniFirst(), "fixture covers the requested currency order");
        manager.initialize(officialKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(officialKey, _range(1_000 ether), ZERO_BYTES);
        _skipOpening();
    }

    struct Balances {
        uint256 walletUni;
        uint256 poolUni;
        uint256 walletToken;
        uint256 poolToken;
    }

    function _balances() private view returns (Balances memory b) {
        b = Balances(uni.balanceOf(address(this)), uni.balanceOf(address(manager)),
            token.balanceOf(address(this)), token.balanceOf(address(manager)));
    }

    function _claims() private view returns (uint256) {
        return manager.balanceOf(address(hook), uint256(uint160(address(uni))));
    }

    function _checkAccounting(Balances memory before_, uint256 gross, uint256 fee) private view {
        uint256 platform = gross * 3_000 / 1_000_000;
        uint256 developer = gross * 3_000 / 1_000_000;
        assertEq(_claims(), fee, "fee is backed by UNI claims");
        assertEq(hook.owed(PLATFORM), platform, "platform receives 0.3 percent of gross UNI");
        assertEq(hook.owed(DEV) + hook.owed(address(beacon)), developer, "developer allocation is conserved");
        assertEq(hook.owed(DISTRIBUTOR), fee - platform - developer, "remaining fee belongs to holders");
        Balances memory after_ = _balances();
        assertEq(after_.walletUni + after_.poolUni, before_.walletUni + before_.poolUni, "UNI transfers conserve balance");
        assertEq(after_.walletToken + after_.poolToken, before_.walletToken + before_.poolToken, "UN1 transfers conserve balance");
        assertEq(token.totalSupply(), 10_000 ether, "normal swaps do not change supply");
    }

    function test_review_buyExactInput_bothOrders() public {
        Balances memory b = _balances();
        _swap(officialKey, true, -10 ether);
        uint256 received = token.balanceOf(address(this)) - b.walletToken;
        assertGt(received, 0);
        assertEq(b.walletUni - uni.balanceOf(address(this)), 10 ether, "exact UNI input");
        assertEq(b.poolToken - token.balanceOf(address(manager)), received, "all UN1 output reaches buyer");
        _checkAccounting(b, 10 ether, 0.27 ether);
    }

    function test_review_buyExactOutput_bothOrders() public {
        Balances memory b = _balances();
        _swap(officialKey, true, 10 ether);
        uint256 gross = b.walletUni - uni.balanceOf(address(this));
        uint256 fee = _claims();
        uint256 net = gross - fee;
        assertEq(token.balanceOf(address(this)) - b.walletToken, 10 ether, "exact UN1 output");
        assertGt(net, 0);
        assertEq(fee, (net * 27_000 + 973_000 - 1) / 973_000, "exact output fee rounds up");
        _checkAccounting(b, gross, fee);
    }

    function test_review_sellExactInput_bothOrders() public {
        Balances memory b = _balances();
        _swap(officialKey, false, -10 ether);
        uint256 received = uni.balanceOf(address(this)) - b.walletUni;
        uint256 fee = _claims();
        uint256 gross = received + fee;
        assertEq(b.walletToken - token.balanceOf(address(this)), 10 ether, "exact UN1 input");
        assertGt(received, 0);
        assertEq(fee, gross * 27_000 / 1_000_000, "exact input fee rounds down");
        _checkAccounting(b, gross, fee);
    }

    function test_review_sellExactOutput_bothOrders() public {
        Balances memory b = _balances();
        _swap(officialKey, false, 5 ether);
        uint256 fee = (uint256(5 ether) * 27_000 + 973_000 - 1) / 973_000;
        assertEq(uni.balanceOf(address(this)) - b.walletUni, 5 ether, "exact UNI output after fee");
        assertGt(b.walletToken - token.balanceOf(address(this)), 0);
        _checkAccounting(b, 5 ether + fee, fee);
    }
}

contract ReviewFeeOrdersUniFirstTest is ReviewFeeOrdersBase {
    function _uniFirst() internal pure override returns (bool) { return true; }
}

contract ReviewFeeOrdersTokenFirstTest is ReviewFeeOrdersBase {
    function _uniFirst() internal pure override returns (bool) { return false; }
}

contract ReviewFeeMathRoundingTest is Test {
    function test_review_smallAmountRoundingBoundaries() public pure {
        assertEq(FeeMath.onGross(0, 27_000), 0);
        assertEq(FeeMath.onGross(37, 27_000), 0);
        assertEq(FeeMath.onGross(38, 27_000), 1);
        assertEq(FeeMath.onNet(0, 27_000), 0);
        assertEq(FeeMath.onNet(1, 27_000), 1);
        assertEq(FeeMath.onNet(973_000, 27_000), 27_000);
        assertEq(FeeMath.share(1_000_000, 2, 3_000), 2);
    }

    function testFuzz_review_feeRoundingBounds(uint128 net, uint16 pipsSeed) public pure {
        uint256 pips = uint256(pipsSeed) % 27_001;
        uint256 fee = FeeMath.onNet(net, pips);
        uint256 gross = uint256(net) + fee;
        uint256 netFromGross = gross - FeeMath.onGross(gross, pips);
        // Exact-output rounds its fee up while exact-input rounds down: their inverse may differ by one wei.
        assertGe(netFromGross, uint256(net), "gross input covers the requested net");
        assertLe(netFromGross, uint256(net) + 1, "opposite rounding differs by at most one wei");
        assertGe(fee * (1_000_000 - pips), uint256(net) * pips, "fee covers the exact rational amount");
        if (fee != 0) {
            assertLt((fee - 1) * (1_000_000 - pips), uint256(net) * pips, "one less fee would underpay");
        }
    }
}
