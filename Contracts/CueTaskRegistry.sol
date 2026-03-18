// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ╔══════════════════════════════════════════════════════════════╗
//  CUETASKREGISTRY  ·  v1.0  ·  Production-Ready
//  CUECOIN Ecosystem  ·  BNB Smart Chain
//
//  On-chain task metadata registry for the CUECOIN standard airdrop
//  claim system. The off-chain task engine reads this contract to
//  know which tasks exist, how to verify them, and what rewards they
//  carry. New tasks can be added at any time without redeploying the
//  airdrop contract or invalidating any Merkle tree.
//
//  ════════════════════════════════════════════════════
//   ARCHITECTURE
//  ════════════════════════════════════════════════════
//
//  This contract is METADATA-ONLY. It holds no tokens, executes no
//  payouts, and does not verify task completion itself. Verification
//  is done by the off-chain task engine (Node.js plugin system).
//  Results are baked into each claimant's Merkle leaf as a total
//  CUECOIN amount, which CueAirdrop.sol pays out.
//
//  Data flow:
//    CueTaskRegistry (on-chain) ──reads──▶ Task Engine (off-chain)
//    Task Engine ──verifies──▶ Redis results cache
//    Redis ──drives──▶ Merkle tree builder
//    Merkle root ──submitted to──▶ CueAirdrop.sol
//    Claimant ──presents proof to──▶ CueAirdrop.sol
//
//  ════════════════════════════════════════════════════
//   THREE-TIER TASK STRUCTURE
//  ════════════════════════════════════════════════════
//
//  MANDATORY (Tier 1) — ALL required to qualify
//  ─────────────────────────────────────────────
//    Every wallet must complete every active mandatory task. Failure
//    to complete any one mandatory task disqualifies the wallet from
//    standard claim eligibility. Currently four mandatory tasks:
//      1. Wallet age ≥ 7 days (BSCScan first-tx timestamp)
//      2. Follow @CueCoin on Twitter/X
//      3. Join CueCoin Discord server
//      4. Pay $2 USD equivalent in BNB anti-bot fee
//
//  ENGAGEMENT (Tier 2) — N-of-M required (default N=3, M=5)
//  ──────────────────────────────────────────────────────────
//    Wallets must complete at least engagementThreshold of the active
//    engagement tasks. The threshold is configurable by the owner or
//    DAO without changing the task list. Currently five tasks:
//      1. Retweet the official launch post
//      2. Refer 1 friend who completes standard claim
//      3. Watch gameplay trailer via wallet-signed link
//      4. Signed up on waitlist before early-bird cutoff
//      5. Quote tweet launch post with 50+ characters
//
//  BONUS (Tier 3) — Optional, additive CUECOIN rewards
//  ────────────────────────────────────────────────────
//    Completing bonus tasks awards additional locked CUECOIN on top
//    of the base allocation. Rewards come from the Standard P2E Unlock
//    pool (already minted — no supply inflation). Currently:
//      1. Refer 3+ qualified friends        → +15 CUECOIN
//      2. Complete ALL 5 engagement tasks   → +10 CUECOIN
//      3. Hold any qualifying BSC gaming
//         token at snapshot block           → +5  CUECOIN
//    Maximum possible bonus: 30 CUECOIN per wallet.
//    All bonus tokens remain locked behind the 100-game P2E schedule.
//
//  ════════════════════════════════════════════════════
//   15 VERIFIER TYPES
//  ════════════════════════════════════════════════════
//
//  Each task declares a VerifierType which tells the off-chain engine
//  which plugin to load. Params are ABI-encoded bytes decoded by the
//  plugin. The encoding schema for each type is documented below and
//  in the params field of each Task.
//
//  ID  Name             What It Checks
//  ─────────────────────────────────────────────────────────────────
//   1  WALLET_AGE       First BSCScan tx timestamp vs min age days
//   2  TWITTER_FOLLOW   OAuth2 account follows specified handle
//   3  TWITTER_RETWEET  OAuth2 account retweeted specific tweet ID
//   4  TWITTER_QUOTE    OAuth2 account posted quote tweet with min chars
//   5  DISCORD_JOIN     OAuth2 Discord account is server member
//   6  DISCORD_ROLE     Discord account holds a specific role
//   7  REFERRAL_COUNT   Redis referral counter meets minimum count
//   8  TRAILER_WATCH    Wallet-signed unique URL recorded in Redis
//   9  WAITLIST_SIGNUP  Redis record with cutoff timestamp check
//  10  TOKEN_HOLD       ERC-20 balance at snapshot block
//  11  ON_CHAIN_TX      BNB payment to recipient or min tx count
//  12  NFT_HOLD         ERC-721 balance at snapshot block
//  13  CUSTOM_API       External HTTP endpoint — any custom logic
//  14  EMAIL_VERIFY     Off-chain email verification record in Redis
//  15  QUIZ_COMPLETE    Redis quiz score record with min threshold
//
//  ════════════════════════════════════════════════════
//   PARAMS ENCODING (ABI-encoded bytes per verifier type)
//  ════════════════════════════════════════════════════
//
//  WALLET_AGE:
//    abi.encode(uint256 minAgeDays)
//    e.g. abi.encode(7) for "wallet must be ≥ 7 days old"
//
//  TWITTER_FOLLOW:
//    abi.encode(string handle)
//    e.g. abi.encode("CueCoin")
//
//  TWITTER_RETWEET:
//    abi.encode(string tweetId)
//    e.g. abi.encode("1234567890123456789")
//
//  TWITTER_QUOTE:
//    abi.encode(string tweetId, uint256 minChars)
//    e.g. abi.encode("1234567890123456789", 50)
//
//  DISCORD_JOIN:
//    abi.encode(string guildId)
//    e.g. abi.encode("987654321098765432")
//
//  DISCORD_ROLE:
//    abi.encode(string guildId, string roleId)
//    e.g. abi.encode("987654321098765432", "111222333444555666")
//
//  REFERRAL_COUNT:
//    abi.encode(uint256 minCount)
//    e.g. abi.encode(1) for "refer at least 1 friend"
//         abi.encode(3) for bonus task "refer 3+ friends"
//
//  TRAILER_WATCH:
//    abi.encode(string trailerId)
//    e.g. abi.encode("launch_v1")  — must match Redis key prefix
//
//  WAITLIST_SIGNUP:
//    abi.encode(uint256 cutoffTimestamp)
//    e.g. abi.encode(1735689600)  — Unix timestamp of cutoff
//
//  TOKEN_HOLD:
//    abi.encode(address tokenContract, uint256 minBalance, uint256 snapshotBlock)
//    tokenContract = address(0) means "any qualifying BSC gaming token"
//    (engine maintains a curated list of qualifying tokens)
//    e.g. abi.encode(address(0), 1, 12345678)
//
//  ON_CHAIN_TX:
//    abi.encode(address recipient, uint256 minAmountWei, uint256 minTxCount)
//    For fee payment: recipient = fee wallet, minAmountWei = $2 USD in BNB wei
//    For tx count: recipient = address(0), minAmountWei = 0, minTxCount = N
//    e.g. abi.encode(0xFeeWallet, 3333333333333333, 1)  (0.00333... BNB ≈ $2)
//
//  NFT_HOLD:
//    abi.encode(address collection, uint256 minBalance, uint256 snapshotBlock)
//    e.g. abi.encode(0xPartnerNFT, 1, 12345678)
//
//  CUSTOM_API:
//    abi.encode(string endpoint, string expectedKey, string expectedValue)
//    The engine calls GET {endpoint}?wallet=0x... and checks
//    response JSON for key == value.
//    e.g. abi.encode("https://api.cuecoin.io/task/engagement-all",
//                    "eligible", "true")
//
//  EMAIL_VERIFY:
//    abi.encode()  — empty bytes
//    Verification is purely off-chain (Redis record set by email flow).
//
//  QUIZ_COMPLETE:
//    abi.encode(string quizId, uint256 minScoreBps)
//    minScoreBps in basis points: 7000 = 70%, 10000 = 100%
//    e.g. abi.encode("cuecoin_knowledge_v1", 7000)
//
//  ════════════════════════════════════════════════════
//   ZERO-DOWNTIME TASK MANAGEMENT
//  ════════════════════════════════════════════════════
//
//  Adding a new task:
//    1. Call addTask() on this contract with full metadata.
//    2. Drop one TypeScript file in /backend/task-engine/tasks/
//       implementing the ITaskVerifier interface.
//    3. Call POST /admin/reload-plugin (hot reload, no restart).
//    4. Task is immediately visible in portal and counted in
//       eligibility on the next Merkle snapshot run.
//    No airdrop contract redeployment. No Merkle invalidation.
//
//  Updating a task (fix URL, change threshold, etc.):
//    Call updateTask() — changes name, description, ctaUrl,
//    bonusAmount, and/or params. Tier and verifierType are immutable
//    on a task once set (structural — change would break engine).
//    For a structural change: disable old task, add new one.
//
//  Disabling a task:
//    Call setTaskActive(taskId, false). Disabled tasks are excluded
//    from eligibility calculations on the next snapshot run.
//    Engagement threshold is checked against active task count.
//
//  ════════════════════════════════════════════════════
//   GOVERNANCE
//  ════════════════════════════════════════════════════
//
//  Owner (team multisig):
//    addTask, updateTask, setTaskActive, setDao
//
//  DAO address (CueDAO — if set):
//    setEngagementThreshold (the spec says "threshold DAO-configurable")
//
//  Owner OR DAO:
//    setEngagementThreshold
//
//  No timelock on task changes. This is intentional:
//    - Bad task = disable it instantly, no funds ever at risk
//    - Snapshot Merkle is regenerated on each run; stale tasks
//      simply don't appear in the next snapshot
//    - The airdrop contract itself holds the CUECOIN and is
//      governed separately
//
//  ════════════════════════════════════════════════════
//   GENESIS STATE (seeded in constructor)
//  ════════════════════════════════════════════════════
//
//  12 genesis tasks are seeded at deployment:
//    IDs 1–4:   Mandatory
//    IDs 5–9:   Engagement
//    IDs 10–12: Bonus
//
//  Some params (Discord guildId, Twitter tweetId, BNB fee amount,
//  snapshot blocks) are UNKNOWN at contract deploy time. These are
//  seeded with placeholder bytes and must be updated via updateTask()
//  before the airdrop claim window opens.
//
//  Tasks that require placeholder updates before launch:
//    Task 3  (DISCORD_JOIN):    set real guildId
//    Task 5  (TWITTER_RETWEET): set real tweetId
//    Task 7  (TRAILER_WATCH):   set real trailerId
//    Task 8  (WAITLIST_SIGNUP): set real cutoffTimestamp
//    Task 9  (TWITTER_QUOTE):   set real tweetId
//    Task 4  (ON_CHAIN_TX):     set real fee recipient + BNB amount
//    Task 12 (TOKEN_HOLD):      set real snapshotBlock
//
// ╚══════════════════════════════════════════════════════════════╝

import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title  CueTaskRegistry
 * @author CUECOIN Team
 * @notice On-chain task metadata registry for the CUECOIN standard airdrop.
 *         15 verifier types. 3 task tiers. Extensible without contract redeployment.
 *         Verification is performed off-chain by the task engine plugin system.
 */
contract CueTaskRegistry is Ownable2Step {

    // ═══════════════════════════════════════════════════════════
    //  CONSTANTS
    // ═══════════════════════════════════════════════════════════

    /// @notice Maximum number of tasks allowed per tier.
    uint256 public constant MAX_MANDATORY_TASKS  = 20;
    uint256 public constant MAX_ENGAGEMENT_TASKS = 50;
    uint256 public constant MAX_BONUS_TASKS      = 50;

    /// @notice Absolute maximum string lengths enforced on addTask/updateTask.
    uint256 public constant MAX_NAME_LEN        = 64;
    uint256 public constant MAX_DESCRIPTION_LEN = 256;
    uint256 public constant MAX_CTA_URL_LEN     = 128;

    /// @notice Maximum ABI-encoded params size (prevents griefing with huge blobs).
    uint256 public constant MAX_PARAMS_LEN = 1024;

    // ═══════════════════════════════════════════════════════════
    //  ENUMS
    // ═══════════════════════════════════════════════════════════

    /// @notice Three-tier task structure matching the spec.
    enum TaskTier {
        MANDATORY,   // All required. Currently 4 tasks.
        ENGAGEMENT,  // N-of-M required. Default 3-of-5.
        BONUS        // Optional, additive reward.
    }

    /// @notice 15 verifier types the off-chain engine supports.
    ///         The engine loads the matching TypeScript plugin for each type.
    ///         Values start at 1; 0 is reserved/invalid.
    enum VerifierType {
        INVALID,         // 0 — sentinel; never used
        WALLET_AGE,      // 1
        TWITTER_FOLLOW,  // 2
        TWITTER_RETWEET, // 3
        TWITTER_QUOTE,   // 4
        DISCORD_JOIN,    // 5
        DISCORD_ROLE,    // 6
        REFERRAL_COUNT,  // 7
        TRAILER_WATCH,   // 8
        WAITLIST_SIGNUP, // 9
        TOKEN_HOLD,      // 10
        ON_CHAIN_TX,     // 11
        NFT_HOLD,        // 12
        CUSTOM_API,      // 13
        EMAIL_VERIFY,    // 14
        QUIZ_COMPLETE    // 15
    }

    // ═══════════════════════════════════════════════════════════
    //  STRUCTS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Full task record.
     *
     * @param taskId        Auto-incremented ID starting at 1.
     * @param name          Short display name shown in the portal (≤64 chars).
     * @param description   What the user must do (≤256 chars).
     * @param ctaUrl        Where to do it — link opened by the CTA button (≤128 chars).
     * @param tier          MANDATORY / ENGAGEMENT / BONUS.
     * @param verifierType  Which off-chain plugin handles verification (1–15).
     * @param bonusAmount   CUECOIN-wei bonus for BONUS tier tasks; 0 for all others.
     *                      Drawn from the Standard P2E Unlock pool — no supply inflation.
     * @param params        ABI-encoded parameters decoded by the verifier plugin.
     *                      Schema documented per-type in the file header.
     * @param active        False = task is hidden and excluded from eligibility checks.
     *                      Can be toggled without deletion.
     * @param addedAt       block.timestamp when task was created.
     * @param updatedAt     block.timestamp of most recent updateTask() call.
     */
    struct Task {
        uint32      taskId;
        string      name;
        string      description;
        string      ctaUrl;
        TaskTier    tier;
        VerifierType verifierType;
        uint256     bonusAmount;
        bytes       params;
        bool        active;
        uint256     addedAt;
        uint256     updatedAt;
    }

    // ═══════════════════════════════════════════════════════════
    //  STATE
    // ═══════════════════════════════════════════════════════════

    /// @notice Next task ID to assign. Starts at 1.
    uint32 private _nextTaskId;

    /// @notice All tasks indexed by taskId.
    mapping(uint32 => Task) private _tasks;

    /// @notice All task IDs in insertion order (includes disabled).
    uint32[] private _allTaskIds;

    /// @notice Per-tier task ID lists (includes disabled).
    mapping(TaskTier => uint32[]) private _tierTaskIds;

    /// @notice Active task counts per tier (kept in sync with setTaskActive).
    mapping(TaskTier => uint256) private _activeCount;

    /// @notice How many ENGAGEMENT tasks are required to qualify.
    ///         Must always be ≤ _activeCount[ENGAGEMENT].
    uint256 public engagementThreshold;

    /// @notice Address permitted to call setEngagementThreshold (CueDAO).
    ///         Owner can also always call it. Zero = only owner.
    address public dao;

    // ═══════════════════════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Emitted when a new task is added.
     *         The off-chain engine subscribes to this to hot-reload its task list.
     */
    event TaskAdded(
        uint32 indexed taskId,
        TaskTier       tier,
        VerifierType   verifierType,
        string         name,
        uint256        bonusAmount,
        bytes          params
    );

    /**
     * @notice Emitted when a task's metadata is updated.
     *         Note: tier and verifierType are NOT updatable — those are structural.
     */
    event TaskUpdated(
        uint32 indexed taskId,
        string         name,
        string         description,
        string         ctaUrl,
        uint256        bonusAmount,
        bytes          params
    );

    /// @notice Emitted when a task is enabled or disabled.
    event TaskStatusChanged(uint32 indexed taskId, bool active);

    /// @notice Emitted when the engagement (tier-2) completion threshold changes.
    event EngagementThresholdChanged(uint256 oldThreshold, uint256 newThreshold);

    /// @notice Emitted when the DAO address is updated.
    event DaoAddressUpdated(address indexed oldDao, address indexed newDao);

    // ═══════════════════════════════════════════════════════════
    //  MODIFIERS
    // ═══════════════════════════════════════════════════════════

    modifier onlyOwnerOrDao() {
        require(
            msg.sender == owner() || (dao != address(0) && msg.sender == dao),
            "CueTaskRegistry: not owner or DAO"
        );
        _;
    }

    // ═══════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Deploy and seed all 12 genesis tasks.
     *
     *         Genesis tasks that require updates before airdrop opens:
     *           Task 3  (DISCORD_JOIN)    — set real guildId via updateTask
     *           Task 4  (ON_CHAIN_TX)     — set real fee recipient + BNB amount
     *           Task 5  (TWITTER_RETWEET) — set real tweetId
     *           Task 7  (TRAILER_WATCH)   — set real trailerId
     *           Task 8  (WAITLIST_SIGNUP) — set real cutoffTimestamp
     *           Task 9  (TWITTER_QUOTE)   — set real tweetId
     *           Task 12 (TOKEN_HOLD)      — set real snapshotBlock
     *
     * @param _dao  CueDAO address for governance calls. May be address(0) at
     *              deploy (set later via setDao when CueDAO is live).
     */
    constructor(address _dao) Ownable(msg.sender) {
        dao = _dao;

        // Default engagement threshold: 3-of-5 per spec
        engagementThreshold = 3;

        // ── MANDATORY TASKS (Tier 1) ──────────────────────────────────────

        // Task 1: Wallet age gate — most powerful sybil filter
        _seedTask(
            "Wallet Age \u2265 7 Days",
            "Your wallet must be at least 7 days old based on first on-chain transaction.",
            "https://bscscan.com",
            TaskTier.MANDATORY,
            VerifierType.WALLET_AGE,
            0,
            abi.encode(uint256(7)) // minAgeDays = 7
        );

        // Task 2: Twitter follow
        _seedTask(
            "Follow @CueCoin on X",
            "Follow the official CueCoin account on Twitter/X to stay updated.",
            "https://twitter.com/CueCoin",
            TaskTier.MANDATORY,
            VerifierType.TWITTER_FOLLOW,
            0,
            abi.encode("CueCoin") // handle (without @)
        );

        // Task 3: Discord join — guildId is placeholder; set before launch
        _seedTask(
            "Join CueCoin Discord",
            "Join the official CueCoin Discord server. It is our primary community hub.",
            "https://discord.gg/cuecoin",
            TaskTier.MANDATORY,
            VerifierType.DISCORD_JOIN,
            0,
            abi.encode("") // guildId: UPDATE VIA updateTask() BEFORE LAUNCH
        );

        // Task 4: Anti-bot BNB fee — recipient and amount are placeholder; set before launch
        // params: abi.encode(address recipient, uint256 minAmountWei, uint256 minTxCount)
        // minAmountWei: ~$2 USD in BNB at deploy time (e.g., 0.00333 BNB at $600/BNB)
        // Set to 0 placeholder — must be updated with real fee wallet and BNB amount
        _seedTask(
            "Pay Anti-Bot Fee ($2 BNB)",
            "Send a one-time $2 USD equivalent in BNB to the anti-bot fee address. "
            "This is the single most powerful sybil guard. Bots do not spend real money.",
            "https://app.cuecoin.io/claim/fee",
            TaskTier.MANDATORY,
            VerifierType.ON_CHAIN_TX,
            0,
            abi.encode(address(0), uint256(0), uint256(1))
            // UPDATE: recipient = fee wallet, minAmountWei = ~$2 BNB, minTxCount = 1
        );

        // ── ENGAGEMENT TASKS (Tier 2, 3-of-5 required) ───────────────────

        // Task 5: Retweet — tweetId is placeholder; set before launch
        _seedTask(
            "Retweet the Launch Post",
            "Retweet the official CueCoin launch announcement. "
            "Each retweet reaches your entire follower list \u2014 zero-cost amplification.",
            "https://twitter.com/CueCoin",
            TaskTier.ENGAGEMENT,
            VerifierType.TWITTER_RETWEET,
            0,
            abi.encode("") // tweetId: UPDATE VIA updateTask() BEFORE LAUNCH
        );

        // Task 6: Refer 1 friend (engagement threshold task)
        _seedTask(
            "Refer 1 Friend",
            "Refer at least 1 friend who completes the standard claim. "
            "Use your unique referral link from the dashboard.",
            "https://app.cuecoin.io/referral",
            TaskTier.ENGAGEMENT,
            VerifierType.REFERRAL_COUNT,
            0,
            abi.encode(uint256(1)) // minCount = 1
        );

        // Task 7: Watch trailer — trailerId is placeholder; set before launch
        _seedTask(
            "Watch the Gameplay Trailer",
            "Watch the official CueCoin gameplay trailer via your unique wallet-signed link. "
            "A trailer-watcher is not an airdrop farmer.",
            "https://app.cuecoin.io/trailer",
            TaskTier.ENGAGEMENT,
            VerifierType.TRAILER_WATCH,
            0,
            abi.encode("") // trailerId: UPDATE VIA updateTask() BEFORE LAUNCH
        );

        // Task 8: Waitlist signup — cutoffTimestamp is placeholder; set before launch
        _seedTask(
            "Early Waitlist Signup",
            "You signed up for the CueCoin waitlist before the early-bird cutoff date. "
            "This rewards our earliest supporters.",
            "https://app.cuecoin.io/waitlist",
            TaskTier.ENGAGEMENT,
            VerifierType.WAITLIST_SIGNUP,
            0,
            abi.encode(uint256(0)) // cutoffTimestamp: UPDATE VIA updateTask() BEFORE LAUNCH
        );

        // Task 9: Quote tweet — tweetId is placeholder; set before launch
        _seedTask(
            "Quote Tweet (50+ Characters)",
            "Quote tweet the official launch post with at least 50 characters of your own words. "
            "Authentic voice, permanent organic marketing content.",
            "https://twitter.com/CueCoin",
            TaskTier.ENGAGEMENT,
            VerifierType.TWITTER_QUOTE,
            0,
            abi.encode("", uint256(50))
            // tweetId: UPDATE VIA updateTask() BEFORE LAUNCH
        );

        // ── BONUS TASKS (Tier 3, optional) ───────────────────────────────

        // Task 10: Refer 3+ friends → +15 CUECOIN
        _seedTask(
            "Refer 3+ Friends",
            "Refer at least 3 friends who each complete the full standard claim. "
            "Earns +15 locked CUECOIN from the Standard P2E Unlock pool.",
            "https://app.cuecoin.io/referral",
            TaskTier.BONUS,
            VerifierType.REFERRAL_COUNT,
            15 ether, // 15 CUECOIN bonus
            abi.encode(uint256(3)) // minCount = 3
        );

        // Task 11: Complete ALL 5 engagement tasks → +10 CUECOIN
        // Uses CUSTOM_API: engine calls internal endpoint that checks tier-2 completion count.
        _seedTask(
            "Complete All 5 Engagement Tasks",
            "Complete all five engagement tasks (not just the required 3). "
            "Earns +10 locked CUECOIN from the Standard P2E Unlock pool.",
            "https://app.cuecoin.io/tasks",
            TaskTier.BONUS,
            VerifierType.CUSTOM_API,
            10 ether, // 10 CUECOIN bonus
            abi.encode(
                "https://task-engine.internal/check/all-engagement",
                "eligible",
                "true"
            )
        );

        // Task 12: Hold BSC gaming token → +5 CUECOIN
        // tokenContract = address(0) = "any qualifying token from engine's curated list"
        // snapshotBlock is placeholder — set before launch
        _seedTask(
            "Hold a BSC Gaming Token",
            "Hold any qualifying BSC gaming token in your wallet at the snapshot block. "
            "Rewards existing BSC gamers and cross-community acquisition. "
            "Earns +5 locked CUECOIN.",
            "https://app.cuecoin.io/tasks/bsc-token",
            TaskTier.BONUS,
            VerifierType.TOKEN_HOLD,
            5 ether, // 5 CUECOIN bonus
            abi.encode(address(0), uint256(1), uint256(0))
            // token=any qualifying, minBalance=1wei, snapshotBlock: UPDATE BEFORE LAUNCH
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  TASK MANAGEMENT — WRITE
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Add a new task to the registry.
     *
     *         The task is active immediately upon addition. If the engine is
     *         listening for TaskAdded events it will hot-reload the task.
     *
     *         Validation:
     *           - name must be non-empty and ≤ MAX_NAME_LEN
     *           - description ≤ MAX_DESCRIPTION_LEN
     *           - ctaUrl ≤ MAX_CTA_URL_LEN
     *           - verifierType must be valid (1–15, i.e. not INVALID)
     *           - bonusAmount must be zero for MANDATORY and ENGAGEMENT tasks
     *           - tier counts must not exceed per-tier maximums
     *           - params must not exceed MAX_PARAMS_LEN bytes
     *
     * @param name          Short display name (≤64 chars).
     * @param description   What the user must do (≤256 chars).
     * @param ctaUrl        Link for the CTA button (≤128 chars).
     * @param tier          MANDATORY / ENGAGEMENT / BONUS.
     * @param verifierType  One of the 15 VerifierType values (not INVALID).
     * @param bonusAmount   CUECOIN-wei bonus; must be 0 unless tier == BONUS.
     * @param params        ABI-encoded verifier parameters. See file header for schema.
     * @return taskId       The newly assigned task ID.
     */
    function addTask(
        string    calldata name,
        string    calldata description,
        string    calldata ctaUrl,
        TaskTier           tier,
        VerifierType       verifierType,
        uint256            bonusAmount,
        bytes     calldata params
    )
        external
        onlyOwner
        returns (uint32 taskId)
    {
        _validateTaskInput(name, description, ctaUrl, tier, verifierType, bonusAmount, params);
        _validateTierCapacity(tier);

        taskId = _nextTask();
        _tasks[taskId] = Task({
            taskId:       taskId,
            name:         name,
            description:  description,
            ctaUrl:       ctaUrl,
            tier:         tier,
            verifierType: verifierType,
            bonusAmount:  bonusAmount,
            params:       params,
            active:       true,
            addedAt:      block.timestamp,
            updatedAt:    block.timestamp
        });

        _allTaskIds.push(taskId);
        _tierTaskIds[tier].push(taskId);
        _activeCount[tier]++;

        emit TaskAdded(taskId, tier, verifierType, name, bonusAmount, params);
    }

    /**
     * @notice Update a task's mutable metadata fields.
     *
     *         TaskTier and VerifierType are IMMUTABLE after creation.
     *         Changing these structural fields would break the off-chain engine's
     *         plugin routing. To change tier or verifierType: disable this task
     *         and call addTask() with the new values.
     *
     *         All string and bytes validations apply identically to addTask().
     *
     * @param taskId      ID of the task to update.
     * @param name        New display name.
     * @param description New description.
     * @param ctaUrl      New CTA link.
     * @param bonusAmount New bonus (must be 0 for non-BONUS tier tasks).
     * @param params      New ABI-encoded params.
     */
    function updateTask(
        uint32    taskId,
        string    calldata name,
        string    calldata description,
        string    calldata ctaUrl,
        uint256            bonusAmount,
        bytes     calldata params
    )
        external
        onlyOwner
    {
        Task storage t = _requireTask(taskId);

        _validateTaskInput(
            name, description, ctaUrl,
            t.tier, t.verifierType,     // tier and verifierType cannot change
            bonusAmount, params
        );

        t.name        = name;
        t.description = description;
        t.ctaUrl      = ctaUrl;
        t.bonusAmount = bonusAmount;
        t.params      = params;
        t.updatedAt   = block.timestamp;

        emit TaskUpdated(taskId, name, description, ctaUrl, bonusAmount, params);
    }

    /**
     * @notice Enable or disable a task.
     *
     *         Disabled tasks are hidden from the portal and excluded from
     *         eligibility calculations on the next snapshot run. The task
     *         record is preserved and can be re-enabled at any time.
     *
     *         Disabling an ENGAGEMENT task may drop the active engagement
     *         count below engagementThreshold. If it does, this call reverts.
     *         Lower engagementThreshold first via setEngagementThreshold(),
     *         then disable the task.
     *
     * @param taskId  Task to change.
     * @param active  true = enabled, false = disabled.
     */
    function setTaskActive(uint32 taskId, bool active) external onlyOwner {
        Task storage t = _requireTask(taskId);

        if (t.active == active) return; // idempotent

        if (active) {
            // Re-enabling a previously disabled task. The task already occupies a slot
            // in _tierTaskIds so the per-tier cap is unaffected — do not re-check it.
            t.active = true;
            _activeCount[t.tier]++;
        } else {
            // Disabling: guard against making threshold unreachable
            if (t.tier == TaskTier.ENGAGEMENT) {
                uint256 newActiveCount = _activeCount[TaskTier.ENGAGEMENT] - 1;
                require(
                    newActiveCount >= engagementThreshold,
                    "CueTaskRegistry: disabling would make threshold unreachable"
                );
            }
            t.active = false;
            _activeCount[t.tier]--;
        }

        t.updatedAt = block.timestamp;
        emit TaskStatusChanged(taskId, active);
    }

    // ═══════════════════════════════════════════════════════════
    //  GOVERNANCE — ENGAGEMENT THRESHOLD
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Set how many ENGAGEMENT tasks a claimant must complete.
     *
     *         The spec states this is "DAO-configurable." Both the owner and
     *         the DAO address (if set) may call this.
     *
     *         Constraints:
     *           - n ≥ 1 (threshold of 0 would make engagement meaningless)
     *           - n ≤ active ENGAGEMENT task count
     *             (cannot require more tasks than exist)
     *
     *         Note: reducing the threshold is always allowed as long as n ≥ 1.
     *         Raising the threshold requires enough active engagement tasks.
     *
     * @param n  New required count (e.g., 3 for "3-of-5").
     */
    function setEngagementThreshold(uint256 n) external onlyOwnerOrDao {
        require(n >= 1, "CueTaskRegistry: threshold must be at least 1");
        require(
            n <= _activeCount[TaskTier.ENGAGEMENT],
            "CueTaskRegistry: threshold exceeds active engagement task count"
        );

        uint256 old = engagementThreshold;
        engagementThreshold = n;

        emit EngagementThresholdChanged(old, n);
    }

    // ═══════════════════════════════════════════════════════════
    //  OWNER ADMIN
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Set the DAO address permitted to call setEngagementThreshold.
     *         Pass address(0) to restrict threshold changes to owner only.
     */
    function setDao(address newDao) external onlyOwner {
        emit DaoAddressUpdated(dao, newDao);
        dao = newDao;
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW — SINGLE TASK
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Fetch a single task by ID. Reverts if the ID does not exist.
     */
    function getTask(uint32 taskId) external view returns (Task memory) {
        return _requireTask(taskId);
    }

    /**
     * @notice Check whether a task ID has been assigned.
     */
    function taskExists(uint32 taskId) external view returns (bool) {
        return taskId >= 1 && taskId < _nextTaskId;
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW — BULK QUERIES
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Return ALL tasks in insertion order (active and inactive).
     *         Intended for admin tools and full registry audits.
     *         Gas cost grows linearly with task count; do not call on-chain
     *         in high-gas contexts.
     */
    function getAllTasks() external view returns (Task[] memory tasks) {
        uint256 count = _allTaskIds.length;
        tasks = new Task[](count);
        for (uint256 i = 0; i < count; i++) {
            tasks[i] = _tasks[_allTaskIds[i]];
        }
    }

    /**
     * @notice Return only ACTIVE tasks across all tiers.
     *         This is the primary query used by the frontend task dashboard.
     */
    function getActiveTasks() external view returns (Task[] memory tasks) {
        uint256 count = _allTaskIds.length;
        uint256 activeCount;

        // Two-pass: count then fill (avoids dynamic array resize)
        for (uint256 i = 0; i < count; i++) {
            if (_tasks[_allTaskIds[i]].active) activeCount++;
        }
        tasks = new Task[](activeCount);
        uint256 idx;
        for (uint256 i = 0; i < count; i++) {
            Task storage t = _tasks[_allTaskIds[i]];
            if (t.active) tasks[idx++] = t;
        }
    }

    /**
     * @notice Return all tasks (active and inactive) for a specific tier.
     */
    function getTasksByTier(TaskTier tier)
        external
        view
        returns (Task[] memory tasks)
    {
        uint32[] storage ids = _tierTaskIds[tier];
        tasks = new Task[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            tasks[i] = _tasks[ids[i]];
        }
    }

    /**
     * @notice Return only ACTIVE tasks for a specific tier.
     *         Primary query for the off-chain eligibility engine per-tier.
     */
    function getActiveTasksByTier(TaskTier tier)
        external
        view
        returns (Task[] memory tasks)
    {
        uint32[] storage ids = _tierTaskIds[tier];
        uint256 activeCount;

        for (uint256 i = 0; i < ids.length; i++) {
            if (_tasks[ids[i]].active) activeCount++;
        }
        tasks = new Task[](activeCount);
        uint256 idx;
        for (uint256 i = 0; i < ids.length; i++) {
            Task storage t = _tasks[ids[i]];
            if (t.active) tasks[idx++] = t;
        }
    }

    /**
     * @notice Return the task IDs for a tier (active and inactive).
     *         Cheaper than returning full Task structs when only IDs are needed.
     */
    function getTaskIdsByTier(TaskTier tier)
        external
        view
        returns (uint32[] memory)
    {
        return _tierTaskIds[tier];
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW — COUNTS & CONFIG
    // ═══════════════════════════════════════════════════════════

    /// @notice Total number of tasks ever registered (includes disabled).
    function taskCount() external view returns (uint32) {
        return _nextTaskId == 0 ? 0 : _nextTaskId - 1;
    }

    /// @notice Active task count for a specific tier.
    function activeTaskCountByTier(TaskTier tier) external view returns (uint256) {
        return _activeCount[tier];
    }

    /// @notice Total active task count across all tiers.
    function totalActiveTaskCount() external view returns (uint256) {
        return
            _activeCount[TaskTier.MANDATORY] +
            _activeCount[TaskTier.ENGAGEMENT] +
            _activeCount[TaskTier.BONUS];
    }

    /**
     * @notice Full eligibility config snapshot for the off-chain engine.
     *         Returns everything needed to compute a claimant's task score.
     *
     * @return mandatory         All active mandatory tasks.
     * @return engagement        All active engagement tasks.
     * @return bonus             All active bonus tasks.
     * @return threshold         Current engagementThreshold.
     * @return maxBonusCuecoin   Sum of all active bonus task bonusAmounts.
     */
    function getEligibilityConfig()
        external
        view
        returns (
            Task[]  memory mandatory,
            Task[]  memory engagement,
            Task[]  memory bonus,
            uint256        threshold,
            uint256        maxBonusCuecoin
        )
    {
        mandatory  = _getActiveForTier(TaskTier.MANDATORY);
        engagement = _getActiveForTier(TaskTier.ENGAGEMENT);
        bonus      = _getActiveForTier(TaskTier.BONUS);
        threshold  = engagementThreshold;

        for (uint256 i = 0; i < bonus.length; i++) {
            maxBonusCuecoin += bonus[i].bonusAmount;
        }
    }

    /**
     * @notice Validate that a given set of task IDs constitutes a complete
     *         mandatory + engagement pass. Reverts with a reason if not.
     *
     *         Used by the off-chain engine to do a quick sanity check of its
     *         computed task sets before submitting a Merkle root.
     *
     * @param completedTaskIds  Array of task IDs the claimant has completed.
     * @return eligible         True if mandatory + engagement threshold satisfied.
     * @return completedMandatory  Count of mandatory tasks completed.
     * @return completedEngagement Count of engagement tasks completed.
     */
    function checkEligibility(uint32[] calldata completedTaskIds)
        external
        view
        returns (
            bool    eligible,
            uint256 completedMandatory,
            uint256 completedEngagement
        )
    {
        // Build O(1) lookup set over task IDs.
        // _nextTaskId is the next-to-assign ID, so valid IDs are 1.._nextTaskId-1.
        // Allocate _nextTaskId slots so index == taskId is always in-bounds.
        bool[] memory completed = new bool[](_nextTaskId);
        for (uint256 i = 0; i < completedTaskIds.length; i++) {
            uint32 id = completedTaskIds[i];
            if (id >= 1 && id < _nextTaskId) {
                completed[id] = true;
            }
        }

        // Check mandatory tasks
        uint32[] storage mandatoryIds = _tierTaskIds[TaskTier.MANDATORY];
        for (uint256 i = 0; i < mandatoryIds.length; i++) {
            Task storage t = _tasks[mandatoryIds[i]];
            if (!t.active) continue;
            if (completed[t.taskId]) completedMandatory++;
        }

        // Check engagement tasks
        uint32[] storage engagementIds = _tierTaskIds[TaskTier.ENGAGEMENT];
        for (uint256 i = 0; i < engagementIds.length; i++) {
            Task storage t = _tasks[engagementIds[i]];
            if (!t.active) continue;
            if (completed[t.taskId]) completedEngagement++;
        }

        uint256 activeMandatoryCount = _activeCount[TaskTier.MANDATORY];
        eligible =
            completedMandatory == activeMandatoryCount &&
            completedEngagement >= engagementThreshold;
    }

    /**
     * @notice Compute the total bonus CUECOIN earned from completed bonus tasks.
     *
     * @param completedTaskIds  Array of task IDs the claimant has completed.
     * @return bonusTotal       Total bonus CUECOIN-wei from completed bonus tasks.
     */
    function computeBonus(uint32[] calldata completedTaskIds)
        external
        view
        returns (uint256 bonusTotal)
    {
        bool[] memory completed = new bool[](_nextTaskId);
        for (uint256 i = 0; i < completedTaskIds.length; i++) {
            uint32 id = completedTaskIds[i];
            if (id >= 1 && id < _nextTaskId) {
                completed[id] = true;
            }
        }

        uint32[] storage bonusIds = _tierTaskIds[TaskTier.BONUS];
        for (uint256 i = 0; i < bonusIds.length; i++) {
            Task storage t = _tasks[bonusIds[i]];
            if (!t.active) continue;
            if (completed[t.taskId]) {
                bonusTotal += t.bonusAmount;
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — HELPERS
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev Seed a genesis task without owner-check (called from constructor only).
     */
    function _seedTask(
        string memory  name,
        string memory  description,
        string memory  ctaUrl,
        TaskTier       tier,
        VerifierType   verifierType,
        uint256        bonusAmount,
        bytes memory   params
    ) internal {
        uint32 taskId = _nextTask();
        _tasks[taskId] = Task({
            taskId:       taskId,
            name:         name,
            description:  description,
            ctaUrl:       ctaUrl,
            tier:         tier,
            verifierType: verifierType,
            bonusAmount:  bonusAmount,
            params:       params,
            active:       true,
            addedAt:      block.timestamp,
            updatedAt:    block.timestamp
        });

        _allTaskIds.push(taskId);
        _tierTaskIds[tier].push(taskId);
        _activeCount[tier]++;

        emit TaskAdded(taskId, tier, verifierType, name, bonusAmount, params);
    }

    /// @dev Increment and return the next task ID.
    function _nextTask() internal returns (uint32 id) {
        if (_nextTaskId == 0) _nextTaskId = 1;
        id = _nextTaskId++;
    }

    /// @dev Fetch a task, reverting if it doesn't exist.
    function _requireTask(uint32 taskId) internal view returns (Task storage t) {
        require(
            taskId >= 1 && taskId < _nextTaskId,
            "CueTaskRegistry: task does not exist"
        );
        t = _tasks[taskId];
    }

    /// @dev Shared validation logic for addTask and updateTask.
    function _validateTaskInput(
        string    memory name,
        string    memory description,
        string    memory ctaUrl,
        TaskTier         tier,
        VerifierType     verifierType,
        uint256          bonusAmount,
        bytes     memory params
    ) internal pure {
        require(bytes(name).length > 0,                     "CueTaskRegistry: name is empty");
        require(bytes(name).length <= MAX_NAME_LEN,         "CueTaskRegistry: name too long");
        require(bytes(description).length <= MAX_DESCRIPTION_LEN, "CueTaskRegistry: description too long");
        require(bytes(ctaUrl).length <= MAX_CTA_URL_LEN,   "CueTaskRegistry: ctaUrl too long");
        require(params.length <= MAX_PARAMS_LEN,           "CueTaskRegistry: params too long");
        require(verifierType != VerifierType.INVALID,      "CueTaskRegistry: invalid verifierType");
        require(uint8(verifierType) <= 15,                 "CueTaskRegistry: verifierType out of range");

        // bonusAmount must be zero for non-BONUS tasks
        if (tier != TaskTier.BONUS) {
            require(bonusAmount == 0, "CueTaskRegistry: bonusAmount must be 0 for non-BONUS tasks");
        }
    }

    /// @dev Check that a tier hasn't hit its cap before adding a task.
    function _validateTierCapacity(TaskTier tier) internal view {
        if (tier == TaskTier.MANDATORY) {
            // Count all mandatory tasks (including disabled) for total capacity
            require(
                _tierTaskIds[TaskTier.MANDATORY].length < MAX_MANDATORY_TASKS,
                "CueTaskRegistry: mandatory task cap reached"
            );
        } else if (tier == TaskTier.ENGAGEMENT) {
            require(
                _tierTaskIds[TaskTier.ENGAGEMENT].length < MAX_ENGAGEMENT_TASKS,
                "CueTaskRegistry: engagement task cap reached"
            );
        } else {
            require(
                _tierTaskIds[TaskTier.BONUS].length < MAX_BONUS_TASKS,
                "CueTaskRegistry: bonus task cap reached"
            );
        }
    }

    /// @dev Internal version of getActiveTasksByTier for getEligibilityConfig.
    function _getActiveForTier(TaskTier tier)
        internal
        view
        returns (Task[] memory tasks)
    {
        uint32[] storage ids = _tierTaskIds[tier];
        uint256 activeCount;
        for (uint256 i = 0; i < ids.length; i++) {
            if (_tasks[ids[i]].active) activeCount++;
        }
        tasks = new Task[](activeCount);
        uint256 idx;
        for (uint256 i = 0; i < ids.length; i++) {
            Task storage t = _tasks[ids[i]];
            if (t.active) tasks[idx++] = t;
        }
    }
}
