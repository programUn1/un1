// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {Appearance} from "./libraries/Appearance.sol";
import {Deal} from "./libraries/Deal.sol";
import {DrandRound} from "./libraries/DrandRound.sol";

interface IUN1Mirror {
    function logTransfer(address from, address to, uint256 id) external;
    function logMetadataUpdate(uint256 id) external;
}

/// @title UN1Token
/// @notice 10,000 tokens. Every whole token is one unit: a card (an id #1..#10,000), a pending slot, or a naked token.
///
///  PoolManager gate (rule ②): tokens may enter or leave the PoolManager only against an allowance the official hook
///  grants inside the same transaction, for the exact amounts it moves. Only official-pool buys grant a draw (rule ①):
///  units arriving under it open pending slots, revealed later from drand. Everything else moves existing units.
///
///  Draw credit: what an account bought in the official pool and has not turned into slots yet. A slot opens when a buy
///  makes the receiver cross a whole token and the credit holds a whole token; otherwise the new unit is naked. So every
///  draw is backed by a whole token bought in the official pool (buying it in several parts works), and selling a
///  fraction of a card's token then buying the fraction back does not draw again.
///
///  Units leave an account in this order: a card named by the ERC721 mirror, pending slots, naked tokens, then cards:
///  first those named by `setOutFirst`, then by priority (single-part fragments first, composed works last). When a transfer makes the
///  receiver cross whole tokens, the first units leaving go to it; the others dissolve: pending slots are cancelled
///  and cards return to the pool (superposition: appearance cleared, a composed work falls back to its own parts).
///  An account can turn on `setGuard`: then a transfer that would send one of its composed works back to the pool
///  reverts (moving a work to another holder, e.g. through the mirror, still works).
///
///  Compose: two cards of the same holder with disjoint parts become one. The holder picks the id to keep; the other is
///  retired forever and one token is burned. Appearances are kept and locked, layers add up, and every compose wraps
///  one more SHA-256 around the provenance and appends it to the chain. One-way: a work cannot be split.
///
///  Any address but the PoolManager can hold cards. Weight counts automatically for accounts without code and EIP-7702
///  accounts; other contracts call `optIn()`. An address that had no code when it first received a unit and has code
///  now (a pair or wallet deployed later at a precomputed address) loses that automatic weight through `revoke`.
///
///  Launch protection (with the hook): for 5 minutes after the pool is created, an address may receive at most 2% of
///  the supply in total, from any sender other than itself; sending tokens away does not give room back. Transfers
///  into the PoolManager are not counted.
///
///  Fee distribution (exact, no external calls): the distributor streams each UNI deposit linearly over one day. A
///  global accumulator (UNI x1e18 per weight unit) advances with time; every account is settled right before its weight
///  changes. Remainders are carried, never dropped: time with no weight is re-streamed with the next deposit, division
///  remainders roll into the next update, and accounts accrue in UNI x1e18 so claims lose no dust. Buying and selling
///  in the same block earns nothing: time does not move.
contract UN1Token is ERC20 {
    uint256 public constant SUPPLY = 10_000 ether;
    uint256 public constant MAX_ID = 10_000;
    /// @notice sha256 of the 10,000 part masks (data/computed/masks.bin), derived from Bitcoin blocks 0..9,999.
    bytes32 public constant MASKS_SHA256 = 0x63eae08679691a41741f7ae00de3607bbf93b8d96a8cd7f6e301cf309c9d64e8;
    /// @notice sha256 of the 10,000 Bitcoin block hashes the masks come from (provenance, see data/README.md).
    bytes32 public constant BLOCKS_SHA256 = 0x710fe265807dd75d5c762a72c99db0589491bd6c763aaeffc32009bd88559498;
    uint256 internal constant ONE = 1 ether;
    uint256 internal constant MASKS_CODE_LENGTH = 1 + 313 * 33;
    uint256 internal constant W1 = 10_000; // weight unit: 1 part
    /// @notice Leading zero bits of the light proof: about a second in a browser. A ritual, not a security measure.
    uint256 public constant PROOF_BITS = 16;
    /// @notice Steps along a slot's dealing order before ranking the ids left by their fixed per-id scores (bounds a
    ///         reveal when the pool holds very few ids; with a few hundred ids or more the walk practically never gets there).
    uint256 public constant MAX_WALK = 1024;
    /// @notice Launch protection: how long, and what one address may receive in that time (2% of the supply).
    uint256 public constant PROTECTION = 5 minutes;
    uint256 public constant WALLET_LIMIT = 200 ether;

    /// @notice Coin metadata, read the way Programmable reads its own coins (FoundationTokenV1: `description`,
    ///         `website`, `image`, `extraData`, `metadata()` and `metadataHash()`). Fixed forever; the launch metadata
    ///         submitted with the launch carries the same values (`launch/lint.py` checks them).
    string public constant description = "A UN1corn, piece by piece.";
    string public constant website = "https://un1.art/";
    string public constant image = "ipfs://bafkreieulpcs7d7rqzf537rcphmgzgcgmbrf3dkuuxqvfn2gfkmpxg2rou";
    bytes public constant extraData = '{"v":1,"x":"https://x.com/UN1hook"}';

    /// @dev FoundationTokenV1's launch tuple, in its order; `metadataHash` is keccak256 of its ABI encoding.
    struct Metadata {
        string name;
        string symbol;
        string description;
        string imageURI;
        string website;
        bytes socialData;
    }

    address public immutable poolManager;
    address public immutable masks; // UN1MasksData: STOP ‖ (PUSH32 ‖ 32 mask bytes) × 313
    /// @notice The graph deployer (the Programmable Graph Factory); it alone calls `initialize`, once.
    address public immutable deployer;
    // set once by `initialize`: the launch graph cannot pass mutual addresses through constructors (no cycles)
    address public hook;
    address public mirror;
    address public beacon;
    address public distributor;
    uint256 public constant STREAM = 1 days;

    /// @dev One storage word: 20 + 8 + 1 + 1 + 2 bytes.
    struct Card {
        address owner;
        uint64 look; // packed appearance (Appearance.sol); 0 in the pool
        uint8 mask; // parts it has now
        uint8 layers;
        uint16 index; // position in the owner's bucket
    }

    /// @dev One storage word: 4 + 4 + 2 + 1 + 1 + 1 + 1 + 8 + 10 bytes.
    struct Account {
        uint32 ids;
        uint32 pending;
        uint16 keys; // non-empty buckets
        bool touched;
        bool weighted;
        bool optedIn; // weighted by `optIn`, not by having no code at the first receipt
        bool guard; // composed works may not dissolve in a transfer
        uint64 rawWeight; // W1 units, counted in totalWeight only when weighted
        uint80 credit; // tokens (wei) bought in the official pool not yet turned into slots
    }

    /// @dev One storage word: 20 + 8 + 3 + 1 bytes.
    struct Slot {
        address owner;
        uint64 round;
        uint24 index; // position in the owner's pending list
        bool alive;
    }

    mapping(uint256 id => Card) internal _cards;
    mapping(address account => Account) internal _accounts;
    mapping(address account => mapping(uint256 key => uint32[])) internal _buckets;
    mapping(address account => uint32[]) internal _pendingOf;
    mapping(address account => uint32[]) internal _outFirst; // stored reversed: pop from the end
    Slot[] internal _slots;
    uint256 public slotHead;
    uint256[40] internal _taken; // bit set = id NOT in superposition (owned or retired); zero at deployment
    uint256 public poolCount;
    uint256 public totalWeight;
    uint256 public composeCount;
    uint256 public retiredCount;
    /// @notice Block of the last slot opened for a round (the fallback reveal uses the hash of the next block).
    mapping(uint64 round => uint256) public lastBlockOf;
    /// @notice Head of the compose chain; starts at the provenance of the Bitcoin blocks.
    bytes32 public chainHead = BLOCKS_SHA256;
    /// @notice Provenance commitment of a composed work (a fragment's is computed, see `commitmentOf`).
    mapping(uint256 id => bytes32) internal _commitOf;
    /// @notice A retired id points to the work it was composed into.
    mapping(uint256 id => uint256) public retiredInto;
    /// @dev Eight 32-bit part details (art v7 micro-variation), drawn with the look; each travels with its part.
    mapping(uint256 id => uint256) internal _detailsOf;

    // fee distribution (amounts in UNI x1e18)
    uint256 public rateX18; // per second
    uint64 public periodFinish;
    uint64 public lastUpdate;
    /// @notice End of launch protection, set by the hook when the pool is created (shares a slot read on every transfer).
    uint64 public protectedUntil;
    uint256 public accPerWeight; // per weight unit
    uint256 internal _accRemainder; // not yet divided by totalWeight
    uint256 internal _carry; // streamed while nobody had weight: re-streamed with the next deposit

    struct Reward {
        uint256 checkpoint; // accPerWeight at the last settlement
        uint256 accruedX18;
    }

    mapping(address account => Reward) internal _rewards;
    /// @notice Tokens (wei) each address received during launch protection.
    mapping(address account => uint256) public receivedDuringProtection;

    uint256 private constant T_IN = uint256(keccak256("un1.token.allow.in"));
    uint256 private constant T_OUT = uint256(keccak256("un1.token.allow.out"));
    uint256 private constant T_DRAW = uint256(keccak256("un1.token.allow.draw"));
    uint256 private constant T_LP_IN = uint256(keccak256("un1.token.allow.lp.in"));
    uint256 private constant T_LP_OUT = uint256(keccak256("un1.token.allow.lp.out"));
    uint256 private constant T_FORCE = uint256(keccak256("un1.token.force"));

    error NotHook();
    error NotMirror();
    error NotBeacon();
    error PoolTransferNotAuthorized();
    error BadMasks();
    error NotOwner();
    error EarlierRoundPending();
    error SameCard();
    error PartsOverlap();
    error BadProof();
    error NotDistributor();
    error NotDeployer();
    error AlreadyInitialized();
    error NotRevocable();
    error WorkGuarded(uint256 id);
    error BadBeacon();
    error AlreadyStarted();
    error WalletLimitExceeded(address recipient, uint256 received, uint256 limit);

    event SlotOpened(address indexed owner, uint256 indexed slot, uint64 round);
    event SlotCancelled(uint256 indexed slot);
    event Measured(uint256 indexed id, address indexed owner, uint256 indexed slot, uint64 look, uint256 details);
    event Decohered(uint256 indexed id);
    event OptIn(address indexed account);
    event Revoked(address indexed account);
    event Guard(address indexed account, bool on);
    event Composed(address indexed owner, uint256 indexed keep, uint256 indexed retired, bytes32 commitment, uint8 mask, uint8 layers);

    constructor(address poolManager_, address masks_) ERC20("Un1corn", "UN1") {
        poolManager = poolManager_;
        masks = masks_;
        deployer = msg.sender;
        if (masks_.code.length != MASKS_CODE_LENGTH || _masksHash(masks_) != MASKS_SHA256) revert BadMasks();
        poolCount = MAX_ID;
    }

    /// @notice Wire the graph and mint the whole supply to the launch initializer. Deployer only, once.
    ///         The beacon is deployed before the launch for this token's predicted address: a missing beacon or one
    ///         bound to another address reverts the whole launch.
    function initialize(address hook_, address mirror_, address beacon_, address distributor_, address initialHolder)
        external
    {
        if (msg.sender != deployer) revert NotDeployer();
        if (hook != address(0)) revert AlreadyInitialized();
        (bool ok, bytes memory ret) = beacon_.staticcall(abi.encodeWithSignature("token()"));
        // compared as a whole word, so a value with dirty high bits is rejected as BadBeacon as well
        if (!ok || ret.length != 32 || abi.decode(ret, (uint256)) != uint160(address(this))) revert BadBeacon();
        hook = hook_;
        mirror = mirror_;
        beacon = beacon_;
        distributor = distributor_;
        _mint(initialHolder, SUPPLY);
    }

    // ================= views =================

    /// @notice (description, website, image, extraData), as FoundationTokenV1 returns them.
    function metadata() external pure returns (string memory, string memory, string memory, bytes memory) {
        return (description, website, image, extraData);
    }

    /// @notice keccak256 of the ABI-encoded launch tuple (name, symbol, description, image, website, extraData).
    function metadataHash() external view returns (bytes32) {
        return keccak256(abi.encode(Metadata(name(), symbol(), description, image, website, extraData)));
    }

    /// @notice The parts id `id` was measured with from its Bitcoin block (never changes).
    function originalMask(uint256 id) public view returns (uint8 m) {
        address d = masks;
        uint256 i = id - 1;
        uint256 offset = 2 + (i / 32) * 33 + (i % 32);
        assembly ("memory-safe") {
            extcodecopy(d, 0x1f, offset, 1)
            m := and(mload(0x00), 0xff)
        }
    }

    function cardOf(uint256 id) external view returns (address owner, uint8 mask, uint8 layers, uint64 look) {
        Card storage c = _cards[id];
        return (c.owner, c.mask, c.layers, c.look);
    }

    function lookOf(uint256 id) external view returns (uint64) {
        return _cards[id].look;
    }

    /// @notice The card's eight 32-bit part details (pixel micro-variation of art v7; not a metadata attribute).
    function detailsOf(uint256 id) external view returns (uint256) {
        return _detailsOf[id];
    }

    function ownerOfId(uint256 id) external view returns (address) {
        return _cards[id].owner;
    }

    function inPool(uint256 id) public view returns (bool) {
        uint256 i = id - 1;
        return (_taken[i >> 8] >> (i & 255)) & 1 == 0;
    }

    function idCount(address account) external view returns (uint256) {
        return _accounts[account].ids;
    }

    function pendingCount(address account) external view returns (uint256) {
        return _accounts[account].pending;
    }

    function nakedCount(address account) external view returns (uint256) {
        Account storage a = _accounts[account];
        return balanceOf(account) / ONE - a.ids - a.pending;
    }

    function weightOf(address account) external view returns (uint256) {
        Account storage a = _accounts[account];
        return a.weighted ? a.rawWeight : 0;
    }

    function isWeighted(address account) external view returns (bool) {
        return _accounts[account].weighted;
    }

    function isGuarded(address account) external view returns (bool) {
        return _accounts[account].guard;
    }

    /// @notice Tokens (wei) bought in the official pool that have not opened a slot yet.
    function drawCreditOf(address account) external view returns (uint256) {
        return _accounts[account].credit;
    }

    /// @notice The cards `setOutFirst` still sends first, in leave order (the sell helper shows and clears leftovers).
    function outFirstOf(address account) external view returns (uint32[] memory ids) {
        uint32[] storage pref = _outFirst[account];
        uint256 n = pref.length;
        ids = new uint32[](n);
        for (uint256 i; i < n; ++i) ids[i] = pref[n - 1 - i];
    }

    function idsOf(address account) external view returns (uint256[] memory ids) {
        Account storage a = _accounts[account];
        ids = new uint256[](a.ids);
        uint256 n;
        for (uint256 k; k < 16; ++k) {
            uint32[] storage b = _buckets[account][k];
            for (uint256 j; j < b.length; ++j) ids[n++] = b[j];
        }
    }

    /// @notice Provenance commitment: a fragment commits to its block (via the provenance root), id and parts; a work
    ///         to the SHA-256 chain of its composes.
    function commitmentOf(uint256 id) public view returns (bytes32) {
        bytes32 c = _commitOf[id];
        return c != 0 ? c : sha256(abi.encodePacked(BLOCKS_SHA256, uint16(id), originalMask(id)));
    }

    /// @notice The light proof digest the browser searches a nonce for.
    function proofDigest(address owner, uint256 keep, uint256 other, uint256 nonce) public pure returns (bytes32) {
        return sha256(abi.encodePacked(owner, uint16(keep), uint16(other), nonce));
    }

    /// @notice UNI (wei) the account can claim now, exact.
    function earned(address account) public view returns (uint256) {
        (uint256 acc,,) = _globalAt(block.timestamp);
        Reward storage r = _rewards[account];
        Account storage a = _accounts[account];
        uint256 x = r.accruedX18;
        if (a.weighted) x += uint256(a.rawWeight) * (acc - r.checkpoint);
        return x / 1e18;
    }

    /// @notice UNI x1e18 not yet credited to anyone: the rest of the stream, the carry and the undivided remainder.
    function undistributedX18() external view returns (uint256 x) {
        (, uint256 rem, uint256 carry) = _globalAt(block.timestamp);
        uint256 end = periodFinish;
        if (end > block.timestamp) x = rateX18 * (end - block.timestamp);
        x += rem + carry;
    }

    /// @notice UNI x1e18 credited to `account` but not claimed yet (whole wei and dust).
    function accruedX18(address account) external view returns (uint256) {
        (uint256 acc,,) = _globalAt(block.timestamp);
        Reward storage r = _rewards[account];
        Account storage a = _accounts[account];
        uint256 x = r.accruedX18;
        if (a.weighted) x += uint256(a.rawWeight) * (acc - r.checkpoint);
        return x;
    }

    function slotCount() external view returns (uint256) {
        return _slots.length;
    }

    function slotOf(uint256 slot) external view returns (address owner, uint64 round, bool alive) {
        Slot storage s = _slots[slot];
        return (s.owner, s.round, s.alive);
    }

    /// @notice Weight of a card: parts × (1 + 2% per extra layer + 5% when complete), in W1 units.
    function cardWeight(uint8 mask, uint8 layers) public pure returns (uint256) {
        return _popcount(mask) * (W1 + 200 * (uint256(layers) - 1) + (mask == 0xff ? 500 : 0));
    }

    // ================= account settings =================

    /// @notice Contracts (Safe, …) hold cards without weight until they opt in. Accounts without code and EIP-7702
    ///         accounts are weighted automatically.
    function optIn() external {
        _updateGlobal();
        _settle(msg.sender);
        Account storage a = _accounts[msg.sender];
        a.touched = true;
        a.optedIn = true;
        if (a.weighted) return;
        a.weighted = true;
        totalWeight += a.rawWeight;
        emit OptIn(msg.sender);
    }

    /// @notice Anyone: remove the automatic weight of an account that has code now (not EIP-7702) and never opted in.
    ///         Such an account had no code when it first received a unit, e.g. a pair created later at an address
    ///         someone sent a card to in advance. Its accrued UNI stays claimable; it can still `optIn()` itself.
    function revoke(address account) external {
        Account storage a = _accounts[account];
        if (!a.weighted || a.optedIn || account.code.length == 0 || _is7702(account)) revert NotRevocable();
        _updateGlobal();
        _settle(account);
        a.weighted = false;
        totalWeight -= a.rawWeight;
        emit Revoked(account);
    }

    /// @notice Protect your composed works: while on, a transfer that would send one of them back to the pool reverts.
    function setGuard(bool on) external {
        _accounts[msg.sender].guard = on;
        emit Guard(msg.sender, on);
    }

    /// @notice Cards to send first on the next transfers out (the sell helper sets this before selling).
    function setOutFirst(uint32[] calldata ids) external {
        delete _outFirst[msg.sender];
        for (uint256 i = ids.length; i > 0; --i) _outFirst[msg.sender].push(ids[i - 1]);
    }

    // ================= hook: launch protection and PoolManager allowances =================

    /// @notice Start launch protection; the hook calls this when the official pool is created, once.
    function startProtection() external {
        if (msg.sender != hook) revert NotHook();
        if (protectedUntil != 0) revert AlreadyStarted();
        protectedUntil = uint64(block.timestamp + PROTECTION);
    }

    /// @dev Official swaps: each direction on its own. The PoolManager keeps every caller's deltas apart, so two
    ///      executors in one unlock settle opposite swaps with separate transfers. A swap pays the fee, so whatever it
    ///      leaves unused cannot make another pool cheaper than the official one.
    function authorize(uint256 amountIn, uint256 amountOut, uint256 draw) external {
        if (msg.sender != hook) revert NotHook();
        if (amountIn != 0) _tstore(T_IN, _tload(T_IN) + amountIn);
        if (amountOut != 0) _tstore(T_OUT, _tload(T_OUT) + amountOut);
        if (draw != 0) _tstore(T_DRAW, _tload(T_DRAW) + draw);
    }

    /// @dev Official liquidity: only the net of the transaction. Liquidity moves without a fee, so adding and removing
    ///      the same amount in one transaction must leave nothing a transfer for another pool could use (review R-02).
    function authorizeLiquidity(uint256 amountIn, uint256 amountOut) external {
        if (msg.sender != hook) revert NotHook();
        uint256 tin = _tload(T_LP_IN) + amountIn;
        uint256 tout = _tload(T_LP_OUT) + amountOut;
        uint256 both = tin < tout ? tin : tout;
        _tstore(T_LP_IN, tin - both);
        _tstore(T_LP_OUT, tout - both);
    }

    // ================= mirror: move one named card with one token =================

    function mirrorTransfer(address from, address to, uint256 id) external {
        if (msg.sender != mirror) revert NotMirror();
        if (_cards[id].owner != from) revert NotOwner();
        if (from == to) {
            // nothing moves; the mirror still clears the token approval and logs the transfer, as ERC721 requires
            IUN1Mirror(mirror).logTransfer(from, to, id);
            return;
        }
        _tstore(T_FORCE, id);
        _transfer(from, to, ONE);
        _tstore(T_FORCE, 0); // consumed by _leave; never outlives this transfer
    }

    // ================= beacon: reveal =================

    /// @notice Reveal up to `max` slots of `round` in creation order with the round's verified randomness.
    function fulfill(uint64 round, bytes32 randomness, uint256 max) external returns (uint256 done) {
        if (msg.sender != beacon) revert NotBeacon();
        _updateGlobal();
        uint256 i = slotHead;
        uint256 n = _slots.length;
        while (i < n && done < max) {
            Slot storage s = _slots[i];
            if (!s.alive) {
                ++i;
                continue;
            }
            if (s.round > round) break;
            if (s.round < round) revert EarlierRoundPending();
            _measure(i, s, keccak256(abi.encodePacked(randomness, i)));
            ++i;
            ++done;
        }
        slotHead = i;
    }

    /// @notice Anyone: move the reveal queue past up to `max` cancelled slots at its head. A reveal walks past cancelled
    ///         slots before the next live one; a long run of them is cleared here in parts, each call bounded.
    function pruneSlots(uint256 max) external returns (uint256 skipped) {
        uint256 i = slotHead;
        uint256 n = _slots.length;
        while (i < n && skipped < max && !_slots[i].alive) {
            ++i;
            ++skipped;
        }
        slotHead = i;
    }

    function _measure(uint256 slot, Slot storage s, bytes32 seed) private {
        address owner = s.owner;
        _settle(owner);
        _removePending(owner, s.index);
        s.alive = false;
        uint256 id;
        for (uint256 k;; ++k) {
            if (k == MAX_WALK) {
                id = _firstInPool(seed);
                break;
            }
            id = Deal.at(k, seed);
            if (inPool(id)) break;
        }
        _poolRemove(id);
        Card storage c = _cards[id];
        c.mask = originalMask(id);
        c.layers = 1;
        uint64 look = Appearance.measure(seed);
        c.look = look;
        uint256 details = Appearance.details(seed);
        _detailsOf[id] = details;
        _addCard(owner, id, address(0));
        emit Measured(id, owner, slot, look, details);
    }

    // ================= compose =================

    /// @notice Compose two of your cards with disjoint parts. `keep` survives (its ground stays), `other` is retired.
    /// @param nonce makes `proofDigest(msg.sender, keep, other, nonce)` start with PROOF_BITS zero bits. It binds only
    ///        the caller, the two ids and the nonce, never the chain head, so nobody can invalidate it by composing first.
    function compose(uint256 keep, uint256 other, uint256 nonce) external returns (bytes32 commitment) {
        if (keep == other) revert SameCard();
        Card storage k = _cards[keep];
        Card storage o = _cards[other];
        if (k.owner != msg.sender || o.owner != msg.sender) revert NotOwner();
        if (k.mask & o.mask != 0) revert PartsOverlap();
        bytes32 proof = proofDigest(msg.sender, keep, other, nonce);
        if (uint256(proof) >> (256 - PROOF_BITS) != 0) revert BadProof();
        _updateGlobal();
        _settle(msg.sender);

        commitment = sha256(abi.encodePacked(commitmentOf(keep), commitmentOf(other), chainHead, proof));
        chainHead = commitment;

        uint8 mask = k.mask | o.mask;
        uint8 layers = k.layers + o.layers;
        uint64 look = Appearance.merge(k.look, o.look, k.mask);
        _detailsOf[keep] = Appearance.mergeDetails(_detailsOf[keep], _detailsOf[other], k.mask);
        _removeCard(msg.sender, keep);
        _removeCard(msg.sender, other);

        // the other id leaves the game for good; one token is burned with it
        o.mask = 0;
        o.layers = 0;
        o.look = 0;
        delete _commitOf[other];
        delete _detailsOf[other];
        retiredInto[other] = keep;
        retiredCount += 1;
        IUN1Mirror(mirror).logTransfer(msg.sender, address(0), other);
        ERC20._update(msg.sender, address(0), ONE); // balance only: the retired card is the unit that leaves

        k.mask = mask;
        k.layers = layers;
        k.look = look;
        _commitOf[keep] = commitment;
        _placeCard(msg.sender, keep);
        IUN1Mirror(mirror).logMetadataUpdate(keep);

        composeCount += 1;
        emit Composed(msg.sender, keep, other, commitment, mask, layers);
    }

    // ================= distributor: stream and claims =================

    /// @notice Stream `amount` UNI to the holders over one day, together with what is still streaming and the carry.
    function notifyReward(uint256 amount) external {
        if (msg.sender != distributor) revert NotDistributor();
        _updateGlobal();
        uint256 total = amount * 1e18 + _carry;
        if (periodFinish > block.timestamp) total += rateX18 * (periodFinish - block.timestamp);
        rateX18 = total / STREAM;
        _carry = total - rateX18 * STREAM;
        periodFinish = uint64(block.timestamp + STREAM);
        lastUpdate = uint64(block.timestamp);
    }

    /// @notice Settle `account` and hand its whole-wei balance to the distributor to pay; the dust stays accrued.
    function settleClaim(address account) external returns (uint256 amount) {
        if (msg.sender != distributor) revert NotDistributor();
        _updateGlobal();
        _settle(account);
        Reward storage r = _rewards[account];
        amount = r.accruedX18 / 1e18;
        r.accruedX18 -= amount * 1e18;
    }

    function _globalAt(uint256 now_) private view returns (uint256 acc, uint256 rem, uint256 carry) {
        acc = accPerWeight;
        rem = _accRemainder;
        carry = _carry;
        uint256 end = periodFinish;
        uint256 t = now_ < end ? now_ : end;
        uint256 last = lastUpdate;
        if (t <= last) return (acc, rem, carry);
        uint256 amt = rateX18 * (t - last);
        uint256 w = totalWeight;
        if (w == 0) {
            carry += amt + rem;
            rem = 0;
        } else {
            amt += rem;
            acc += amt / w;
            rem = amt % w;
        }
    }

    function _updateGlobal() private {
        uint256 end = periodFinish;
        uint256 t = block.timestamp < end ? block.timestamp : end;
        if (t <= lastUpdate) return;
        (accPerWeight, _accRemainder, _carry) = _globalAt(block.timestamp);
        lastUpdate = uint64(t);
    }

    /// @dev Credit the account up to the current accumulator; called right before its weight changes.
    function _settle(address account) private {
        Reward storage r = _rewards[account];
        uint256 acc = accPerWeight;
        uint256 ckpt = r.checkpoint;
        if (acc == ckpt) return;
        Account storage a = _accounts[account];
        if (a.weighted && a.rawWeight != 0) r.accruedX18 += uint256(a.rawWeight) * (acc - ckpt);
        r.checkpoint = acc;
    }

    // ================= ERC20 transfer: move units =================

    function _update(address from, address to, uint256 value) internal override {
        uint256 draw;
        if (to == poolManager) _consume(T_IN, T_LP_IN, value);
        if (from == poolManager) {
            _consume(T_OUT, T_LP_OUT, value);
            draw = _tload(T_DRAW);
            if (draw != 0) {
                if (draw > value) draw = value;
                _tstore(T_DRAW, _tload(T_DRAW) - draw);
            }
        }
        if (from != to) {
            _updateGlobal();
            if (_holds(from)) _settle(from);
            if (_holds(to)) _settle(to);
            if (block.timestamp < protectedUntil && from != address(0) && to != address(0) && to != poolManager && value != 0) {
                uint256 received = receivedDuringProtection[to] + value;
                if (received > WALLET_LIMIT) revert WalletLimitExceeded(to, received, WALLET_LIMIT);
                receivedDuringProtection[to] = received;
            }
        }
        uint256 fromBefore = from == address(0) ? 0 : balanceOf(from);
        uint256 toBefore = to == address(0) ? 0 : balanceOf(to);
        super._update(from, to, value);
        if (from == to || value == 0) return;

        uint256 nOut = _holds(from) ? fromBefore / ONE - (fromBefore - value) / ONE : 0;
        uint256 nIn = _holds(to) ? (toBefore + value) / ONE - toBefore / ONE : 0;
        uint256 given = nOut == 0 ? 0 : _leave(from, to, nOut, nIn, fromBefore / ONE);
        if (draw != 0 && _holds(to)) {
            // every whole token of credit opens one slot, as far as the receiver crosses whole tokens
            Account storage a = _accounts[to];
            uint256 credit = a.credit + draw;
            uint256 slots = credit / ONE;
            uint256 room = nIn - given;
            if (slots > room) slots = room;
            credit -= slots * ONE;
            a.credit = uint80(credit < type(uint80).max ? credit : type(uint80).max);
            for (uint256 k; k < slots; ++k) _openSlot(to);
        }
    }

    /// @dev Send `nOut` units out of `from` in leave order; the first `nIn` go to `to`. Returns how many went to `to`.
    function _leave(address from, address to, uint256 nOut, uint256 nIn, uint256 unitsBefore) private returns (uint256 given) {
        Account storage a = _accounts[from];
        uint256 naked = unitsBefore - a.ids - a.pending;

        uint256 forced = _tload(T_FORCE);
        if (forced != 0) {
            _tstore(T_FORCE, 0);
            if (_cards[forced].owner != from) revert NotOwner();
            _removeCard(from, forced);
            given += _handOver(forced, from, to, given < nIn);
            --nOut;
        }
        while (nOut != 0 && a.pending != 0) {
            uint32[] storage list = _pendingOf[from];
            uint256 slot = list[list.length - 1];
            _removePending(from, list.length - 1);
            if (given < nIn) {
                _givePending(to, slot);
                ++given;
            } else {
                _slots[slot].alive = false;
                emit SlotCancelled(slot);
            }
            --nOut;
        }
        uint256 k = naked < nOut ? naked : nOut;
        nOut -= k;
        uint256 g = nIn > given ? nIn - given : 0;
        given += k < g ? k : g; // naked units arrive naked
        while (nOut != 0) {
            uint256 id = _nextCard(from);
            _removeCard(from, id);
            given += _handOver(id, from, to, given < nIn);
            --nOut;
        }
    }

    function _handOver(uint256 id, address from, address to, bool toReceiver) private returns (uint256) {
        if (toReceiver) {
            _addCard(to, id, from);
            return 1;
        }
        if (_cards[id].layers > 1 && _accounts[from].guard) revert WorkGuarded(id);
        _decohere(id, from);
        return 0;
    }

    function _nextCard(address from) private returns (uint256 id) {
        uint32[] storage pref = _outFirst[from];
        while (pref.length != 0) {
            id = pref[pref.length - 1];
            pref.pop();
            if (_cards[id].owner == from) return id;
        }
        uint16 keys = _accounts[from].keys;
        uint256 key;
        while ((keys >> key) & 1 == 0) ++key;
        uint32[] storage b = _buckets[from][key];
        return b[b.length - 1];
    }

    // ================= cards =================

    function _addCard(address to, uint256 id, address from) private {
        _placeCard(to, id);
        IUN1Mirror(mirror).logTransfer(from, to, id);
    }

    function _placeCard(address to, uint256 id) private {
        Card storage c = _cards[id];
        uint256 key = _key(c);
        uint32[] storage b = _buckets[to][key];
        c.owner = to;
        c.index = uint16(b.length);
        b.push(uint32(id));
        Account storage a = _touch(to);
        a.ids += 1;
        a.keys |= uint16(1 << key);
        _addWeight(a, cardWeight(c.mask, c.layers));
    }

    function _removeCard(address from, uint256 id) private {
        Card storage c = _cards[id];
        uint256 key = _key(c);
        uint32[] storage b = _buckets[from][key];
        uint32 last = b[b.length - 1];
        b[c.index] = last;
        _cards[last].index = c.index;
        b.pop();
        Account storage a = _accounts[from];
        a.ids -= 1;
        if (b.length == 0) a.keys &= ~uint16(1 << key);
        _subWeight(a, cardWeight(c.mask, c.layers));
        c.owner = address(0);
    }

    /// @dev Back to superposition: appearance cleared; a composed work falls back to its own parts (audit X-1).
    function _decohere(uint256 id, address from) private {
        Card storage c = _cards[id];
        c.mask = originalMask(id);
        c.layers = 1;
        c.look = 0;
        delete _detailsOf[id];
        delete _commitOf[id];
        _poolAdd(id);
        IUN1Mirror(mirror).logTransfer(from, address(0), id);
        emit Decohered(id);
    }

    // ================= pending slots =================

    function _openSlot(address to) private {
        uint256 slot = _slots.length;
        uint64 round = DrandRound.target(block.timestamp);
        lastBlockOf[round] = block.number;
        _slots.push(Slot({owner: to, round: round, index: uint24(_pendingOf[to].length), alive: true}));
        _pendingOf[to].push(uint32(slot));
        Account storage a = _touch(to);
        a.pending += 1;
        _addWeight(a, W1);
        emit SlotOpened(to, slot, round);
    }

    function _givePending(address to, uint256 slot) private {
        Slot storage s = _slots[slot];
        s.owner = to;
        s.index = uint24(_pendingOf[to].length);
        _pendingOf[to].push(uint32(slot));
        Account storage a = _touch(to);
        a.pending += 1;
        _addWeight(a, W1);
    }

    function _removePending(address owner, uint256 index) private {
        uint32[] storage list = _pendingOf[owner];
        uint32 last = list[list.length - 1];
        list[index] = last;
        _slots[last].index = uint24(index);
        list.pop();
        Account storage a = _accounts[owner];
        a.pending -= 1;
        _subWeight(a, W1);
    }

    // ================= weight =================

    function _touch(address account) private returns (Account storage a) {
        a = _accounts[account];
        if (!a.touched) {
            a.touched = true;
            a.weighted = account.code.length == 0 || _is7702(account);
        }
    }

    function _addWeight(Account storage a, uint256 w) private {
        a.rawWeight += uint64(w); // at most 95,200 per card, 10,000 cards: far below 2^64
        if (a.weighted) totalWeight += w;
    }

    function _subWeight(Account storage a, uint256 w) private {
        a.rawWeight -= uint64(w);
        if (a.weighted) totalWeight -= w;
    }

    function _is7702(address account) private view returns (bool) {
        if (account.code.length != 23) return false;
        bytes3 prefix;
        assembly ("memory-safe") {
            extcodecopy(account, 0x00, 0, 3)
            prefix := and(mload(0x00), shl(232, 0xffffff))
        }
        return prefix == 0xef0100;
    }

    // ================= pool bitmap =================

    function _poolRemove(uint256 id) private {
        uint256 i = id - 1;
        _taken[i >> 8] |= uint256(1) << (i & 255);
        poolCount -= 1;
    }

    function _poolAdd(uint256 id) private {
        uint256 i = id - 1;
        _taken[i >> 8] &= ~(uint256(1) << (i & 255));
        poolCount += 1;
    }

    /// @dev Continue the slot's fixed order after its MAX_WALK prefix: independent per-id hash scores, then id to
    ///      break a tie. Scores do not depend on poolCount or other ids, so adding an id can only retain the previous
    ///      winner or select that added id, including a transition back into the prefix. Fixed pools are uniform up
    ///      to negligible 256-bit hash collisions. Read 40 bitmap words and score only their free ids (at most 8,976
    ///      after a missed prefix). The pool is never empty when a slot is revealed (pool >= pending slots).
    function _firstInPool(bytes32 seed) private view returns (uint256 id) {
        bytes32 orderSeed = keccak256(abi.encodePacked(seed, "un1.pool-order"));
        uint256 best = type(uint256).max;
        for (uint256 w; w < 40; ++w) {
            uint256 free = ~_taken[w];
            if (w == 39) free &= (uint256(1) << 16) - 1; // positions 9,984..9,999: the last 16 ids
            while (free != 0) {
                uint256 candidate = (w << 8) + BitMath.leastSignificantBit(free) + 1;
                uint256 score;
                assembly ("memory-safe") {
                    mstore(0x00, orderSeed)
                    mstore(0x20, candidate)
                    score := keccak256(0x00, 0x40)
                }
                if (id == 0 || score < best) {
                    id = candidate;
                    best = score;
                }
                free &= free - 1;
            }
        }
    }

    // ================= helpers =================

    function _holds(address account) private view returns (bool) {
        return account != address(0) && account != poolManager;
    }

    /// @dev Reassemble the 10,000 logical bytes from the PUSH32 chunks and hash them.
    function _masksHash(address d) private view returns (bytes32 h) {
        bytes memory data = new bytes(313 * 32);
        assembly ("memory-safe") {
            for { let j := 0 } lt(j, 313) { j := add(j, 1) } {
                extcodecopy(d, add(add(data, 0x20), mul(j, 32)), add(2, mul(j, 33)), 32)
            }
            mstore(data, 10000)
        }
        h = sha256(data);
    }

    /// @dev Leave priority: fragments by part count first, composed works after them.
    function _key(Card storage c) private view returns (uint256) {
        return (c.layers > 1 ? 8 : 0) + _popcount(c.mask) - 1;
    }

    function _popcount(uint8 m) private pure returns (uint256 c) {
        for (; m != 0; m &= m - 1) ++c;
    }

    /// @dev Spend `value` of the swap allowance `a`, then of the liquidity allowance `b`.
    function _consume(uint256 a, uint256 b, uint256 value) private {
        uint256 x = _tload(a);
        if (x >= value) {
            _tstore(a, x - value);
            return;
        }
        uint256 y = _tload(b);
        if (x + y < value) revert PoolTransferNotAuthorized();
        if (x != 0) _tstore(a, 0);
        _tstore(b, y - (value - x));
    }

    function _tstore(uint256 slot, uint256 v) private {
        assembly ("memory-safe") {
            tstore(slot, v)
        }
    }

    function _tload(uint256 slot) private view returns (uint256 v) {
        assembly ("memory-safe") {
            v := tload(slot)
        }
    }
}
