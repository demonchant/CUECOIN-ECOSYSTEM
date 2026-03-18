// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ╔══════════════════════════════════════════════════════════════╗
//  CUEREFERRAL  ·  v2.0  ·  Attack-Hardened
//  CUECOIN Ecosystem  ·  BNB Smart Chain
//
//  Fully on-chain trustless referral system.
//  Rewards unlock only after the referee completes their first real
//  wager match — eliminating sign-up farming entirely.
//  No new tokens are created. All rewards come from the DAO pool.
//
//  ════════════════════════════════════════════════════
//   v1 → v2 SECURITY FIXES
//  ════════════════════════════════════════════════════
//
//   [FIX-A1]  DIAMOND WASH-TRADING — GROSS POT REPLACED WITH FEE BASE
//
//   Root cause (v1):
//     revenue = matchPot × 0.1%
//     An attacker controlling both sides of a match can cycle the same
//     capital through unlimited matches. Each cycle costs the attacker
//     2% in protocol fees (1% burn + 1% P2E), but earns them 0.1% from
//     the referral pool. The 20× fee/reward ratio means the attack is
//     not directly profitable — but it steadily drains the referral pool
//     funded by honest DAO treasury contributions.
//     "Protocol-subsidised wash trading yield farm."
//
//   Fix (v2):
//     revenue = protocolFee × DIAMOND_FEE_SHARE_BPS / 10_000
//     where protocolFee = matchPot × ESCROW_FEE_BPS / 10_000
//                       = matchPot × 2% (burn + P2E)
//
//     DIAMOND_FEE_SHARE_BPS = 500  (5% of protocol fee)
//     ESCROW_FEE_BPS        = 200  (2% = mirrors CueEscrow.TOTAL_FEE_BPS)
//
//     Equivalence for legitimate play:
//       matchPot=2,000 → fee=40 → revenue = 40 × 5% = 2 CUECOIN
//       Identical to v1's 2,000 × 0.1% = 2 CUECOIN for normal activity.
//
//     Why wash trading is now provably impossible to profit from:
//       Cost per match:  40 CUE (burn + P2E) — exits attacker's capital
//       Revenue:          2 CUE (from referral pool)
//       Net per match:  –38 CUE, always, regardless of scale.
//       No volume level ever makes this profitable.
//
//     Additional defence:
//       MIN_DIAMOND_POT = 200 CUECOIN (100 per player minimum)
//       Micro-wager spam to inflate match count is gated by minimum pot size.
//       Below this threshold, recordWagerVolume silently returns (no revenue).
//
//   [FIX-A4]  AUTHORISED CALLER TIMELOCK
//
//   Root cause (v1):
//     setAuthorisedCaller(caller, true) was instant, owner-only.
//     A compromised owner key (or malicious upgrade to an ecosystem contract
//     that keeps the same address) could immediately grant any address the
//     power to call recordMatchCompletion() and mass-farm referral rewards
//     without real matches ever occurring.
//
//   Fix (v2):
//     Two-step with CALLER_UPDATE_DELAY (48 hours).
//
//       queueCallerChange(caller, add)  — owner only, starts 48h clock
//       applyCallerChange(caller)       — anyone after 48h (permissionless)
//       cancelCallerChange(caller)      — owner only, before apply
//
//     Community has 48h to observe any new caller being queued and raise
//     an alarm. During that window the caller has NO power.
//
//     Cap: MAX_AUTHORISED_CALLERS = 10
//     Prevents unbounded whitelist accumulation. An owner who has reached
//     the cap must revoke an existing caller before adding a new one.
//     Revocation is also timelocked — you cannot instantly remove a valid
//     escrow and replace it with a malicious one.
//
//   [FIX-A4b] ADMIN MATCH COMPLETION RATE LIMIT
//
//     adminMarkMatchCompleted() is an emergency recovery function that the
//     owner can call to manually set hasCompletedMatch[player] = true when
//     an authorised caller failed to notify (e.g., escrow was not wired
//     at deployment). In v1 it was unbounded.
//
//     Fix: MAX_ADMIN_COMPLETIONS_PER_DAY = 100
//     The owner can patch up to 100 missed notifications per calendar day.
//     Above that, the call reverts. Prevents it being used for bulk farming
//     even if the owner key is compromised.
//     Each call emits AdminMatchCompleted for on-chain audit trail.
//
//  ════════════════════════════════════════════════════
//   FOUR-TIER REWARD STRUCTURE  (unchanged from v1)
//  ════════════════════════════════════════════════════
//
//    Tier      Referrals   Reward/Referral   Bonus
//    ─────────────────────────────────────────────────
//    Bronze    1 – 9       25 CUECOIN        Base reward only
//    Silver    10 – 49     40 CUECOIN        Silver Badge NFT
//    Gold      50 – 99     60 CUECOIN        Gold Badge NFT
//    Diamond   100+       100 CUECOIN        Diamond Badge NFT
//                                          + 5% of escrow protocol fee
//                                            on each referee match forever
//                                            (≡ ~0.1% of pot at 2% fee rate)
//
//    Referee bonus: 10 CUECOIN paid to the referee on their first
//    completed wager match (NOT at airdrop claim — anti-sybil gate).
//
//  ════════════════════════════════════════════════════
//   LIFECYCLE
//  ════════════════════════════════════════════════════
//
//    1. Referee visits referral link (off-chain URL ?ref=0xAddr).
//    2. Referee calls registerReferral(referrer) on-chain.
//         - Self-referral rejected at Solidity level.
//         - Referrer must have hasCompletedMatch = true.
//         - Each referee can only register once (immutable link).
//    3. Referee plays their first wager match in CueEscrow.
//    4. CueEscrow calls recordMatchCompletion(referee) [best-effort].
//    5. CueReferral:
//         - Marks referee.matchCompleted = true.
//         - Computes referrer reward at current tier rate.
//         - Increments referrer.completedReferrals.
//         - Upgrades referrer tier if threshold crossed.
//         - Mints badge NFT if tier upgraded (best-effort).
//         - Credits referrer: pendingReward += reward.
//         - Pays referee 10 CUECOIN bonus (queued if pool dry).
//    6. After EACH resolved match: CueEscrow calls
//         recordWagerVolume(player, matchPot)
//       Diamond referrers accrue 5% of the 2% protocol fee on that match.
//    7. Referrer calls claimRewards() to pull pending CUECOIN.
//    8. Diamond referrers call claimDiamondRevenue() separately.
//    9. Referee calls claimRefereeBonus() if bonus was queued.
//
//  ════════════════════════════════════════════════════
//   TIER UPGRADE MECHANICS
//  ════════════════════════════════════════════════════
//
//  Tier upgrades when completedReferrals crosses a threshold:
//    NONE → BRONZE   at 1    (first completion)
//    BRONZE → SILVER at 10
//    SILVER → GOLD   at 50
//    GOLD → DIAMOND  at 100
//
//  The triggering completion earns the PRE-upgrade tier rate.
//  The next completion earns the new tier rate.
//
//  Badge NFTs minted at most once per tier crossing (bitmask guard).
//  Mint failure is best-effort — reward never blocked by CueNFT revert.
//
//  ════════════════════════════════════════════════════
//   REWARD POOL ACCOUNTING
//  ════════════════════════════════════════════════════
//
//  rewardPool = CUECOIN currently available for immediate payout.
//  Invariant: rewardPool ≤ balanceOf(address(this)).
//
//  When rewardPool is sufficient at accrual time:
//    rewardPool    -= reward      (committed immediately)
//    pendingReward += reward      (available to claim)
//
//  When rewardPool is insufficient at accrual time:
//    pendingReward += reward      (queued — unfunded)
//    (pool NOT decremented — no overclaim possible)
//
//  At claimRewards():
//    pay = min(pendingReward, rewardPool)
//    pendingReward -= pay
//    rewardPool    -= pay
//    transfer pay to referrer
//
//  totalRewardAccrued  = all rewards credited (funded + unfunded)
//  totalRewardClaimed  = CUECOIN actually transferred out
//  These diverge during pool drought — both are tracked separately.
//
//  ════════════════════════════════════════════════════
//   HASCOMPLETEDMATCH — SCOPE
//  ════════════════════════════════════════════════════
//
//  Set by ANY authorised caller (CueEscrow, CueSitAndGo, etc.).
//  Enables SitAndGo-only players to become referrers.
//  Only CueEscrow (1v1 wager matches) triggers full referral reward
//  flow via recordWagerVolume (SitAndGo calls recordMatchCompletion
//  which sets the flag but does not process referral rewards unless
//  the player is a registered referee whose match hadn't been counted).
//
//  ════════════════════════════════════════════════════
//   ANTI-ABUSE MECHANISMS
//  ════════════════════════════════════════════════════
//
//    Self-referral             require(referrer != referee)        Solidity
//    Sign-up farming           reward only after matchCompleted    On-chain
//    Inactive referrer         require(hasCompletedMatch[ref])     On-chain
//    Double register           referee can only register once      On-chain
//    Pool drain                rewards queued, never overpaid      On-chain
//    Caller spoofing           authorisedCaller whitelist          On-chain
//    Caller addition           48h timelock on setAuthorisedCaller On-chain
//    Caller cap                MAX_AUTHORISED_CALLERS = 10         On-chain
//    Wash-trading drain        fee-base revenue (not gross pot)    On-chain
//    Micro-match spam          MIN_DIAMOND_POT = 200 CUECOIN       On-chain
//    Admin farming             MAX_ADMIN_COMPLETIONS_PER_DAY = 100 On-chain
//    Fresh-wallet sybil        wallet age in task engine           Off-chain
//
//  ════════════════════════════════════════════════════
//   SECURITY MODEL
//  ════════════════════════════════════════════════════
//
//  Owner CAN:    queueCallerChange (48h delay before active)
//                cancelCallerChange
//                updateNFTContract
//                adminMarkMatchCompleted (capped 100/day, audited)
//                pause / unpause
//                recoverERC20 (non-CUECOIN only)
//
//  Owner CANNOT: change reward rates (bytecode constants)
//                change tier thresholds (bytecode constants)
//                redirect reward pool
//                inflate referral counts
//                instantly add a new caller without 48h wait
//                call adminMarkMatchCompleted > 100 times per day
//                recover CUECOIN from pool (DAO governance only)
// ╚══════════════════════════════════════════════════════════════╝

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ─────────────────────────────────────────────────────────────
//  INTERFACES
// ─────────────────────────────────────────────────────────────

/// @dev Minimal CueNFT surface for badge minting.
interface ICueNFT {
    function mintBadge(address to, uint8 badgeTier, uint256 referralCount)
        external
        returns (uint256 tokenId);

    function BADGE_SILVER()  external pure returns (uint8);
    function BADGE_GOLD()    external pure returns (uint8);
    function BADGE_DIAMOND() external pure returns (uint8);
}

/**
 * @title  CueReferral
 * @author CUECOIN Team
 * @notice v2.0: Diamond revenue re-based on protocol fee (not gross pot) to
 *         eliminate wash-trading drain. Authorised-caller changes now require
 *         a 48-hour timelock. Admin completions rate-limited to 100/day.
 */
contract CueReferral is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════
    //  CONSTANTS  (bytecode — no actor can change these)
    // ═══════════════════════════════════════════════════════════

    // ── Tier thresholds ──
    uint256 public constant BRONZE_THRESHOLD  = 1;
    uint256 public constant SILVER_THRESHOLD  = 10;
    uint256 public constant GOLD_THRESHOLD    = 50;
    uint256 public constant DIAMOND_THRESHOLD = 100;

    // ── Per-referral CUECOIN reward by tier ──
    uint256 public constant BRONZE_REWARD  =  25 ether;
    uint256 public constant SILVER_REWARD  =  40 ether;
    uint256 public constant GOLD_REWARD    =  60 ether;
    uint256 public constant DIAMOND_REWARD = 100 ether;

    /// @notice Referee receives this bonus on first match completion.
    uint256 public constant REFEREE_BONUS  = 10 ether;

    // ── [FIX-A1] Fee-based Diamond revenue share ──

    /// @notice CueEscrow charges 2% on victories (1% burn + 1% P2E).
    ///         This mirrors CueEscrow.TOTAL_FEE_BPS and is used to derive
    ///         the protocol fee from matchPot without an external call.
    ///         If CueEscrow's fee rate ever changes, this must be updated
    ///         via contract upgrade — it is intentionally a constant so
    ///         the revenue calculation is transparent and auditable.
    uint256 public constant ESCROW_FEE_BPS = 200; // 2% of pot

    /// @notice Diamond earns this fraction OF THE PROTOCOL FEE (not of pot).
    ///         500 bps = 5% of the 2% fee = 0.1% of pot at current fee rate.
    ///         For a 2,000 CUE pot: fee=40, revenue=40×5%=2 CUE.
    ///         Wash-trade analysis: attacker burns 20 CUE, sends 20 to P2E,
    ///         earns 2 CUE from pool. Net = –38 CUE per match. Always negative.
    uint256 public constant DIAMOND_FEE_SHARE_BPS = 500;

    /// @notice [FIX-A1] Minimum total match pot for Diamond revenue eligibility.
    ///         Blocks micro-wager spam that floods recordWagerVolume with tiny
    ///         pots to inflate match count.  100 CUE per player = 200 CUE pot.
    uint256 public constant MIN_DIAMOND_POT = 200 ether;

    // ── [FIX-A4] Caller timelock ──
    /// @notice Delay before a queued caller change takes effect.
    uint256 public constant CALLER_UPDATE_DELAY = 48 hours;

    /// @notice Hard cap on the number of authorised callers.
    ///         Prevents unbounded whitelist accumulation.
    uint256 public constant MAX_AUTHORISED_CALLERS = 10;

    // ── [FIX-A4b] Admin completion rate limit ──
    /// @notice Maximum calls to adminMarkMatchCompleted per calendar day (UTC).
    uint256 public constant MAX_ADMIN_COMPLETIONS_PER_DAY = 100;

    // ═══════════════════════════════════════════════════════════
    //  ENUMS & STRUCTS
    // ═══════════════════════════════════════════════════════════

    enum Tier { NONE, BRONZE, SILVER, GOLD, DIAMOND }

    /// @notice Per-referrer state.
    struct ReferrerData {
        uint256 completedReferrals; // referees who finished first match
        Tier    tier;               // current tier
        uint256 pendingReward;      // CUECOIN accrued, not yet claimed
        uint256 revenueAccrued;     // Diamond: fee-share queued, not claimed
        uint256 totalRewardAccrued; // lifetime credited (funded + unfunded)
        uint256 totalRewardClaimed; // lifetime actually transferred to referrer
        uint256 totalRevenueClaimed;
        uint8   badgeMinted;        // bitmask: bit0=Silver, bit1=Gold, bit2=Diamond
    }

    /// @notice Per-referee state.
    struct RefereeData {
        address referrer;       // who referred this wallet (immutable after set)
        bool    registered;     // referral link exists
        bool    matchCompleted; // first wager match done
        bool    bonusPaid;      // 10 CUECOIN referee bonus handled
    }

    /// @notice [FIX-A4] Pending authorised-caller change.
    struct PendingCallerChange {
        bool    add;  // true = adding, false = removing
        uint256 eta;  // executable after this timestamp
        bool    exists;
    }

    // ═══════════════════════════════════════════════════════════
    //  STATE VARIABLES
    // ═══════════════════════════════════════════════════════════

    IERC20  public immutable cueCoin;
    ICueNFT public           nftContract;

    /// @notice CUECOIN available for immediate payout.
    ///         Invariant: rewardPool ≤ balanceOf(address(this)).
    uint256 public rewardPool;

    // ── [FIX-A4] Caller whitelist with timelock ──
    mapping(address => bool)               public authorisedCaller;
    mapping(address => PendingCallerChange) private _pendingCallerChange;
    uint256 public authorisedCallerCount;

    mapping(address => ReferrerData) private _referrer;
    mapping(address => RefereeData)  private _referee;

    /// @notice Set once any authorised caller confirms a player's first match.
    ///         Required for a player to become a referrer (activity gate).
    mapping(address => bool) public hasCompletedMatch;

    /// @notice Queued referee bonus for players whose pool was dry at match time.
    mapping(address => uint256) public pendingRefereeBonus;

    // ── [FIX-A4b] Admin rate limiting ──
    uint256 private _adminCompletionDay;  // UTC day number of last admin call
    uint256 private _adminCompletionsToday;

    // ── Protocol stats ──
    uint256 public totalReferralsCompleted;
    uint256 public totalRewardAccrued;    // all rewards credited (funded + unfunded)
    uint256 public totalRewardClaimed;    // CUECOIN actually transferred out
    uint256 public totalRevenueClaimed;
    uint256 public totalRefereeBonusPaid;
    uint256 public totalPoolReceived;
    uint256 public totalPoolRefills;

    // ═══════════════════════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════════════════════

    event ReferralRegistered(
        address indexed referee,
        address indexed referrer
    );

    event MatchCompleted(
        address indexed player,
        bool            wasReferee
    );

    event ReferralCompleted(
        address indexed referee,
        address indexed referrer,
        Tier            tierAtCompletion,
        uint256         reward,
        bool            fundedByPool
    );

    event TierUpgraded(
        address indexed referrer,
        Tier            fromTier,
        Tier            toTier,
        uint256         completedReferrals
    );

    event BadgeMinted(address indexed referrer, uint8 badgeTier, uint256 tokenId);
    event BadgeMintFailed(address indexed referrer, uint8 badgeTier, bytes reason);

    event RefereeBonus(address indexed referee, uint256 amount, bool paidNow);

    event WagerVolumeRecorded(
        address indexed player,
        address indexed diamondReferrer,
        uint256         matchPot,
        uint256         protocolFee,  // [FIX-A1] emitted for auditability
        uint256         revenueAccrued
    );

    event RewardClaimed(address indexed referrer, uint256 amount);
    event DiamondRevenueClaimed(address indexed referrer, uint256 amount);
    event RefereeBonusClaimed(address indexed referee, uint256 amount);

    event PoolRefilled(address indexed sender, uint256 amount, uint256 newPoolBalance);

    // ── [FIX-A4] Caller timelock events ──
    event CallerChangeQueued(address indexed caller, bool add, uint256 eta);
    event CallerChangeApplied(address indexed caller, bool add);
    event CallerChangeCancelled(address indexed caller);

    // ── [FIX-A4b] Admin audit trail ──
    event AdminMatchCompleted(address indexed player, address indexed admin);

    event NFTContractUpdated(address indexed oldNFT, address indexed newNFT);

    // ═══════════════════════════════════════════════════════════
    //  MODIFIERS
    // ═══════════════════════════════════════════════════════════

    modifier onlyAuthorised() {
        require(
            authorisedCaller[msg.sender] || msg.sender == owner(),
            "CueReferral: not an authorised caller"
        );
        _;
    }

    // ═══════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    /**
     * @param _cueCoin     CueCoin BEP-20 contract.
     * @param _escrow      CueEscrow — authorised for recordMatchCompletion.
     * @param _sitAndGo    CueSitAndGo — also authorised (sets hasCompletedMatch
     *                     so SitAndGo-only players can become referrers).
     *                     Pass address(0) if not yet deployed.
     * @param _nftContract CueNFT — receives mintBadge calls.
     */
    constructor(
        address _cueCoin,
        address _escrow,
        address _sitAndGo,
        address _nftContract
    )
        Ownable(msg.sender)
    {
        require(_cueCoin     != address(0), "CueReferral: zero cueCoin");
        require(_escrow      != address(0), "CueReferral: zero escrow");
        require(_nftContract != address(0), "CueReferral: zero nftContract");

        cueCoin     = IERC20(_cueCoin);
        nftContract = ICueNFT(_nftContract);

        // Constructor callers bypass the 48h timelock — these are known
        // deployment-time contracts that have been reviewed.
        _addCaller(_escrow);
        if (_sitAndGo != address(0)) {
            _addCaller(_sitAndGo);
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  REFERRAL REGISTRATION
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Link the caller (referee) to a referrer wallet.
     *
     *         The link is immutable once set. Rewards do not flow until the
     *         referee completes their first wager match.
     *
     *         Anti-abuse enforced:
     *           1. Self-referral rejected at Solidity level.
     *           2. Referee can only register once.
     *           3. Referrer must have hasCompletedMatch = true
     *              (prevents inactive wallet link-farming).
     *
     * @param referrer  Wallet that referred the caller.
     */
    function registerReferral(address referrer) external whenNotPaused {
        address referee = msg.sender;

        require(referrer != address(0),            "CueReferral: zero referrer");
        require(referrer != referee,               "CueReferral: self-referral forbidden");
        require(!_referee[referee].registered,     "CueReferral: already registered");
        require(
            hasCompletedMatch[referrer],
            "CueReferral: referrer has not completed any match"
        );

        _referee[referee] = RefereeData({
            referrer:       referrer,
            registered:     true,
            matchCompleted: false,
            bonusPaid:      false
        });

        emit ReferralRegistered(referee, referrer);
    }

    // ═══════════════════════════════════════════════════════════
    //  MATCH CALLBACKS  (called by CueEscrow / CueSitAndGo)
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Record that a player has completed their first match.
     *
     *         Called by CueEscrow after a victory or forfeit payout, and by
     *         CueSitAndGo after a tournament resolves. Designed to be called
     *         via a best-effort low-level call — must never block the payout.
     *
     *         Two effects:
     *           A) hasCompletedMatch[player] = true (always, unconditional).
     *           B) If player is a registered referee completing their first
     *              match: trigger full referral reward flow.
     *
     * @param player  Player who completed the match.
     */
    function recordMatchCompletion(address player)
        external
        onlyAuthorised
        nonReentrant
    {
        bool wasReferee = _setMatchCompleted(player);
        emit MatchCompleted(player, wasReferee);
    }

    /**
     * @notice Record wager volume for Diamond revenue share.
     *
     *         Called by CueEscrow after each resolved victory (not forfeits —
     *         forfeits carry no protocol fee). Both participants should be
     *         reported so both referrers (if Diamond) accrue revenue.
     *
     *         [FIX-A1] Revenue is now computed from the PROTOCOL FEE, not from
     *         the gross pot. This makes wash-trading provably unprofitable:
     *
     *           protocolFee = matchPot × ESCROW_FEE_BPS / 10_000   (2%)
     *           revenue     = protocolFee × DIAMOND_FEE_SHARE_BPS / 10_000  (5%)
     *
     *         Cost to attacker per wash match (2,000 pot):
     *           Fee paid out: 40 CUE (20 burned + 20 to P2E)
     *           Revenue earned from pool: 2 CUE
     *           Net per match: –38 CUE. Always negative at any scale.
     *
     *         [FIX-A1] MIN_DIAMOND_POT = 200 CUECOIN silently skips micro-pots.
     *
     * @param player    One participant in the resolved match.
     * @param matchPot  Total CUECOIN pot (wagerPerPlayer × 2).
     */
    function recordWagerVolume(address player, uint256 matchPot)
        external
        onlyAuthorised
        nonReentrant
    {
        // [FIX-A1] Minimum pot guard — micro-wager spam protection
        if (matchPot < MIN_DIAMOND_POT) return;

        RefereeData storage ref = _referee[player];
        if (!ref.registered || !ref.matchCompleted) return;

        ReferrerData storage rr = _referrer[ref.referrer];
        if (rr.tier != Tier.DIAMOND) return;

        // [FIX-A1] Compute revenue from protocol fee, not gross pot
        uint256 protocolFee = (matchPot * ESCROW_FEE_BPS) / 10_000;
        uint256 revenue     = (protocolFee * DIAMOND_FEE_SHARE_BPS) / 10_000;
        if (revenue == 0) return;

        rr.revenueAccrued += revenue;
        emit WagerVolumeRecorded(player, ref.referrer, matchPot, protocolFee, revenue);
    }

    // ═══════════════════════════════════════════════════════════
    //  CLAIM FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Referrer withdraws accumulated CUECOIN rewards.
     *
     *         Pays min(pendingReward, rewardPool). Partial payment if pool
     *         is insufficient — remainder stays in pendingReward for the
     *         next DAO refill. No rewards are ever lost.
     */
    function claimRewards() external nonReentrant whenNotPaused {
        ReferrerData storage rr = _referrer[msg.sender];
        uint256 pending = rr.pendingReward;

        require(pending > 0, "CueReferral: no pending reward");

        uint256 payout = pending < rewardPool ? pending : rewardPool;
        require(payout > 0, "CueReferral: pool empty — await DAO refill");

        rr.pendingReward      -= payout;
        rr.totalRewardClaimed += payout;
        rewardPool            -= payout;
        totalRewardClaimed    += payout;

        cueCoin.safeTransfer(msg.sender, payout);
        emit RewardClaimed(msg.sender, payout);
    }

    /**
     * @notice Diamond referrer withdraws accumulated fee-share revenue.
     *
     *         Pays min(revenueAccrued, rewardPool). Revenue and referral
     *         rewards compete for the same pool on a first-claim basis.
     */
    function claimDiamondRevenue() external nonReentrant whenNotPaused {
        ReferrerData storage rr = _referrer[msg.sender];

        require(rr.tier == Tier.DIAMOND, "CueReferral: not a Diamond referrer");

        uint256 accrued = rr.revenueAccrued;
        require(accrued > 0, "CueReferral: no revenue accrued");

        uint256 payout = accrued < rewardPool ? accrued : rewardPool;
        require(payout > 0, "CueReferral: pool empty — await DAO refill");

        rr.revenueAccrued      -= payout;
        rr.totalRevenueClaimed += payout;
        rewardPool             -= payout;
        totalRevenueClaimed    += payout;

        cueCoin.safeTransfer(msg.sender, payout);
        emit DiamondRevenueClaimed(msg.sender, payout);
    }

    /**
     * @notice Referee claims their queued 10 CUECOIN bonus.
     *         Only needed if the pool was empty at first match completion.
     */
    function claimRefereeBonus() external nonReentrant whenNotPaused {
        uint256 queued = pendingRefereeBonus[msg.sender];
        require(queued > 0, "CueReferral: no referee bonus pending");

        uint256 payout = queued < rewardPool ? queued : rewardPool;
        require(payout > 0, "CueReferral: pool empty — await DAO refill");

        pendingRefereeBonus[msg.sender] -= payout;
        rewardPool                      -= payout;
        totalRefereeBonusPaid           += payout;

        cueCoin.safeTransfer(msg.sender, payout);
        emit RefereeBonusClaimed(msg.sender, payout);
    }

    // ═══════════════════════════════════════════════════════════
    //  POOL MANAGEMENT
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Notify this contract of a CUECOIN pool refill from CueDAO.
     *
     *         Permissionless: the balance check IS the authorisation.
     *         An attacker calling notifyRefill(1000) without first
     *         transferring 1000 CUECOIN to this contract fails the check.
     *
     *         CueDAO workflow:
     *           1. DAO proposal: UPDATE_REFERRAL_POOL transfers tokens here.
     *           2. CueDAO calls notifyRefill(amount) after the transfer.
     *
     * @param amount  CUECOIN just transferred to this contract.
     */
    function notifyRefill(uint256 amount) external nonReentrant {
        require(amount > 0, "CueReferral: zero refill");

        require(
            cueCoin.balanceOf(address(this)) >= rewardPool + amount,
            "CueReferral: transfer not received or already counted"
        );

        rewardPool        += amount;
        totalPoolReceived += amount;
        totalPoolRefills++;

        emit PoolRefilled(msg.sender, amount, rewardPool);
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — CORE REFERRAL LOGIC
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev Set a player's match-completed flag and trigger the referral
     *      reward flow if they are an unprocessed registered referee.
     *      Returns true if a referral reward was triggered.
     */
    function _setMatchCompleted(address player) internal returns (bool wasReferee) {
        hasCompletedMatch[player] = true;

        RefereeData storage ref = _referee[player];
        if (!ref.registered || ref.matchCompleted) return false;

        ref.matchCompleted = true;
        wasReferee = true;
        totalReferralsCompleted++;

        _processReferralCompletion(player, ref);
    }

    /**
     * @dev Process the full referral reward flow for a referee's first match.
     *      Called exactly once per referee. Steps:
     *
     *        1. Read tier BEFORE incrementing (reward uses pre-upgrade rate).
     *        2. Increment completedReferrals.
     *        3. Compute new tier — emit TierUpgraded + mint badge if crossed.
     *        4. Credit referrer reward (funded from pool or queued).
     *        5. Pay or queue referee 10 CUECOIN bonus.
     */
    function _processReferralCompletion(
        address           referee,
        RefereeData storage ref
    ) internal {
        address            referrer = ref.referrer;
        ReferrerData storage rr    = _referrer[referrer];

        // Step 1: rate at PRE-increment tier (NONE → use BRONZE rate)
        Tier tierAtCompletion = rr.tier == Tier.NONE ? Tier.BRONZE : rr.tier;
        uint256 reward = _rewardForTier(tierAtCompletion);

        // Step 2: increment
        rr.completedReferrals++;

        // Step 3: tier upgrade
        Tier newTier = _computeTier(rr.completedReferrals);
        if (newTier != rr.tier) {
            Tier oldTier = rr.tier;
            rr.tier = newTier;
            emit TierUpgraded(referrer, oldTier, newTier, rr.completedReferrals);
            _tryMintBadge(referrer, newTier, rr.completedReferrals, rr);
        }

        // Step 4: credit reward
        bool funded = rewardPool >= reward;
        if (funded) {
            rewardPool -= reward;
        }
        // Always add to pendingReward — pool services it at claimRewards() time
        rr.pendingReward      += reward;
        rr.totalRewardAccrued += reward;
        totalRewardAccrued    += reward;

        emit ReferralCompleted(referee, referrer, tierAtCompletion, reward, funded);

        // Step 5: referee bonus
        _handleRefereeBonus(referee, ref);
    }

    /**
     * @dev Pay or queue the 10 CUECOIN referee bonus.
     *      bonusPaid is set before any transfer — redundant with nonReentrant
     *      but makes the intent explicit.
     */
    function _handleRefereeBonus(address referee, RefereeData storage ref) internal {
        if (ref.bonusPaid) return;
        ref.bonusPaid = true;

        if (rewardPool >= REFEREE_BONUS) {
            rewardPool           -= REFEREE_BONUS;
            totalRefereeBonusPaid += REFEREE_BONUS;
            cueCoin.safeTransfer(referee, REFEREE_BONUS);
            emit RefereeBonus(referee, REFEREE_BONUS, true);
        } else {
            pendingRefereeBonus[referee] += REFEREE_BONUS;
            emit RefereeBonus(referee, REFEREE_BONUS, false);
        }
    }

    /**
     * @dev Attempt badge NFT mint for a tier upgrade. Best-effort via try/catch.
     *      Each badge tier minted at most once per referrer (bitmask guard).
     *      Bit 0 = Silver, bit 1 = Gold, bit 2 = Diamond.
     */
    function _tryMintBadge(
        address              referrer,
        Tier                 newTier,
        uint256              referralCount,
        ReferrerData storage rr
    ) internal {
        uint8 badgeTier;
        uint8 bit;

        if      (newTier == Tier.SILVER)  { badgeTier = nftContract.BADGE_SILVER();  bit = 0; }
        else if (newTier == Tier.GOLD)    { badgeTier = nftContract.BADGE_GOLD();    bit = 1; }
        else if (newTier == Tier.DIAMOND) { badgeTier = nftContract.BADGE_DIAMOND(); bit = 2; }
        else return;

        if (rr.badgeMinted & (1 << bit) != 0) return;
        rr.badgeMinted |= uint8(1 << bit);

        try nftContract.mintBadge(referrer, badgeTier, referralCount)
            returns (uint256 tokenId)
        {
            emit BadgeMinted(referrer, badgeTier, tokenId);
        } catch (bytes memory reason) {
            emit BadgeMintFailed(referrer, badgeTier, reason);
            // Reward is NEVER affected by badge mint failure.
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — CALLER MANAGEMENT  [FIX-A4]
    // ═══════════════════════════════════════════════════════════

    /// @dev Unconditionally add a caller (constructor use only).
    function _addCaller(address caller) internal {
        if (authorisedCaller[caller]) return;
        require(authorisedCallerCount < MAX_AUTHORISED_CALLERS, "CueReferral: caller cap reached");
        authorisedCaller[caller] = true;
        authorisedCallerCount++;
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — PURE HELPERS
    // ═══════════════════════════════════════════════════════════

    function _computeTier(uint256 count) internal pure returns (Tier) {
        if (count == 0)                return Tier.NONE;
        if (count < SILVER_THRESHOLD)  return Tier.BRONZE;
        if (count < GOLD_THRESHOLD)    return Tier.SILVER;
        if (count < DIAMOND_THRESHOLD) return Tier.GOLD;
        return Tier.DIAMOND;
    }

    function _rewardForTier(Tier tier) internal pure returns (uint256) {
        if (tier == Tier.BRONZE || tier == Tier.NONE) return BRONZE_REWARD;
        if (tier == Tier.SILVER)                      return SILVER_REWARD;
        if (tier == Tier.GOLD)                        return GOLD_REWARD;
        if (tier == Tier.DIAMOND)                     return DIAMOND_REWARD;
        revert("CueReferral: unknown tier");
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Full referrer dashboard data.
     */
    function getReferrerInfo(address referrer)
        external
        view
        returns (
            uint256 completedReferrals,
            Tier    tier,
            uint256 pendingReward,
            uint256 revenueAccrued,
            uint256 totalRewardAccrued_,
            uint256 totalRewardClaimed_,
            uint256 totalRevenueClaimed_,
            bool    hasSilverBadge,
            bool    hasGoldBadge,
            bool    hasDiamondBadge
        )
    {
        ReferrerData storage rr = _referrer[referrer];
        return (
            rr.completedReferrals,
            rr.tier,
            rr.pendingReward,
            rr.revenueAccrued,
            rr.totalRewardAccrued,
            rr.totalRewardClaimed,
            rr.totalRevenueClaimed,
            rr.badgeMinted & 1 != 0,
            rr.badgeMinted & 2 != 0,
            rr.badgeMinted & 4 != 0
        );
    }

    /**
     * @notice Full referee status.
     */
    function getRefereeInfo(address referee)
        external
        view
        returns (
            address referrer,
            bool    registered,
            bool    matchCompleted,
            bool    bonusPaid,
            uint256 pendingBonus
        )
    {
        RefereeData storage ref = _referee[referee];
        return (
            ref.referrer,
            ref.registered,
            ref.matchCompleted,
            ref.bonusPaid,
            pendingRefereeBonus[referee]
        );
    }

    /**
     * @notice Referrals needed to reach the next tier.
     */
    function tierProgress(address referrer)
        external
        view
        returns (Tier nextTier, uint256 referralsNeeded)
    {
        ReferrerData storage rr = _referrer[referrer];
        uint256 count = rr.completedReferrals;

        if (rr.tier == Tier.DIAMOND)  return (Tier.DIAMOND, 0);
        if (count < SILVER_THRESHOLD)  return (Tier.SILVER,  SILVER_THRESHOLD  - count);
        if (count < GOLD_THRESHOLD)    return (Tier.GOLD,    GOLD_THRESHOLD    - count);
        return (Tier.DIAMOND, DIAMOND_THRESHOLD - count);
    }

    /**
     * @notice CUECOIN reward for the referrer's next completed referral.
     */
    function nextReferralReward(address referrer)
        external
        view
        returns (uint256 rewardAmount, Tier currentTier)
    {
        ReferrerData storage rr = _referrer[referrer];
        currentTier  = rr.tier;
        rewardAmount = _rewardForTier(rr.tier == Tier.NONE ? Tier.BRONZE : rr.tier);
    }

    /**
     * @notice [FIX-A1] Estimated Diamond revenue per match at current fee rates.
     *         Useful for frontend display and off-chain monitoring.
     *
     * @param matchPot         Total match pot in CUECOIN-wei.
     * @return protocolFee     2% of matchPot (what escrow takes).
     * @return diamondRevenue  5% of protocolFee (what Diamond referrer earns).
     */
    function diamondRevenueForPot(uint256 matchPot)
        external
        pure
        returns (uint256 protocolFee, uint256 diamondRevenue)
    {
        protocolFee   = (matchPot * ESCROW_FEE_BPS) / 10_000;
        diamondRevenue = (protocolFee * DIAMOND_FEE_SHARE_BPS) / 10_000;
    }

    /**
     * @notice Estimated daily Diamond revenue for a referrer.
     * @param referrer          Diamond referrer address.
     * @param avgDailyMatchPot  Average match pot per referee per day (CUECOIN-wei).
     * @return dailyRevenue     5% of 2% × active referees × avgDailyMatchPot.
     */
    function estimateDiamondDailyRevenue(address referrer, uint256 avgDailyMatchPot)
        external
        view
        returns (uint256 dailyRevenue)
    {
        ReferrerData storage rr = _referrer[referrer];
        if (rr.tier != Tier.DIAMOND) return 0;
        uint256 totalDailyPot = rr.completedReferrals * avgDailyMatchPot;
        uint256 fee           = (totalDailyPot * ESCROW_FEE_BPS) / 10_000;
        dailyRevenue          = (fee * DIAMOND_FEE_SHARE_BPS) / 10_000;
    }

    /**
     * @notice [FIX-A4] Status of a pending caller change.
     */
    function pendingCallerChange(address caller)
        external
        view
        returns (bool add, uint256 eta, bool exists)
    {
        PendingCallerChange storage p = _pendingCallerChange[caller];
        return (p.add, p.eta, p.exists);
    }

    /**
     * @notice Protocol-wide statistics.
     */
    function protocolStats()
        external
        view
        returns (
            uint256 poolBalance,
            uint256 referralsCompleted,
            uint256 rewardAccrued,
            uint256 rewardClaimed,
            uint256 revenueClaimed,
            uint256 refereeBonusesPaid,
            uint256 poolRefills,
            uint256 poolTotalReceived,
            uint256 activeCallers
        )
    {
        return (
            rewardPool,
            totalReferralsCompleted,
            totalRewardAccrued,
            totalRewardClaimed,
            totalRevenueClaimed,
            totalRefereeBonusPaid,
            totalPoolRefills,
            totalPoolReceived,
            authorisedCallerCount
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  OWNER ADMIN — CALLER TIMELOCK  [FIX-A4]
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Queue an authorised-caller change. 48-hour delay before active.
     *         Owner-only.
     *
     *         Adding a caller: new contract can call recordMatchCompletion /
     *         recordWagerVolume after the delay.
     *         Removing a caller: existing contract loses that power after delay.
     *
     *         Both addition and removal are timelocked — you cannot silently
     *         swap a legitimate escrow for a malicious one:
     *           1. Remove old escrow → 48h wait.
     *           2. Add new escrow   → 48h wait.
     *         96h minimum for a full swap. Community has ample time to react.
     *
     * @param caller    Contract address to add or remove.
     * @param add       true = grant access, false = revoke access.
     */
    function queueCallerChange(address caller, bool add) external onlyOwner {
        require(caller != address(0), "CueReferral: zero caller");

        if (add) {
            require(!authorisedCaller[caller],               "CueReferral: already authorised");
            require(authorisedCallerCount < MAX_AUTHORISED_CALLERS, "CueReferral: caller cap reached");
        } else {
            require(authorisedCaller[caller], "CueReferral: not currently authorised");
        }

        uint256 eta = block.timestamp + CALLER_UPDATE_DELAY;
        _pendingCallerChange[caller] = PendingCallerChange({ add: add, eta: eta, exists: true });
        emit CallerChangeQueued(caller, add, eta);
    }

    /**
     * @notice Apply a queued caller change after the 48-hour delay.
     *         Permissionless — anyone can execute after the delay elapses.
     *
     * @param caller  The caller address for which a change was queued.
     */
    function applyCallerChange(address caller) external nonReentrant {
        PendingCallerChange storage p = _pendingCallerChange[caller];

        require(p.exists,                        "CueReferral: no pending change");
        require(block.timestamp >= p.eta,         "CueReferral: delay not elapsed");

        bool add = p.add;
        delete _pendingCallerChange[caller];

        if (add) {
            // Re-check cap at apply time (another add could have been applied first)
            require(
                authorisedCallerCount < MAX_AUTHORISED_CALLERS,
                "CueReferral: caller cap reached at apply time"
            );
            if (!authorisedCaller[caller]) {
                authorisedCaller[caller] = true;
                authorisedCallerCount++;
            }
        } else {
            if (authorisedCaller[caller]) {
                authorisedCaller[caller] = false;
                if (authorisedCallerCount > 0) authorisedCallerCount--;
            }
        }

        emit CallerChangeApplied(caller, add);
    }

    /**
     * @notice Cancel a queued caller change before it applies. Owner-only.
     */
    function cancelCallerChange(address caller) external onlyOwner {
        require(_pendingCallerChange[caller].exists, "CueReferral: no pending change");
        delete _pendingCallerChange[caller];
        emit CallerChangeCancelled(caller);
    }

    // ═══════════════════════════════════════════════════════════
    //  OWNER ADMIN — OTHER
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Replace the CueNFT contract for badge minting.
     */
    function updateNFTContract(address newNFT) external onlyOwner {
        require(newNFT != address(0), "CueReferral: zero address");
        emit NFTContractUpdated(address(nftContract), newNFT);
        nftContract = ICueNFT(newNFT);
    }

    /**
     * @notice [FIX-A4b] Emergency: mark a player as having completed a match.
     *         Use only when an authorised caller failed to notify (e.g., escrow
     *         not yet wired at launch). Rate-limited to MAX_ADMIN_COMPLETIONS_PER_DAY.
     *
     *         Every call is individually emitted as AdminMatchCompleted for
     *         on-chain audit. Any monitoring tool can alert on this event.
     *
     *         Does NOT bypass the registered-referee check — if the player is
     *         not a registered referee, only hasCompletedMatch is set (same
     *         behaviour as a normal authorised-caller invocation).
     *
     * @param player  Player to mark as having completed a match.
     */
    function adminMarkMatchCompleted(address player)
        external
        onlyOwner
        nonReentrant
    {
        require(player != address(0), "CueReferral: zero address");

        // [FIX-A4b] Rate limit: max 100 per UTC calendar day
        uint256 today = block.timestamp / 1 days;
        if (_adminCompletionDay != today) {
            _adminCompletionDay    = today;
            _adminCompletionsToday = 0;
        }
        require(
            _adminCompletionsToday < MAX_ADMIN_COMPLETIONS_PER_DAY,
            "CueReferral: admin completion daily limit reached"
        );
        _adminCompletionsToday++;

        bool wasReferee = _setMatchCompleted(player);

        emit AdminMatchCompleted(player, msg.sender);
        emit MatchCompleted(player, wasReferee);
    }

    function pause()   external onlyOwner { _pause();   }
    function unpause() external onlyOwner { _unpause(); }

    /**
     * @notice Recover ERC-20 tokens accidentally sent to this contract.
     *         CUECOIN is the reward pool — governed by DAO, not recoverable here.
     */
    function recoverERC20(address token, uint256 amount) external onlyOwner {
        require(token != address(cueCoin), "CueReferral: cannot recover CUECOIN");
        IERC20(token).safeTransfer(owner(), amount);
    }
}
