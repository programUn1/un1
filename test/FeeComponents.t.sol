// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UN1Hook} from "../src/UN1Hook.sol";
import {UN1FeeVault} from "../src/UN1FeeVault.sol";
import {UN1OpeningTaxVault} from "../src/UN1OpeningTaxVault.sol";
import {UN1ProtectionModule} from "../src/UN1ProtectionModule.sol";
import {FeeMath} from "../src/libraries/FeeMath.sol";
import {Base} from "./utils/Base.sol";

/// @notice Programmable review, 2026-10-18: protection and fees are separate components. The hook creates the normal-fee
///  vault, the protection module and the opening-tax vault (CREATE children 1, 2, 3, as launch protection v1 does). The
///  hook holds no fee claims; the opening tax is payable only to the platform treasury and never mixes with the normal
///  platform fee; every ledger pays only its fixed recipient; the developer and the six wallets are exempt only from the
///  opening tax.
contract FeeComponentsTest is Base {
    address carol = makeAddr("carol");
    uint256 start;
    UN1FeeVault vault;
    UN1OpeningTaxVault taxVault;
    UN1ProtectionModule module;
    uint256 id;

    function _exempt() internal view override returns (address[6] memory e) {
        e[1] = carol;
    }

    function setUp() public override {
        super.setUp();
        _fund(carol);
        start = block.timestamp;
        modifyLiquidityRouter.modifyLiquidity(officialKey, _range(20_000 ether), ZERO_BYTES);
        vault = hook.feeVault();
        taxVault = hook.openingTaxVault();
        module = hook.protectionModule();
        id = uint256(uint160(address(uni)));
    }

    function _claims(address who) internal view returns (uint256) {
        return manager.balanceOf(who, id);
    }

    function _backed() internal view {
        assertEq(_claims(address(hook)), 0, "the hook holds no fee claims");
        assertEq(_claims(address(vault)),
            vault.platformAccrued() + vault.developerAccrued() + vault.bountyAccrued() + vault.holdersAccrued(),
            "normal-fee vault: claims = its four ledgers");
        assertEq(_claims(address(taxVault)), taxVault.accrued(), "opening-tax vault: claims = its ledger");
    }

    // ---------------------------------------------------------------- structure

    function test_children_areCreate123_ofTheHook() public view {
        assertEq(address(vault), vm.computeCreateAddress(address(hook), 1), "normal-fee vault: child 1");
        assertEq(address(module), vm.computeCreateAddress(address(hook), 2), "protection module: child 2");
        assertEq(address(taxVault), vm.computeCreateAddress(address(hook), 3), "opening-tax vault: child 3");
        assertEq(vault.kernel(), address(hook));
        assertEq(module.kernel(), address(hook));
        assertEq(taxVault.kernel(), address(hook));
        assertEq(vault.PLATFORM_RECIPIENT(), PLATFORM);
        assertEq(taxVault.PLATFORM_RECIPIENT(), PLATFORM);
        assertEq(vault.developer(), DEV);
        assertEq(vault.distributor(), DISTRIBUTOR, "bound by the hook's initializer");
        assertEq(vault.beacon(), address(beacon));
        assertEq(module.developer(), DEV);
        assertEq(module.token(), address(token));
    }

    function test_onlyTheHook_recordsOrBinds() public {
        vm.expectRevert(UN1FeeVault.NotKernel.selector);
        vault.recordFees(1, 0, 0, 0);
        vm.expectRevert(UN1FeeVault.NotKernel.selector);
        vault.bind(alice, alice);
        vm.prank(address(hook));
        vm.expectRevert(UN1FeeVault.AlreadyBound.selector);
        vault.bind(alice, alice);
        vm.expectRevert(UN1OpeningTaxVault.NotKernel.selector);
        taxVault.recordTax(1);
        vm.expectRevert(UN1ProtectionModule.OnlyKernel.selector);
        module.protectedBuyer(alice, false);
    }

    function test_records_mustBeBackedByClaims() public {
        vm.startPrank(address(hook));
        vm.expectRevert(UN1FeeVault.InsufficientFeeBacking.selector);
        vault.recordFees(1, 0, 0, 0);
        vm.expectRevert(UN1OpeningTaxVault.InsufficientFeeBacking.selector);
        taxVault.recordTax(1);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- normal fees

    function test_normalFees_mintedToTheVault_splitIntoFourLedgers() public {
        _skipOpening();
        _swap(officialKey, true, -100 ether); // 100 UNI in
        _swap(officialKey, false, -20 ether); // 20 tokens in
        _backed();
        assertGt(vault.platformAccrued(), 0);
        assertGt(vault.bountyAccrued(), 0, "the dev fee fills the bounty reserve first");
        assertGt(vault.holdersAccrued(), 0);
        assertEq(taxVault.accrued(), 0, "no opening tax after 30 seconds");
    }

    function test_claims_payOnlyTheFixedRecipients_anyoneCanCall() public {
        _skipOpening();
        for (uint256 i; i < 10; ++i) { // round trips of 1,000 UNI: past the 50 UNI bounty reserve
            uint256 before = token.balanceOf(address(this));
            _swap(officialKey, true, -1_000 ether);
            _swap(officialKey, false, -int256(token.balanceOf(address(this)) - before));
        }
        uint256 platform = vault.platformAccrued();
        uint256 dev = vault.developerAccrued();
        uint256 bounty = vault.bountyAccrued();
        uint256 holders = vault.holdersAccrued();
        assertGt(dev, 0, "the dev fee reaches the developer once the reserve is full");
        vm.startPrank(alice); // any caller; the money never goes to it
        assertEq(vault.claimPlatform(), platform);
        assertEq(vault.claimDeveloper(), dev);
        assertEq(vault.claimBounty(), bounty);
        assertEq(vault.claimHolders(), holders);
        vm.stopPrank();
        assertEq(uni.balanceOf(PLATFORM), platform);
        assertEq(uni.balanceOf(DEV), dev);
        assertEq(uni.balanceOf(address(beacon)), bounty);
        assertEq(uni.balanceOf(DISTRIBUTOR), holders);
        assertEq(uni.balanceOf(alice), 10_000 ether, "the caller gets nothing");
        assertEq(_claims(address(vault)), 0);
        vm.expectRevert(UN1FeeVault.NothingToClaim.selector);
        vault.claimDeveloper();
    }

    // ---------------------------------------------------------------- the opening tax

    function test_openingTax_onlyToThePlatformTreasury_separateFromItsNormalFee() public {
        _swap(officialKey, true, 1 ether); // the launch buy: the developer's, no opening tax
        assertEq(taxVault.accrued(), 0);
        vm.warp(start + 10);
        uint256 pips = hook.buyFee(alice);
        uint256 normal = hook.totalFee();
        assertGt(pips, normal);
        uint256 platformBefore = vault.platformAccrued();
        uint256 holdersBefore = vault.holdersAccrued();
        vm.prank(alice);
        router.swap(officialKey, uniIs0, -10 ether); // exact input of 10 UNI
        uint256 fee = FeeMath.onGross(10 ether, pips);
        uint256 normalFee = FeeMath.onGross(10 ether, normal);
        uint256 platform = FeeMath.share(10 ether, normalFee, hook.PLATFORM_FEE());
        uint256 dev = FeeMath.share(10 ether, normalFee - platform, hook.DEV_FEE());
        assertEq(taxVault.accrued(), fee - normalFee, "the extra above the normal fee, in its own vault");
        assertEq(taxVault.totalRecorded(), fee - normalFee);
        assertEq(vault.platformAccrued() - platformBefore, platform, "the normal-fee vault gets only the 0.3%");
        assertEq(vault.holdersAccrued() - holdersBefore, normalFee - platform - dev, "holders: from the normal fee only");
        _backed();

        uint256 tax = taxVault.accrued();
        vm.prank(alice);
        assertEq(taxVault.claim(), tax);
        assertEq(uni.balanceOf(PLATFORM), tax, "paid to the platform treasury, by any caller");
        assertEq(taxVault.accrued(), 0);
        assertEq(taxVault.totalRecorded(), tax, "the total stays");
        vm.expectRevert(UN1OpeningTaxVault.NothingToClaim.selector);
        taxVault.claim();
    }

    function test_exemptWallets_skipOnlyTheOpeningTax() public {
        _swap(officialKey, true, 1 ether);
        vm.warp(start + 5);
        assertTrue(module.isExempt(carol));
        assertEq(hook.buyFee(carol), hook.totalFee(), "exempt: the normal fee only");
        uint256 platformBefore = vault.platformAccrued();
        vm.prank(carol);
        router.swap(officialKey, uniIs0, -10 ether); // exact input of 10 UNI
        assertEq(taxVault.accrued(), 0, "no opening tax");
        uint256 normalFee = FeeMath.onGross(10 ether, hook.totalFee());
        assertEq(vault.platformAccrued() - platformBefore, FeeMath.share(10 ether, normalFee, hook.PLATFORM_FEE()),
            "the normal platform fee is still paid");
        assertEq(hook.boughtDuringProtection(carol), token.balanceOf(carol), "and the buyer cap still counts it");
    }

    function test_unlockCallbacks_onlyThePoolManager() public {
        vm.expectRevert(UN1FeeVault.NotPoolManager.selector);
        vault.unlockCallback(abi.encode(alice, 1));
        vm.expectRevert(UN1OpeningTaxVault.NotPoolManager.selector);
        taxVault.unlockCallback(abi.encode(1));
    }
}
