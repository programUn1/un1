// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DrandBeacon} from "./libraries/DrandBeacon.sol";
import {DrandRound} from "./libraries/DrandRound.sol";

interface IUN1TokenReveal {
    function fulfill(uint64 round, bytes32 randomness, uint256 max) external returns (uint256 done);
    function lastBlockOf(uint64 round) external view returns (uint256);
    function hook() external view returns (address);
}

interface IUN1HookCollect {
    function collect(address recipient) external;
    function devFeeOf(uint64 round) external view returns (uint256);
}

/// @title UN1Beacon
/// @notice Reveals pending slots. Anyone brings a drand quicknet signature for a round; it is verified on-chain with
///  the EIP-2537 precompiles (Temo's DrandBeacon) and its keccak is the randomness. The result of a round is fixed by
///  the signature: the caller only delivers it, it cannot choose it.
///  - bounty in UNI, funded from the dev fee (the hook tops up a capped reserve): a base amount once per round plus an
///    amount per revealed slot, so that MEV bots reveal without any keeper; a round is paid at most the dev fee its own
///    buys paid (`hook.devFeeOf`), so opening slots only to collect the bounty never pays
///  - fallback: a round still unrevealed one day after its time uses the hash of the block after its last slot
///    (EIP-2935 history, about 27 hours). To prefer it over drand, someone would have to stop every bot, the keeper and
///    every user from submitting the signature for a whole day.
///  - a round is revealed with one randomness: the first successful batch fixes it and every later batch of the round
///    reuses it, whichever entry point and whenever. A round that has not started takes the source of the moment:
///    drand until one day after its time, then the fallback while its block hash is available, then drand again
///  - deployed before the launch as public infrastructure (CREATE2 proxy), bound to the token's predicted address
///    (launch/cli_predict.py); the token checks the binding in its initializer, and the hook is read from the token
contract UN1Beacon {
    using SafeERC20 for IERC20;

    uint256 public constant BASE_BOUNTY = 0.05 ether; // UNI, once per round: covers the signature check
    uint256 public constant SLOT_BOUNTY = 0.01 ether; // UNI per revealed slot
    uint256 public constant MAX_PER_CALL = 64;
    uint256 public constant FALLBACK_DELAY = 1 days;
    address public constant HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935; // EIP-2935

    IUN1TokenReveal public immutable token;
    IERC20 public immutable uni;

    mapping(uint64 round => bool) public basePaid;
    /// @notice The randomness a round was first revealed with; every later batch of the round reuses it.
    mapping(uint64 round => bytes32) public randomnessOf;
    /// @notice Whether that randomness came from the fallback.
    mapping(uint64 round => bool) public fallbackUsedOf;
    /// @notice Bounty already paid for a round (UNI).
    mapping(uint64 round => uint256) public paidOf;

    error TooEarly();
    error BadSignature();
    error NothingToReveal();
    error NoBlockHash();
    error UseFallback();

    event Revealed(uint64 indexed round, address indexed payee, uint256 slots, uint256 bounty, bool fallbackUsed);

    constructor(address token_, address uni_) {
        token = IUN1TokenReveal(token_);
        uni = IERC20(uni_);
    }

    /// @notice The token's hook (set once by the token's initializer).
    function hook() public view returns (IUN1HookCollect) {
        return IUN1HookCollect(token.hook());
    }

    /// @param signature the round's BLS signature, uncompressed (x || y, 64 bytes each); see keeper/drand_decompress.py
    /// @notice Reveal with the round's drand signature. Once a round has started, later batches reuse its randomness
    ///         and the signature is not needed again (pass any bytes).
    function reveal(uint64 round, bytes calldata signature, uint256 max, address payee) external returns (uint256 done) {
        bytes32 r = randomnessOf[round];
        if (r == 0) {
            if (block.timestamp < DrandRound.roundTime(round)) revert TooEarly();
            if (block.timestamp >= DrandRound.roundTime(round) + FALLBACK_DELAY && _fallbackHash(round) != 0) revert UseFallback();
            if (!DrandBeacon.verify(round, signature)) revert BadSignature();
            r = keccak256(signature);
        }
        done = _fulfill(round, r, max, false);
        _payBounty(round, done, payee, fallbackUsedOf[round]);
    }

    /// @notice Reveal with the fallback randomness, one day after the round's time. Once a round has started, later
    ///         batches reuse its randomness, whatever its source.
    function revealFallback(uint64 round, uint256 max, address payee) external returns (uint256 done) {
        bytes32 r = randomnessOf[round];
        if (r == 0) {
            if (block.timestamp < DrandRound.roundTime(round) + FALLBACK_DELAY) revert TooEarly();
            bytes32 h = _fallbackHash(round);
            if (h == 0) revert NoBlockHash();
            r = keccak256(abi.encodePacked("un1.fallback", round, h));
        }
        done = _fulfill(round, r, max, true);
        _payBounty(round, done, payee, fallbackUsedOf[round]);
    }

    function _fulfill(uint64 round, bytes32 randomness, uint256 max, bool fromFallback) private returns (uint256 done) {
        done = token.fulfill(round, randomness, max > MAX_PER_CALL ? MAX_PER_CALL : max);
        if (done == 0) revert NothingToReveal();
        if (randomnessOf[round] == 0) {
            randomnessOf[round] = randomness; // fixed for the rest of the round (review F2-02)
            if (fromFallback) fallbackUsedOf[round] = true;
        }
    }

    function _payBounty(uint64 round, uint256 done, address payee, bool fallbackUsed) private {
        uint256 amount = done * SLOT_BOUNTY;
        if (!basePaid[round]) {
            basePaid[round] = true;
            amount += BASE_BOUNTY;
        }
        IUN1HookCollect h = hook();
        uint256 paid = paidOf[round];
        uint256 budget = h.devFeeOf(round);
        uint256 room = budget > paid ? budget - paid : 0;
        if (amount > room) amount = room;
        if (payee == address(0)) amount = 0;
        uint256 bal = uni.balanceOf(address(this));
        if (bal < amount) {
            try h.collect(address(this)) {} catch {}
            bal = uni.balanceOf(address(this));
        }
        if (amount > bal) amount = bal;
        if (amount != 0) {
            paidOf[round] = paid + amount;
            uni.safeTransfer(payee, amount);
        }
        emit Revealed(round, payee, done, amount, fallbackUsed);
    }

    function _fallbackHash(uint64 round) private view returns (bytes32) {
        return _blockHash(token.lastBlockOf(round) + 1);
    }

    function _blockHash(uint256 n) private view returns (bytes32 h) {
        if (n >= block.number) return 0;
        if (block.number - n <= 256) return blockhash(n);
        (bool ok, bytes memory out) = HISTORY.staticcall(abi.encode(n));
        if (ok && out.length == 32) h = abi.decode(out, (bytes32));
    }
}
