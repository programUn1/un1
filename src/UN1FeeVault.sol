// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title UN1FeeVault
/// @notice The normal-fee vault of the official pool, created by the hook (CREATE child 1, as in Programmable's
///  launch protection v1). The hook mints each swap's normal fee here as UNI claims (ERC-6909 in the PoolManager) and
///  records it in four ledgers, each payable only to its recipient:
///  - platform: 0.30% of every swap, to the fixed platform treasury
///  - developer: the dev fee after the bounty top-up, to the developer
///  - bounty: the reveal bounty reserve, to the beacon
///  - holders: the halving fee, to the distributor
///  The developer is fixed at creation; the distributor and the beacon are bound once by the hook's initializer, before
///  the pool exists. Only accrued fees can leave, to those recipients; anyone may pay the gas of a claim. No owner, no
///  allowances, no principal withdrawal, no arbitrary calls. Opening taxes never enter this vault.
contract UN1FeeVault is IUnlockCallback {
    address public constant PLATFORM_RECIPIENT = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;

    IPoolManager public immutable poolManager;
    address public immutable kernel; // the hook
    address public immutable uni;
    address public immutable developer;

    address public distributor;
    address public beacon;
    uint256 public platformAccrued;
    uint256 public developerAccrued;
    uint256 public bountyAccrued;
    uint256 public holdersAccrued;

    error NotKernel();
    error NotPoolManager();
    error AlreadyBound();
    error NotBound();
    error InsufficientFeeBacking();
    error NothingToClaim();

    event FeesRecorded(uint256 platform, uint256 developer, uint256 bounty, uint256 holders);
    event FeesClaimed(address indexed recipient, uint256 amount);

    constructor(IPoolManager poolManager_, address uni_, address developer_) {
        poolManager = poolManager_;
        kernel = msg.sender;
        uni = uni_;
        developer = developer_;
    }

    /// @notice Set the holders' and the bounty recipients. The hook's initializer only, once.
    function bind(address distributor_, address beacon_) external {
        if (msg.sender != kernel) revert NotKernel();
        if (distributor != address(0)) revert AlreadyBound();
        if (distributor_ == address(0) || beacon_ == address(0)) revert NotBound();
        distributor = distributor_;
        beacon = beacon_;
    }

    /// @notice Record fees whose UNI claims the hook has just minted to this vault.
    function recordFees(uint256 platform, uint256 developer_, uint256 bounty, uint256 holders) external {
        if (msg.sender != kernel) revert NotKernel();
        platformAccrued += platform;
        developerAccrued += developer_;
        bountyAccrued += bounty;
        holdersAccrued += holders;
        uint256 total = platformAccrued + developerAccrued + bountyAccrued + holdersAccrued;
        if (poolManager.balanceOf(address(this), uint256(uint160(uni))) < total) revert InsufficientFeeBacking();
        emit FeesRecorded(platform, developer_, bounty, holders);
    }

    /// @notice Pay the platform ledger to the platform treasury.
    function claimPlatform() external returns (uint256 amount) {
        amount = platformAccrued;
        platformAccrued = 0;
        _pay(PLATFORM_RECIPIENT, amount);
    }

    /// @notice Pay the developer ledger to the developer.
    function claimDeveloper() external returns (uint256 amount) {
        amount = developerAccrued;
        developerAccrued = 0;
        _pay(developer, amount);
    }

    /// @notice Pay the bounty ledger to the beacon (it calls this when its balance runs short).
    function claimBounty() external returns (uint256 amount) {
        if (beacon == address(0)) revert NotBound();
        amount = bountyAccrued;
        bountyAccrued = 0;
        _pay(beacon, amount);
    }

    /// @notice Pay the holders' ledger to the distributor (its `sync` calls this).
    function claimHolders() external returns (uint256 amount) {
        if (distributor == address(0)) revert NotBound();
        amount = holdersAccrued;
        holdersAccrued = 0;
        _pay(distributor, amount);
    }

    function _pay(address recipient, uint256 amount) private {
        if (amount == 0) revert NothingToClaim();
        poolManager.unlock(abi.encode(recipient, amount));
        emit FeesClaimed(recipient, amount);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (address recipient, uint256 amount) = abi.decode(data, (address, uint256));
        poolManager.burn(address(this), uint256(uint160(uni)), amount);
        poolManager.take(Currency.wrap(uni), recipient, amount);
        return "";
    }
}
