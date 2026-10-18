// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "../utils/Base.sol";
import {UN1Token} from "../../src/UN1Token.sol";
import {UN1Distributor} from "../../src/UN1Distributor.sol";

/// @dev Local lifecycle fixture: its address can receive cards before CREATE2 deployment.
contract ReviewRewardWallet {
    function optIn(UN1Token token) external {
        token.optIn();
    }

    function claim(UN1Distributor distributor) external returns (uint256) {
        return distributor.claim();
    }
}

/// @notice Defensive regression coverage for reward eligibility and guarded composition transitions.
contract ReviewRewardTransitionsTest is Base {
    function setUp() public override {
        super.setUp();
        _skipOpening();
    }

    function _fundStream() private returns (uint256 funded) {
        for (uint256 i; i < 5; ++i) {
            _swap(officialKey, false, -20 ether);
            _swap(officialKey, true, 20 ether);
        }
        (funded,) = distributor.sync();
        assertGt(funded, 0, "a real local swap-fee stream was funded");
    }

    function _holders(address wallet) private view returns (address[] memory holders) {
        holders = new address[](4);
        holders[0] = alice;
        holders[1] = bob;
        holders[2] = address(this);
        holders[3] = wallet;
    }

    function _checkRewards(address wallet) private view {
        address[] memory holders = _holders(wallet);
        uint256 credited = distributor.totalClaimed() * 1e18;
        for (uint256 i; i < holders.length; ++i) credited += token.accruedX18(holders[i]);
        assertEq(credited + token.undistributedX18(), distributor.totalFunded() * 1e18, "exact reward conservation");
        _checkInvariants(holders);
    }

    function test_Review_revokeThenOptIn_preservesAccruedRewardsAndTimeShares() public {
        bytes32 salt = keccak256("reward lifecycle wallet");
        address predicted = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff), address(this), salt, keccak256(type(ReviewRewardWallet).creationCode)
        )))));
        _buy(alice, 4 ether);
        _revealAll("review-reward-lifecycle");
        vm.prank(alice);
        token.transfer(predicted, 2 ether);
        uint256 walletWeight = token.weightOf(predicted);
        uint256 bothWeight = token.totalWeight();
        uint256 funded = _fundStream();
        uint256 start = block.timestamp;
        _checkRewards(predicted);

        // The wallet earns normally during the first quarter of the stream.
        vm.warp(start + 6 hours);
        uint256 accruedBeforeRevoke = token.accruedX18(predicted);
        uint256 aliceAtRevoke = token.earned(alice);
        assertGt(accruedBeforeRevoke, 0);
        assertApproxEqAbs(token.earned(predicted), funded * walletWeight / bothWeight / 4, 2);
        ReviewRewardWallet wallet = new ReviewRewardWallet{salt: salt}();
        assertEq(address(wallet), predicted);
        token.revoke(predicted);
        assertFalse(token.isWeighted(predicted));
        assertEq(token.weightOf(predicted), 0);
        assertEq(token.totalWeight(), bothWeight - walletWeight);
        assertEq(token.accruedX18(predicted), accruedBeforeRevoke, "revocation preserves prior accrual including dust");
        _checkRewards(predicted);

        // During the next half-day, Alice receives the whole stream; the revoked wallet receives none.
        vm.warp(start + 18 hours);
        assertEq(token.accruedX18(predicted), accruedBeforeRevoke, "no accrual while revoked");
        assertApproxEqAbs(token.earned(alice) - aliceAtRevoke, funded / 2, 2);
        _checkRewards(predicted);
        uint256 claimed = wallet.claim(distributor);
        assertEq(claimed, accruedBeforeRevoke / 1e18);
        assertEq(uni.balanceOf(predicted), claimed, "previously earned UNI remains payable to the wallet");
        uint256 dust = accruedBeforeRevoke - claimed * 1e18;
        assertEq(token.accruedX18(predicted), dust);

        wallet.optIn(token);
        assertTrue(token.isWeighted(predicted));
        assertEq(token.weightOf(predicted), walletWeight);
        assertEq(token.totalWeight(), bothWeight);
        assertEq(token.accruedX18(predicted), dust, "opting in grants no retroactive reward");
        _checkRewards(predicted);

        vm.warp(start + 1 days);
        assertApproxEqAbs(claimed + token.earned(predicted), funded * walletWeight / bothWeight / 2, 3);
        _checkRewards(predicted);
        wallet.claim(distributor);
        vm.prank(alice);
        distributor.claim();
        _checkRewards(predicted);
    }

    function _disjointPair() private view returns (uint256 keep, uint256 other, uint8 combined) {
        uint256[] memory ids = token.idsOf(alice);
        for (uint256 i; i < ids.length; ++i) {
            (, uint8 a,,) = token.cardOf(ids[i]);
            for (uint256 j = i + 1; j < ids.length; ++j) {
                (, uint8 b,,) = token.cardOf(ids[j]);
                if (a & b == 0) return (ids[i], ids[j], a | b);
            }
        }
        revert("fixture needs a disjoint pair");
    }

    function test_Review_guardedCompose_preservesRewardAndUnitConservation() public {
        _buy(alice, 12 ether);
        _buy(bob, 2 ether);
        _revealAll("review-guarded-compose");
        (uint256 keep, uint256 other, uint8 combined) = _disjointPair();
        uint256 nonce;
        while (uint256(sha256(abi.encodePacked(alice, uint16(keep), uint16(other), nonce))) >> 240 != 0) ++nonce;
        assertEq(uint256(token.proofDigest(alice, keep, other, nonce)) >> 240, 0);
        vm.prank(alice);
        token.setGuard(true);
        _fundStream();
        vm.warp(block.timestamp + 6 hours);
        uint256 accrued = token.accruedX18(alice);
        uint256 bobWeight = token.weightOf(bob);
        uint256 expectedWeight = token.weightOf(alice)
            - token.cardWeight(token.originalMask(keep), 1)
            - token.cardWeight(token.originalMask(other), 1) + token.cardWeight(combined, 2);
        _checkRewards(address(0));

        vm.prank(alice);
        token.compose(keep, other, nonce);
        assertTrue(token.isGuarded(alice), "composition preserves the guard setting");
        assertEq(token.balanceOf(alice), 11 ether);
        assertEq(token.idCount(alice), 11);
        assertEq(token.totalSupply(), token.SUPPLY() - 1 ether);
        assertEq(token.retiredCount(), 1);
        assertEq(token.retiredInto(other), keep);
        assertEq(token.ownerOfId(other), address(0));
        assertFalse(token.inPool(other), "the retired card stays outside the pool");
        assertEq(token.weightOf(alice), expectedWeight);
        assertEq(token.weightOf(bob), bobWeight);
        assertEq(token.totalWeight(), expectedWeight + bobWeight);
        assertEq(token.accruedX18(alice), accrued, "existing rewards settle before the composition weight changes");
        _checkRewards(address(0));

        vm.warp(block.timestamp + 18 hours);
        assertGt(token.accruedX18(alice), accrued);
        _checkRewards(address(0));
        vm.prank(alice);
        distributor.claim();
        vm.prank(bob);
        distributor.claim();
        _checkRewards(address(0));
    }
}
