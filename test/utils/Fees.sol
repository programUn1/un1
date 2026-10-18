// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UN1Hook} from "../../src/UN1Hook.sol";
import {UN1FeeVault} from "../../src/UN1FeeVault.sol";

address constant PLATFORM_TREASURY = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;

/// @dev Reads of the hook's two vaults per fee recipient (`using Fees for UN1Hook;`): the platform treasury's normal
///      fee plus its opening tax, the developer, the beacon's bounty reserve, the distributor.
library Fees {
    /// @dev UNI the vaults still hold for `who`.
    function owed(UN1Hook hook, address who) internal view returns (uint256) {
        UN1FeeVault v = hook.feeVault();
        if (who == PLATFORM_TREASURY) return v.platformAccrued() + hook.openingTaxVault().accrued();
        if (who == v.developer()) return v.developerAccrued();
        if (who == v.beacon()) return v.bountyAccrued();
        if (who == v.distributor()) return v.holdersAccrued();
        return 0;
    }

    /// @dev Pay out what the vaults hold for `who` (each ledger through its own claim).
    function collect(UN1Hook hook, address who) internal {
        UN1FeeVault v = hook.feeVault();
        if (who == PLATFORM_TREASURY) {
            if (v.platformAccrued() != 0) v.claimPlatform();
            if (hook.openingTaxVault().accrued() != 0) hook.openingTaxVault().claim();
        } else if (who == v.developer()) {
            v.claimDeveloper();
        } else if (who == v.beacon()) {
            v.claimBounty();
        } else if (who == v.distributor()) {
            v.claimHolders();
        } else {
            revert("not a fee recipient");
        }
    }

    /// @dev All opening tax ever taken (platform treasury only).
    function openingFeesCollected(UN1Hook hook) internal view returns (uint256) {
        return hook.openingTaxVault().totalRecorded();
    }
}
