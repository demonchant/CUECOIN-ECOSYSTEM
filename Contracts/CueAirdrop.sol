// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ╔══════════════════════════════════════════════════════════════╗
//  CUEAIRDROP  ·  v3.0  ·  Security-Hardened
//  CUECOIN Ecosystem  ·  BNB Smart Chain
//
//  v1 features (carried forward):
//   [V1-1]  Two-tier Merkle airdrop (Premium + Standard)
//   [V1-2]  EIP-712 signed UnlockCertificates (AWS KMS oracle)
//   [V1-3]  Per-user nonce replay protection on unlock certs
//   [V1-4]  Play-to-unlock: 10 milestones × 10 % = 100 games
//   [V1-5]  Bonus task tokens: Merkle leaf encodes (wallet, amount)
//   [V1-6]  ToS versioning: on-chain acceptance required per version
//   [V1-7]  Compliance oracle: individual wallet blocks (not geographic)
//   [V1-8]  Premium auto-deploy at PREMIUM_CAP (400k) claims — hardcoded
//   [V1-9]  Standard fee deployment — callable by owner any time
//   [V1-10] Ownable2Step, ReentrancyGuard, Pausable, SafeERC20
//
//  v2 improvements:
//   [V2-1]  BNB accounting separation — premium fees tracked independently
//            so _deployPremiumFunds() only deploys what it should
//   [V2-2]  totalActiveLocks counter — contract balance check uses this,
//            not raw balanceOf, preventing false-fail on full pools
//   [V2-3]  Timelock on sensitive owner ops (48h delay): setOracleSigner,
//            setComplianceOracle, setPremiumDestinations,
//            setStandardDestinations, incrementTosVersion
//   [V2-4]  Minimum certificate validity window (5 min) — prevents
//            instantly-expiring certs that race with block inclusion
//   [V2-5]  Standard fee deployment cooldown (7 days) replaces the
//            misleading one-shot flag
//   [V2-6]  Emergency BNB rescue — callable before fundsDeployed only
//   [V2-7]  UnlockRelayed event — distinguishes self-unlock from relayer
//   [V2-8]  airdropConfig() view — exposes all constants in one call
//   [V2-9]  cueCoinBalance() view — convenience for relayers/frontend
//   [V2-10] Timelock status view + cancel
//
//  v3 security hardening (audit-driven):
//   [V3-1]  ORACLE KEY COMPROMISE DEFENCE — dual-oracle 2-of-2 threshold.
//            unlockTokens() now requires TWO valid EIP-712 signatures:
//            one from oracleSigner (AWS KMS) and one from oracleSigner2
//            (independent HSM / Fireblocks). A single compromised key
//            cannot drain any locked tokens.
//   [V3-2]  PER-BLOCK UNLOCK RATE LIMIT — globalUnlockCapPerBlock
//            (default: 500,000 CUECOIN / block). Limits blast radius of
//            any oracle compromise to a fraction of total locked supply
//            per block. Configurable by owner (timelocked).
//   [V3-3]  PREMIUM DEPLOY DECOUPLED FROM CLAIM — auto-deploy is now
//            guarded by (premiumClaimCount >= PREMIUM_CAP) rather than
//            (== PREMIUM_CAP). Claim #400,000 no longer atomically
//            triggers deployment. Instead, deployment fires in a
//            separate call via triggerPremiumDeploy() (owner or
//            anyone after cap is reached). This eliminates the
//            "400,000th claimer griefing" attack where a reverting
//            destination permanently blocks the final claim.
//   [V3-4]  TIMELOCK OPERATION UNIQUENESS — opId now includes
//            keccak256(msg.data) so setOracleSigner(A) and
//            setOracleSigner(B) queue as distinct operations with
//            independent 48-hour timers. Eliminates governance
//            collision and admin lockout risk.
//   [V3-5]  STANDARD BNB ACCOUNTING SEPARATION — standardBNBAccumulated
//            tracks standard fee revenue independently of premium BNB.
//            rescueBNB() can only withdraw BNB above both tracked pools,
//            preventing the owner from draining standard fee revenue
//            before the 7-day deployment cooldown expires.
// ╚══════════════════════════════════════════════════════════════╝

import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  CueAirdrop
 * @author CUECOIN Team
 * @notice Manages the two-tier CUECOIN airdrop campaign.
 *
 * ══════════════════════════════════════════════════════════
 *  PREMIUM TIER  (400,000 cap)
 * ══════════════════════════════════════════════════════════
 *   • Entry fee: $20 equivalent in BNB (updated by owner)
 *   • Gate:      Merkle proof — curated whitelist only
 *   • Award:     250 CUECOIN — released instantly on claim
 *   • Deploy:    Once premiumClaimCount >= 400,000, the
 *                owner (or anyone) calls triggerPremiumDeploy().
 *                Decoupled from the final claim to prevent
 *                griefing via a reverting destination contract.
 *
 *   Premium BNB split:
 *     50 %  →  CueLiquidityLocker  (LP locked 18 months)
 *     20 %  →  Game Development Multisig
 *     15 %  →  Tournament Prize Seed (CueTournament.sol)
 *     10 %  →  Marketing Wallet
 *      5 %  →  DAO Emergency Reserve (CueDAO.sol)
 *
 * ══════════════════════════════════════════════════════════
 *  STANDARD TIER  (5,000,000 cap)
 * ══════════════════════════════════════════════════════════
 *   • Entry fee: $2 equivalent in BNB (anti-bot gate)
 *   • Gate:      Merkle proof — leaf encodes (wallet, totalCuecoin)
 *                where totalCuecoin = 50 base + 0–30 task bonuses
 *   • Award:     LOCKED. Released 10 % per 10 verified games.
 *   • Full unlock: 100 games → 100 % of claim (50–80 CUECOIN)
 *
 *   Standard fee split (owner-callable, any time, 7-day cooldown):
 *     40 %  →  Game Development Multisig
 *     30 %  →  Infrastructure / Server Costs wallet
 *     20 %  →  Additional DEX Liquidity (CueLiquidityLocker)
 *     10 %  →  DAO Treasury (CueDAO.sol)
 *
 * ══════════════════════════════════════════════════════════
 *  PLAY-TO-UNLOCK ORACLE  (EIP-712, 2-of-2 dual-oracle)
 * ══════════════════════════════════════════════════════════
 *   The Unity Authoritative Server validates each completed
 *   wager match. After each 10-game milestone, BOTH oracle
 *   keys sign an UnlockCertificate. The on-chain verifier
 *   requires both signatures (oracleSigner + oracleSigner2).
 *   Either the player or a backend relayer submits on-chain.
 *   Certificates carry a nonce (replay protection) and a
 *   24-hour expiry with a 5-minute minimum validity window.
 *   A per-block rate limit caps max CUECOIN unlocked globally.
 *
 * ══════════════════════════════════════════════════════════
 *  TASK SYSTEM INTEGRATION
 * ══════════════════════════════════════════════════════════
 *   The CueTaskRegistry backend computes each standard
 *   claimant's verified task completion score and encodes
 *   their bonus CUECOIN directly into the Merkle leaf.
 *   Task bonus tiers:
 *     Tier 1 (mandatory) + Tier 2 (3-of-5 engagement) = 50 base
 *     Bonus T2 (all 5 tasks)                           = +10
 *     Bonus T3 referral (3+ friends)                   = +15
 *     Bonus T3 BSC token hold                          = +5
 *     Maximum possible:                                = 80 CUECOIN
 *
 * ══════════════════════════════════════════════════════════
 *  ACCESS CONTROL
 * ══════════════════════════════════════════════════════════
 *   Open globally — no geographic IP blocking.
 *   ToS on-chain acceptance is the sole gate.
 *   Individual wallet blocks (court orders, confirmed fraud)
 *   are handled by the compliance oracle only.
 *   Sensitive owner operations go through a 48-hour timelock.
 *
 * ══════════════════════════════════════════════════════════
 *  TOKEN ALLOCATION BUDGET
 * ══════════════════════════════════════════════════════════
 *   Premium:  400,000 × 250     = 100,000,000 CUECOIN
 *   Standard: 5,000,000 × up to 80 base+bonus
 *             worst case: 5M × 80  = 400,000,000 CUECOIN
 *             (in practice: most users earn 50–65 CUECOIN)
 *   Contract budget must be funded with 350,000,000 CUECOIN
 *   (accounting for average, not worst-case bonus distribution).
 *   Owner is responsible for topping up if bonus rates exceed
 *   projections — this is monitored by the backend.
 */
contract CueAirdrop is Ownable2Step, ReentrancyGuard, Pausable, EIP712 {
    using SafeERC20 for IERC20;
    using ECDSA     for bytes32;

    // ═══════════════════════════════════════════════════════════
    //  CONSTANTS
    // ═══════════════════════════════════════════════════════════

    // ── Token awards ──
    uint256 public constant PREMIUM_AWARD        = 250 ether;   // 250 CUECOIN
    uint256 public constant STANDARD_BASE_AWARD  = 50 ether;    // 50 CUECOIN base
    uint256 public constant STANDARD_MAX_BONUS   = 30 ether;    // 30 CUECOIN max bonus
    uint256 public constant STANDARD_MAX_AWARD   = STANDARD_BASE_AWARD + STANDARD_MAX_BONUS; // 80

    // ── Caps ──
    uint256 public constant PREMIUM_CAP   = 400_000;
    uint256 public constant STANDARD_CAP  = 5_000_000;

    // ── Play-to-unlock schedule ──
    uint256 public constant GAMES_PER_MILESTONE   = 10;   // unlock every 10 games
    uint256 public constant MILESTONES_TOTAL       = 10;   // 10 milestones = 100 %
    uint256 public constant GAMES_FOR_FULL_UNLOCK  = GAMES_PER_MILESTONE * MILESTONES_TOTAL; // 100

    // ── Premium fund deployment splits (basis points, sum = 10_000) ──
    uint16 public constant PREM_SPLIT_LIQUIDITY   = 5_000; // 50 %
    uint16 public constant PREM_SPLIT_DEVELOPMENT = 2_000; // 20 %
    uint16 public constant PREM_SPLIT_TOURNAMENT  = 1_500; // 15 %
    uint16 public constant PREM_SPLIT_MARKETING   = 1_000; // 10 %
    uint16 public constant PREM_SPLIT_RESERVE     =   500; //  5 %

    // ── Standard fee splits (basis points, sum = 10_000) ──
    uint16 public constant STD_SPLIT_DEVELOPMENT  = 4_000; // 40 %
    uint16 public constant STD_SPLIT_SERVERS      = 3_000; // 30 %
    uint16 public constant STD_SPLIT_LIQUIDITY    = 2_000; // 20 %
    uint16 public constant STD_SPLIT_DAO          = 1_000; // 10 %

    // ── EIP-712 type hash ──
    bytes32 public constant UNLOCK_TYPEHASH = keccak256(
        "UnlockCertificate(address user,uint256 gamesPlayed,uint256 nonce,uint256 expiry)"
    );

    // ── Certificate validity bounds ──
    uint256 public constant CERT_MIN_VALID_WINDOW = 5 minutes;  // [V2-4] minimum validity
    uint256 public constant CERT_MAX_EXPIRY_WINDOW = 24 hours;  // maximum validity

    // ── [V2-5] Standard fee deployment cooldown ──
    uint256 public constant STD_DEPLOY_COOLDOWN = 7 days;

    // ── [V2-3] Timelock ──
    uint256 public constant TIMELOCK_DELAY = 48 hours;
    uint256 public constant TIMELOCK_GRACE = 14 days;

    // ── [V3-2] Per-block unlock rate limit — default cap ──
    // Maximum CUECOIN that can be unlocked across ALL users in a single block.
    // 500,000 CUECOIN / block caps oracle-compromise blast radius to ~0.125%
    // of worst-case locked supply per block. Owner can adjust (timelocked).
    uint256 public constant DEFAULT_UNLOCK_CAP_PER_BLOCK = 500_000 ether;

    // ─────────────────────────────────────────────────────────────
    //  STATE VARIABLES
    // ─────────────────────────────────────────────────────────────

    // ── Core token ──
    IERC20 public immutable cueCoin;

    // ── Merkle roots ──
    /// @notice Premium whitelist root. Leaf = keccak256(abi.encodePacked(address)).
    bytes32 public premiumMerkleRoot;

    /// @notice Standard eligibility root.
    ///         Leaf = keccak256(abi.encodePacked(address, totalCuecoinWei))
    ///         where totalCuecoinWei = base (50e18) + bonus (0–30e18).
    bytes32 public standardMerkleRoot;

    // ── Fees (BNB-wei, set at deploy, updatable while claims closed) ──
    uint256 public premiumFeeWei;
    uint256 public standardFeeWei;

    // ── Claim state ──
    uint256 public premiumClaimCount;
    uint256 public standardClaimCount;
    bool    public claimOpen;
    bool    public fundsDeployed;       // Premium auto-deploy has fired

    // ── [V2-1] BNB accounting ──
    // Tracks how much BNB arrived specifically as premium fees.
    // _deployPremiumFunds() deploys ONLY this amount, not the total balance.
    uint256 public premiumBNBAccumulated;

    // ── [V2-5] Standard fee deployment timestamp ──
    uint256 public lastStdDeployTimestamp;

    // ── [V2-2] Active lock counter ──
    // Total CUECOIN currently locked for standard claimants (not yet unlocked).
    // Used for the balance sufficiency check in claimStandard.
    uint256 public totalActiveLocks;

    // ── ToS versioning ──
    uint256 public currentTosVersion;

    // ── Destination addresses (premium) ──
    address public liquidityLocker;      // CueLiquidityLocker.sol
    address public developmentMultisig;  // Gnosis Safe 3-of-5
    address public tournamentSeed;       // CueTournament.sol
    address public marketingWallet;      // Gnosis Safe 3-of-5
    address public daoReserve;           // CueDAO.sol

    // ── Destination addresses (standard) ──
    address public serverCostWallet;     // Ops infrastructure wallet

    // ── Oracle addresses ──
    address public oracleSigner;         // AWS KMS — signs UnlockCertificates (primary)
    address public oracleSigner2;        // [V3-1] Independent HSM/Fireblocks — secondary oracle
    address public complianceOracle;     // Compliance team — individual wallet blocks

    // ── [V3-2] Per-block unlock rate limit ──
    uint256 public globalUnlockCapPerBlock;   // Max CUECOIN unlockable in any single block
    uint256 public blockUnlockAccumulator;    // CUECOIN unlocked so far in current block
    uint256 public lastUnlockBlock;           // Block number of most recent unlock call

    // ── [V3-5] Standard BNB accounting ──
    // Tracks standard fee revenue separately so rescueBNB() cannot drain it.
    uint256 public standardBNBAccumulated;

    // ── Per-user claim and lock state ──
    mapping(address => bool) public premiumClaimed;
    mapping(address => bool) public standardClaimed;
    mapping(address => uint256) public tosVersionAccepted;
    mapping(address => bool)    public isBlocked;

    struct StandardLock {
        uint256 totalLocked;     // CUECOIN locked at claim (base + bonus)
        uint256 totalUnlocked;   // CUECOIN released so far
        uint256 gamesVerified;   // Highest verified game count from oracle
        uint256 nonce;           // Monotonic replay-protection counter
    }
    mapping(address => StandardLock) public standardLocks;

    // ── [V2-3] On-chain timelock ──
    mapping(bytes32 => uint256) public timelockEta;
    mapping(bytes32 => bool)    public timelockExecuted;

    // ─────────────────────────────────────────────────────────────
    //  EVENTS
    // ─────────────────────────────────────────────────────────────

    event ClaimOpenUpdated(bool isOpen, uint256 timestamp);
    event MerkleRootsUpdated(bytes32 premiumRoot, bytes32 standardRoot, uint256 timestamp);

    event PremiumClaimed(
        address indexed user,
        uint256 cueCoinAwarded,
        uint256 feePaid,
        uint256 claimNumber
    );

    event StandardClaimed(
        address indexed user,
        uint256 totalLocked,
        uint256 baseAmount,
        uint256 bonusAmount,
        uint256 feePaid,
        uint256 claimNumber
    );

    event TokensUnlocked(
        address indexed user,
        address indexed relayer,      // [V2-7] address(0) if self-submitted
        uint256 amountUnlocked,
        uint256 totalUnlocked,
        uint256 totalLocked,
        uint256 gamesVerified
    );

    event PremiumFundsDeployed(
        uint256 totalBNB,
        uint256 liquidityAmount,
        uint256 developmentAmount,
        uint256 tournamentAmount,
        uint256 marketingAmount,
        uint256 reserveAmount,
        uint256 timestamp
    );

    event StandardFundsDeployed(
        uint256 totalBNB,
        uint256 developmentAmount,
        uint256 serverAmount,
        uint256 liquidityAmount,
        uint256 daoAmount,
        uint256 timestamp
    );

    event OracleSignerUpdated(address indexed oldSigner, address indexed newSigner);
    event OracleSigner2Updated(address indexed oldSigner2, address indexed newSigner2); // [V3-1]
    event UnlockCapUpdated(uint256 newCapPerBlock);                                      // [V3-2]
    event PremiumDeployTriggered(address indexed triggeredBy);                           // [V3-3]
    event ComplianceOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event AddressBlocked(address indexed account, string reason);
    event AddressUnblocked(address indexed account);
    event FeesUpdated(uint256 premiumFeeWei, uint256 standardFeeWei);
    event TosVersionUpdated(uint256 newVersion);
    event TosAccepted(address indexed user, uint256 version, uint256 timestamp);
    event DestinationsUpdated(string tier);
    event BNBRescued(address indexed to, uint256 amount); // [V2-6]

    // [V2-3] Timelock events
    event TimelockQueued(bytes32 indexed operationId, bytes32 action, uint256 eta);
    event TimelockExecuted(bytes32 indexed operationId, bytes32 action);
    event TimelockCancelled(bytes32 indexed operationId);

    // ─────────────────────────────────────────────────────────────
    //  MODIFIERS
    // ─────────────────────────────────────────────────────────────

    modifier onlyComplianceOrOwner() {
        require(
            msg.sender == complianceOracle || msg.sender == owner(),
            "CueAirdrop: not compliance oracle or owner"
        );
        _;
    }

    /**
     * @dev [V2-3 / V3-4] Two-call timelock for sensitive owner operations.
     *
     *      CALL 1 — Queues the operation. Returns immediately.
     *               TimelockQueued event emitted. ETA = now + 48 hours.
     *
     *      CALL 2 (after 48 h, within 14 days) — Executes the function body.
     *               TimelockExecuted event emitted.
     *
     *      [V3-4] opId now includes keccak256(msg.data) so two different
     *      calls to the same function (e.g. setOracleSigner(A) vs
     *      setOracleSigner(B)) get independent operation IDs and independent
     *      48-hour timers. This eliminates governance collision where queuing
     *      one value would silently apply to a different value.
     */
    modifier timelocked(bytes32 action) {
        // [V3-4] Include calldata hash — different arguments = different opId
        bytes32 opId = keccak256(abi.encodePacked(action, msg.sender, keccak256(msg.data)));
        if (timelockEta[opId] == 0) {
            // First call: queue
            uint256 eta = block.timestamp + TIMELOCK_DELAY;
            timelockEta[opId] = eta;
            emit TimelockQueued(opId, action, eta);
            return;
        }
        // Second call: validate and execute
        require(block.timestamp >= timelockEta[opId],                      "CueAirdrop: timelock not elapsed");
        require(block.timestamp <  timelockEta[opId] + TIMELOCK_GRACE,     "CueAirdrop: timelock expired");
        require(!timelockExecuted[opId],                                    "CueAirdrop: already executed");
        timelockExecuted[opId] = true;
        emit TimelockExecuted(opId, action);
        _;
    }

    // ─────────────────────────────────────────────────────────────
    //  CONSTRUCTOR
    // ─────────────────────────────────────────────────────────────

    /**
     * @param _cueCoin             CueCoin token contract address.
     * @param _premiumFeeWei       BNB-wei equivalent of $20 USD at deploy time.
     * @param _standardFeeWei      BNB-wei equivalent of $2 USD at deploy time.
     * @param _liquidityLocker     CueLiquidityLocker — receives 50% of premium BNB.
     * @param _developmentMultisig Gnosis Safe 3-of-5 — game dev fund.
     * @param _tournamentSeed      CueTournament.sol — prize pool seed.
     * @param _marketingWallet     Gnosis Safe — marketing & listings.
     * @param _daoReserve          CueDAO.sol — emergency reserve.
     * @param _serverCostWallet    Ops wallet — server/infrastructure.
     * @param _oracleSigner        AWS KMS address that signs UnlockCertificates (primary).
     * @param _oracleSigner2       [V3-1] Independent HSM address (secondary oracle, 2-of-2).
     * @param _complianceOracle    Address allowed to block/unblock individual wallets.
     */
    constructor(
        address _cueCoin,
        uint256 _premiumFeeWei,
        uint256 _standardFeeWei,
        address _liquidityLocker,
        address _developmentMultisig,
        address _tournamentSeed,
        address _marketingWallet,
        address _daoReserve,
        address _serverCostWallet,
        address _oracleSigner,
        address _oracleSigner2,
        address _complianceOracle
    )
        Ownable(msg.sender)
        EIP712("CueAirdrop", "3")
    {
        require(_cueCoin              != address(0), "CueAirdrop: zero cueCoin");
        require(_liquidityLocker      != address(0), "CueAirdrop: zero liquidityLocker");
        require(_developmentMultisig  != address(0), "CueAirdrop: zero devMultisig");
        require(_tournamentSeed       != address(0), "CueAirdrop: zero tournamentSeed");
        require(_marketingWallet      != address(0), "CueAirdrop: zero marketingWallet");
        require(_daoReserve           != address(0), "CueAirdrop: zero daoReserve");
        require(_serverCostWallet     != address(0), "CueAirdrop: zero serverCostWallet");
        require(_oracleSigner         != address(0), "CueAirdrop: zero oracleSigner");
        require(_oracleSigner2        != address(0), "CueAirdrop: zero oracleSigner2");
        require(_oracleSigner         != _oracleSigner2, "CueAirdrop: oracles must differ");
        require(_complianceOracle     != address(0), "CueAirdrop: zero complianceOracle");
        require(_premiumFeeWei        > 0,           "CueAirdrop: zero premium fee");
        require(_standardFeeWei       > 0,           "CueAirdrop: zero standard fee");

        cueCoin              = IERC20(_cueCoin);
        premiumFeeWei        = _premiumFeeWei;
        standardFeeWei       = _standardFeeWei;
        liquidityLocker      = _liquidityLocker;
        developmentMultisig  = _developmentMultisig;
        tournamentSeed       = _tournamentSeed;
        marketingWallet      = _marketingWallet;
        daoReserve           = _daoReserve;
        serverCostWallet     = _serverCostWallet;
        oracleSigner         = _oracleSigner;
        oracleSigner2        = _oracleSigner2;
        complianceOracle     = _complianceOracle;
        currentTosVersion    = 1;

        // [V3-2] Initialise rate limit to default
        globalUnlockCapPerBlock = DEFAULT_UNLOCK_CAP_PER_BLOCK;
    }

    // ═══════════════════════════════════════════════════════════
    //  TERMS OF SERVICE
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Record on-chain that the caller has accepted the current Terms of Service.
     *         Must be called before any claim or unlock. Acceptance is per ToS version —
     *         if the owner increments the version, all users must re-accept.
     *
     * @dev The full ToS text lives off-chain at cuecoin.io/tos, content-addressed via IPFS.
     *      The version number maps to an IPFS hash tracked off-chain.
     *      Submitting this transaction constitutes affirmative consent.
     */
    function acceptToS() external {
        require(!isBlocked[msg.sender], "CueAirdrop: address blocked");
        tosVersionAccepted[msg.sender] = currentTosVersion;
        emit TosAccepted(msg.sender, currentTosVersion, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════
    //  PREMIUM CLAIM
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Claim premium airdrop. Pays $20 BNB, receives 250 CUECOIN instantly.
     *
     *         When this call fills the 400,000th slot, ALL accumulated premium BNB
     *         is automatically split and forwarded to five destinations.
     *         This auto-deploy is hardcoded and cannot be prevented or delayed.
     *
     * @param proof  Merkle proof. Leaf = keccak256(abi.encodePacked(msg.sender)).
     */
    function claimPremium(
        bytes32[] calldata proof
    )
        external
        payable
        nonReentrant
        whenNotPaused
    {
        // ── Pre-flight checks ──
        require(claimOpen,                                              "CueAirdrop: claims not open");
        require(tosVersionAccepted[msg.sender] == currentTosVersion,   "CueAirdrop: ToS not accepted");
        require(!isBlocked[msg.sender],                                 "CueAirdrop: address blocked");
        require(!premiumClaimed[msg.sender],                            "CueAirdrop: already claimed");
        require(premiumClaimCount < PREMIUM_CAP,                        "CueAirdrop: premium cap reached");
        require(msg.value >= premiumFeeWei,                             "CueAirdrop: insufficient fee");

        // ── Merkle verification ──
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
        require(
            MerkleProof.verify(proof, premiumMerkleRoot, leaf),
            "CueAirdrop: invalid premium proof"
        );

        // ── State update (checks-effects-interactions) ──
        premiumClaimed[msg.sender] = true;
        uint256 claimNumber = ++premiumClaimCount;

        // ── [V2-1] Account premium BNB separately ──
        // Only the exact fee amount (not any refunded excess) counts toward premium revenue.
        premiumBNBAccumulated += premiumFeeWei;

        // ── Refund excess BNB ──
        uint256 excess = msg.value - premiumFeeWei;
        if (excess > 0) {
            (bool refundOk, ) = payable(msg.sender).call{value: excess}("");
            require(refundOk, "CueAirdrop: BNB refund failed");
        }

        // ── Transfer 250 CUECOIN instantly ──
        // Check the contract has enough CUECOIN for this award.
        // Uses free balance = total balance - currently locked tokens.
        uint256 freeBalance = cueCoin.balanceOf(address(this)) - totalActiveLocks;
        require(freeBalance >= PREMIUM_AWARD, "CueAirdrop: insufficient free CUECOIN");
        cueCoin.safeTransfer(msg.sender, PREMIUM_AWARD);

        emit PremiumClaimed(msg.sender, PREMIUM_AWARD, premiumFeeWei, claimNumber);

        // ── [V3-3] Cap reached notification — deploy is DECOUPLED ──
        // Previously, the 400,000th claim would atomically call _deployPremiumFunds().
        // This created a griefing vector: if any destination contract reverted, the
        // 400,000th claimer's transaction would revert, permanently preventing the
        // final claim and stalling fundsDeployed = true.
        //
        // Now: reaching the cap merely makes triggerPremiumDeploy() callable by anyone.
        // Claim and deploy are fully independent. The final claimant's gas is never at risk.
        if (premiumClaimCount >= PREMIUM_CAP && !fundsDeployed) {
            emit PremiumDeployTriggered(address(0)); // signals readiness, not execution
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  STANDARD CLAIM
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Claim standard airdrop. Pays $2 BNB, tokens are locked pending play-to-unlock.
     *
     *         The Merkle leaf encodes (wallet address, totalCuecoin). This ties the bonus
     *         amount to what the task engine verified — the user cannot claim more than
     *         the backend computed.
     *
     * @param proof          Merkle proof.
     * @param totalCuecoin   Total CUECOIN entitlement (50 base + 0–30 bonus).
     *                       Must match Merkle leaf exactly.
     */
    function claimStandard(
        bytes32[] calldata proof,
        uint256 totalCuecoin
    )
        external
        payable
        nonReentrant
        whenNotPaused
    {
        // ── Pre-flight checks ──
        require(claimOpen,                                              "CueAirdrop: claims not open");
        require(tosVersionAccepted[msg.sender] == currentTosVersion,   "CueAirdrop: ToS not accepted");
        require(!isBlocked[msg.sender],                                 "CueAirdrop: address blocked");
        require(!standardClaimed[msg.sender],                           "CueAirdrop: already claimed");
        require(standardClaimCount < STANDARD_CAP,                      "CueAirdrop: standard cap reached");
        require(msg.value >= standardFeeWei,                            "CueAirdrop: insufficient fee");

        // ── Validate amount range ──
        require(
            totalCuecoin >= STANDARD_BASE_AWARD && totalCuecoin <= STANDARD_MAX_AWARD,
            "CueAirdrop: totalCuecoin out of range"
        );

        // ── Merkle verification ──
        // Leaf encodes both wallet and entitlement amount — tamper-proof.
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, totalCuecoin));
        require(
            MerkleProof.verify(proof, standardMerkleRoot, leaf),
            "CueAirdrop: invalid standard proof"
        );

        // ── [V2-2] Check contract has enough free CUECOIN to cover this new lock ──
        // Free balance = total CUECOIN balance - tokens already locked for others.
        // This ensures a new claimer's entitlement is actually available.
        {
            uint256 freeBalance = cueCoin.balanceOf(address(this)) - totalActiveLocks;
            require(freeBalance >= totalCuecoin, "CueAirdrop: insufficient free CUECOIN for lock");
        }

        // ── State update ──
        standardClaimed[msg.sender] = true;
        uint256 claimNumber = ++standardClaimCount;

        // Register lock — tokens remain in contract until unlocked via oracle cert
        uint256 bonusAmount = totalCuecoin - STANDARD_BASE_AWARD;
        standardLocks[msg.sender] = StandardLock({
            totalLocked:   totalCuecoin,
            totalUnlocked: 0,
            gamesVerified: 0,
            nonce:         0
        });

        // [V2-2] Increase active locks counter
        totalActiveLocks += totalCuecoin;

        // [V3-5] Track standard fee BNB separately — prevents rescueBNB() from
        //        draining this revenue before the 7-day deployment cooldown expires.
        standardBNBAccumulated += standardFeeWei;

        // ── Refund excess BNB ──
        uint256 excess = msg.value - standardFeeWei;
        if (excess > 0) {
            (bool refundOk, ) = payable(msg.sender).call{value: excess}("");
            require(refundOk, "CueAirdrop: BNB refund failed");
        }

        emit StandardClaimed(
            msg.sender,
            totalCuecoin,
            STANDARD_BASE_AWARD,
            bonusAmount,
            standardFeeWei,
            claimNumber
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  PLAY-TO-UNLOCK
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Unlock a tranche of standard tokens using dual oracle-signed certificates.
     *
     *         Callable by the user themselves, or by a trusted backend relayer on their
     *         behalf. Both unlock certificates must be signed by different oracle keys —
     *         oracleSigner (AWS KMS) AND oracleSigner2 (independent HSM). Both signatures
     *         cover the same struct hash; they must match the same parameters.
     *
     *         [V3-1] DUAL-ORACLE 2-of-2: A single compromised key cannot unlock tokens.
     *         An attacker who controls AWS KMS but not the HSM (or vice versa) cannot
     *         forge a valid unlock. Both must be compromised simultaneously.
     *
     *         [V3-2] PER-BLOCK RATE LIMIT: globalUnlockCapPerBlock limits the total
     *         CUECOIN unlocked across all users in any single block. This caps the
     *         blast radius of a simultaneous dual-key compromise to a small fraction
     *         of total locked supply per block.
     *
     *         Unlock schedule:
     *           10 games  →  10 % released
     *           20 games  →  20 % released (cumulative)
     *           ...
     *           100 games → 100 % released (full unlock)
     *
     * @param user         Wallet that claimed standard tokens.
     * @param gamesPlayed  New cumulative verified game count (must exceed stored value).
     * @param nonce        Must equal standardLocks[user].nonce exactly (one-use certs).
     * @param expiry       Unix timestamp after which this cert is invalid.
     *                     Must be: block.timestamp + [5 min, 24 h].
     * @param signature1   EIP-712 signature from oracleSigner (primary, AWS KMS).
     * @param signature2   EIP-712 signature from oracleSigner2 (secondary, HSM). [V3-1]
     */
    function unlockTokens(
        address user,
        uint256 gamesPlayed,
        uint256 nonce,
        uint256 expiry,
        bytes calldata signature1,
        bytes calldata signature2
    )
        external
        nonReentrant
        whenNotPaused
    {
        // ── Basic validity ──
        require(user != address(0),                                     "CueAirdrop: zero user");
        require(block.timestamp <= expiry,                              "CueAirdrop: certificate expired");

        // [V2-4] Certificate must have been issued with at least 5 minutes of validity.
        require(expiry >= block.timestamp + CERT_MIN_VALID_WINDOW,      "CueAirdrop: cert validity too short");

        // Certificate must not have been issued more than 24 hours ahead of now.
        require(expiry <= block.timestamp + CERT_MAX_EXPIRY_WINDOW,     "CueAirdrop: expiry too far");

        StandardLock storage lock = standardLocks[user];

        require(lock.totalLocked > 0,                                   "CueAirdrop: no locked tokens");
        require(gamesPlayed > lock.gamesVerified,                       "CueAirdrop: no new games");
        require(nonce == lock.nonce,                                     "CueAirdrop: invalid nonce");

        // ── EIP-712 struct hash (same for both signatures) ──
        bytes32 structHash = keccak256(abi.encode(
            UNLOCK_TYPEHASH,
            user,
            gamesPlayed,
            nonce,
            expiry
        ));
        bytes32 digest = _hashTypedDataV4(structHash);

        // ── [V3-1] Dual-oracle 2-of-2 signature verification ──
        // Both signatures must verify. Neither oracle alone can unlock tokens.
        address recovered1 = digest.recover(signature1);
        require(recovered1 == oracleSigner,  "CueAirdrop: invalid primary oracle signature");

        address recovered2 = digest.recover(signature2);
        require(recovered2 == oracleSigner2, "CueAirdrop: invalid secondary oracle signature");

        // ── State update (before transfer — CEI pattern) ──
        lock.gamesVerified = gamesPlayed;
        lock.nonce++;   // Invalidate this cert immediately — one-use

        // ── Calculate unlockable amount ──
        uint256 milestones = gamesPlayed / GAMES_PER_MILESTONE;
        if (milestones > MILESTONES_TOTAL) milestones = MILESTONES_TOTAL;

        // shouldBeUnlocked = totalLocked × (milestones / 10)
        uint256 shouldBeUnlocked = (lock.totalLocked * milestones) / MILESTONES_TOTAL;
        uint256 newUnlock        = shouldBeUnlocked - lock.totalUnlocked;

        require(newUnlock > 0, "CueAirdrop: nothing new to unlock");

        // ── [V3-2] Per-block rate limit ──
        // Reset accumulator if we've moved to a new block.
        if (block.number != lastUnlockBlock) {
            blockUnlockAccumulator = 0;
            lastUnlockBlock        = block.number;
        }
        blockUnlockAccumulator += newUnlock;
        require(
            blockUnlockAccumulator <= globalUnlockCapPerBlock,
            "CueAirdrop: per-block unlock cap exceeded"
        );

        lock.totalUnlocked += newUnlock;

        // [V2-2] Reduce active locks counter
        totalActiveLocks -= newUnlock;

        // ── Transfer ──
        cueCoin.safeTransfer(user, newUnlock);

        // [V2-7] Distinguish self-unlock from relayed unlock
        address relayer = (msg.sender == user) ? address(0) : msg.sender;

        emit TokensUnlocked(
            user,
            relayer,
            newUnlock,
            lock.totalUnlocked,
            lock.totalLocked,
            gamesPlayed
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  PREMIUM FUND DEPLOYMENT  [V3-3 — DECOUPLED FROM FINAL CLAIM]
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Deploy accumulated premium BNB to five destinations.
     *
     *         [V3-3] This function is now DECOUPLED from the 400,000th claim.
     *         Previously, deployment fired atomically inside claimPremium() when
     *         claimNumber == PREMIUM_CAP. This was vulnerable to griefing: if any
     *         destination contract had a reverting fallback (misconfigured multisig,
     *         paused contract, etc.), the entire final claim transaction would revert,
     *         permanently preventing premiumClaimCount from reaching PREMIUM_CAP and
     *         freezing fundsDeployed at false forever.
     *
     *         Now: deployment is a separate call. Callable by ANYONE once the cap is
     *         reached. This means:
     *           • The 400,000th claimer's transaction cannot be griefed by destinations.
     *           • If a destination reverts, the deployer can diagnose and retry.
     *           • The owner is not the only one who can trigger deployment — reducing
     *             trust requirements.
     *
     *         Guard: premiumClaimCount >= PREMIUM_CAP (not ==, tolerates over-counting edge cases).
     *         One-shot: fundsDeployed flag prevents double-deployment.
     */
    function triggerPremiumDeploy() external nonReentrant {
        require(premiumClaimCount >= PREMIUM_CAP, "CueAirdrop: premium cap not yet reached");
        require(!fundsDeployed,                   "CueAirdrop: already deployed");
        emit PremiumDeployTriggered(msg.sender);
        _deployPremiumFunds();
    }

    /**
     * @dev Internal premium fund deployment logic. Splits and forwards premium BNB.
     *      Rounding dust goes to daoReserve.
     *      Cannot be called before cap is reached (guarded by triggerPremiumDeploy).
     */
    function _deployPremiumFunds() internal {
        fundsDeployed = true;

        // [V2-1] Deploy ONLY the premium BNB, not the entire contract balance.
        uint256 total = premiumBNBAccumulated;
        require(total > 0, "CueAirdrop: no premium BNB to deploy");

        // Reset accumulated counter — prevents double-deploy if somehow called twice
        premiumBNBAccumulated = 0;

        uint256 liqAmt  = (total * PREM_SPLIT_LIQUIDITY)   / 10_000;
        uint256 devAmt  = (total * PREM_SPLIT_DEVELOPMENT) / 10_000;
        uint256 tourAmt = (total * PREM_SPLIT_TOURNAMENT)  / 10_000;
        uint256 mktAmt  = (total * PREM_SPLIT_MARKETING)   / 10_000;
        uint256 resAmt  = total - liqAmt - devAmt - tourAmt - mktAmt; // dust → DAO

        _sendBNB(liquidityLocker,     liqAmt,  "liquidity locker");
        _sendBNB(developmentMultisig, devAmt,  "development multisig");
        _sendBNB(tournamentSeed,      tourAmt, "tournament seed");
        _sendBNB(marketingWallet,     mktAmt,  "marketing wallet");
        _sendBNB(daoReserve,          resAmt,  "DAO reserve");

        emit PremiumFundsDeployed(
            total, liqAmt, devAmt, tourAmt, mktAmt, resAmt,
            block.timestamp
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  STANDARD FEE DEPLOYMENT
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Deploy accumulated standard tier fees to four destinations.
     *
     *         Unlike premium deployment, this is NOT automatic — it can be called by
     *         the owner at any time, subject to a 7-day cooldown between calls.
     *         This allows fees to accumulate before deployment (reduces gas waste)
     *         while preventing the owner from draining tiny amounts repeatedly.
     *
     *         The amount deployed = contract.balance - premiumBNBAccumulated.
     *         This ensures we never accidentally deploy premium funds early.
     */
    function deployStandardFees() external onlyOwner nonReentrant {
        // [V2-5] Enforce 7-day cooldown between calls
        require(
            block.timestamp >= lastStdDeployTimestamp + STD_DEPLOY_COOLDOWN,
            "CueAirdrop: standard deploy cooldown active"
        );

        // Deploy ONLY the portion of balance that is NOT tracked as premium BNB
        uint256 total = address(this).balance - premiumBNBAccumulated;
        require(total > 0, "CueAirdrop: no standard fees to deploy");

        lastStdDeployTimestamp = block.timestamp;

        // [V3-5] Reset standard BNB tracker — we're deploying it all now.
        standardBNBAccumulated = 0;

        uint256 devAmt    = (total * STD_SPLIT_DEVELOPMENT) / 10_000;
        uint256 serverAmt = (total * STD_SPLIT_SERVERS)     / 10_000;
        uint256 liqAmt    = (total * STD_SPLIT_LIQUIDITY)   / 10_000;
        uint256 daoAmt    = total - devAmt - serverAmt - liqAmt;  // dust → DAO

        _sendBNB(developmentMultisig, devAmt,    "std dev");
        _sendBNB(serverCostWallet,    serverAmt, "std servers");
        _sendBNB(liquidityLocker,     liqAmt,    "std liquidity");
        _sendBNB(daoReserve,          daoAmt,    "std dao");

        emit StandardFundsDeployed(
            total, devAmt, serverAmt, liqAmt, daoAmt,
            block.timestamp
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  COMPLIANCE ORACLE
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Block a specific wallet.
     *         Used ONLY for individual wallet-level blocks (court orders, confirmed fraud).
     *         NOT used for geographic blocking — the contract is open globally.
     */
    function blockAddress(
        address account,
        string calldata reason
    ) external onlyComplianceOrOwner {
        require(account != address(0), "CueAirdrop: zero address");
        isBlocked[account] = true;
        emit AddressBlocked(account, reason);
    }

    /**
     * @notice Block multiple wallets in one transaction (gas-efficient pre-launch screening).
     *         Max 500 per call to avoid block gas limit issues.
     */
    function blockAddressBatch(
        address[] calldata accounts,
        string calldata reason
    ) external onlyComplianceOrOwner {
        uint256 len = accounts.length;
        require(len > 0,    "CueAirdrop: empty list");
        require(len <= 500, "CueAirdrop: max 500 per batch");
        for (uint256 i = 0; i < len; ) {
            if (accounts[i] != address(0)) {
                isBlocked[accounts[i]] = true;
                emit AddressBlocked(accounts[i], reason);
            }
            unchecked { ++i; }
        }
    }

    /**
     * @notice Unblock a previously blocked wallet.
     */
    function unblockAddress(address account) external onlyComplianceOrOwner {
        isBlocked[account] = false;
        emit AddressUnblocked(account);
    }

    // ═══════════════════════════════════════════════════════════
    //  [V2-3] ON-CHAIN TIMELOCK
    // ═══════════════════════════════════════════════════════════

    /// @notice Cancel a queued timelock operation. Owner only. Cannot cancel executed ops.
    function cancelTimelock(bytes32 operationId) external onlyOwner {
        require(timelockEta[operationId] > 0,    "CueAirdrop: not queued");
        require(!timelockExecuted[operationId],  "CueAirdrop: already executed");
        delete timelockEta[operationId];
        emit TimelockCancelled(operationId);
    }

    /// @notice View ETA and status of a timelock operation.
    /**
     * @notice [V2-10 / V3-4] View ETA and status of a timelock operation.
     *
     *         [V3-4] Because opId now includes keccak256(msg.data), the operation ID
     *         is specific to both the action AND the exact arguments. Pass the opId
     *         directly (emitted in TimelockQueued events) rather than recomputing it.
     *
     * @param operationId  The opId emitted in the TimelockQueued event.
     */
    function timelockStatus(bytes32 operationId) external view returns (
        uint256 eta,
        bool    executable,
        bool    expired
    ) {
        eta        = timelockEta[operationId];
        executable = eta > 0 &&
                     block.timestamp >= eta &&
                     block.timestamp < eta + TIMELOCK_GRACE &&
                     !timelockExecuted[operationId];
        expired    = eta > 0 && block.timestamp >= eta + TIMELOCK_GRACE;
    }

    // ═══════════════════════════════════════════════════════════
    //  OWNER / DAO ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Open or close the claim window.
     *         NOTE: Not timelocked — opening/closing must be instant for launch ops.
     */
    function setClaimOpen(bool _open) external onlyOwner {
        claimOpen = _open;
        emit ClaimOpenUpdated(_open, block.timestamp);
    }

    /**
     * @notice Update both Merkle roots atomically.
     *         NOT timelocked — Merkle updates must be fast (snapshot generation).
     *         Called by the task engine backend after each snapshot.
     */
    function setMerkleRoots(
        bytes32 _premiumRoot,
        bytes32 _standardRoot
    ) external onlyOwner {
        require(_premiumRoot  != bytes32(0), "CueAirdrop: zero premium root");
        require(_standardRoot != bytes32(0), "CueAirdrop: zero standard root");
        premiumMerkleRoot  = _premiumRoot;
        standardMerkleRoot = _standardRoot;
        emit MerkleRootsUpdated(_premiumRoot, _standardRoot, block.timestamp);
    }

    /**
     * @notice Update claim fees in BNB-wei (adjusts for BNB/USD price movements).
     *         Only callable while claims are closed — protects in-flight claimants.
     *         NOT timelocked — price updates must track BNB price daily.
     */
    function setFees(
        uint256 _premiumFeeWei,
        uint256 _standardFeeWei
    ) external onlyOwner {
        require(!claimOpen,           "CueAirdrop: close claims first");
        require(_premiumFeeWei  > 0,  "CueAirdrop: zero premium fee");
        require(_standardFeeWei > 0,  "CueAirdrop: zero standard fee");
        premiumFeeWei  = _premiumFeeWei;
        standardFeeWei = _standardFeeWei;
        emit FeesUpdated(_premiumFeeWei, _standardFeeWei);
    }

    /**
     * @notice Update the oracle signer address (e.g. on KMS key rotation).
     *         TIMELOCKED — 48 hours. A compromised oracle key needs immediate
     *         response; the timelock forces the attacker to wait 48h too.
     *         The response in that window is to pause the contract.
     */
    function setOracleSigner(
        address _signer
    ) external onlyOwner timelocked(keccak256("setOracleSigner")) {
        require(_signer != address(0), "CueAirdrop: zero signer");
        require(_signer != oracleSigner2, "CueAirdrop: must differ from signer2");
        emit OracleSignerUpdated(oracleSigner, _signer);
        oracleSigner = _signer;
    }

    /**
     * @notice [V3-1] Update the secondary oracle signer (independent HSM rotation).
     *         TIMELOCKED — 48 hours. Same reasoning as setOracleSigner.
     *         oracleSigner2 must differ from oracleSigner at all times.
     */
    function setOracleSigner2(
        address _signer2
    ) external onlyOwner timelocked(keccak256("setOracleSigner2")) {
        require(_signer2 != address(0),   "CueAirdrop: zero signer2");
        require(_signer2 != oracleSigner, "CueAirdrop: must differ from signer1");
        emit OracleSigner2Updated(oracleSigner2, _signer2);
        oracleSigner2 = _signer2;
    }

    /**
     * @notice [V3-2] Update the per-block CUECOIN unlock cap.
     *         TIMELOCKED — 48 hours. Lowering the cap is a critical safety control;
     *         raising it is a governance decision. Both warrant a timelock.
     *         Cannot be set to zero (would permanently freeze all unlocks).
     *
     * @param _capPerBlock New maximum CUECOIN (in wei) unlockable per block across all users.
     */
    function setUnlockCapPerBlock(
        uint256 _capPerBlock
    ) external onlyOwner timelocked(keccak256("setUnlockCapPerBlock")) {
        require(_capPerBlock > 0, "CueAirdrop: cap cannot be zero");
        globalUnlockCapPerBlock = _capPerBlock;
        emit UnlockCapUpdated(_capPerBlock);
    }

    /**
     * @notice Update the compliance oracle address.
     *         TIMELOCKED — 48 hours.
     */
    function setComplianceOracle(
        address _oracle
    ) external onlyOwner timelocked(keccak256("setComplianceOracle")) {
        require(_oracle != address(0), "CueAirdrop: zero oracle");
        emit ComplianceOracleUpdated(complianceOracle, _oracle);
        complianceOracle = _oracle;
    }

    /**
     * @notice Update all five premium destination addresses atomically.
     *         TIMELOCKED — 48 hours. Changing destinations while 400k claims are
     *         accumulating is the highest-risk admin operation in this contract.
     *         Cannot be called after fundsDeployed = true.
     */
    function setPremiumDestinations(
        address _liquidityLocker,
        address _developmentMultisig,
        address _tournamentSeed,
        address _marketingWallet,
        address _daoReserve
    ) external onlyOwner timelocked(keccak256("setPremiumDestinations")) {
        require(!fundsDeployed,           "CueAirdrop: funds already deployed");
        require(_liquidityLocker     != address(0), "CueAirdrop: zero liquidityLocker");
        require(_developmentMultisig != address(0), "CueAirdrop: zero devMultisig");
        require(_tournamentSeed      != address(0), "CueAirdrop: zero tournamentSeed");
        require(_marketingWallet     != address(0), "CueAirdrop: zero marketingWallet");
        require(_daoReserve          != address(0), "CueAirdrop: zero daoReserve");

        liquidityLocker     = _liquidityLocker;
        developmentMultisig = _developmentMultisig;
        tournamentSeed      = _tournamentSeed;
        marketingWallet     = _marketingWallet;
        daoReserve          = _daoReserve;

        emit DestinationsUpdated("premium");
    }

    /**
     * @notice Update standard fee destination addresses.
     *         TIMELOCKED — 48 hours.
     */
    function setStandardDestinations(
        address _developmentMultisig,
        address _serverCostWallet,
        address _liquidityLocker,
        address _daoReserve
    ) external onlyOwner timelocked(keccak256("setStandardDestinations")) {
        require(_developmentMultisig != address(0), "CueAirdrop: zero devMultisig");
        require(_serverCostWallet    != address(0), "CueAirdrop: zero serverCostWallet");
        require(_liquidityLocker     != address(0), "CueAirdrop: zero liquidityLocker");
        require(_daoReserve          != address(0), "CueAirdrop: zero daoReserve");

        developmentMultisig = _developmentMultisig;
        serverCostWallet    = _serverCostWallet;
        liquidityLocker     = _liquidityLocker;
        daoReserve          = _daoReserve;

        emit DestinationsUpdated("standard");
    }

    // ── ToS management ──

    /**
     * @notice Increment ToS version. All existing acceptances are invalidated.
     *         TIMELOCKED — 48 hours. Gives the community time to react if this
     *         function is called maliciously.
     */
    function incrementTosVersion() external onlyOwner timelocked(keccak256("incrementTosVersion")) {
        currentTosVersion++;
        emit TosVersionUpdated(currentTosVersion);
    }

    // ── Pause controls ──

    /// @notice Pause all claim and unlock operations. Emergency use only.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume operations after a pause.
    function unpause() external onlyOwner {
        _unpause();
    }

    // ── [V2-6] Emergency BNB rescue ──

    /**
     * @notice Rescue stranded BNB that is NOT tracked as premium or standard fee revenue.
     *         Only callable before premium funds have been deployed (safety window).
     *
     *         [V3-5] rescuable = contract.balance - premiumBNBAccumulated - standardBNBAccumulated
     *         This correctly protects BOTH tracked pools. Previously only premium BNB was
     *         guarded, meaning the owner could drain standard fee revenue before the 7-day
     *         deployment cooldown expired.
     *
     * @param amount BNB-wei to rescue.
     * @param to     Recipient (must be owner).
     */
    function rescueBNB(uint256 amount, address to) external onlyOwner nonReentrant {
        require(!fundsDeployed, "CueAirdrop: rescue disabled after deploy");
        require(to == owner(),  "CueAirdrop: rescue target must be owner");

        // [V3-5] Protected balance = all tracked fee revenue (premium + standard).
        // rescueBNB can only withdraw BNB that landed in the contract via non-fee paths
        // (e.g. direct ETH transfer, mistaken send).
        uint256 protectedBalance = premiumBNBAccumulated + standardBNBAccumulated;
        uint256 rescuable        = address(this).balance > protectedBalance
            ? address(this).balance - protectedBalance
            : 0;

        require(amount > 0,          "CueAirdrop: zero amount");
        require(amount <= rescuable, "CueAirdrop: amount exceeds rescuable BNB");

        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "CueAirdrop: rescue transfer failed");

        emit BNBRescued(to, amount);
    }

    // ── Foreign ERC-20 rescue ──

    /**
     * @notice Recover accidentally sent ERC-20 tokens.
     *         CANNOT recover CUECOIN — those are user funds (locked or unclaimed).
     */
    function recoverERC20(address token, uint256 amount) external onlyOwner {
        require(token != address(cueCoin), "CueAirdrop: cannot recover CUECOIN");
        IERC20(token).safeTransfer(owner(), amount);
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Full unlock status for a standard claimant. For frontend dashboards.
     */
    function unlockStatus(address user)
        external
        view
        returns (
            uint256 totalLocked,
            uint256 totalUnlocked,
            uint256 remaining,
            uint256 gamesVerified,
            uint256 nextMilestone,
            uint256 percentUnlocked
        )
    {
        StandardLock storage lock = standardLocks[user];
        totalLocked   = lock.totalLocked;
        totalUnlocked = lock.totalUnlocked;
        remaining     = totalLocked - totalUnlocked;
        gamesVerified = lock.gamesVerified;

        uint256 currentMilestone = lock.gamesVerified / GAMES_PER_MILESTONE;
        nextMilestone = (currentMilestone >= MILESTONES_TOTAL)
            ? 0  // fully unlocked
            : ((currentMilestone + 1) * GAMES_PER_MILESTONE) - lock.gamesVerified;

        percentUnlocked = totalLocked > 0
            ? (totalUnlocked * 100) / totalLocked
            : 0;
    }

    /**
     * @notice Preview how much would be unlocked by a hypothetical game count.
     *         For frontend progress bars — does not submit anything on-chain.
     */
    function previewUnlock(address user, uint256 gamesPlayed)
        external
        view
        returns (uint256 unlockable)
    {
        StandardLock storage lock = standardLocks[user];
        if (lock.totalLocked == 0) return 0;
        if (gamesPlayed <= lock.gamesVerified) return 0;

        uint256 milestones = gamesPlayed / GAMES_PER_MILESTONE;
        if (milestones > MILESTONES_TOTAL) milestones = MILESTONES_TOTAL;

        uint256 shouldBeUnlocked = (lock.totalLocked * milestones) / MILESTONES_TOTAL;
        unlockable = shouldBeUnlocked > lock.totalUnlocked
            ? shouldBeUnlocked - lock.totalUnlocked
            : 0;
    }

    /**
     * @notice Returns the EIP-712 domain separator. For off-chain signing tools.
     */
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @notice Returns the current nonce for a standard claimant.
     *         Frontend must pass this when requesting an unlock cert from the oracle.
     */
    function getUnlockNonce(address user) external view returns (uint256) {
        return standardLocks[user].nonce;
    }

    /**
     * @notice All key airdrop statistics in a single call. For frontends.
     */
    function airdropStats()
        external
        view
        returns (
            uint256 premiumClaims,
            uint256 premiumRemaining,
            uint256 standardClaims,
            uint256 standardRemaining,
            bool    isOpen,
            bool    isPremiumDeployed,
            uint256 contractBNBBalance,
            uint256 premiumBNBPending,
            uint256 standardBNBPending,     // [V3-5]
            uint256 contractCueCoinBalance,
            uint256 activeLocks,
            uint256 blockUnlockUsed,        // [V3-2] accumulator for current block
            uint256 blockUnlockCap          // [V3-2]
        )
    {
        premiumClaims         = premiumClaimCount;
        premiumRemaining      = PREMIUM_CAP > premiumClaimCount ? PREMIUM_CAP - premiumClaimCount : 0;
        standardClaims        = standardClaimCount;
        standardRemaining     = STANDARD_CAP > standardClaimCount ? STANDARD_CAP - standardClaimCount : 0;
        isOpen                = claimOpen;
        isPremiumDeployed     = fundsDeployed;
        contractBNBBalance    = address(this).balance;
        premiumBNBPending     = premiumBNBAccumulated;
        standardBNBPending    = standardBNBAccumulated;
        contractCueCoinBalance = cueCoin.balanceOf(address(this));
        activeLocks            = totalActiveLocks;
        blockUnlockUsed        = (block.number == lastUnlockBlock) ? blockUnlockAccumulator : 0;
        blockUnlockCap         = globalUnlockCapPerBlock;
    }

    /**
     * @notice [V2-8 / V3] All immutable and key mutable contract parameters in one call.
     *         Useful for frontend configuration and audit tools.
     */
    function airdropConfig()
        external
        view
        returns (
            uint256 premiumAward,
            uint256 standardBaseAward,
            uint256 standardMaxBonus,
            uint256 standardMaxAward,
            uint256 premiumCap,
            uint256 standardCap,
            uint256 gamesPerMilestone,
            uint256 milestonesTotal,
            uint256 gamesForFullUnlock,
            uint256 certMinValidWindow,
            uint256 certMaxExpiryWindow,
            uint256 timelockDelay,
            uint256 stdDeployCooldown,
            uint256 unlockCapPerBlock,       // [V3-2]
            address primaryOracle,           // [V3-1]
            address secondaryOracle          // [V3-1]
        )
    {
        premiumAward          = PREMIUM_AWARD;
        standardBaseAward     = STANDARD_BASE_AWARD;
        standardMaxBonus      = STANDARD_MAX_BONUS;
        standardMaxAward      = STANDARD_MAX_AWARD;
        premiumCap            = PREMIUM_CAP;
        standardCap           = STANDARD_CAP;
        gamesPerMilestone     = GAMES_PER_MILESTONE;
        milestonesTotal       = MILESTONES_TOTAL;
        gamesForFullUnlock    = GAMES_FOR_FULL_UNLOCK;
        certMinValidWindow    = CERT_MIN_VALID_WINDOW;
        certMaxExpiryWindow   = CERT_MAX_EXPIRY_WINDOW;
        timelockDelay         = TIMELOCK_DELAY;
        stdDeployCooldown     = STD_DEPLOY_COOLDOWN;
        unlockCapPerBlock     = globalUnlockCapPerBlock;
        primaryOracle         = oracleSigner;
        secondaryOracle       = oracleSigner2;
    }

    /**
     * @notice Preview premium fund deployment amounts at current BNB balance.
     */
    function previewPremiumDeployment()
        external
        view
        returns (
            uint256 total,
            uint256 toLiquidity,
            uint256 toDevelopment,
            uint256 toTournament,
            uint256 toMarketing,
            uint256 toReserve
        )
    {
        total         = premiumBNBAccumulated;
        toLiquidity   = (total * PREM_SPLIT_LIQUIDITY)   / 10_000;
        toDevelopment = (total * PREM_SPLIT_DEVELOPMENT) / 10_000;
        toTournament  = (total * PREM_SPLIT_TOURNAMENT)  / 10_000;
        toMarketing   = (total * PREM_SPLIT_MARKETING)   / 10_000;
        toReserve     = total - toLiquidity - toDevelopment - toTournament - toMarketing;
    }

    /**
     * @notice Check eligibility for premium claim.
     */
    function isPremiumEligible(address wallet)
        external
        view
        returns (bool eligible, string memory reason)
    {
        if (!claimOpen)                                          return (false, "claims not open");
        if (isBlocked[wallet])                                   return (false, "address blocked");
        if (premiumClaimed[wallet])                              return (false, "already claimed");
        if (premiumClaimCount >= PREMIUM_CAP)                    return (false, "cap reached");
        if (tosVersionAccepted[wallet] != currentTosVersion)     return (false, "ToS not accepted");
        return (true, "eligible");
    }

    /**
     * @notice Check eligibility for standard claim.
     */
    function isStandardEligible(address wallet)
        external
        view
        returns (bool eligible, string memory reason)
    {
        if (!claimOpen)                                          return (false, "claims not open");
        if (isBlocked[wallet])                                   return (false, "address blocked");
        if (standardClaimed[wallet])                             return (false, "already claimed");
        if (standardClaimCount >= STANDARD_CAP)                  return (false, "cap reached");
        if (tosVersionAccepted[wallet] != currentTosVersion)     return (false, "ToS not accepted");
        return (true, "eligible");
    }

    /**
     * @notice [V2-9] Current CUECOIN balance of this contract.
     *         Broken out for relayer bots that need quick balance checks.
     */
    function cueCoinBalance() external view returns (uint256 total, uint256 locked, uint256 free) {
        total  = cueCoin.balanceOf(address(this));
        locked = totalActiveLocks;
        free   = total > locked ? total - locked : 0;
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev Send BNB to a destination using low-level call.
     *      Supports smart contract recipients (Gnosis Safe, etc.).
     *      Reverts with a descriptive label on failure.
     */
    function _sendBNB(
        address destination,
        uint256 amount,
        string memory label
    ) internal {
        if (amount == 0) return;
        (bool ok, ) = payable(destination).call{value: amount}("");
        require(ok, string(abi.encodePacked("CueAirdrop: BNB send failed: ", label)));
    }

    // ═══════════════════════════════════════════════════════════
    //  RECEIVE BNB  (fee payments land here)
    // ═══════════════════════════════════════════════════════════

    receive() external payable {}
}
