// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ╔══════════════════════════════════════════════════════════════╗
//  CUETOURNAMENT  ·  v1.0  ·  Production-Ready
//  CUECOIN Ecosystem  ·  BNB Smart Chain
//
//  On-chain tournament bracket management. Single-elimination
//  brackets seeded at registration, advanced by EIP-712 oracle
//  signatures, prizes auto-distributed at completion. Zero manual
//  payout steps — the contract pays itself.
//
//  ════════════════════════════════════════════════════
//   FOUR-TIER TOURNAMENT STRUCTURE
//  ════════════════════════════════════════════════════
//
//  ┌────────────┬──────────┬──────────┬───────────────────────┐
//  │ Tier       │ Entry    │ NFT Req  │ NFT Prize             │
//  ├────────────┼──────────┼──────────┼───────────────────────┤
//  │ Weekly     │  50 CUE  │ None     │ None                  │
//  │ Monthly    │ 200 CUE  │ Common+  │ Rare (Pro Cue)        │
//  │ Regional   │ 500 CUE  │ Rare+    │ Epic (Master Cue)     │
//  │ World      │5,000 CUE │ Legendary│ Legendary 1-of-1 +HoF │
//  └────────────┴──────────┴──────────┴───────────────────────┘
//
//  All tiers use the same hardcoded split:
//    60%  → 1st place
//    20%  → 2nd place (runner-up / finalist)
//    10%  → Burned permanently (0xdead)
//    10%  → DAO Treasury
//
//  Bracket sizes: 8, 16, 32, 64, or 128 players (powers of two).
//
//  ════════════════════════════════════════════════════
//   BRACKET MODEL (single-elimination)
//  ════════════════════════════════════════════════════
//
//  Players are assigned slots 0..bracketSize-1 in registration
//  order. Each round pairs adjacent slots:
//
//    Round 0: (slot0 vs slot1), (slot2 vs slot3), …
//    Round 1: winners of above, similarly paired
//    …
//    Final:   1 match → determines 1st and 2nd place
//
//  Rounds required: log2(bracketSize)
//    8   → 3 rounds   (QF, SF, F)
//    16  → 4 rounds
//    32  → 5 rounds
//    64  → 6 rounds
//    128 → 7 rounds
//
//  Total matches per tournament: bracketSize − 1.
//  matchesInRound(r) = bracketSize >> (r + 1).
//
//  The oracle submits match results round-by-round via EIP-712
//  signed payloads. When all matches in a round are complete, the
//  contract automatically builds the next round's participant list
//  and advances currentRound. No human needs to trigger this.
//
//  When the final match is submitted, prizes are distributed
//  automatically in the same transaction. No separate payout call.
//
//  ════════════════════════════════════════════════════
//   TOURNAMENT LIFECYCLE
//  ════════════════════════════════════════════════════
//
//   1. Owner or DAO (via GENERIC_CALL) creates tournament.
//      Parameters: name, tier, bracketSize, registrationDeadline.
//      Entry fee and NFT requirement are fixed per-tier (bytecode).
//
//   2. Players register: pay entry fee, meet NFT requirement.
//      When all slots fill → status automatically → IN_PROGRESS.
//      Registration order determines bracket slot assignment.
//
//   3. If registrationDeadline passes and bracket is not full:
//      anyone calls expireTournament() → CANCELLED.
//      Players call claimRefund() to recover entry fee.
//
//   4. Oracle submits match results (EIP-712 signed) round by round.
//      Each submission advances the bracket automatically.
//
//   5. Final match submitted → prizes distributed → NFT minted.
//      Status → COMPLETED. Fully automatic, no further calls needed.
//
//  ════════════════════════════════════════════════════
//   ORACLE DESIGN
//  ════════════════════════════════════════════════════
//
//  The oracle set is an owner-managed whitelist of signers (AWS KMS
//  instances). Any single registered oracle can submit a match result.
//  This differs from CueEscrow's 2-of-3 for high-value wagers — here
//  the oracle is submitting bracket state advancement, not releasing
//  a specific player's wager. Replay protection is via per-tournament
//  sequential nonce enforced in the EIP-712 payload.
//
//  Signature format (EIP-712):
//    MatchResult(
//      uint32 tournamentId,
//      uint8  round,
//      uint8  matchIndex,
//      address winner,
//      address loser,
//      uint256 nonce,
//      uint256 expiry
//    )
//
//  Expiry prevents stale signatures from being submitted after a
//  pause or network delay. Default: oracle should set expiry to
//  block.timestamp + 30 minutes at signing time.
//
//  ════════════════════════════════════════════════════
//   NFT PRIZE MINTING
//  ════════════════════════════════════════════════════
//
//  CueTournament must be registered as the tier minter in CueNFT:
//    CueNFT.setTierMinter(TIER_RARE,      address(CueTournament))  // Monthly Cup
//    CueNFT.setTierMinter(TIER_EPIC,      address(CueTournament))  // Regional
//    CueNFT.setTierMinter(TIER_LEGENDARY, address(CueTournament))  // World
//  (All three require the 48-hour timelock in CueNFT — queue immediately after deploy.)
//
//  The oracle includes a matchHistoryRoot (bytes32 Merkle root of the
//  winner's full bracket result history) in the final match submission.
//  This root is stored in the tournament record and passed to CueNFT
//  on mint — permanently encoding the win record on-chain.
//
//  NFT minting is attempted in a try/catch: if minting fails (supply
//  cap reached, wallet cap reached, CueNFT paused), the prize money
//  is still distributed and the tournament completes. The mint failure
//  is logged via NftMintFailed event for off-chain resolution.
//
//  ════════════════════════════════════════════════════
//   ACCESS CONTROL
//  ════════════════════════════════════════════════════
//
//  Owner (team multisig) CAN:
//    createTournament, cancelTournament
//    addOracle, removeOracle
//    setGuardian (two-step)
//    queueDaoTreasuryUpdate / cancelDaoTreasuryUpdate
//    pause / unpause
//    recoverERC20 (non-CUECOIN only)
//    setCueNft (update CueNFT address if upgraded)
//
//  DAO (via CueDAO GENERIC_CALL, CueTournament as approvedTarget):
//    createTournament — owner function, DAO uses GENERIC_CALL
//
//  Guardian (Gnosis Safe 3-of-5) CAN:
//    pause / unpause
//    acceptGuardian
//
//  Oracle (registered KMS signer) CAN:
//    submitMatchResult
//
//  Nobody CAN:
//    Change PRIZE_FIRST_BPS, PRIZE_SECOND_BPS, BURN_BPS, DAO_BPS
//    Cancel a tournament that is IN_PROGRESS
//    Submit results without a valid EIP-712 oracle signature
//    Submit a result for a match whose participants it does not name correctly
//    Replay a used oracle signature (nonce enforcement)
//
// ╚══════════════════════════════════════════════════════════════╝

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ═══════════════════════════════════════════════════════════════
//  CUENTF INTERFACE
// ═══════════════════════════════════════════════════════════════

interface ICueNFT {
    function walletTierHighest(address wallet) external view returns (uint8 highestTier);

    function mintRare(
        address to,
        uint256 winsAtMint,
        bytes32 matchHistoryRoot
    ) external returns (uint256 tokenId);

    function mintEpic(
        address to,
        string calldata tournamentName,
        bytes32 matchHistoryRoot
    ) external returns (uint256 tokenId);

    function mintLegendary(
        address to,
        string calldata tournamentName,
        bytes32 matchHistoryRoot
    ) external returns (uint256 tokenId);
}

// ═══════════════════════════════════════════════════════════════
//  MAIN CONTRACT
// ═══════════════════════════════════════════════════════════════

/**
 * @title  CueTournament
 * @author CUECOIN Team
 * @notice Single-elimination tournament bracket management.
 *         EIP-712 oracle result submission. Automatic prize distribution.
 *         NFT minting to winners. Pull-pattern refunds on cancellation.
 */
contract CueTournament is EIP712, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ECDSA     for bytes32;

    // ═══════════════════════════════════════════════════════════
    //  CONSTANTS  (bytecode — nothing can change these)
    // ═══════════════════════════════════════════════════════════

    /// @notice Prize split — sum = 10,000 (100%).
    uint256 public constant PRIZE_FIRST_BPS  = 6_000; // 60% to 1st place
    uint256 public constant PRIZE_SECOND_BPS = 2_000; // 20% to 2nd place
    uint256 public constant BURN_BPS         = 1_000; // 10% burned
    uint256 public constant DAO_BPS          = 1_000; // 10% to DAO Treasury
    // Invariant: 6000 + 2000 + 1000 + 1000 = 10000 ✓

    // ── Entry fees per tier (bytecode constants matching spec) ──
    uint256 public constant FEE_WEEKLY   =     50 ether; //    50 CUECOIN
    uint256 public constant FEE_MONTHLY  =    200 ether; //   200 CUECOIN
    uint256 public constant FEE_REGIONAL =    500 ether; //   500 CUECOIN
    uint256 public constant FEE_WORLD    =  5_000 ether; // 5,000 CUECOIN

    // ── NFT tier requirements (min tier to enter; 255 = none required) ──
    // CueNFT tier constants: COMMON=0, RARE=1, EPIC=2, LEGENDARY=3, GENESIS=4
    // NO_NFT_SENTINEL = 255 (walletTierHighest returns this if wallet holds no NFT)
    uint8 public constant NFT_REQ_WEEKLY   = 255; // no requirement
    uint8 public constant NFT_REQ_MONTHLY  =   0; // Common or above (COMMON = 0)
    uint8 public constant NFT_REQ_REGIONAL =   1; // Rare or above   (RARE = 1)
    uint8 public constant NFT_REQ_WORLD    =   3; // Legendary or Genesis (LEGENDARY = 3, GENESIS = 4 ≥ 3)

    // ── Valid bracket sizes ──
    uint8 public constant MIN_BRACKET = 8;
    uint8 public constant MAX_BRACKET = 128;

    // ── Admin constants ──
    uint256 public constant TREASURY_UPDATE_DELAY = 48 hours;
    uint256 public constant MAX_ORACLE_EXPIRY      = 2  hours; // max allowed expiry delta from now

    address public constant BURN_ADDRESS =
        0x000000000000000000000000000000000000dEaD;

    // ── EIP-712 type hash ──
    bytes32 public constant MATCH_RESULT_TYPEHASH = keccak256(
        "MatchResult(uint32 tournamentId,uint8 round,uint8 matchIndex,"
        "address winner,address loser,uint256 nonce,uint256 expiry)"
    );

    // ═══════════════════════════════════════════════════════════
    //  ENUMS & STRUCTS
    // ═══════════════════════════════════════════════════════════

    enum TournamentTier   { WEEKLY, MONTHLY, REGIONAL, WORLD }
    enum TournamentStatus { REGISTRATION, IN_PROGRESS, COMPLETED, CANCELLED }

    /**
     * @notice Core tournament record.
     *
     * @param tournamentId           Auto-assigned, 1-indexed.
     * @param tier                   WEEKLY / MONTHLY / REGIONAL / WORLD.
     * @param status                 Current lifecycle state.
     * @param bracketSize            8 / 16 / 32 / 64 / 128.
     * @param entryFee               Per-player entry fee in CUECOIN-wei (tier-derived).
     * @param nftRequirement         Minimum CueNFT tier to enter (255 = none).
     * @param name                   Human-readable tournament name (used in NFT metadata).
     * @param registrationDeadline   Unix timestamp after which unfilled brackets expire.
     *                               0 = no deadline (wait indefinitely for full bracket).
     * @param totalPot               entryFee × bracketSize (set when bracket fills).
     * @param playerCount            Number of registered players so far.
     * @param currentRound           0-indexed round now accepting results.
     * @param totalRounds            log2(bracketSize) — total rounds to play.
     * @param winner                 1st-place wallet (set on completion).
     * @param runnerUp               2nd-place wallet / finalist (set on completion).
     * @param matchHistoryRoot       Merkle root of winner's bracket history (oracle-provided).
     * @param createdAt              block.timestamp at tournament creation.
     * @param completedAt            block.timestamp at completion (0 until then).
     */
    struct Tournament {
        uint32           tournamentId;
        TournamentTier   tier;
        TournamentStatus status;
        uint8            bracketSize;
        uint256          entryFee;
        uint8            nftRequirement;
        string           name;
        uint256          registrationDeadline;
        uint256          totalPot;
        uint8            playerCount;
        uint8            currentRound;
        uint8            totalRounds;
        address          winner;
        address          runnerUp;
        bytes32          matchHistoryRoot;
        uint256          createdAt;
        uint256          completedAt;
    }

    // ═══════════════════════════════════════════════════════════
    //  IMMUTABLES
    // ═══════════════════════════════════════════════════════════

    IERC20 public immutable cueCoin;

    // ═══════════════════════════════════════════════════════════
    //  STATE
    // ═══════════════════════════════════════════════════════════

    // ── CueNFT reference (owner-updatable in case of upgrade) ──
    ICueNFT public cueNft;

    // ── Tournament storage ──
    uint32 private _nextTournamentId;
    mapping(uint32 => Tournament) private _tournaments;

    // ── Bracket participant list per (tournament, round) ──
    // roundParticipants[tid][0] = initial player slots (in registration order)
    // roundParticipants[tid][r] = winners advancing into round r
    mapping(uint32 => mapping(uint8 => address[])) public roundParticipants;

    // ── Match winner record — prevents double submission ──
    // key = keccak256(abi.encode(tournamentId, round, matchIndex))
    mapping(bytes32 => address) public matchWinner;

    // ── Match completion tracking per round ──
    mapping(uint32 => mapping(uint8 => uint8)) public roundMatchesCompleted;

    // ── Per-tournament oracle nonce (replay protection) ──
    mapping(uint32 => uint256) public tournamentNonce;

    // ── Refunds for cancelled tournaments ──
    // pendingRefund[player][tournamentId] = entry fee to return
    mapping(address => mapping(uint32 => uint256)) public pendingRefund;

    // ── Oracle whitelist ──
    mapping(address => bool) public isOracle;

    // ── DAO treasury ──
    address public daoTreasury;
    address private _pendingDaoTreasury;
    uint256 private _pendingDaoTreasuryEta;

    // ── Guardian ──
    address public guardian;
    address public pendingGuardian;

    // ── Pause ──
    bool public paused;

    // ── Global stats ──
    uint256 public totalTournamentsCreated;
    uint256 public totalTournamentsCompleted;
    uint256 public totalCueBurned;
    uint256 public totalDaoPaid;
    uint256 public totalPrizePaid;

    // ═══════════════════════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════════════════════

    event TournamentCreated(
        uint32 indexed tournamentId,
        TournamentTier  tier,
        string          name,
        uint8           bracketSize,
        uint256         entryFee,
        uint8           nftRequirement,
        uint256         registrationDeadline
    );

    event PlayerRegistered(
        uint32 indexed tournamentId,
        address indexed player,
        uint8           slot
    );

    event TournamentStarted(
        uint32 indexed tournamentId,
        address[]       players
    );

    event MatchResultSubmitted(
        uint32 indexed tournamentId,
        uint8           round,
        uint8           matchIndex,
        address indexed winner,
        address indexed loser
    );

    event RoundCompleted(
        uint32 indexed tournamentId,
        uint8           round,
        address[]       advancingPlayers
    );

    event TournamentCompleted(
        uint32 indexed tournamentId,
        address indexed winner,
        address indexed runnerUp,
        uint256         prizeToFirst,
        uint256         prizeToSecond,
        uint256         burned,
        uint256         toDao
    );

    event TournamentCancelled(
        uint32 indexed tournamentId,
        address indexed by
    );

    event TournamentExpired(uint32 indexed tournamentId);

    event RefundClaimed(
        uint32 indexed tournamentId,
        address indexed player,
        uint256         amount
    );

    event NftPrizeMinted(
        uint32 indexed tournamentId,
        address indexed winner,
        uint256         tokenId,
        uint8           tier
    );

    event NftMintFailed(
        uint32 indexed tournamentId,
        address indexed winner,
        string          reason
    );

    event OracleAdded(address indexed oracle);
    event OracleRemoved(address indexed oracle);

    event Paused(address indexed by);
    event Unpaused(address indexed by);

    event GuardianNominated(address indexed nominee);
    event GuardianAccepted(address indexed oldGuardian, address indexed newGuardian);

    event DaoTreasuryUpdateQueued(address indexed newTreasury, uint256 eta);
    event DaoTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event DaoTreasuryUpdateCancelled(address indexed cancelled);

    event CueNftUpdated(address indexed oldNft, address indexed newNft);

    // ═══════════════════════════════════════════════════════════
    //  MODIFIERS
    // ═══════════════════════════════════════════════════════════

    modifier onlyGuardian() {
        require(msg.sender == guardian, "CueTournament: not guardian");
        _;
    }

    modifier onlyOwnerOrGuardian() {
        require(
            msg.sender == owner() || msg.sender == guardian,
            "CueTournament: not owner or guardian"
        );
        _;
    }

    /// @dev Blocks register() and submitMatchResult(). Refunds always work.
    modifier whenNotPaused() {
        require(!paused, "CueTournament: paused");
        _;
    }

    // ═══════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    /**
     * @param _cueCoin      CueCoin ERC-20 contract.
     * @param _cueNft       CueNFT contract (must set this contract as tier minter
     *                      for RARE, EPIC, LEGENDARY via CueNFT.setTierMinter()).
     * @param _guardian     Guardian address (Gnosis Safe 3-of-5).
     * @param _daoTreasury  CueDAO address — receives 10% of every tournament pot.
     *
     * @dev Post-deploy steps (order matters):
     *   1. CueNFT.queueTierMinterUpdate(TIER_RARE,      address(this)) — wait 48h
     *   2. CueNFT.queueTierMinterUpdate(TIER_EPIC,      address(this)) — wait 48h
     *   3. CueNFT.queueTierMinterUpdate(TIER_LEGENDARY, address(this)) — wait 48h
     *   4. CueNFT.applyTierMinterUpdate(TIER_RARE)
     *   5. CueNFT.applyTierMinterUpdate(TIER_EPIC)
     *   6. CueNFT.applyTierMinterUpdate(TIER_LEGENDARY)
     *   7. addOracle(kmsSignerAddress) for each KMS instance
     *   8. createTournament(...) for the first Weekly League
     */
    constructor(
        address _cueCoin,
        address _cueNft,
        address _guardian,
        address _daoTreasury
    )
        EIP712("CueTournament", "1")
        Ownable(msg.sender)
    {
        require(_cueCoin     != address(0), "CueTournament: zero cueCoin");
        require(_cueNft      != address(0), "CueTournament: zero cueNft");
        require(_guardian    != address(0), "CueTournament: zero guardian");
        require(_daoTreasury != address(0), "CueTournament: zero treasury");

        cueCoin      = IERC20(_cueCoin);
        cueNft       = ICueNFT(_cueNft);
        guardian     = _guardian;
        daoTreasury  = _daoTreasury;
    }

    // ═══════════════════════════════════════════════════════════
    //  TOURNAMENT CREATION — OWNER (or DAO via GENERIC_CALL)
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Create a new tournament. Owner or DAO (via GENERIC_CALL).
     *
     *         Entry fee and NFT requirement are derived from tier — not
     *         caller-specified. Only name, tier, bracketSize, and deadline
     *         are creator choices.
     *
     * @param tier                   Tournament tier (determines fee + NFT req + NFT prize).
     * @param name                   Unique-ish descriptive name, e.g. "Weekly League #47".
     *                               Used in NFT metadata for MONTHLY/REGIONAL/WORLD.
     * @param bracketSize            Number of players: 8, 16, 32, 64, or 128.
     *                               World Tournament spec: 128. Other tiers: flexible.
     * @param registrationDeadline   Unix timestamp when unfilled brackets expire.
     *                               0 = no deadline (bracket waits until full indefinitely).
     * @return tournamentId          The newly created tournament's ID.
     */
    function createTournament(
        TournamentTier tier,
        string calldata name,
        uint8 bracketSize,
        uint256 registrationDeadline
    )
        external
        onlyOwner
        returns (uint32 tournamentId)
    {
        require(bytes(name).length > 0,   "CueTournament: empty name");
        require(_isValidBracketSize(bracketSize), "CueTournament: invalid bracket size");
        require(
            registrationDeadline == 0 ||
            registrationDeadline > block.timestamp,
            "CueTournament: deadline in the past"
        );

        uint256 entryFee       = _entryFeeForTier(tier);
        uint8   nftReq         = _nftReqForTier(tier);
        uint8   totalRounds    = _log2(bracketSize);

        if (_nextTournamentId == 0) _nextTournamentId = 1;
        tournamentId = _nextTournamentId++;

        _tournaments[tournamentId] = Tournament({
            tournamentId:          tournamentId,
            tier:                  tier,
            status:                TournamentStatus.REGISTRATION,
            bracketSize:           bracketSize,
            entryFee:              entryFee,
            nftRequirement:        nftReq,
            name:                  name,
            registrationDeadline:  registrationDeadline,
            totalPot:              0,
            playerCount:           0,
            currentRound:          0,
            totalRounds:           totalRounds,
            winner:                address(0),
            runnerUp:              address(0),
            matchHistoryRoot:      bytes32(0),
            createdAt:             block.timestamp,
            completedAt:           0
        });

        totalTournamentsCreated++;

        emit TournamentCreated(
            tournamentId, tier, name, bracketSize,
            entryFee, nftReq, registrationDeadline
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  PLAYER REGISTRATION
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Register for a tournament.
     *
     *         Validates: tournament is in REGISTRATION status, bracket not full,
     *         deadline not passed, player not already registered, NFT requirement met.
     *         Pulls entry fee from player. Assigns a bracket slot.
     *         When the last slot fills → tournament status → IN_PROGRESS.
     *
     * @param tournamentId  Tournament to register for.
     */
    function register(uint32 tournamentId)
        external
        nonReentrant
        whenNotPaused
    {
        Tournament storage t = _requireTournament(tournamentId);

        require(
            t.status == TournamentStatus.REGISTRATION,
            "CueTournament: not in registration"
        );
        require(
            t.playerCount < t.bracketSize,
            "CueTournament: bracket full"
        );
        require(
            t.registrationDeadline == 0 || block.timestamp <= t.registrationDeadline,
            "CueTournament: registration deadline passed"
        );

        address player = msg.sender;

        // Check not already registered (O(n) but bracketSize ≤ 128 → acceptable)
        address[] storage slots = roundParticipants[tournamentId][0];
        for (uint256 i = 0; i < slots.length; i++) {
            require(slots[i] != player, "CueTournament: already registered");
        }

        // NFT requirement check
        _requireNftEligibility(player, t.nftRequirement);

        // Pull entry fee
        cueCoin.safeTransferFrom(player, address(this), t.entryFee);

        // Assign slot
        uint8 slot = t.playerCount;
        roundParticipants[tournamentId][0].push(player);
        t.playerCount++;

        // Track refund eligibility (in case tournament is later cancelled)
        pendingRefund[player][tournamentId] += t.entryFee;

        emit PlayerRegistered(tournamentId, player, slot);

        // If bracket is now full → start tournament
        if (t.playerCount == t.bracketSize) {
            t.totalPot = t.entryFee * t.bracketSize;
            t.status   = TournamentStatus.IN_PROGRESS;

            // Clear refund tracking — prizes will be paid instead
            // (done per-player in _clearRefundsOnStart to save gas on cancel path)
            _clearRefundsOnStart(tournamentId, roundParticipants[tournamentId][0]);

            emit TournamentStarted(tournamentId, roundParticipants[tournamentId][0]);
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  ORACLE MATCH RESULT SUBMISSION
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Submit a signed match result and advance the bracket.
     *
     *         Oracle provides: which tournament, which round, which match within
     *         that round, who won, who lost, a nonce for replay protection,
     *         an expiry timestamp, and an EIP-712 signature.
     *
     *         The contract validates:
     *           1. Tournament is IN_PROGRESS.
     *           2. round matches t.currentRound.
     *           3. matchIndex is in range.
     *           4. winner and loser are the expected participants.
     *           5. This match has not already been submitted.
     *           6. nonce matches tournamentNonce[id].
     *           7. block.timestamp < expiry.
     *           8. EIP-712 signature is from a registered oracle.
     *
     *         After recording the result:
     *           - If all matches in this round are done → builds next round,
     *             emits RoundCompleted, advances currentRound.
     *           - If this was the final round → distributes prizes,
     *             mints NFT prize, sets status = COMPLETED.
     *
     * @param tournamentId   Tournament ID.
     * @param round          0-indexed round number (must equal t.currentRound).
     * @param matchIndex     Index of this match within the round (0-based).
     * @param winner         Address of the match winner.
     * @param loser          Address of the match loser.
     * @param matchHistoryRoot  Merkle root of winner's full match history (used for final only;
     *                          oracle can pass bytes32(0) for non-final rounds).
     * @param nonce          Must equal tournamentNonce[tournamentId].
     * @param expiry         Unix timestamp after which the signature is invalid.
     * @param sig            EIP-712 signature from a registered oracle.
     */
    function submitMatchResult(
        uint32  tournamentId,
        uint8   round,
        uint8   matchIndex,
        address winner,
        address loser,
        bytes32 matchHistoryRoot,
        uint256 nonce,
        uint256 expiry,
        bytes calldata sig
    )
        external
        nonReentrant
        whenNotPaused
    {
        Tournament storage t = _requireTournament(tournamentId);

        require(
            t.status == TournamentStatus.IN_PROGRESS,
            "CueTournament: tournament not in progress"
        );
        require(round == t.currentRound,         "CueTournament: wrong round");
        require(block.timestamp < expiry,         "CueTournament: signature expired");
        require(expiry <= block.timestamp + MAX_ORACLE_EXPIRY,
                                                  "CueTournament: expiry too far ahead");
        require(nonce == tournamentNonce[tournamentId],
                                                  "CueTournament: invalid nonce");

        // Validate matchIndex range
        uint8 matchesThisRound = _matchesInRound(t.bracketSize, round);
        require(matchIndex < matchesThisRound,    "CueTournament: matchIndex out of range");

        // Validate participants
        address[] storage participants = roundParticipants[tournamentId][round];
        address expected0 = participants[uint256(matchIndex) * 2];
        address expected1 = participants[uint256(matchIndex) * 2 + 1];

        require(
            (winner == expected0 && loser == expected1) ||
            (winner == expected1 && loser == expected0),
            "CueTournament: winner/loser do not match bracket"
        );
        require(winner != address(0) && loser != address(0),
                                                  "CueTournament: zero address");

        // Check match not already submitted
        bytes32 matchKey = _matchKey(tournamentId, round, matchIndex);
        require(matchWinner[matchKey] == address(0), "CueTournament: match already submitted");

        // Verify EIP-712 signature
        bytes32 structHash = keccak256(abi.encode(
            MATCH_RESULT_TYPEHASH,
            tournamentId,
            round,
            matchIndex,
            winner,
            loser,
            nonce,
            expiry
        ));
        address signer = _hashTypedDataV4(structHash).recover(sig);
        require(isOracle[signer], "CueTournament: invalid oracle signature");

        // Consume nonce
        tournamentNonce[tournamentId]++;

        // Record match result
        matchWinner[matchKey] = winner;
        roundMatchesCompleted[tournamentId][round]++;

        emit MatchResultSubmitted(tournamentId, round, matchIndex, winner, loser);

        // Check if round is complete
        if (roundMatchesCompleted[tournamentId][round] == matchesThisRound) {
            _onRoundComplete(tournamentId, round, matchHistoryRoot);
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  CANCELLATION & EXPIRY
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Cancel a tournament that is in REGISTRATION status.
     *         Owner-only. Tournaments that have started (IN_PROGRESS) cannot
     *         be cancelled — the bracket must run to completion.
     *
     *         After cancellation, registered players call claimRefund().
     *
     * @param tournamentId  Tournament to cancel.
     */
    function cancelTournament(uint32 tournamentId) external onlyOwner nonReentrant {
        Tournament storage t = _requireTournament(tournamentId);
        require(
            t.status == TournamentStatus.REGISTRATION,
            "CueTournament: can only cancel during registration"
        );

        t.status = TournamentStatus.CANCELLED;
        emit TournamentCancelled(tournamentId, msg.sender);
    }

    /**
     * @notice Expire a tournament whose registration deadline has passed
     *         without filling the bracket.
     *
     *         Permissionless — anyone can call this to trigger the cancellation
     *         and allow players to claim their refunds, even if the creator is
     *         inactive.
     *
     * @param tournamentId  Tournament to expire.
     */
    function expireTournament(uint32 tournamentId) external nonReentrant {
        Tournament storage t = _requireTournament(tournamentId);

        require(
            t.status == TournamentStatus.REGISTRATION,
            "CueTournament: not in registration"
        );
        require(
            t.registrationDeadline > 0 && block.timestamp > t.registrationDeadline,
            "CueTournament: deadline not passed"
        );
        require(
            t.playerCount < t.bracketSize,
            "CueTournament: bracket was full — use normal flow"
        );

        t.status = TournamentStatus.CANCELLED;
        emit TournamentExpired(tournamentId);
    }

    // ═══════════════════════════════════════════════════════════
    //  REFUNDS — CANCELLED TOURNAMENTS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Claim a full entry fee refund for a cancelled tournament.
     *
     *         Pull pattern: players call this themselves rather than receiving
     *         automatic pushes. Available once status = CANCELLED.
     *
     * @param tournamentId  Cancelled tournament ID.
     */
    function claimRefund(uint32 tournamentId) external nonReentrant {
        Tournament storage t = _requireTournament(tournamentId);
        require(
            t.status == TournamentStatus.CANCELLED,
            "CueTournament: not cancelled"
        );

        uint256 amount = pendingRefund[msg.sender][tournamentId];
        require(amount > 0, "CueTournament: no refund");

        pendingRefund[msg.sender][tournamentId] = 0;
        cueCoin.safeTransfer(msg.sender, amount);

        emit RefundClaimed(tournamentId, msg.sender, amount);
    }

    // ═══════════════════════════════════════════════════════════
    //  ORACLE MANAGEMENT — OWNER
    // ═══════════════════════════════════════════════════════════

    /// @notice Register an oracle signer. Owner-only.
    function addOracle(address oracle) external onlyOwner {
        require(oracle != address(0), "CueTournament: zero oracle");
        require(!isOracle[oracle],    "CueTournament: already oracle");
        isOracle[oracle] = true;
        emit OracleAdded(oracle);
    }

    /// @notice Remove an oracle signer. Owner-only.
    function removeOracle(address oracle) external onlyOwner {
        require(isOracle[oracle], "CueTournament: not an oracle");
        isOracle[oracle] = false;
        emit OracleRemoved(oracle);
    }

    // ═══════════════════════════════════════════════════════════
    //  CUENTFT ADDRESS UPDATE — OWNER
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Update the CueNFT contract address (for upgrades).
     *         Immediately effective — no timelock needed as NFT minting
     *         only occurs on tournament completion which requires prior setup.
     */
    function setCueNft(address newNft) external onlyOwner {
        require(newNft != address(0), "CueTournament: zero address");
        address old = address(cueNft);
        cueNft = ICueNFT(newNft);
        emit CueNftUpdated(old, newNft);
    }

    // ═══════════════════════════════════════════════════════════
    //  PAUSE — OWNER OR GUARDIAN
    // ═══════════════════════════════════════════════════════════

    function pause() external onlyOwnerOrGuardian {
        require(!paused, "CueTournament: already paused");
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwnerOrGuardian {
        require(paused, "CueTournament: not paused");
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ═══════════════════════════════════════════════════════════
    //  GUARDIAN UPDATE — TWO-STEP
    // ═══════════════════════════════════════════════════════════

    function setGuardian(address nominee) external onlyOwner {
        require(nominee != address(0), "CueTournament: zero nominee");
        pendingGuardian = nominee;
        emit GuardianNominated(nominee);
    }

    function acceptGuardian() external {
        require(msg.sender == pendingGuardian, "CueTournament: not pending guardian");
        address old     = guardian;
        guardian        = pendingGuardian;
        pendingGuardian = address(0);
        emit GuardianAccepted(old, guardian);
    }

    // ═══════════════════════════════════════════════════════════
    //  DAO TREASURY UPDATE — TIMELOCKED
    // ═══════════════════════════════════════════════════════════

    function queueDaoTreasuryUpdate(address newTreasury) external onlyOwner {
        require(newTreasury != address(0),   "CueTournament: zero treasury");
        require(newTreasury != daoTreasury,  "CueTournament: same treasury");
        uint256 eta = block.timestamp + TREASURY_UPDATE_DELAY;
        _pendingDaoTreasury    = newTreasury;
        _pendingDaoTreasuryEta = eta;
        emit DaoTreasuryUpdateQueued(newTreasury, eta);
    }

    function applyDaoTreasuryUpdate() external nonReentrant {
        require(_pendingDaoTreasuryEta != 0,               "CueTournament: no pending update");
        require(block.timestamp >= _pendingDaoTreasuryEta,  "CueTournament: delay not elapsed");
        address old        = daoTreasury;
        daoTreasury        = _pendingDaoTreasury;
        _pendingDaoTreasury    = address(0);
        _pendingDaoTreasuryEta = 0;
        emit DaoTreasuryUpdated(old, daoTreasury);
    }

    function cancelDaoTreasuryUpdate() external onlyOwner {
        require(_pendingDaoTreasuryEta != 0, "CueTournament: no pending update");
        address cancelled      = _pendingDaoTreasury;
        _pendingDaoTreasury    = address(0);
        _pendingDaoTreasuryEta = 0;
        emit DaoTreasuryUpdateCancelled(cancelled);
    }

    // ═══════════════════════════════════════════════════════════
    //  RECOVERY — OWNER
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Recover non-CUECOIN tokens accidentally sent here.
     *         CUECOIN cannot be recovered — it is the prize reserve.
     */
    function recoverERC20(address token, uint256 amount) external onlyOwner {
        require(
            token != address(cueCoin),
            "CueTournament: cannot recover CUECOIN — it is the prize reserve"
        );
        IERC20(token).safeTransfer(owner(), amount);
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW — TOURNAMENTS
    // ═══════════════════════════════════════════════════════════

    /// @notice Fetch a tournament record. Reverts if not found.
    function getTournament(uint32 tournamentId)
        external
        view
        returns (Tournament memory)
    {
        return _requireTournament(tournamentId);
    }

    /// @notice Players registered in a specific round's bracket.
    function getRoundParticipants(uint32 tournamentId, uint8 round)
        external
        view
        returns (address[] memory)
    {
        return roundParticipants[tournamentId][round];
    }

    /// @notice Winner of a specific match (address(0) if not yet submitted).
    function getMatchWinner(uint32 tournamentId, uint8 round, uint8 matchIndex)
        external
        view
        returns (address)
    {
        return matchWinner[_matchKey(tournamentId, round, matchIndex)];
    }

    /**
     * @notice Participants for the next match result to submit.
     *         Returns the two players expected for the given matchIndex in
     *         the current round.
     */
    function getNextMatchParticipants(uint32 tournamentId, uint8 matchIndex)
        external
        view
        returns (address player0, address player1)
    {
        Tournament storage t = _requireTournament(tournamentId);
        address[] storage parts = roundParticipants[tournamentId][t.currentRound];
        require(uint256(matchIndex) * 2 + 1 < parts.length, "CueTournament: matchIndex OOB");
        player0 = parts[uint256(matchIndex) * 2];
        player1 = parts[uint256(matchIndex) * 2 + 1];
    }

    /**
     * @notice Number of matches remaining in the current round.
     */
    function matchesRemainingInRound(uint32 tournamentId)
        external
        view
        returns (uint256)
    {
        Tournament storage t = _requireTournament(tournamentId);
        if (t.status != TournamentStatus.IN_PROGRESS) return 0;
        uint8 total     = _matchesInRound(t.bracketSize, t.currentRound);
        uint8 completed = roundMatchesCompleted[tournamentId][t.currentRound];
        return total > completed ? total - completed : 0;
    }

    /**
     * @notice Preview the prize breakdown for a given total pot.
     */
    function previewPrizes(uint256 totalPot)
        external
        pure
        returns (
            uint256 toFirst,
            uint256 toSecond,
            uint256 burned,
            uint256 toDao
        )
    {
        (toFirst, toSecond, burned, toDao) = _computePrizes(totalPot);
    }

    /// @notice Total tournament count (all-time).
    function tournamentCount() external view returns (uint32) {
        return _nextTournamentId == 0 ? 0 : _nextTournamentId - 1;
    }

    /// @notice EIP-712 domain separator (for off-chain signature construction).
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @notice Build the EIP-712 struct hash for a match result — for oracle use.
     */
    function matchResultHash(
        uint32  tournamentId,
        uint8   round,
        uint8   matchIndex,
        address winner,
        address loser,
        uint256 nonce,
        uint256 expiry
    )
        external
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(keccak256(abi.encode(
            MATCH_RESULT_TYPEHASH,
            tournamentId, round, matchIndex,
            winner, loser, nonce, expiry
        )));
    }

    /**
     * @notice Protocol snapshot.
     */
    function protocolStats()
        external
        view
        returns (
            uint32  created,
            uint256 completed,
            uint256 cueBurned,
            uint256 daoPaid,
            uint256 prizePaid,
            bool    paused_,
            address treasury_,
            address guardian_
        )
    {
        return (
            totalTournamentsCreated == 0 ? 0 : _nextTournamentId - 1,
            totalTournamentsCompleted,
            totalCueBurned,
            totalDaoPaid,
            totalPrizePaid,
            paused,
            daoTreasury,
            guardian
        );
    }

    function pendingTreasuryUpdate()
        external
        view
        returns (address pending, uint256 eta)
    {
        return (_pendingDaoTreasury, _pendingDaoTreasuryEta);
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — BRACKET ADVANCEMENT
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev Called after the last match of a round is submitted.
     *      Collects all match winners for this round, builds the next
     *      round's participant list, and advances currentRound.
     *      If this was the final round, distributes prizes and mints NFT.
     */
    function _onRoundComplete(
        uint32 tournamentId,
        uint8 round,
        bytes32 matchHistoryRoot
    ) internal {
        Tournament storage t = _tournaments[tournamentId];
        uint8 matchesThisRound = _matchesInRound(t.bracketSize, round);

        // Collect winners from this round in match order
        address[] memory winners = new address[](matchesThisRound);
        for (uint8 i = 0; i < matchesThisRound; i++) {
            winners[i] = matchWinner[_matchKey(tournamentId, round, i)];
        }

        bool isFinal = (round + 1 == t.totalRounds);

        if (!isFinal) {
            // Build next round participants
            for (uint8 i = 0; i < matchesThisRound; i++) {
                roundParticipants[tournamentId][round + 1].push(winners[i]);
            }
            t.currentRound = round + 1;

            emit RoundCompleted(tournamentId, round, winners);
        } else {
            // Tournament over — winners[0] is the champion of the final match
            // (matchesThisRound == 1 for the final)
            address champion  = winners[0];
            // Runner-up is the loser of the final — both participants are in round array
            address[] storage finalists = roundParticipants[tournamentId][round];
            address finalist0 = finalists[0];
            address finalist1 = finalists[1];
            address runnerUp  = (champion == finalist0) ? finalist1 : finalist0;

            t.winner          = champion;
            t.runnerUp        = runnerUp;
            t.matchHistoryRoot = matchHistoryRoot;
            t.completedAt     = block.timestamp;
            t.status          = TournamentStatus.COMPLETED;

            emit RoundCompleted(tournamentId, round, winners);

            totalTournamentsCompleted++;

            // Distribute prizes (state already updated above — CEI)
            _distributePrizes(tournamentId, champion, runnerUp, t.totalPot);

            // Mint NFT prize
            _mintNftPrize(tournamentId, champion, t.tier, t.name, matchHistoryRoot, t.totalRounds);
        }
    }

    /**
     * @dev Distribute the tournament pot.
     *      CEI: status is set to COMPLETED before this call in _onRoundComplete.
     */
    function _distributePrizes(
        uint32 tournamentId,
        address champion,
        address runnerUp,
        uint256 totalPot
    ) internal {
        (
            uint256 toFirst,
            uint256 toSecond,
            uint256 burned,
            uint256 toDao
        ) = _computePrizes(totalPot);

        // CEI: update all state before external transfers
        totalCueBurned  += burned;
        totalDaoPaid    += toDao;
        totalPrizePaid  += toFirst + toSecond;

        emit TournamentCompleted(
            tournamentId, champion, runnerUp,
            toFirst, toSecond, burned, toDao
        );

        // External transfers after all state updates (CEI)
        if (toFirst  > 0) cueCoin.safeTransfer(champion,    toFirst);
        if (toSecond > 0) cueCoin.safeTransfer(runnerUp,    toSecond);
        if (burned   > 0) cueCoin.safeTransfer(BURN_ADDRESS, burned);
        if (toDao    > 0) cueCoin.safeTransfer(daoTreasury,  toDao);
    }

    /**
     * @dev Attempt to mint the NFT prize. Wrapped in try/catch — if minting
     *      fails (supply cap, wallet cap, CueNFT paused), prize money has
     *      already been paid and the tournament is COMPLETED. The failure
     *      is logged for off-chain resolution (manual mint or alternative award).
     *
     *      CueTournament must be registered as the tier minter in CueNFT for
     *      RARE, EPIC, and LEGENDARY tiers before this will succeed.
     */
    function _mintNftPrize(
        uint32 tournamentId,
        address champion,
        TournamentTier tier,
        string memory tName,
        bytes32 matchHistoryRoot,
        uint8   totalRounds
    ) internal {
        if (tier == TournamentTier.WEEKLY) {
            // Weekly League has no NFT prize
            return;
        }

        if (matchHistoryRoot == bytes32(0)) {
            emit NftMintFailed(tournamentId, champion, "no matchHistoryRoot");
            return;
        }

        if (tier == TournamentTier.MONTHLY) {
            // Monthly Cup → Rare "Pro Cue" NFT
            try cueNft.mintRare(champion, totalRounds, matchHistoryRoot)
                returns (uint256 tokenId)
            {
                emit NftPrizeMinted(tournamentId, champion, tokenId, 1); // TIER_RARE = 1
            } catch Error(string memory reason) {
                emit NftMintFailed(tournamentId, champion, reason);
            } catch {
                emit NftMintFailed(tournamentId, champion, "mintRare: unknown error");
            }

        } else if (tier == TournamentTier.REGIONAL) {
            // Regional Tournament → Epic "Master Cue" NFT
            try cueNft.mintEpic(champion, tName, matchHistoryRoot)
                returns (uint256 tokenId)
            {
                emit NftPrizeMinted(tournamentId, champion, tokenId, 2); // TIER_EPIC = 2
            } catch Error(string memory reason) {
                emit NftMintFailed(tournamentId, champion, reason);
            } catch {
                emit NftMintFailed(tournamentId, champion, "mintEpic: unknown error");
            }

        } else if (tier == TournamentTier.WORLD) {
            // World Tournament → Legendary 1-of-1 "Grand Master" NFT + Hall of Fame
            try cueNft.mintLegendary(champion, tName, matchHistoryRoot)
                returns (uint256 tokenId)
            {
                emit NftPrizeMinted(tournamentId, champion, tokenId, 3); // TIER_LEGENDARY = 3
            } catch Error(string memory reason) {
                emit NftMintFailed(tournamentId, champion, reason);
            } catch {
                emit NftMintFailed(tournamentId, champion, "mintLegendary: unknown error");
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — REGISTRATION HELPERS
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev When the bracket fills and becomes IN_PROGRESS, clear all
     *      pendingRefund entries — players are now competing for prizes.
     *      This prevents refunds from being claimed mid-tournament.
     */
    function _clearRefundsOnStart(uint32 tournamentId, address[] storage players) internal {
        for (uint256 i = 0; i < players.length; i++) {
            pendingRefund[players[i]][tournamentId] = 0;
        }
    }

    /**
     * @dev Validate NFT eligibility. Returns immediately if no requirement.
     *      Uses CueNFT.walletTierHighest() which returns NO_NFT_SENTINEL (255)
     *      when the wallet holds no gameplay NFT.
     *      Higher tier values = higher tiers (COMMON=0 … GENESIS=4).
     */
    function _requireNftEligibility(address player, uint8 minTier) internal view {
        if (minTier == 255) return; // no requirement for Weekly League

        uint8 highest = cueNft.walletTierHighest(player);

        // 255 = sentinel (no NFT held), not a real tier
        require(
            highest != 255 && highest >= minTier,
            "CueTournament: NFT tier requirement not met"
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — PURE HELPERS
    // ═══════════════════════════════════════════════════════════

    function _computePrizes(uint256 totalPot)
        internal
        pure
        returns (
            uint256 toFirst,
            uint256 toSecond,
            uint256 burned,
            uint256 toDao
        )
    {
        toFirst  = (totalPot * PRIZE_FIRST_BPS)  / 10_000;
        toSecond = (totalPot * PRIZE_SECOND_BPS) / 10_000;
        toDao    = (totalPot * DAO_BPS)           / 10_000;
        // burn absorbs any 1-wei rounding dust: remainder after first+second+dao
        burned   = totalPot - toFirst - toSecond - toDao;
    }

    function _matchKey(uint32 tournamentId, uint8 round, uint8 matchIndex)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(tournamentId, round, matchIndex));
    }

    /// @dev matchesInRound(bracketSize, round) = bracketSize >> (round + 1)
    ///      e.g. bracketSize=16: round0→8, round1→4, round2→2, round3→1
    function _matchesInRound(uint8 bracketSize, uint8 round)
        internal
        pure
        returns (uint8)
    {
        return uint8(uint256(bracketSize) >> (uint256(round) + 1));
    }

    /// @dev log2 for valid bracket sizes (8, 16, 32, 64, 128).
    function _log2(uint8 n) internal pure returns (uint8) {
        if (n == 8)   return 3;
        if (n == 16)  return 4;
        if (n == 32)  return 5;
        if (n == 64)  return 6;
        if (n == 128) return 7;
        revert("CueTournament: invalid bracket size");
    }

    function _isValidBracketSize(uint8 n) internal pure returns (bool) {
        return n == 8 || n == 16 || n == 32 || n == 64 || n == 128;
    }

    function _entryFeeForTier(TournamentTier tier) internal pure returns (uint256) {
        if (tier == TournamentTier.WEEKLY)   return FEE_WEEKLY;
        if (tier == TournamentTier.MONTHLY)  return FEE_MONTHLY;
        if (tier == TournamentTier.REGIONAL) return FEE_REGIONAL;
        return FEE_WORLD;
    }

    function _nftReqForTier(TournamentTier tier) internal pure returns (uint8) {
        if (tier == TournamentTier.WEEKLY)   return NFT_REQ_WEEKLY;
        if (tier == TournamentTier.MONTHLY)  return NFT_REQ_MONTHLY;
        if (tier == TournamentTier.REGIONAL) return NFT_REQ_REGIONAL;
        return NFT_REQ_WORLD;
    }

    function _requireTournament(uint32 tournamentId)
        internal
        view
        returns (Tournament storage)
    {
        require(
            tournamentId >= 1 && tournamentId < _nextTournamentId,
            "CueTournament: tournament does not exist"
        );
        return _tournaments[tournamentId];
    }
}
