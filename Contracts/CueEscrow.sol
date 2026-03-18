// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ╔══════════════════════════════════════════════════════════════╗
//  CUEESCROW  ·  v3.0  ·  Security-Hardened
//  CUECOIN Ecosystem  ·  BNB Smart Chain
//
//  The trustless referee for every CUECOIN wager match.
//
//  v1 features (carried forward from /contracts/CueEscrow.sol):
//   [V1-1]  createMatch() / createPrivateMatch() — wager lock
//   [V1-2]  joinMatch() — opponent locks, activates timeout clock
//   [V1-3]  claimVictory() — 1-of-3 oracle EIP-712 resolution
//   [V1-4]  claimVictoryHighValue() — 2-of-3 oracle for > 10k CUECOIN
//   [V1-5]  submitHighValueSignature() — first-sig storage for HV flow
//   [V1-6]  claimForfeit() — heartbeat disconnect, 100% to winner
//   [V1-7]  claimTimeout() — 24hr on-chain fallback, full refund
//   [V1-8]  cancelMatch() — pre-join creator cancel, full refund
//   [V1-9]  proposeMutualCancel() / confirmMutualCancel() — post-join
//   [V1-10] NFT bonus routed through CueRewardsPool (best-effort call)
//   [V1-11] 1% burn (0xdead) + 1% P2E pool fee on claimVictory only
//   [V1-12] Global nonce registry — replay-proof across all matches
//
//  v2 improvements:
//   [V2-1]  REFERRAL HOOK — claimVictory and claimForfeit call
//            CueReferral.recordMatchCompletion(winner) after every
//            resolved first match. Enables "first wager match" referral
//            milestone with zero additional trust. Best-effort call.
//   [V2-2]  TIMELOCK ON ORACLE ROTATION — updateOracles() queues a
//            48-hour on-chain timelock. Oracle key rotation is the
//            highest-risk admin action; observers have 48h to detect
//            and respond to any malicious rotation attempt.
//   [V2-3]  MATCH EXPIRY FOR OPEN MATCHES — an OPEN match that nobody
//            joins within 24 hours auto-expires. The creator may call
//            expireMatch() for a full refund. Prevents indefinite capital
//            lock in unmatched queues.
//   [V2-4]  WAGER PAUSE THRESHOLD — owner can set maxWagerPerPlayer.
//            While set, createMatch rejects wagers above threshold.
//            Useful for soft-launching with lower-stakes matches only.
//   [V2-5]  matchStats() VIEW — single-call summary for frontend
//            dashboards: total matches, resolved, cancelled, total
//            CUECOIN burned through escrow, total P2E routed.
//   [V2-6]  HARDCODED OPEN MATCH EXPIRY DURATION — 24 hours (same as
//            timeout duration). Now tracked via createdAt timestamp.
//   [V2-7]  MUTUAL CANCEL EXPIRY — mutual cancel proposals expire after
//            MUTUAL_CANCEL_EXPIRY (6 hours) if not confirmed. The
//            proposer or owner can clear the stale proposal.
//   [V2-8]  TIMELOCKED REWARDS POOL UPDATE — updateRewardsPool() now
//            uses a 48-hour timelock, protecting the critical P2E fee
//            routing address.
//   [V2-9]  PROTOCOL STATS TRACKING — on-chain accumulators for total
//            CUECOIN burned and routed to P2E pool via this contract.
//   [V2-10] forfeitDigest() exposed as a public view function for
//            off-chain oracle tooling.
//
//  v3 security hardening (audit-driven):
//   [V3-1]  PER-ORACLE DAILY SIGNING CAP — on-chain CUECOIN-denominated
//            cap per oracle address per UTC day. Each oracle tracks its
//            own daily accumulated payout exposure. Once an oracle
//            reaches oracleDailyCapWei (default: 5,000,000 CUECOIN /
//            oracle / day), every subsequent claimVictory or claimForfeit
//            signed by that oracle is rejected until the next UTC day.
//
//            WHY THIS OVER 2-of-3 FOR ALL MATCHES:
//            — 2-of-3 for all matches adds 1 full tx latency to every
//              standard match resolution — degrading UX for all players.
//            — The per-oracle cap requires zero latency change. Normal
//              matches are unaffected: one oracle signs, match resolves.
//            — A compromised oracle can still sign — but the blast radius
//              is bounded. At 5M CUECOIN / oracle / day and a 100 CUECOIN
//              average wager, an attacker needs 50,000 fraudulent
//              claimVictory calls to exhaust the cap — a blatant anomaly
//              that monitoring catches within minutes, not hours.
//            — The cap converts "wipe everything in one block" into
//              "slow drain that monitoring catches before meaningful loss".
//
//            CAP IS TIMELOCKED (48h) AND OWNER-ADJUSTABLE:
//            — At launch with low wager volume: 5M / oracle / day is well
//              above legitimate daily throughput. As volume grows, the
//              owner raises the cap via timelocked setOracleDailyCap().
//            — The cap can be set per-oracle (individual) or globally
//              (all three oracles share the same cap value).
//
//            TRACKING MECHANISM:
//            — oracleDay[oracle] → the UTC day number of the last reset
//              (block.timestamp / 86400).
//            — oracleDailyUsed[oracle] → CUECOIN-wei exposure attributed
//              to this oracle in the current UTC day.
//            — On each claimVictory/claimForfeit: if the current UTC day
//              differs from oracleDay[oracle], reset oracleDailyUsed and
//              update oracleDay. Then add the match pot to used. Reject
//              if used > cap.
//            — "Exposure" = total pot on victory, total pot on forfeit.
//              Not the winner payout — the full pot the oracle could have
//              redirected.
//
//   [V3-2]  PER-ORACLE CAP STATS VIEW — oracleCapStatus(oracle) returns
//            cap, used, remaining, and UTC day for each oracle. For
//            monitoring dashboards and alert systems.
// ╚══════════════════════════════════════════════════════════════╝

import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  CueEscrow
 * @author CUECOIN Team
 * @notice Trustless wager escrow for all CUECOIN 1v1 ranked and private matches.
 *
 * ══════════════════════════════════════════════════════════
 *  MATCH LIFECYCLE — STANDARD
 * ══════════════════════════════════════════════════════════
 *
 *   OPEN MATCH (public matchmaking):
 *   1. createMatch()        — Player A locks wager into this contract.
 *   2. joinMatch()          — Player B locks equal wager. Match → ACTIVE.
 *                             24-hour timeout clock begins.
 *   3. [Unity Authoritative Server runs the physics match]
 *   4a. claimVictory()     — Winner submits oracle-signed VictoryCertificate.
 *                             Fees deducted (1% burn + 1% P2E). Winner gets 98%.
 *                             Optional NFT bonus paid from CueRewardsPool (best-effort).
 *   4b. claimForfeit()     — Oracle signs ForfeitCertificate (opponent's heartbeat stopped).
 *                             Winner gets 100% of pot. No fees (not player's fault).
 *   4c. claimTimeout()     — After 24h no resolution; either player triggers full refund.
 *                             Zero oracle involvement required.
 *   4d. cancelMatch()      — Player A cancels BEFORE anyone joins. Instant refund.
 *       expireMatch()      — Anyone expires an OPEN match after 24h with no join.
 *
 *   PRIVATE MATCH (direct challenge):
 *   1. createPrivateMatch() — Player A locks wager, names exactly who may join.
 *   2. joinMatch()          — Only named Player B may join.
 *   3. Resolution same as open match.
 *
 *   MUTUAL CANCEL (post-join, both agree):
 *   1. proposeMutualCancel()  — Either player proposes. Proposal valid for 6 hours.
 *   2. confirmMutualCancel()  — The OTHER player confirms. Both refunded 100%.
 *      clearExpiredProposal() — Anyone clears a stale proposal after 6 hours.
 *
 * ══════════════════════════════════════════════════════════
 *  HIGH-VALUE MATCH (wager > 10,000 CUECOIN per player)
 * ══════════════════════════════════════════════════════════
 *
 *   Victory requires 2-of-3 oracle signatures:
 *   Step 1: submitHighValueSignature() — first oracle submits sig.
 *   Step 2: claimVictoryHighValue()   — second (distinct) oracle confirms.
 *   Forfeit and timeout still work identically to standard matches.
 *
 * ══════════════════════════════════════════════════════════
 *  FEE STRUCTURE (claimVictory only)
 * ══════════════════════════════════════════════════════════
 *   1 % of total pot → Burn (0xdead — permanent deflation)
 *   1 % of total pot → CueRewardsPool (P2E refill from wager volume)
 *   ─────────────────────────────────────────────────────────
 *   2 % total protocol fee
 *   98 % to winner
 *
 *   Forfeit:      100 % to winner, 0 % fees (penalty event).
 *   Timeout:      100 % refund each, 0 % fees (not players' fault).
 *   MutualCancel: 100 % refund each, 0 % fees (agreement).
 *   CancelMatch:  100 % refund to Player A, 0 % fees (no opponent yet).
 *   ExpireMatch:  100 % refund to Player A, 0 % fees (no opponent found).
 *
 * ══════════════════════════════════════════════════════════
 *  NFT WAGER BONUS (paid from CueRewardsPool, not from pot)
 * ══════════════════════════════════════════════════════════
 *   Winner holds eligible NFT → receives bonus from CueRewardsPool.
 *   Bonus declared in VictoryCertificate by oracle (reads NFT ownership server-side).
 *   Oracle signs the amount — it cannot be forged or inflated by the claimant.
 *   Bonus does NOT come from the opponent's stake.
 *   The call is best-effort: if the pool is depleted or reverts, the winner
 *   still receives their full 98% pot payout.
 *
 *   NFT Tier → Bonus (% of winner's individual wager):
 *     Rare      +5 %    (500 bps)
 *     Epic      +10 %   (1,000 bps)
 *     Legendary +15 %   (1,500 bps)
 *     Genesis   +20 %   (2,000 bps — hardcoded cap)
 *
 * ══════════════════════════════════════════════════════════
 *  ORACLE ARCHITECTURE
 * ══════════════════════════════════════════════════════════
 *   Three independent AWS KMS instances (US-East-1, EU-West-1, AP-Southeast-1).
 *   Normal matches  (wager ≤ 10,000 CUECOIN): 1-of-3 oracle signatures.
 *   High-value matches (wager > 10,000 CUECOIN): 2-of-3 oracle signatures.
 *   Oracle rotation uses a 48-hour on-chain timelock [V2-2].
 *
 *   [V3-1] PER-ORACLE DAILY CAP:
 *   Each oracle has an independent on-chain daily CUECOIN exposure cap
 *   (default: 5,000,000 CUECOIN per oracle per UTC day). A compromised
 *   oracle can sign fraudulent certificates — but only up to this cap before
 *   all further claims from that oracle are rejected until UTC midnight.
 *   At 5M CUECOIN cap and 100 CUECOIN average wager, an attacker needs
 *   50,000 fraudulent claimVictory calls per oracle per day to exhaust it —
 *   a volume anomaly that Datadog/PagerDuty catches in minutes.
 *   This bounds blast radius without adding any latency to normal resolution.
 *
 * ══════════════════════════════════════════════════════════
 *  REFERRAL INTEGRATION
 * ══════════════════════════════════════════════════════════
 *   After every match resolved (victory or forfeit), CueEscrow calls
 *   CueReferral.recordMatchCompletion(player) for the WINNER.
 *   CueReferral tracks "first match completed" to gate referral rewards.
 *   This is a best-effort call — failure never reverts the payout.
 *
 * ══════════════════════════════════════════════════════════
 *  HARDCODED CONSTANTS (bytecode — unchangeable after deploy)
 * ══════════════════════════════════════════════════════════
 *   TIMEOUT_DURATION           24 hours
 *   OPEN_MATCH_EXPIRY          24 hours
 *   MUTUAL_CANCEL_EXPIRY       6 hours
 *   BURN_FEE_BPS               100 (1 %)
 *   REWARDS_FEE_BPS            100 (1 %)
 *   HIGH_VALUE_THRESHOLD       10,000 CUECOIN
 *   MAX_NFT_BONUS_BPS          2,000 (20 % — Genesis tier cap)
 *   VICTORY_CERT_EXPIRY        1 hour
 *   FORFEIT_CERT_EXPIRY        2 hours
 *   TIMELOCK_DELAY             48 hours
 *   TIMELOCK_GRACE             14 days
 *   DEFAULT_ORACLE_DAILY_CAP   5,000,000 CUECOIN (per oracle, per UTC day)
 *   BURN_ADDRESS               0x000000000000000000000000000000000000dEaD
 */
contract CueEscrow is EIP712, Ownable2Step, ReentrancyGuard, Pausable {
    using ECDSA     for bytes32;
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════
    //  CONSTANTS
    // ═══════════════════════════════════════════════════════════

    // ── EIP-712 type hashes ──
    bytes32 public constant VICTORY_TYPEHASH = keccak256(
        "VictoryCertificate(bytes32 matchId,address winner,uint256 nftBonusWei,"
        "uint256 nonce,uint256 expiry)"
    );
    bytes32 public constant FORFEIT_TYPEHASH = keccak256(
        "ForfeitCertificate(bytes32 matchId,address winner,address forfeiter,"
        "uint256 nonce,uint256 expiry)"
    );

    // ── Fees (basis points) ──
    uint256 public constant BURN_FEE_BPS    = 100;  // 1 % of total pot
    uint256 public constant REWARDS_FEE_BPS = 100;  // 1 % of total pot
    uint256 public constant TOTAL_FEE_BPS   = BURN_FEE_BPS + REWARDS_FEE_BPS; // 2 %

    // ── High-value threshold ──
    /// @notice Per-player wager above which 2-of-3 oracle sigs are required.
    uint256 public constant HIGH_VALUE_THRESHOLD = 10_000 ether; // 10,000 CUECOIN

    // ── NFT bonus cap ──
    /// @notice Maximum NFT bonus the oracle may include in a VictoryCertificate.
    ///         20 % of winner's individual wager — Genesis tier cap.
    uint256 public constant MAX_NFT_BONUS_BPS = 2_000;

    // ── Timing constants ──
    /// @notice Timeout from joinMatch(). After 24h, either player may trigger full refund.
    uint256 public constant TIMEOUT_DURATION = 24 hours;

    /// @notice [V2-3] An OPEN match expires if nobody joins within 24 hours.
    uint256 public constant OPEN_MATCH_EXPIRY = 24 hours;

    /// @notice [V2-7] A mutual cancel proposal expires if not confirmed within 6 hours.
    uint256 public constant MUTUAL_CANCEL_EXPIRY = 6 hours;

    // ── Certificate validity windows ──
    uint256 public constant VICTORY_CERT_EXPIRY = 1 hours;
    uint256 public constant FORFEIT_CERT_EXPIRY = 2 hours;

    // ── [V2-2] Timelock ──
    uint256 public constant TIMELOCK_DELAY = 48 hours;
    uint256 public constant TIMELOCK_GRACE = 14 days;

    // ── [V3-1] Per-oracle daily signing cap default ──
    // 5,000,000 CUECOIN = 50,000 × 100 CUECOIN average wagers per oracle per day.
    // A compromise that exhausts this would trigger hundreds of PagerDuty alerts
    // long before approaching the cap. Owner can raise via timelocked setter.
    uint256 public constant DEFAULT_ORACLE_DAILY_CAP = 5_000_000 ether;

    // ── Burn address ──
    address public constant BURN_ADDRESS = address(0x000000000000000000000000000000000000dEaD);

    // ═══════════════════════════════════════════════════════════
    //  ENUMS & STRUCTS
    // ═══════════════════════════════════════════════════════════

    /// @notice Match lifecycle states.
    ///   OPEN      — Created, waiting for Player B.
    ///   ACTIVE    — Both players locked in, game in progress. Timeout clock running.
    ///   RESOLVED  — Payout complete (victory or forfeit).
    ///   CANCELLED — Refunded (timeout, cancel, expire, or mutual cancel).
    enum MatchStatus { OPEN, ACTIVE, RESOLVED, CANCELLED }

    /// @notice Wager tier — enforced server-side for ELO bracket matching.
    ///         Stored on-chain for transparency and dispute reference.
    enum WagerTier {
        MICRO,    // 10 CUECOIN   — entry level
        SMALL,    // 50 CUECOIN
        MEDIUM,   // 100 CUECOIN
        LARGE,    // 500 CUECOIN
        XLARGE,   // 1,000 CUECOIN
        WHALE     // 5,000 CUECOIN — standard high-value tier
        // Note: HIGH_VALUE_THRESHOLD (10,000) can be hit with custom wagers above WHALE
    }

    struct Match {
        address     playerA;               // Match creator
        address     playerB;               // Opponent (zero until joined; or fixed for private)
        address     targetPlayerB;         // Private match gate (zero = public)
        uint256     wagerPerPlayer;        // CUECOIN each player deposited
        uint256     createdAt;             // Block timestamp of createMatch()
        uint256     activatedAt;           // Block timestamp of joinMatch() — timeout from here
        uint256     mutualCancelProposedAt;// [V2-7] Timestamp of mutual cancel proposal (0 = none)
        MatchStatus status;
        WagerTier   tier;
        bool        isHighValue;           // wagerPerPlayer > HIGH_VALUE_THRESHOLD
        bool        mutualCancelProposed;
        address     mutualCancelProposer;
    }

    /// @dev Stored data for the first oracle signature on a high-value match.
    ///      Key: _nonceKey(matchId, nonce)
    struct HighValueFirstSig {
        address signer;
        bool    submitted;
    }

    // ═══════════════════════════════════════════════════════════
    //  STATE VARIABLES
    // ═══════════════════════════════════════════════════════════

    // ── Core token ──
    IERC20 public immutable cueCoin;

    // ── External contracts ──
    /// @notice CueRewardsPool — source of NFT wager bonuses and P2E refill recipient.
    address public rewardsPool;

    /// @notice [V2-1] CueReferral — notified on first match completion.
    address public referralContract;

    // ── Oracle addresses — three independent AWS KMS instances ──
    address public oracle0; // US-East-1
    address public oracle1; // EU-West-1
    address public oracle2; // AP-Southeast-1

    // ── [V3-1] Per-oracle daily signing cap ──
    // Single cap value applied to all three oracles. Timelocked to change.
    uint256 public oracleDailyCapWei;

    // Per-oracle daily exposure tracking:
    // oracleDay[oracle]      → UTC day of most recent activity (block.timestamp / 86400)
    // oracleDailyUsed[oracle] → total pot exposure accumulated today (in CUECOIN-wei)
    // "Exposure" = totalPot of each match signed, regardless of payout split.
    // Using totalPot (not winnerPayout) measures the max a rogue oracle could redirect.
    mapping(address => uint256) public oracleDay;
    mapping(address => uint256) public oracleDailyUsed;

    // ── [V2-4] Optional wager ceiling (0 = no limit) ──
    /// @notice When non-zero, createMatch rejects wagerPerPlayer above this value.
    ///         Used for soft-launches or risk management during high volatility.
    uint256 public maxWagerPerPlayer;

    // ── Match storage ──
    mapping(bytes32 => Match) public matches;

    // ── Global nonce registry — prevents any certificate replay across all matches ──
    // Key: keccak256(matchId, nonce) → used
    mapping(bytes32 => bool) public usedNonces;

    // ── High-value first-sig storage ──
    // Key: keccak256(matchId, nonce) → HighValueFirstSig
    mapping(bytes32 => HighValueFirstSig) private _hvFirstSig;

    // ── Monotonically increasing counter — contributes to matchId entropy ──
    uint256 private _matchCounter;

    // ── Per-player match index (for frontend queries) ──
    mapping(address => bytes32[]) private _playerMatches;

    // ── [V2-9] Protocol statistics accumulators ──
    uint256 public totalMatchesCreated;
    uint256 public totalMatchesResolved;   // Victory + Forfeit
    uint256 public totalMatchesCancelled;  // Timeout + Cancel + Expire + MutualCancel
    uint256 public totalCueCoinBurned;     // CUECOIN permanently burned through this contract
    uint256 public totalCueCoinToP2E;      // CUECOIN routed to CueRewardsPool through this contract

    // ── [V2-2] On-chain timelock ──
    mapping(bytes32 => uint256) public timelockEta;
    mapping(bytes32 => bool)    public timelockExecuted;

    // ── [V2-1] Per-player first-match tracking ──
    // Records whether this contract has ever fired recordMatchCompletion(player)
    // for a given address. Prevents duplicate referral notifications.
    mapping(address => bool) public firstMatchNotified;

    // ═══════════════════════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════════════════════

    event MatchCreated(
        bytes32 indexed matchId,
        address indexed playerA,
        uint256 wagerPerPlayer,
        WagerTier tier,
        bool isPrivate,
        bool isHighValue
    );

    event MatchJoined(
        bytes32 indexed matchId,
        address indexed playerB,
        uint256 activatedAt
    );

    event MatchResolved(
        bytes32 indexed matchId,
        address indexed winner,
        address indexed loser,
        uint256 winnerPayout,
        uint256 nftBonus,
        uint256 burnedAmount,
        uint256 rewardsAmount
    );

    event MatchForfeited(
        bytes32 indexed matchId,
        address indexed winner,
        address indexed forfeiter,
        uint256 winnerPayout
    );

    event MatchTimedOut(
        bytes32 indexed matchId,
        address indexed triggeredBy,
        uint256 refundPerPlayer
    );

    event MatchCancelled(
        bytes32 indexed matchId,
        address indexed cancelledBy,
        uint256 refundAmount
    );

    event MatchExpired(
        bytes32 indexed matchId,
        address indexed triggeredBy,
        uint256 refundAmount
    );

    event MutualCancelProposed(
        bytes32 indexed matchId,
        address indexed proposer,
        uint256 expiresAt        // [V2-7]
    );

    event MutualCancelCompleted(
        bytes32 indexed matchId,
        uint256 refundPerPlayer
    );

    event MutualCancelProposalCleared(  // [V2-7]
        bytes32 indexed matchId,
        address indexed clearedBy
    );

    event HighValueFirstSigSubmitted(
        bytes32 indexed matchId,
        address indexed oracle,
        uint256 nonce
    );

    // [V2-2] Timelock events
    event TimelockQueued(bytes32 indexed operationId, bytes32 indexed action, uint256 eta);
    event TimelockExecuted(bytes32 indexed operationId, bytes32 indexed action);
    event TimelockCancelled(bytes32 indexed operationId);

    event OraclesUpdated(address indexed oracle0, address indexed oracle1, address indexed oracle2);
    event RewardsPoolUpdated(address indexed oldPool, address indexed newPool);     // [V2-8]
    event ReferralContractUpdated(address indexed oldContract, address indexed newContract);
    event MaxWagerUpdated(uint256 newMaxWager);                                      // [V2-4]
    event OracleDailyCapUpdated(uint256 newCapWei);                                  // [V3-1]
    // [V3-1] Fires when an oracle's daily usage crosses 80% of cap (tx succeeds — event persists).
    // Use this for PagerDuty alerting. Hard revert at 100% is detected via failed-tx monitoring.
    event OracleCapApproaching(
        address indexed oracle,
        uint256 indexed day,
        uint256 usedWei,
        uint256 capWei
    );

    // ═══════════════════════════════════════════════════════════
    //  MODIFIERS
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev [V2-2] Two-call on-chain timelock for high-risk admin operations.
     *
     *      CALL 1 — Queues the operation. Emits TimelockQueued. Returns immediately.
     *               ETA = block.timestamp + 48 hours.
     *
     *      CALL 2 (after 48h, within 14 days) — Executes the function body.
     *               Emits TimelockExecuted.
     *
     *      opId includes keccak256(msg.data) so different arguments generate
     *      independent operations with independent timers.
     */
    modifier timelocked(bytes32 action) {
        bytes32 opId = keccak256(abi.encodePacked(action, msg.sender, keccak256(msg.data)));
        if (timelockEta[opId] == 0) {
            uint256 eta = block.timestamp + TIMELOCK_DELAY;
            timelockEta[opId] = eta;
            emit TimelockQueued(opId, action, eta);
            return;
        }
        require(block.timestamp >= timelockEta[opId],               "CueEscrow: timelock not elapsed");
        require(block.timestamp <  timelockEta[opId] + TIMELOCK_GRACE, "CueEscrow: timelock expired");
        require(!timelockExecuted[opId],                            "CueEscrow: already executed");
        timelockExecuted[opId] = true;
        emit TimelockExecuted(opId, action);
        _;
    }

    // ═══════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    /**
     * @param _cueCoin          CueCoin BEP-20 token address.
     * @param _rewardsPool      CueRewardsPool — receives 1% P2E fee and pays NFT bonuses.
     * @param _referralContract CueReferral — notified on first match completion (may be zero at deploy).
     * @param _oracle0          AWS KMS oracle instance 0 — US-East-1.
     * @param _oracle1          AWS KMS oracle instance 1 — EU-West-1.
     * @param _oracle2          AWS KMS oracle instance 2 — AP-Southeast-1.
     */
    constructor(
        address _cueCoin,
        address _rewardsPool,
        address _referralContract,
        address _oracle0,
        address _oracle1,
        address _oracle2
    )
        EIP712("CueEscrow", "3")
        Ownable(msg.sender)
    {
        require(_cueCoin     != address(0), "CueEscrow: zero cueCoin");
        require(_rewardsPool != address(0), "CueEscrow: zero rewardsPool");
        require(_oracle0     != address(0), "CueEscrow: zero oracle0");
        require(_oracle1     != address(0), "CueEscrow: zero oracle1");
        require(_oracle2     != address(0), "CueEscrow: zero oracle2");
        require(
            _oracle0 != _oracle1 && _oracle1 != _oracle2 && _oracle0 != _oracle2,
            "CueEscrow: oracle addresses must be distinct"
        );

        cueCoin            = IERC20(_cueCoin);
        rewardsPool        = _rewardsPool;
        referralContract   = _referralContract; // zero is acceptable at deploy
        oracle0            = _oracle0;
        oracle1            = _oracle1;
        oracle2            = _oracle2;

        // [V3-1] Initialise per-oracle daily cap to default
        oracleDailyCapWei = DEFAULT_ORACLE_DAILY_CAP;
    }

    // ═══════════════════════════════════════════════════════════
    //  MATCH CREATION
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Create a public match — any ELO-matched opponent can join.
     *         Locks wager into this contract immediately.
     *         The match expires if nobody joins within OPEN_MATCH_EXPIRY (24h).
     *
     * @param wagerPerPlayer  CUECOIN amount per player. Must be > 0.
     *                        If maxWagerPerPlayer is set, must not exceed it.
     * @param tier            Wager tier — matches ELO bracket server-side.
     * @return matchId        Unique, deterministic match identifier.
     */
    function createMatch(
        uint256 wagerPerPlayer,
        WagerTier tier
    )
        external
        nonReentrant
        whenNotPaused
        returns (bytes32 matchId)
    {
        _checkWagerLimits(wagerPerPlayer);

        matchId = _generateMatchId(msg.sender, wagerPerPlayer);
        _createMatchInternal(matchId, msg.sender, address(0), wagerPerPlayer, tier);
        cueCoin.safeTransferFrom(msg.sender, address(this), wagerPerPlayer);
    }

    /**
     * @notice Create a private match — only a specific address may join.
     *         Useful for direct challenges between known players.
     *
     * @param wagerPerPlayer  CUECOIN amount per player.
     * @param tier            Wager tier.
     * @param targetPlayerB   The only address allowed to call joinMatch() on this match.
     * @return matchId        Unique match identifier.
     */
    function createPrivateMatch(
        uint256 wagerPerPlayer,
        WagerTier tier,
        address targetPlayerB
    )
        external
        nonReentrant
        whenNotPaused
        returns (bytes32 matchId)
    {
        _checkWagerLimits(wagerPerPlayer);
        require(targetPlayerB != address(0), "CueEscrow: zero targetPlayerB");
        require(targetPlayerB != msg.sender, "CueEscrow: cannot challenge yourself");

        matchId = _generateMatchId(msg.sender, wagerPerPlayer);
        _createMatchInternal(matchId, msg.sender, targetPlayerB, wagerPerPlayer, tier);
        cueCoin.safeTransferFrom(msg.sender, address(this), wagerPerPlayer);
    }

    /**
     * @dev Internal match creation — writes storage, emits event, indexes player.
     */
    function _createMatchInternal(
        bytes32 matchId,
        address playerA,
        address target,
        uint256 wagerPerPlayer,
        WagerTier tier
    ) internal {
        bool isHighValue = wagerPerPlayer > HIGH_VALUE_THRESHOLD;

        matches[matchId] = Match({
            playerA:                playerA,
            playerB:                address(0),
            targetPlayerB:          target,
            wagerPerPlayer:         wagerPerPlayer,
            createdAt:              block.timestamp,
            activatedAt:            0,
            mutualCancelProposedAt: 0,
            status:                 MatchStatus.OPEN,
            tier:                   tier,
            isHighValue:            isHighValue,
            mutualCancelProposed:   false,
            mutualCancelProposer:   address(0)
        });

        _playerMatches[playerA].push(matchId);
        totalMatchesCreated++;

        emit MatchCreated(
            matchId, playerA, wagerPerPlayer, tier,
            target != address(0), isHighValue
        );
    }

    /**
     * @dev Validate wager against limits.
     */
    function _checkWagerLimits(uint256 wager) internal view {
        require(wager > 0, "CueEscrow: zero wager");
        if (maxWagerPerPlayer > 0) {
            require(wager <= maxWagerPerPlayer, "CueEscrow: wager exceeds current ceiling");
        }
    }

    /**
     * @dev Generate a unique matchId.
     *      Uses block.number (not timestamp), a global counter, caller, and wager.
     *      Collision-proof even with multiple transactions in the same block.
     */
    function _generateMatchId(address creator, uint256 wager) internal returns (bytes32) {
        return keccak256(abi.encodePacked(
            creator,
            wager,
            block.number,
            ++_matchCounter,
            address(this)
        ));
    }

    // ═══════════════════════════════════════════════════════════
    //  JOINING A MATCH
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Join an OPEN match and activate it.
     *
     *         For private matches: only targetPlayerB may call this.
     *         For public matches: any address other than playerA may join.
     *
     *         The match must not have expired (createdAt + OPEN_MATCH_EXPIRY).
     *         The 24-hour timeout clock starts from this block.
     *
     * @param matchId  The match to join.
     */
    function joinMatch(bytes32 matchId)
        external
        nonReentrant
        whenNotPaused
    {
        Match storage m = matches[matchId];

        require(m.playerA != address(0),       "CueEscrow: match not found");
        require(m.status == MatchStatus.OPEN,  "CueEscrow: match not open");
        require(msg.sender != m.playerA,       "CueEscrow: cannot join own match");

        // [V2-3] Reject join on an expired open match
        require(
            block.timestamp < m.createdAt + OPEN_MATCH_EXPIRY,
            "CueEscrow: open match has expired — use expireMatch()"
        );

        // Private match gate
        if (m.targetPlayerB != address(0)) {
            require(msg.sender == m.targetPlayerB, "CueEscrow: not the invited player");
        }

        // Lock Player B's wager — CEI: state before transfer
        m.playerB     = msg.sender;
        m.activatedAt = block.timestamp;
        m.status      = MatchStatus.ACTIVE;

        _playerMatches[msg.sender].push(matchId);

        cueCoin.safeTransferFrom(msg.sender, address(this), m.wagerPerPlayer);

        emit MatchJoined(matchId, msg.sender, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════
    //  OPEN MATCH EXPIRY  [V2-3]
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Expire an OPEN match that nobody joined within OPEN_MATCH_EXPIRY (24h).
     *         Can be called by anyone — typically Player A or a backend cleanup job.
     *         Player A receives their full wager back. No fees.
     *
     *         Design: this separates "creator-initiated cancel" (cancelMatch) from
     *         "oracle-free system expiry" (expireMatch). Both return 100% to Player A.
     *
     * @param matchId  The OPEN, expired match.
     */
    function expireMatch(bytes32 matchId) external nonReentrant {
        Match storage m = matches[matchId];

        require(m.playerA != address(0),       "CueEscrow: match not found");
        require(m.status == MatchStatus.OPEN,  "CueEscrow: match not open");
        require(
            block.timestamp >= m.createdAt + OPEN_MATCH_EXPIRY,
            "CueEscrow: match has not expired yet"
        );

        // CEI: state before transfer
        address playerA = m.playerA;
        uint256 refund  = m.wagerPerPlayer;
        m.status        = MatchStatus.CANCELLED;
        totalMatchesCancelled++;

        cueCoin.safeTransfer(playerA, refund);

        emit MatchExpired(matchId, msg.sender, refund);
    }

    // ═══════════════════════════════════════════════════════════
    //  VICTORY RESOLUTION  (standard matches ≤ 10,000 CUECOIN)
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Claim victory with a single oracle signature.
     *         For matches where wagerPerPlayer ≤ HIGH_VALUE_THRESHOLD (10,000 CUECOIN).
     *         For high-value matches, use submitHighValueSignature() + claimVictoryHighValue().
     *
     *         Either player (or a trusted relayer) may submit — not just the winner.
     *         The winner is declared inside the oracle-signed certificate; it cannot
     *         be changed by the submitter.
     *
     * @param matchId      The ACTIVE match to resolve.
     * @param winner       Address of the winning player (must be A or B).
     * @param nftBonusWei  NFT bonus in CUECOIN-wei (0 if no eligible NFT, signed by oracle).
     *                     Capped at MAX_NFT_BONUS_BPS (20 %) of wagerPerPlayer.
     * @param nonce        Oracle-issued nonce for this certificate (one-use).
     * @param expiry       Unix timestamp after which this certificate is invalid.
     *                     Must be ≤ block.timestamp + VICTORY_CERT_EXPIRY.
     * @param signature    EIP-712 signature from any registered oracle (oracle0/1/2).
     */
    function claimVictory(
        bytes32 matchId,
        address winner,
        uint256 nftBonusWei,
        uint256 nonce,
        uint256 expiry,
        bytes calldata signature
    )
        external
        nonReentrant
        whenNotPaused
    {
        Match storage m = matches[matchId];

        // ── Checks ──
        require(m.status == MatchStatus.ACTIVE,  "CueEscrow: match not active");
        require(!m.isHighValue,                  "CueEscrow: use high-value claim path");
        require(_isParticipant(m, winner),       "CueEscrow: winner not a participant");
        require(block.timestamp <= expiry,       "CueEscrow: certificate expired");
        require(
            expiry <= block.timestamp + VICTORY_CERT_EXPIRY,
            "CueEscrow: certificate expiry window too long"
        );

        // NFT bonus hard cap
        require(
            nftBonusWei <= (m.wagerPerPlayer * MAX_NFT_BONUS_BPS) / 10_000,
            "CueEscrow: nft bonus exceeds cap"
        );

        bytes32 nonceKey = _nonceKey(matchId, nonce);
        require(!usedNonces[nonceKey], "CueEscrow: nonce already used");

        // ── Oracle signature verification (1-of-3) ──
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
            VICTORY_TYPEHASH, matchId, winner, nftBonusWei, nonce, expiry
        )));
        address signer = digest.recover(signature);
        require(_isOracle(signer), "CueEscrow: invalid oracle signature");

        // [V3-1] Per-oracle daily cap — must pass before any state change
        _checkOracleDailyCap(signer, m.wagerPerPlayer * 2);

        // ── Effects ──
        usedNonces[nonceKey] = true;
        m.status             = MatchStatus.RESOLVED;
        totalMatchesResolved++;

        // ── Interactions ──
        _executeVictoryPayout(matchId, m, winner, nftBonusWei);
        _notifyReferral(winner);
    }

    // ═══════════════════════════════════════════════════════════
    //  HIGH-VALUE VICTORY (> 10,000 CUECOIN — 2-of-3 required)
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Step 1 of 2 for high-value match resolution.
     *         First oracle submits their EIP-712 signature on the VictoryCertificate.
     *         Stored on-chain. Emits HighValueFirstSigSubmitted.
     *
     *         Both oracles MUST sign IDENTICAL certificate parameters:
     *         same matchId, winner, nftBonusWei, nonce, expiry.
     *
     * @param matchId      The high-value ACTIVE match.
     * @param winner       Address of winning player.
     * @param nftBonusWei  NFT bonus in CUECOIN-wei.
     * @param nonce        Oracle-issued nonce (must match Step 2).
     * @param expiry       Certificate expiry timestamp (must match Step 2).
     * @param signature    EIP-712 signature from first oracle.
     */
    function submitHighValueSignature(
        bytes32 matchId,
        address winner,
        uint256 nftBonusWei,
        uint256 nonce,
        uint256 expiry,
        bytes calldata signature
    )
        external
        nonReentrant
        whenNotPaused
    {
        Match storage m = matches[matchId];

        require(m.status == MatchStatus.ACTIVE,  "CueEscrow: match not active");
        require(m.isHighValue,                   "CueEscrow: not a high-value match");
        require(_isParticipant(m, winner),       "CueEscrow: winner not a participant");
        require(block.timestamp <= expiry,       "CueEscrow: certificate expired");
        require(
            expiry <= block.timestamp + VICTORY_CERT_EXPIRY,
            "CueEscrow: expiry window too long"
        );

        require(
            nftBonusWei <= (m.wagerPerPlayer * MAX_NFT_BONUS_BPS) / 10_000,
            "CueEscrow: nft bonus exceeds cap"
        );

        bytes32 nonceKey = _nonceKey(matchId, nonce);
        require(!usedNonces[nonceKey],            "CueEscrow: nonce already used");
        require(!_hvFirstSig[nonceKey].submitted, "CueEscrow: first signature already submitted");

        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
            VICTORY_TYPEHASH, matchId, winner, nftBonusWei, nonce, expiry
        )));
        address signer = digest.recover(signature);
        require(_isOracle(signer), "CueEscrow: invalid oracle signature");

        _hvFirstSig[nonceKey] = HighValueFirstSig({ signer: signer, submitted: true });

        emit HighValueFirstSigSubmitted(matchId, signer, nonce);
    }

    /**
     * @notice Step 2 of 2 for high-value match resolution.
     *         Second oracle provides their signature, completing 2-of-3 quorum.
     *         Certificate parameters must be IDENTICAL to those in Step 1.
     *         The two signing oracles must be DISTINCT addresses.
     *
     * @param matchId      Same as Step 1.
     * @param winner       Same winner as Step 1.
     * @param nftBonusWei  Same nftBonusWei as Step 1.
     * @param nonce        Same nonce as Step 1.
     * @param expiry       Same expiry as Step 1.
     * @param signature    EIP-712 signature from a DIFFERENT registered oracle.
     */
    function claimVictoryHighValue(
        bytes32 matchId,
        address winner,
        uint256 nftBonusWei,
        uint256 nonce,
        uint256 expiry,
        bytes calldata signature
    )
        external
        nonReentrant
        whenNotPaused
    {
        Match storage m = matches[matchId];

        require(m.status == MatchStatus.ACTIVE,  "CueEscrow: match not active");
        require(m.isHighValue,                   "CueEscrow: not a high-value match");
        require(_isParticipant(m, winner),       "CueEscrow: winner not a participant");
        require(block.timestamp <= expiry,       "CueEscrow: certificate expired");

        bytes32 nonceKey = _nonceKey(matchId, nonce);
        require(!usedNonces[nonceKey],           "CueEscrow: nonce already used");
        require(_hvFirstSig[nonceKey].submitted, "CueEscrow: submit first signature first");

        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
            VICTORY_TYPEHASH, matchId, winner, nftBonusWei, nonce, expiry
        )));
        address signer2 = digest.recover(signature);
        require(_isOracle(signer2),              "CueEscrow: invalid second oracle signature");
        require(
            signer2 != _hvFirstSig[nonceKey].signer,
            "CueEscrow: oracles must be distinct"
        );

        // [V3-1] Per-oracle daily cap applied to the FIRST signer.
        // The first oracle made the independent signing decision that determined the outcome.
        // The second oracle is a quorum confirmation, not an additional independent authority.
        // Charging both would double-count the exposure against two separate daily budgets.
        _checkOracleDailyCap(_hvFirstSig[nonceKey].signer, m.wagerPerPlayer * 2);

        // ── Effects ──
        usedNonces[nonceKey] = true;
        m.status             = MatchStatus.RESOLVED;
        totalMatchesResolved++;

        // ── Interactions ──
        _executeVictoryPayout(matchId, m, winner, nftBonusWei);
        _notifyReferral(winner);
    }

    // ═══════════════════════════════════════════════════════════
    //  FORFEIT RESOLUTION
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Claim forfeit — opponent's heartbeat stopped for > 30 seconds.
     *         Oracle signs a ForfeitCertificate after monitoring game heartbeat data.
     *         Winner receives 100% of the total pot. No protocol fees on forfeit —
     *         the disconnect was the forfeiter's fault, not a completed game.
     *
     *         Valid for both standard and high-value matches (1 oracle sig always sufficient
     *         for forfeit — the disconnect evidence is unambiguous).
     *
     * @param matchId    The ACTIVE match.
     * @param winner     The player who remained connected.
     * @param forfeiter  The player who disconnected.
     * @param nonce      Oracle-issued nonce.
     * @param expiry     Certificate expiry (must be ≤ block.timestamp + FORFEIT_CERT_EXPIRY).
     * @param signature  EIP-712 ForfeitCertificate signature from any registered oracle.
     */
    function claimForfeit(
        bytes32 matchId,
        address winner,
        address forfeiter,
        uint256 nonce,
        uint256 expiry,
        bytes calldata signature
    )
        external
        nonReentrant
        whenNotPaused
    {
        Match storage m = matches[matchId];

        require(m.status == MatchStatus.ACTIVE,                "CueEscrow: match not active");
        require(_isParticipant(m, winner),                     "CueEscrow: winner not a participant");
        require(_isParticipant(m, forfeiter),                  "CueEscrow: forfeiter not a participant");
        require(winner != forfeiter,                           "CueEscrow: winner and forfeiter must differ");
        require(block.timestamp <= expiry,                     "CueEscrow: certificate expired");
        require(
            expiry <= block.timestamp + FORFEIT_CERT_EXPIRY,
            "CueEscrow: forfeit certificate expiry too long"
        );

        bytes32 nonceKey = _nonceKey(matchId, nonce);
        require(!usedNonces[nonceKey], "CueEscrow: nonce already used");

        // ── Oracle signature verification (1-of-3, including for high-value) ──
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
            FORFEIT_TYPEHASH, matchId, winner, forfeiter, nonce, expiry
        )));
        address forfeitSigner = digest.recover(signature);
        require(_isOracle(forfeitSigner), "CueEscrow: invalid oracle signature");

        // [V3-1] Per-oracle daily cap — full pot exposure measured even on forfeit
        _checkOracleDailyCap(forfeitSigner, m.wagerPerPlayer * 2);

        // ── Effects ──
        usedNonces[nonceKey] = true;
        m.status             = MatchStatus.RESOLVED;
        totalMatchesResolved++;

        // ── Forfeit payout: 100% to winner, zero fees ──
        uint256 totalPot = m.wagerPerPlayer * 2;

        // ── Interactions ──
        cueCoin.safeTransfer(winner, totalPot);
        _notifyReferral(winner);

        emit MatchForfeited(matchId, winner, forfeiter, totalPot);
    }

    // ═══════════════════════════════════════════════════════════
    //  24-HOUR TIMEOUT FALLBACK  (zero oracle involvement)
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice 24-hour on-chain safety net.
     *         If no resolution arrives within TIMEOUT_DURATION of joinMatch(),
     *         either participant triggers this to recover both wagers in full.
     *
     *         No oracle signature required.
     *         No protocol fees.
     *         Callable even when contract is paused — player funds MUST be recoverable.
     *
     * @param matchId  The ACTIVE match past its timeout window.
     */
    function claimTimeout(bytes32 matchId) external nonReentrant {
        Match storage m = matches[matchId];

        require(m.status == MatchStatus.ACTIVE,                 "CueEscrow: match not active");
        require(
            msg.sender == m.playerA || msg.sender == m.playerB,
            "CueEscrow: not a participant"
        );
        require(
            block.timestamp >= m.activatedAt + TIMEOUT_DURATION,
            "CueEscrow: timeout not yet reached"
        );

        // ── Effects ──
        uint256 refund = m.wagerPerPlayer;
        address pA     = m.playerA;
        address pB     = m.playerB;
        m.status       = MatchStatus.CANCELLED;
        totalMatchesCancelled++;

        // ── Interactions ──
        cueCoin.safeTransfer(pA, refund);
        cueCoin.safeTransfer(pB, refund);

        emit MatchTimedOut(matchId, msg.sender, refund);
    }

    // ═══════════════════════════════════════════════════════════
    //  PRE-JOIN CANCEL  (Player A only, while status = OPEN)
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Cancel a match that nobody has joined yet.
     *         Player A receives their full wager back. No fees.
     *         Cannot be called once Player B has joined (match is ACTIVE).
     *
     * @param matchId  The OPEN match to cancel.
     */
    function cancelMatch(bytes32 matchId) external nonReentrant {
        Match storage m = matches[matchId];

        require(m.playerA == msg.sender,          "CueEscrow: not match creator");
        require(m.status == MatchStatus.OPEN,     "CueEscrow: match not open");

        // ── Effects ──
        uint256 refund = m.wagerPerPlayer;
        m.status       = MatchStatus.CANCELLED;
        totalMatchesCancelled++;

        // ── Interactions ──
        cueCoin.safeTransfer(msg.sender, refund);

        emit MatchCancelled(matchId, msg.sender, refund);
    }

    // ═══════════════════════════════════════════════════════════
    //  MUTUAL CANCEL  (both players agree post-join)
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Propose mutual cancellation of an ACTIVE match.
     *         The other player must confirm within MUTUAL_CANCEL_EXPIRY (6 hours).
     *         If not confirmed, the proposal expires and either player can clear it.
     *
     *         Use case: both players agree to abort mid-game due to technical issues
     *         or personal circumstances, without waiting for the 24-hour timeout.
     *
     * @param matchId  The ACTIVE match to propose cancellation for.
     */
    function proposeMutualCancel(bytes32 matchId)
        external
        nonReentrant
        whenNotPaused
    {
        Match storage m = matches[matchId];

        require(m.status == MatchStatus.ACTIVE,     "CueEscrow: match not active");
        require(_isParticipant(m, msg.sender),      "CueEscrow: not a participant");
        require(!m.mutualCancelProposed,             "CueEscrow: proposal already pending");

        m.mutualCancelProposed   = true;
        m.mutualCancelProposer   = msg.sender;
        m.mutualCancelProposedAt = block.timestamp;

        uint256 expiresAt = block.timestamp + MUTUAL_CANCEL_EXPIRY;
        emit MutualCancelProposed(matchId, msg.sender, expiresAt);
    }

    /**
     * @notice Confirm a pending mutual cancellation.
     *         Only the OTHER player (not the proposer) may confirm.
     *         Proposal must not have expired (within 6 hours of proposal).
     *         Triggers immediate full refund to both players, no fees.
     *
     * @param matchId  The ACTIVE match with a pending mutual cancel proposal.
     */
    function confirmMutualCancel(bytes32 matchId)
        external
        nonReentrant
        whenNotPaused
    {
        Match storage m = matches[matchId];

        require(m.status == MatchStatus.ACTIVE,     "CueEscrow: match not active");
        require(m.mutualCancelProposed,             "CueEscrow: no proposal pending");
        require(_isParticipant(m, msg.sender),      "CueEscrow: not a participant");
        require(msg.sender != m.mutualCancelProposer, "CueEscrow: proposer cannot confirm own proposal");

        // [V2-7] Proposal must not have expired
        require(
            block.timestamp <= m.mutualCancelProposedAt + MUTUAL_CANCEL_EXPIRY,
            "CueEscrow: mutual cancel proposal has expired — clear it and re-propose"
        );

        // ── Effects ──
        uint256 refund = m.wagerPerPlayer;
        address pA     = m.playerA;
        address pB     = m.playerB;
        m.status       = MatchStatus.CANCELLED;
        totalMatchesCancelled++;

        // ── Interactions ──
        cueCoin.safeTransfer(pA, refund);
        cueCoin.safeTransfer(pB, refund);

        emit MutualCancelCompleted(matchId, refund);
    }

    /**
     * @notice [V2-7] Clear an expired mutual cancel proposal.
     *         After MUTUAL_CANCEL_EXPIRY elapses without confirmation, the proposal
     *         is stale and blocks new proposals. Either player or the owner clears it.
     *
     * @param matchId  The ACTIVE match with an expired proposal.
     */
    function clearExpiredProposal(bytes32 matchId) external nonReentrant {
        Match storage m = matches[matchId];

        require(m.status == MatchStatus.ACTIVE,  "CueEscrow: match not active");
        require(m.mutualCancelProposed,          "CueEscrow: no proposal to clear");
        require(
            msg.sender == m.playerA ||
            msg.sender == m.playerB ||
            msg.sender == owner(),
            "CueEscrow: not a participant or owner"
        );
        require(
            block.timestamp > m.mutualCancelProposedAt + MUTUAL_CANCEL_EXPIRY,
            "CueEscrow: proposal not yet expired"
        );

        m.mutualCancelProposed   = false;
        m.mutualCancelProposer   = address(0);
        m.mutualCancelProposedAt = 0;

        emit MutualCancelProposalCleared(matchId, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL PAYOUT ENGINE
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev Executes the full victory payout:
     *
     *      1. Burns 1% of total pot to BURN_ADDRESS (0xdead).
     *      2. Sends 1% of total pot to rewardsPool (P2E refill).
     *      3. Transfers 98% of total pot to winner.
     *         Remainder arithmetic guarantees totalPot is fully distributed.
     *      4. If nftBonusWei > 0: requests NFT bonus from CueRewardsPool (best-effort).
     *
     *      All arithmetic uses subtraction for the winner amount — never addition —
     *      so rounding dust always goes to the winner and never to 0xdead.
     */
    function _executeVictoryPayout(
        bytes32 matchId,
        Match storage m,
        address winner,
        uint256 nftBonusWei
    ) internal {
        uint256 totalPot = m.wagerPerPlayer * 2;

        uint256 burnAmt    = (totalPot * BURN_FEE_BPS)    / 10_000;
        uint256 rewardsAmt = (totalPot * REWARDS_FEE_BPS) / 10_000;
        uint256 winnerPay  = totalPot - burnAmt - rewardsAmt; // remainder → winner (CEI-safe)

        address loser = (winner == m.playerA) ? m.playerB : m.playerA;

        // ── 1. Burn ──
        if (burnAmt > 0) {
            cueCoin.safeTransfer(BURN_ADDRESS, burnAmt);
            totalCueCoinBurned += burnAmt;
        }

        // ── 2. Rewards pool (P2E refill from wager volume) ──
        if (rewardsAmt > 0) {
            cueCoin.safeTransfer(rewardsPool, rewardsAmt);
            totalCueCoinToP2E += rewardsAmt;
        }

        // ── 3. Winner pot payout ──
        cueCoin.safeTransfer(winner, winnerPay);

        // ── 4. NFT bonus (from CueRewardsPool, not from pot — best-effort) ──
        uint256 actualBonus = 0;
        if (nftBonusWei > 0) {
            actualBonus = _requestNFTBonus(winner, nftBonusWei);
        }

        emit MatchResolved(
            matchId, winner, loser,
            winnerPay, actualBonus, burnAmt, rewardsAmt
        );
    }

    /**
     * @dev Request NFT bonus from CueRewardsPool.
     *      Uses low-level call so a failing pool never reverts the payout.
     *      The winner always receives their 98% pot regardless.
     *      Interface: payNFTBonus(address recipient, uint256 amount) returns (uint256 paid)
     *
     * @return actual  Amount actually transferred (0 if pool failed or depleted).
     */
    function _requestNFTBonus(address winner, uint256 bonusAmount)
        internal
        returns (uint256 actual)
    {
        if (rewardsPool == address(0)) return 0;
        (bool ok, bytes memory data) = rewardsPool.call(
            abi.encodeWithSignature("payNFTBonus(address,uint256)", winner, bonusAmount)
        );
        if (ok && data.length >= 32) {
            actual = abi.decode(data, (uint256));
        }
        // Pool failure is silently absorbed — payout already complete
    }

    /**
     * @dev [V2-1] Notify CueReferral of a player's first completed match.
     *      Only fires once per player (firstMatchNotified gate).
     *      Best-effort low-level call — never reverts the payout.
     *      Interface: recordMatchCompletion(address player) external
     */
    function _notifyReferral(address player) internal {
        if (referralContract == address(0)) return;
        if (firstMatchNotified[player]) return;

        firstMatchNotified[player] = true;

        // Absorb any revert — referral tracking is non-critical
        referralContract.call(
            abi.encodeWithSignature("recordMatchCompletion(address)", player)
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════

    function _isOracle(address addr) internal view returns (bool) {
        return addr != address(0) && (addr == oracle0 || addr == oracle1 || addr == oracle2);
    }

    function _isParticipant(Match storage m, address addr) internal view returns (bool) {
        return addr == m.playerA || addr == m.playerB;
    }

    /// @dev Global nonce key — unique per (matchId, nonce) pair.
    function _nonceKey(bytes32 matchId, uint256 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(matchId, nonce));
    }

    /**
     * @dev [V3-1] Enforce per-oracle daily CUECOIN exposure cap.
     *
     *      Called immediately after oracle identity is verified in claimVictory
     *      and claimForfeit. Adds the match's total pot to the oracle's daily
     *      accumulator and reverts if it would exceed oracleDailyCapWei.
     *
     *      "Exposure" is measured as the TOTAL POT of the match — the maximum
     *      CUECOIN the oracle could have redirected if fraudulent. Using winnerPayout
     *      (98% of pot) would understate the true risk by 2%.
     *
     *      UTC day = block.timestamp / 86400. No timezone ambiguity; BSC timestamps
     *      are Unix epoch seconds. The day boundary is at midnight UTC.
     *
     *      High-value matches (2-of-3) count the exposure once — against the first
     *      oracle that submitted a signature. The second oracle's contribution is a
     *      confirmation, not an independent signing decision.
     *
     * @param oracle    The oracle address that signed this certificate.
     * @param totalPot  Total CUECOIN pot of the match (wagerPerPlayer * 2).
     */
    /**
     * @dev [V3-1] Enforce per-oracle daily CUECOIN exposure cap.
     *
     *      Called immediately after oracle identity is verified in claimVictory,
     *      claimVictoryHighValue, and claimForfeit. Adds the match's total pot
     *      to the signing oracle's daily accumulator and reverts if it would
     *      exceed oracleDailyCapWei.
     *
     *      "Exposure" = totalPot of the match (wagerPerPlayer * 2), regardless
     *      of payout split. A rogue oracle could theoretically redirect the full
     *      pot, so measuring the full pot is the conservative correct choice.
     *
     *      UTC day = block.timestamp / 86400 (midnight UTC boundary).
     *
     *      WARNING LEVEL (80% of cap): OracleCapApproaching is emitted when a
     *      single match pushes daily usage above 80% of the cap. This event
     *      persists on-chain (the tx succeeds) and gives monitoring systems
     *      advance notice before the cap triggers a hard revert.
     *
     *      HARD REVERT at 100%: OracleCapExhausted is NOT emitted (events are
     *      discarded on revert). The revert itself is the signal — backend
     *      monitoring on failed transactions detects the specific revert reason.
     *
     * @param oracle    The oracle address that signed this certificate.
     * @param totalPot  Total CUECOIN pot of the match (wagerPerPlayer * 2).
     */
    function _checkOracleDailyCap(address oracle, uint256 totalPot) internal {
        uint256 today = block.timestamp / 86400;

        // Reset accumulator at start of each new UTC day
        if (oracleDay[oracle] != today) {
            oracleDay[oracle]       = today;
            oracleDailyUsed[oracle] = 0;
        }

        uint256 prevUsed = oracleDailyUsed[oracle];
        uint256 newUsed  = prevUsed + totalPot;

        // Hard cap — revert. The revert reason string is the monitoring signal.
        require(newUsed <= oracleDailyCapWei, "CueEscrow: oracle daily cap exceeded");

        oracleDailyUsed[oracle] = newUsed;

        // Soft warning at 80% — this event DOES persist (tx succeeds).
        // Monitoring systems should page on this event to proactively investigate.
        uint256 warningThreshold = (oracleDailyCapWei * 80) / 100;
        if (prevUsed < warningThreshold && newUsed >= warningThreshold) {
            emit OracleCapApproaching(oracle, today, newUsed, oracleDailyCapWei);
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Full Match struct for a given matchId.
     */
    function getMatch(bytes32 matchId) external view returns (Match memory) {
        return matches[matchId];
    }

    /**
     * @notice Whether a given nonce has already been consumed.
     */
    function isNonceUsed(bytes32 matchId, uint256 nonce) external view returns (bool) {
        return usedNonces[_nonceKey(matchId, nonce)];
    }

    /**
     * @notice Status of the first-sig storage for a high-value match.
     */
    function hasHighValueFirstSig(bytes32 matchId, uint256 nonce)
        external
        view
        returns (bool submitted, address signerAddress)
    {
        HighValueFirstSig storage hv = _hvFirstSig[_nonceKey(matchId, nonce)];
        submitted     = hv.submitted;
        signerAddress = hv.signer;
    }

    /**
     * @notice All matchIds the player has ever been involved in (including historical).
     *         Frontend should filter by match status.
     */
    function playerMatches(address player) external view returns (bytes32[] memory) {
        return _playerMatches[player];
    }

    /**
     * @notice Seconds remaining until a match times out.
     *         Returns 0 if already timed out or match is not ACTIVE.
     */
    function timeoutRemaining(bytes32 matchId) external view returns (uint256) {
        Match storage m = matches[matchId];
        if (m.status != MatchStatus.ACTIVE || m.activatedAt == 0) return 0;
        uint256 deadline = m.activatedAt + TIMEOUT_DURATION;
        if (block.timestamp >= deadline) return 0;
        return deadline - block.timestamp;
    }

    /**
     * @notice Seconds remaining before an OPEN match expires (and can be expired via expireMatch).
     *         Returns 0 if already expired or match is not OPEN.
     */
    function openMatchExpiryRemaining(bytes32 matchId) external view returns (uint256) {
        Match storage m = matches[matchId];
        if (m.status != MatchStatus.OPEN || m.createdAt == 0) return 0;
        uint256 deadline = m.createdAt + OPEN_MATCH_EXPIRY;
        if (block.timestamp >= deadline) return 0;
        return deadline - block.timestamp;
    }

    /**
     * @notice Seconds remaining on a mutual cancel proposal before it expires.
     *         Returns 0 if no proposal is pending or it has already expired.
     */
    function mutualCancelProposalRemaining(bytes32 matchId) external view returns (uint256) {
        Match storage m = matches[matchId];
        if (!m.mutualCancelProposed || m.mutualCancelProposedAt == 0) return 0;
        uint256 deadline = m.mutualCancelProposedAt + MUTUAL_CANCEL_EXPIRY;
        if (block.timestamp >= deadline) return 0;
        return deadline - block.timestamp;
    }

    /**
     * @notice Preview payout splits for a given match at current state.
     *         For frontend display before the oracle certificate arrives.
     *
     * @param matchId     Match to preview.
     * @param nftBonusBps NFT bonus in basis points (0 = no NFT; 500 = Rare; 1000 = Epic;
     *                    1500 = Legendary; 2000 = Genesis).
     * @return winnerBase    98% of pot (from escrow).
     * @return burnAmount    1% of pot burned to 0xdead.
     * @return rewardsAmount 1% of pot to CueRewardsPool.
     * @return nftBonus      NFT bonus from CueRewardsPool (informational, best-effort).
     */
    function previewPayout(bytes32 matchId, uint256 nftBonusBps)
        external
        view
        returns (
            uint256 winnerBase,
            uint256 burnAmount,
            uint256 rewardsAmount,
            uint256 nftBonus
        )
    {
        Match storage m = matches[matchId];
        require(m.playerA != address(0), "CueEscrow: match not found");

        uint256 totalPot = m.wagerPerPlayer * 2;
        burnAmount    = (totalPot * BURN_FEE_BPS)    / 10_000;
        rewardsAmount = (totalPot * REWARDS_FEE_BPS) / 10_000;
        winnerBase    = totalPot - burnAmount - rewardsAmount;
        nftBonus      = (m.wagerPerPlayer * nftBonusBps) / 10_000;
    }

    /**
     * @notice Whether an address is a registered oracle.
     */
    function isRegisteredOracle(address addr) external view returns (bool) {
        return _isOracle(addr);
    }

    /**
     * @notice EIP-712 domain separator — for off-chain signing tools.
     */
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @notice Compute the EIP-712 digest for a VictoryCertificate.
     *         Used by oracle signers to verify exactly what they are signing.
     */
    function victoryDigest(
        bytes32 matchId,
        address winner,
        uint256 nftBonusWei,
        uint256 nonce,
        uint256 expiry
    ) external view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(
            VICTORY_TYPEHASH, matchId, winner, nftBonusWei, nonce, expiry
        )));
    }

    /**
     * @notice Compute the EIP-712 digest for a ForfeitCertificate.
     */
    function forfeitDigest(
        bytes32 matchId,
        address winner,
        address forfeiter,
        uint256 nonce,
        uint256 expiry
    ) external view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(
            FORFEIT_TYPEHASH, matchId, winner, forfeiter, nonce, expiry
        )));
    }

    /**
     * @notice [V2-5] Protocol-wide summary statistics in a single call.
     *         For frontend dashboards and analytics backends.
     */
    function matchStats()
        external
        view
        returns (
            uint256 created,
            uint256 resolved,
            uint256 cancelled,
            uint256 active,
            uint256 cueCoinBurned,
            uint256 cueCoinToP2E,
            uint256 contractCueCoinBalance,
            uint256 currentMaxWager,
            uint256 oracleDailyCap    // [V3-1]
        )
    {
        created    = totalMatchesCreated;
        resolved   = totalMatchesResolved;
        cancelled  = totalMatchesCancelled;
        // active = created - resolved - cancelled (all other states are OPEN or ACTIVE)
        active                 = created - resolved - cancelled;
        cueCoinBurned          = totalCueCoinBurned;
        cueCoinToP2E           = totalCueCoinToP2E;
        contractCueCoinBalance = cueCoin.balanceOf(address(this));
        currentMaxWager        = maxWagerPerPlayer;
        oracleDailyCap         = oracleDailyCapWei;
    }

    /**
     * @notice View ETA and status of a timelock operation.
     *         Pass the operationId emitted in the TimelockQueued event.
     */
    function timelockStatus(bytes32 operationId)
        external
        view
        returns (uint256 eta, bool executable, bool expired)
    {
        eta        = timelockEta[operationId];
        executable = eta > 0 &&
                     block.timestamp >= eta &&
                     block.timestamp < eta + TIMELOCK_GRACE &&
                     !timelockExecuted[operationId];
        expired    = eta > 0 && block.timestamp >= eta + TIMELOCK_GRACE;
    }

    // ═══════════════════════════════════════════════════════════
    //  OWNER / DAO ADMIN
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice [V2-2] Update all three oracle addresses atomically.
     *         TIMELOCKED — 48 hours.
     *
     *         Oracle rotation is the highest-risk admin operation in this contract.
     *         A malicious rotation that swapped in an attacker-controlled address
     *         would allow unlimited fraudulent VictoryCertificates. The timelock
     *         gives 48 hours for the community or guardian to detect and respond.
     *
     *         Emergency response during the timelock window: call pause().
     *
     *         All three addresses must be distinct and non-zero.
     *         Called on quarterly KMS key rotation.
     *
     * @param _oracle0  New oracle 0 (US-East-1).
     * @param _oracle1  New oracle 1 (EU-West-1).
     * @param _oracle2  New oracle 2 (AP-Southeast-1).
     */
    function updateOracles(
        address _oracle0,
        address _oracle1,
        address _oracle2
    ) external onlyOwner timelocked(keccak256("updateOracles")) {
        require(_oracle0 != address(0), "CueEscrow: zero oracle0");
        require(_oracle1 != address(0), "CueEscrow: zero oracle1");
        require(_oracle2 != address(0), "CueEscrow: zero oracle2");
        require(
            _oracle0 != _oracle1 && _oracle1 != _oracle2 && _oracle0 != _oracle2,
            "CueEscrow: oracle addresses must be distinct"
        );

        oracle0 = _oracle0;
        oracle1 = _oracle1;
        oracle2 = _oracle2;

        emit OraclesUpdated(_oracle0, _oracle1, _oracle2);
    }

    /**
     * @notice [V2-8] Update the CueRewardsPool address.
     *         TIMELOCKED — 48 hours.
     *
     *         The rewardsPool is the destination of 1% of every wager pot AND the
     *         source of NFT bonuses. A malicious address here could drain all
     *         incoming P2E fees or fail NFT bonus payments. Timelock is warranted.
     *
     * @param _pool  New CueRewardsPool address.
     */
    function updateRewardsPool(address _pool)
        external
        onlyOwner
        timelocked(keccak256("updateRewardsPool"))
    {
        require(_pool != address(0), "CueEscrow: zero rewardsPool");
        emit RewardsPoolUpdated(rewardsPool, _pool);
        rewardsPool = _pool;
    }

    /**
     * @notice Update the CueReferral contract address.
     *         NOT timelocked — referral is a non-critical best-effort call.
     *         Can be set to address(0) to disable referral notifications.
     *
     * @param _referral  New CueReferral address (zero to disable).
     */
    function updateReferralContract(address _referral) external onlyOwner {
        emit ReferralContractUpdated(referralContract, _referral);
        referralContract = _referral;
    }

    /**
     * @notice [V2-4] Set the maximum wager per player (soft ceiling).
     *         NOT timelocked — must be adjustable quickly during market volatility
     *         or launch risk management.
     *         Set to 0 to remove any ceiling (open market).
     *
     * @param _maxWager  New ceiling in CUECOIN-wei. Zero = no limit.
     */
    function setMaxWager(uint256 _maxWager) external onlyOwner {
        maxWagerPerPlayer = _maxWager;
        emit MaxWagerUpdated(_maxWager);
    }

    /**
     * @notice [V3-1] Update the per-oracle daily CUECOIN exposure cap.
     *         TIMELOCKED — 48 hours.
     *
     *         The cap is a critical security parameter. Raising it too high
     *         reduces its protective value. Lowering it too aggressively can
     *         break legitimate high-volume days. Both directions warrant a
     *         48-hour observation window before taking effect.
     *
     *         Cannot be set to zero — that would block all match resolution.
     *         To temporarily halt oracle signing, use pause() instead.
     *
     *         Sizing guidance:
     *           At 100k DAU × 3 matches/day × 100 CUECOIN avg wager × 2 (total pot):
     *           = 60,000,000 CUECOIN / day across all three oracles combined.
     *           ÷ 3 oracles = 20,000,000 CUECOIN / oracle / day legitimate throughput.
     *           Set cap 2-3× above your expected daily peak per oracle.
     *
     * @param _capWei  New daily cap in CUECOIN-wei (must be > 0).
     */
    function setOracleDailyCap(
        uint256 _capWei
    ) external onlyOwner timelocked(keccak256("setOracleDailyCap")) {
        require(_capWei > 0, "CueEscrow: cap cannot be zero");
        oracleDailyCapWei = _capWei;
        emit OracleDailyCapUpdated(_capWei);
    }

    /**
     * @notice [V3-2] Current daily cap status for each oracle.
     *         For monitoring dashboards and automated alert systems.
     *
     * @param oracle  One of oracle0, oracle1, oracle2.
     * @return cap          Current oracleDailyCapWei (same for all three oracles).
     * @return used         CUECOIN-wei exposure accumulated today by this oracle.
     * @return remaining    Cap minus used (0 if cap already reached — will revert on next use).
     * @return utcDay       Current UTC day number (block.timestamp / 86400).
     * @return oracleUtcDay The UTC day recorded for this oracle's last activity.
     *                      If utcDay != oracleUtcDay, the accumulator will reset on next use.
     * @return pctUsed      Percentage of daily cap consumed (0–100). Over 80 → alert.
     */
    function oracleCapStatus(address oracle)
        external
        view
        returns (
            uint256 cap,
            uint256 used,
            uint256 remaining,
            uint256 utcDay,
            uint256 oracleUtcDay,
            uint256 pctUsed
        )
    {
        cap         = oracleDailyCapWei;
        utcDay      = block.timestamp / 86400;
        oracleUtcDay = oracleDay[oracle];

        // If the oracle hasn't acted today, its effective used is 0
        used = (oracleUtcDay == utcDay) ? oracleDailyUsed[oracle] : 0;

        remaining = (used < cap) ? cap - used : 0;
        pctUsed   = (cap > 0) ? (used * 100) / cap : 0;
    }
     *         Emergency use — e.g. a malicious oracle rotation was queued.
     *         Cannot cancel already-executed operations.
     *
     * @param operationId  The opId emitted in the TimelockQueued event.
     */
    function cancelTimelock(bytes32 operationId) external onlyOwner {
        require(timelockEta[operationId] > 0,   "CueEscrow: not queued");
        require(!timelockExecuted[operationId], "CueEscrow: already executed");
        delete timelockEta[operationId];
        emit TimelockCancelled(operationId);
    }

    /**
     * @notice Emergency pause.
     *         Halts: createMatch, createPrivateMatch, joinMatch, claimVictory,
     *         claimVictoryHighValue, submitHighValueSignature, claimForfeit,
     *         proposeMutualCancel, confirmMutualCancel.
     *
     *         NOT halted: claimTimeout, cancelMatch, expireMatch, clearExpiredProposal.
     *         Player funds are ALWAYS recoverable even during a security emergency.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Resume normal operations after a pause.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Recover accidentally sent ERC-20 tokens.
     *         CANNOT recover CUECOIN — those are player wagers that must not be touched.
     *
     * @param token   The ERC-20 token to recover (must not be cueCoin).
     * @param amount  Amount to transfer to the owner.
     */
    function recoverERC20(address token, uint256 amount) external onlyOwner {
        require(token != address(cueCoin), "CueEscrow: cannot recover CUECOIN");
        IERC20(token).safeTransfer(owner(), amount);
    }
}
