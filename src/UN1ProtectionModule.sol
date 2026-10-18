// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev The Universal Router reports the account that called it (the v4 locker) to hooks.
interface IMsgSender {
    function msgSender() external view returns (address);
}

interface IUN1Kernel {
    function launchedAt() external view returns (uint40);
}

/// @title UN1ProtectionModule
/// @notice The launch protection policy of the official pool (Programmable launch protection v1, with UNI as the
///  quote), created by the hook (CREATE child 2). Immutable and read-only; the hook asks it, during a swap:
///  - who is buying during the 5-minute protection window: the launch buy (the pool's first swap, made by the Seeder
///    in the launch transaction) is the developer's; every other buy must come from the canonical Universal Router,
///    whose msgSender is the buyer. The hook caps each buyer at 2% of supply; the token caps each recipient the same
///  - the opening tax of a buy: for the first 30 seconds the total buy fee starts at 99% and falls linearly to the normal
///    fee. The hook mints the extra to the opening-tax vault, payable only to the platform treasury
///  - who pays no opening tax: the developer and up to six wallets fixed here. They keep both 2% limits
contract UN1ProtectionModule {
    uint256 public constant PROTECTION = 5 minutes;
    uint256 public constant OPENING_FEE_WINDOW = 30 seconds;
    uint256 public constant OPENING_TOTAL_FEE = 990_000; // pips: 99% of a buy at the pool's first second
    /// @notice The canonical Universal Router (Uniswap, mainnet). During protection it is the only way to buy.
    address public constant ROUTER = 0xd92A36B0000531EF3063dEd4De20A0783308446C;

    address public immutable kernel; // the hook
    address public immutable token;
    address public immutable poolManager;
    address public immutable developer;
    /// @notice The router's code when the hook was deployed (in the launch transaction): buys during protection must
    ///         come from that exact code.
    bytes32 public immutable routerCodeHash;
    address private immutable exempt0;
    address private immutable exempt1;
    address private immutable exempt2;
    address private immutable exempt3;
    address private immutable exempt4;
    address private immutable exempt5;

    error OnlyKernel();
    error InvalidExemption();
    error UnsupportedRouter();
    error InvalidBuyer();

    /// @param exempt Wallets exempt from the opening tax besides the developer, as the reference module checks them:
    ///        zero entries are unused; no duplicates; never the developer, the hook, the token, the PoolManager or the
    ///        router.
    constructor(address token_, address poolManager_, address developer_, address[6] memory exempt) {
        for (uint256 i; i < 6; ++i) {
            address w = exempt[i];
            if (w == address(0)) continue;
            if (w == developer_ || w == msg.sender || w == token_ || w == poolManager_ || w == ROUTER) revert InvalidExemption();
            for (uint256 j; j < i; ++j) {
                if (w == exempt[j]) revert InvalidExemption();
            }
        }
        kernel = msg.sender;
        token = token_;
        poolManager = poolManager_;
        developer = developer_;
        routerCodeHash = ROUTER.codehash;
        (exempt0, exempt1, exempt2, exempt3, exempt4, exempt5) = (exempt[0], exempt[1], exempt[2], exempt[3], exempt[4], exempt[5]);
    }

    /// @notice The six wallet slots exempt from the opening tax besides the developer (0 = unused).
    function exemptWallets() external view returns (address[6] memory) {
        return [exempt0, exempt1, exempt2, exempt3, exempt4, exempt5];
    }

    /// @notice Whether `wallet` pays no opening tax: the developer and the exempt wallets.
    function isExempt(address wallet) public view returns (bool) {
        return wallet != address(0)
            && (wallet == developer || wallet == exempt0 || wallet == exempt1 || wallet == exempt2 || wallet == exempt3
                || wallet == exempt4 || wallet == exempt5);
    }

    /// @notice Opening tax a buy by `buyer` pays now, in pips, on top of the normal fee `normal` (pips): (99% minus the
    ///         normal fee) at the pool's first second, falling linearly to 0 over 30 seconds; 0 for exempt wallets.
    function openingTax(address buyer, uint256 normal) public view returns (uint256) {
        uint256 start = IUN1Kernel(kernel).launchedAt();
        if (start == 0 || block.timestamp >= start + OPENING_FEE_WINDOW || isExempt(buyer)) return 0;
        return Math.mulDiv(OPENING_TOTAL_FEE - normal, start + OPENING_FEE_WINDOW - block.timestamp, OPENING_FEE_WINDOW);
    }

    /// @notice The buyer of a buy during protection, for the hook. `sender` is the PoolManager's swap caller;
    ///         `launchBuy` is true for the pool's first swap, which the launch makes for the developer.
    function protectedBuyer(address sender, bool launchBuy) external view returns (address buyer) {
        if (msg.sender != kernel) revert OnlyKernel();
        if (launchBuy) return developer;
        if (sender != ROUTER || sender.codehash != routerCodeHash) revert UnsupportedRouter();
        buyer = IMsgSender(sender).msgSender();
        if (buyer == address(0) || buyer == ROUTER || buyer == kernel || buyer == poolManager) revert InvalidBuyer();
    }
}
