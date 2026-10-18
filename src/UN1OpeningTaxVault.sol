// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title UN1OpeningTaxVault
/// @notice The opening-tax vault of the official pool, created by the hook (CREATE child 3, as in Programmable's launch
///  protection v1). During the first 30 seconds after the pool is created, a buy pays a total fee that starts at 99%
///  and falls linearly to the normal fee; the hook mints the part above the normal fee here as UNI claims (ERC-6909 in
///  the PoolManager). One ledger, payable only to the fixed platform treasury; anyone may pay the gas of a claim. No
///  owner, no allowances, no principal withdrawal, no arbitrary calls.
contract UN1OpeningTaxVault is IUnlockCallback {
    address public constant PLATFORM_RECIPIENT = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;

    IPoolManager public immutable poolManager;
    address public immutable kernel; // the hook
    address public immutable uni;

    /// @notice Opening tax not yet paid to the platform treasury.
    uint256 public accrued;
    /// @notice All opening tax ever recorded.
    uint256 public totalRecorded;

    error NotKernel();
    error NotPoolManager();
    error InsufficientFeeBacking();
    error NothingToClaim();

    event TaxRecorded(uint256 amount);
    event TaxClaimed(uint256 amount);

    constructor(IPoolManager poolManager_, address uni_) {
        poolManager = poolManager_;
        kernel = msg.sender;
        uni = uni_;
    }

    /// @notice Record an opening tax whose UNI claims the hook has just minted to this vault.
    function recordTax(uint256 amount) external {
        if (msg.sender != kernel) revert NotKernel();
        accrued += amount;
        totalRecorded += amount;
        if (poolManager.balanceOf(address(this), uint256(uint160(uni))) < accrued) revert InsufficientFeeBacking();
        emit TaxRecorded(amount);
    }

    /// @notice Pay everything accrued to the platform treasury.
    function claim() external returns (uint256 amount) {
        amount = accrued;
        if (amount == 0) revert NothingToClaim();
        accrued = 0;
        poolManager.unlock(abi.encode(amount));
        emit TaxClaimed(amount);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        uint256 amount = abi.decode(data, (uint256));
        poolManager.burn(address(this), uint256(uint160(uni)), amount);
        poolManager.take(Currency.wrap(uni), PLATFORM_RECIPIENT, amount);
        return "";
    }
}
