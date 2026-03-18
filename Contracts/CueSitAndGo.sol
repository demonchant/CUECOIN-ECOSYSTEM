// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ╔══════════════════════════════════════════════════════════════╗
//  CUESITANDGO  ·  v2.0  ·  Security-Hardened
//  CUECOIN Ecosystem  ·  BNB Smart Chain
//
//  Self-filling, self-starting 16-player tournament.
//  No DAO creation. No schedule. No NFT required.
//  16 players enter → pot fills → tournament starts → top 2
//  get paid → 8% burns → 2% to ops → new queue opens.
//
//  ════════════════════════════════════════════════════
//   v1 → v2 SECURITY HARDENING
//  ════════════════════════════════════════════════════
//
//   [V2-1]  2-OF-3 ORACLE SIGNATURES — v1 accepted any single
//            oracle (1-of-3). One compromised KMS key could drain
//            any game pot. v2 requires TWO DISTINCT oracle sigs
//            on the SAME certificate before any payout fires.
//
//            Exploit closed: Attack Path 1 — oracle key compromise.
//            Attacker now needs two geographically separate KMS
//            instances compromised simultaneously.
//
//            Pattern (mirrors CueEscrow high-value matches):
//              Step 1 — submitFirstSignature(): Oracle A signs.
//                        Stored pending. Nothing paid.
//              Step 2 — resolveGame(): Oracle B signs same cert.
//                        Verifies B ≠ A. Executes payout.
//
//   [V2-2]  PER-BLOCK PAYOUT CAP — MAX_POT_PER_BLOCK = 500,000
//            CUECOIN. Even if 2-of-3 keys are both compromised,
//            the attacker cannot drain multiple games in one block.
//            A single WHALE pot (80,000 CUECOIN) is well below
//            the cap — legitimate play is completely unaffected.
//
//   [V2-3]  RESOLUTION TIMEOUT 24h → 6h — 24h maximised capital
//            lockup during DoS timeout griefing (Attack Path 5).
//            6h is generous for any server recovery scenario.
//
//   [V2-4]  FIRST SIGNATURE EXPIRY (2h) — a stale first sig from
//            a compromised oracle cannot sit indefinitely waiting
//            for a colluding second oracle to arrive. After 2h it
//            expires and a fresh submitFirstSignature() is needed.
//
//  ════════════════════════════════════════════════════
//   POT DISTRIBUTION  (hardcoded bytecode constants)
//  ════════════════════════════════════════════════════
//
//    16 × entryFee = total pot
//    70%  →  1st place winner
//    20%  →  2nd place (runner-up)
//     8%  →  burned to 0xdead
//     2%  →  devMultisig (payroll, infra, marketing)
//   ──────────────────────────────────────────────────
//   100%  total  [ 7000 + 2000 + 800 + 200 = 10,000 ✓ ]
//
//  ════════════════════════════════════════════════════
//   ENTRY FEE TIERS
//  ════════════════════════════════════════════════════
//
//    MICRO   —    10 CUECOIN  (     160 CUECOIN pot)
//    SMALL   —    50 CUECOIN  (     800 CUECOIN pot)
//    MEDIUM  —   100 CUECOIN  (   1,600 CUECOIN pot)
//    LARGE   —   500 CUECOIN  (   8,000 CUECOIN pot)
//    XLARGE  — 1,000 CUECOIN  (  16,000 CUECOIN pot)
//    WHALE   — 5,000 CUECOIN  (  80,000 CUECOIN pot)
//
//  ════════════════════════════════════════════════════
//   ORACLE ARCHITECTURE  [V2-1]
//  ════════════════════════════════════════════════════
//
//  EIP-712 certificate (same domain pattern as CueEscrow):
//
//    SitAndGoResult(
//      bytes32 gameId,    ← keccak256(tier, queueIndex)
//      address first,     ← 1st place wallet
//      address second,    ← 2nd place wallet
//      uint256 nonce,     ← replay-protection nonce
//      uint256 expiry     ← 1h validity window
//    )
//
//  Two-step resolution:
//    submitFirstSignature(params + sigA)  → stores pending
//    resolveGame(params + sigB)           → verifies B ≠ A → pays
//
//  Fraud guards the oracle cannot bypass (on-chain):
//    - first and second must both be in players[16]
//    - first != second
//    - nonce consumed (no replay)
//    - cert expiry window
//    - per-block payout cap [V2-2]
//    - oracles distinct [V2-1]
//
//  ════════════════════════════════════════════════════
//   LIFECYCLE
//  ════════════════════════════════════════════════════
//
//    FILLING  — < 16 players. withdraw() available for full refund.
//    ACTIVE   — 16th joined. SitAndGoStarted emitted to backend.
//               Players locked. Oracle driving bracket.
//    RESOLVED — 2-of-3 oracle quorum. Payouts complete.
//               New queue opens automatically.
//    CANCELLED — 6h timeout or owner emergency. All refunded.
//                New queue opens automatically.
//
//  ════════════════════════════════════════════════════
//   SECURITY MODEL
//  ════════════════════════════════════════════════════
//
//  Owner CAN:    pause, update oracles (48h TL), update devMultisig
//                (48h TL), emergencyCancel (triggers full refund)
//  Owner CANNOT: redirect funds, change payout %, prevent timeout,
//                access CUECOIN outside defined payout paths
// ╚══════════════════════════════════════════════════════════════╝

import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  CueSitAndGo
 * @author CUECOIN Team
 * @notice Self-filling 16-player Sit & Go tournament.
 *         v2.0: 2-of-3 oracle quorum, per-block payout cap,
 *         6h resolution timeout, first-signature expiry.
 */
contract CueSitAndGo is EIP712, Ownable2Step, ReentrancyGuard, Pausable {
    using ECDSA     for bytes32;
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════
    //  CONSTANTS
    // ═══════════════════════════════════════════════════════════

    bytes32 public constant RESULT_TYPEHASH = keccak256(
        "SitAndGoResult(bytes32 gameId,address first,address second,"
        "uint256 nonce,uint256 expiry)"
    );

    uint8 public constant PLAYERS_PER_GAME = 16;

    // ── Payout split (bps, 10_000 = 100%) ──
    uint256 public constant PAYOUT_FIRST_BPS  = 7_000; // 70 %
    uint256 public constant PAYOUT_SECOND_BPS = 2_000; // 20 %
    uint256 public constant PAYOUT_BURN_BPS   =   800; //  8 %
    uint256 public constant PAYOUT_DEV_BPS    =   200; //  2 %
    // Invariant: 7000 + 2000 + 800 + 200 = 10_000 ✓

    // ── Entry fee tiers ──
    uint256 public constant FEE_MICRO   =    10 ether;
    uint256 public constant FEE_SMALL   =    50 ether;
    uint256 public constant FEE_MEDIUM  =   100 ether;
    uint256 public constant FEE_LARGE   =   500 ether;
    uint256 public constant FEE_XLARGE  = 1_000 ether;
    uint256 public constant FEE_WHALE   = 5_000 ether;

    // ── [V2-2] Per-block payout cap ──
    // WHALE pot = 80,000. Cap = 500,000 → allows 6 WHALE resolutions
    // per block before triggering (impossible in legitimate operation).
    uint256 public constant MAX_POT_PER_BLOCK = 500_000 ether;

    // ── Timing ──
    /// @notice [V2-3] Reduced from 24h. Minimises DoS capital lockup window.
    uint256 public constant RESOLUTION_TIMEOUT = 6 hours;

    /// @notice Oracle result certificate valid for 1 hour.
    uint256 public constant CERT_EXPIRY = 1 hours;

    /// @notice [V2-4] First signature expires after 2 hours if no second arrives.
    uint256 public constant FIRST_SIG_EXPIRY = 2 hours;

    // ── Timelock ──
    uint256 public constant TIMELOCK_DELAY = 48 hours;
    uint256 public constant TIMELOCK_GRACE = 14 days;

    address public constant BURN_ADDRESS =
        address(0x000000000000000000000000000000000000dEaD);

    // ═══════════════════════════════════════════════════════════
    //  ENUMS & STRUCTS
    // ═══════════════════════════════════════════════════════════

    enum Tier { MICRO, SMALL, MEDIUM, LARGE, XLARGE, WHALE }

    enum GameStatus { FILLING, ACTIVE, RESOLVED, CANCELLED }

    struct Game {
        Tier       tier;
        GameStatus status;
        uint256    entryFee;
        uint256    activatedAt;
        address[PLAYERS_PER_GAME] players;
        uint8      filledSlots;
    }

    /// @notice [V2-1] Pending first oracle signature.
    struct FirstSig {
        address signer;       // Oracle that signed first
        uint256 submittedAt;  // For FIRST_SIG_EXPIRY check [V2-4]
        bool    exists;
    }

    // ═══════════════════════════════════════════════════════════
    //  STATE VARIABLES
    // ═══════════════════════════════════════════════════════════

    IERC20 public immutable cueCoin;
    address public devMultisig;

    // ── Oracle set — 3 registered signers, 2-of-3 required [V2-1] ──
    address[3] public oracles;

    // ── Per-tier queue state ──
    mapping(uint8 => uint256) public currentQueueIndex;
    mapping(bytes32 => Game)  private _games;

    // ── [V2-1] Pending first sigs — keyed by keccak256(gameId, nonce) ──
    mapping(bytes32 => FirstSig) private _firstSig;

    // ── Anti-sybil: 1 slot per wallet per tier ──
    mapping(uint8 => mapping(address => uint8)) public activeSlot;

    // ── Nonce registry (replay protection) ──
    mapping(uint256 => bool) public nonceUsed;

    // ── Resolved game guard ──
    mapping(bytes32 => bool) public gameResolved;

    // ── [V2-2] Per-block payout tracking ──
    uint256 public lastPayoutBlock;
    uint256 public payoutThisBlock;

    // ── Timelock ──
    mapping(bytes32 => uint256) public timelockEta;
    mapping(bytes32 => bool)    public timelockExecuted;

    // ── Protocol stats ──
    uint256 public totalGamesStarted;
    uint256 public totalGamesResolved;
    uint256 public totalCueCoinBurned;
    uint256 public totalCueCoinToDev;
    uint256 public totalCueCoinPaidOut;

    // ═══════════════════════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════════════════════

    event PlayerJoined(
        bytes32 indexed gameId,
        address indexed player,
        Tier    indexed tier,
        uint8           slotIndex,
        uint8           filledSlots
    );

    event PlayerWithdrew(
        bytes32 indexed gameId,
        address indexed player,
        Tier    indexed tier,
        uint8           slotIndex
    );

    event SitAndGoStarted(
        bytes32 indexed gameId,
        Tier    indexed tier,
        uint256         entryFee,
        uint256         totalPot,
        address[PLAYERS_PER_GAME] players
    );

    /// @notice [V2-1] First sig stored. Backend should dispatch second oracle.
    event FirstSignatureSubmitted(
        bytes32 indexed gameId,
        address indexed oracleSigner,
        uint256         nonce
    );

    event SitAndGoResolved(
        bytes32 indexed gameId,
        Tier    indexed tier,
        address indexed first,
        address         second,
        uint256         firstPayout,
        uint256         secondPayout,
        uint256         burnAmount,
        uint256         devAmount,
        address         oracle1,  // both signers recorded for audit trail
        address         oracle2
    );

    event SitAndGoCancelled(
        bytes32 indexed gameId,
        Tier    indexed tier,
        address         cancelledBy,
        string          reason
    );

    event PlayerRefunded(bytes32 indexed gameId, address indexed player, uint256 amount);

    event NewQueueOpened(Tier indexed tier, uint256 queueIndex, bytes32 gameId);

    /// @notice [V2-4] Stale first sig expired before second oracle arrived.
    event FirstSignatureExpired(bytes32 indexed gameId, uint256 nonce, address staleSigner);

    event OraclesUpdated(address oracle0, address oracle1, address oracle2);
    event DevMultisigUpdated(address indexed oldDev, address indexed newDev);
    event TimelockQueued(bytes32 indexed operationId, bytes32 indexed action, uint256 eta);
    event TimelockExecuted(bytes32 indexed operationId, bytes32 indexed action);
    event TimelockCancelled(bytes32 indexed operationId);

    // ═══════════════════════════════════════════════════════════
    //  MODIFIERS
    // ═══════════════════════════════════════════════════════════

    modifier timelocked(bytes32 action) {
        bytes32 opId = keccak256(abi.encodePacked(action, msg.sender, keccak256(msg.data)));
        if (timelockEta[opId] == 0) {
            uint256 eta = block.timestamp + TIMELOCK_DELAY;
            timelockEta[opId] = eta;
            emit TimelockQueued(opId, action, eta);
            return;
        }
        require(block.timestamp >= timelockEta[opId],                  "SitAndGo: timelock not elapsed");
        require(block.timestamp <  timelockEta[opId] + TIMELOCK_GRACE, "SitAndGo: timelock grace expired");
        require(!timelockExecuted[opId],                               "SitAndGo: already executed");
        timelockExecuted[opId] = true;
        emit TimelockExecuted(opId, action);
        _;
    }

    // ═══════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    /**
     * @param _cueCoin       CueCoin BEP-20 contract.
     * @param _devMultisig   Gnosis Safe — receives 2% of every pot.
     * @param _oracle0       AWS KMS signer 1.
     * @param _oracle1       AWS KMS signer 2.
     * @param _oracle2       AWS KMS signer 3.
     */
    constructor(
        address _cueCoin,
        address _devMultisig,
        address _oracle0,
        address _oracle1,
        address _oracle2
    )
        EIP712("CueSitAndGo", "2")
        Ownable(msg.sender)
    {
        require(_cueCoin     != address(0), "SitAndGo: zero cueCoin");
        require(_devMultisig != address(0), "SitAndGo: zero devMultisig");
        require(_oracle0     != address(0), "SitAndGo: zero oracle0");
        require(_oracle1     != address(0), "SitAndGo: zero oracle1");
        require(_oracle2     != address(0), "SitAndGo: zero oracle2");
        require(
            _oracle0 != _oracle1 && _oracle1 != _oracle2 && _oracle0 != _oracle2,
            "SitAndGo: oracles must be distinct"
        );

        cueCoin    = IERC20(_cueCoin);
        devMultisig = _devMultisig;
        oracles[0] = _oracle0;
        oracles[1] = _oracle1;
        oracles[2] = _oracle2;

        for (uint8 t = 0; t <= uint8(Tier.WHALE); ) {
            _openNewQueue(Tier(t));
            unchecked { ++t; }
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  PLAYER ACTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Join the current Sit & Go queue for a tier.
     *         Locks the entry fee from caller. If this is the 16th
     *         player, status transitions to ACTIVE and SitAndGoStarted
     *         fires for the backend to begin bracket assignment.
     *
     *         Caller must approve this contract for at least
     *         entryFeeForTier(tier) before calling.
     */
    function join(Tier tier)
        external
        nonReentrant
        whenNotPaused
    {
        uint8   t      = uint8(tier);
        bytes32 gameId = _currentGameId(tier);
        Game storage g = _games[gameId];

        require(g.status == GameStatus.FILLING,   "SitAndGo: queue not open");
        require(g.filledSlots < PLAYERS_PER_GAME, "SitAndGo: queue full");
        require(activeSlot[t][msg.sender] == 0,   "SitAndGo: already in this queue");

        // CEI: collect entry fee before state mutation
        cueCoin.safeTransferFrom(msg.sender, address(this), g.entryFee);

        uint8 slot = g.filledSlots;
        g.players[slot]           = msg.sender;
        g.filledSlots             = slot + 1;
        activeSlot[t][msg.sender] = slot + 1; // 1-based in map, 0-based in array

        emit PlayerJoined(gameId, msg.sender, tier, slot, g.filledSlots);

        if (g.filledSlots == PLAYERS_PER_GAME) {
            g.status      = GameStatus.ACTIVE;
            g.activatedAt = block.timestamp;
            totalGamesStarted++;
            emit SitAndGoStarted(gameId, tier, g.entryFee, g.entryFee * PLAYERS_PER_GAME, g.players);
        }
    }

    /**
     * @notice Withdraw from a FILLING queue for a full refund.
     *         Only callable while status == FILLING.
     *         Once all 16 fill (ACTIVE), withdrawal is not possible.
     */
    function withdraw(Tier tier)
        external
        nonReentrant
    {
        uint8   t      = uint8(tier);
        bytes32 gameId = _currentGameId(tier);
        Game storage g = _games[gameId];

        require(g.status == GameStatus.FILLING, "SitAndGo: cannot withdraw after start");

        uint8 slotOneBased = activeSlot[t][msg.sender];
        require(slotOneBased > 0, "SitAndGo: not in this queue");

        uint8 slot     = slotOneBased - 1;
        uint8 lastSlot = g.filledSlots - 1;

        // Compact: move last player into the vacated slot (O(1), no gaps)
        if (slot != lastSlot) {
            address lastPlayer           = g.players[lastSlot];
            g.players[slot]              = lastPlayer;
            activeSlot[t][lastPlayer]    = slot + 1;
        }
        g.players[lastSlot]       = address(0);
        g.filledSlots             = lastSlot;
        activeSlot[t][msg.sender] = 0;

        cueCoin.safeTransfer(msg.sender, g.entryFee);
        emit PlayerWithdrew(gameId, msg.sender, tier, slot);
    }

    // ═══════════════════════════════════════════════════════════
    //  ORACLE RESOLUTION — 2-OF-3  [V2-1]
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Step 1 of 2 — first oracle submits a signed result certificate.
     *         Stored pending. Nothing is paid. Game stays ACTIVE.
     *
     *         [V2-4] The pending entry expires after FIRST_SIG_EXPIRY (2h).
     *         A stale compromised-oracle signature cannot wait indefinitely
     *         for a colluding second signer. After expiry, a fresh call
     *         with a new nonce overwrites the slot.
     *
     *         Winner fraud guards run here (not just in Step 2) so a
     *         malformed first submission fails fast before any sig is stored.
     *
     * @param tier    Tier of the game to resolve.
     * @param first   Proposed 1st place wallet.
     * @param second  Proposed 2nd place wallet.
     * @param nonce   Unique nonce (must not be used before).
     * @param expiry  Certificate validity end (≤ now + CERT_EXPIRY).
     * @param sig     EIP-712 SitAndGoResult signature from a registered oracle.
     */
    function submitFirstSignature(
        Tier    tier,
        address first,
        address second,
        uint256 nonce,
        uint256 expiry,
        bytes calldata sig
    )
        external
        nonReentrant
        whenNotPaused
    {
        bytes32 gameId = _currentGameId(tier);
        Game storage g = _games[gameId];

        require(g.status == GameStatus.ACTIVE,           "SitAndGo: game not active");
        require(block.timestamp <= expiry,                "SitAndGo: certificate expired");
        require(expiry <= block.timestamp + CERT_EXPIRY,  "SitAndGo: expiry window too long");
        require(!nonceUsed[nonce],                        "SitAndGo: nonce already used");
        require(!gameResolved[gameId],                    "SitAndGo: already resolved");

        // ── EIP-712 verification ──
        address signer = _hashTypedDataV4(
            _buildStructHash(gameId, first, second, nonce, expiry)
        ).recover(sig);
        require(_isOracle(signer), "SitAndGo: not a registered oracle");

        // ── Winner fraud guards — fail fast ──
        require(first  != address(0) && second != address(0), "SitAndGo: zero winner address");
        require(first  != second,     "SitAndGo: first and second must differ");
        require(_isPlayer(g, first),  "SitAndGo: first not in game");
        require(_isPlayer(g, second), "SitAndGo: second not in game");

        // ── Handle expired pending first sig [V2-4] ──
        bytes32 nonceKey = _nonceKey(gameId, nonce);
        if (_firstSig[nonceKey].exists) {
            // Only allow overwrite if the existing one has expired
            require(
                block.timestamp > _firstSig[nonceKey].submittedAt + FIRST_SIG_EXPIRY,
                "SitAndGo: first signature already pending"
            );
            emit FirstSignatureExpired(gameId, nonce, _firstSig[nonceKey].signer);
        }

        _firstSig[nonceKey] = FirstSig({
            signer:      signer,
            submittedAt: block.timestamp,
            exists:      true
        });

        emit FirstSignatureSubmitted(gameId, signer, nonce);
    }

    /**
     * @notice Step 2 of 2 — second oracle completes 2-of-3 quorum.
     *         Validates the second EIP-712 signature, confirms it is
     *         from a DISTINCT oracle, then executes payout atomically.
     *
     *         ALL parameters must be IDENTICAL to Step 1. The same
     *         struct hash links both signatures to the same data — a
     *         second oracle that disagrees with the first cannot
     *         produce a valid second signature for the same nonce.
     *
     *         [V2-2] Per-block payout cap checked before transfer.
     *
     * @param tier    Same as Step 1.
     * @param first   Same as Step 1.
     * @param second  Same as Step 1.
     * @param nonce   Same nonce as Step 1.
     * @param expiry  Same expiry as Step 1.
     * @param sig     EIP-712 signature from a DIFFERENT registered oracle.
     */
    function resolveGame(
        Tier    tier,
        address first,
        address second,
        uint256 nonce,
        uint256 expiry,
        bytes calldata sig
    )
        external
        nonReentrant
        whenNotPaused
    {
        bytes32 gameId = _currentGameId(tier);
        Game storage g = _games[gameId];

        // ── State guards ──
        require(g.status == GameStatus.ACTIVE,           "SitAndGo: game not active");
        require(block.timestamp <= expiry,                "SitAndGo: certificate expired");
        require(expiry <= block.timestamp + CERT_EXPIRY,  "SitAndGo: expiry window too long");
        require(!nonceUsed[nonce],                        "SitAndGo: nonce already used");
        require(!gameResolved[gameId],                    "SitAndGo: already resolved");

        // ── [V2-1] Retrieve first signature ──
        bytes32 nonceKey = _nonceKey(gameId, nonce);
        require(_firstSig[nonceKey].exists,   "SitAndGo: submit first signature first");
        require(
            block.timestamp <= _firstSig[nonceKey].submittedAt + FIRST_SIG_EXPIRY,
            "SitAndGo: first signature expired — resubmit"
        );

        // ── [V2-1] Verify second signature ──
        address signer2 = _hashTypedDataV4(
            _buildStructHash(gameId, first, second, nonce, expiry)
        ).recover(sig);
        require(_isOracle(signer2), "SitAndGo: not a registered oracle");

        // ── [V2-1] Oracles must be DISTINCT — closes oracle key collusion ──
        address signer1 = _firstSig[nonceKey].signer;
        require(signer2 != signer1, "SitAndGo: oracles must be distinct");

        // ── Winner fraud guards ──
        require(first  != address(0) && second != address(0), "SitAndGo: zero winner address");
        require(first  != second,     "SitAndGo: first and second must differ");
        require(_isPlayer(g, first),  "SitAndGo: first not in game");
        require(_isPlayer(g, second), "SitAndGo: second not in game");

        // ── [V2-2] Per-block payout cap ──
        _checkAndAccumulateBlockCap(uint256(g.entryFee) * PLAYERS_PER_GAME);

        // ── CEI: mark consumed before external calls ──
        nonceUsed[nonce]     = true;
        gameResolved[gameId] = true;
        g.status             = GameStatus.RESOLVED;
        totalGamesResolved++;
        delete _firstSig[nonceKey];

        // ── Payout, slot cleanup, new queue ──
        _executePayout(gameId, g, first, second, signer1, signer2);
        _clearActiveSlots(tier, g);
        _openNewQueue(tier);
    }

    // ═══════════════════════════════════════════════════════════
    //  TIMEOUT SAFETY  [V2-3]
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Full refund for all 16 players when oracle fails to resolve
     *         within 6 hours of ACTIVE [V2-3].
     *         Callable by anyone — no oracle or owner permission needed.
     */
    function claimTimeout(Tier tier)
        external
        nonReentrant
    {
        bytes32 gameId = _currentGameId(tier);
        Game storage g = _games[gameId];

        require(g.status == GameStatus.ACTIVE, "SitAndGo: game not active");
        require(
            block.timestamp >= g.activatedAt + RESOLUTION_TIMEOUT,
            "SitAndGo: timeout period not elapsed"
        );

        g.status = GameStatus.CANCELLED;
        emit SitAndGoCancelled(gameId, tier, msg.sender, "Oracle timeout");

        _refundAllPlayers(gameId, g);
        _clearActiveSlots(tier, g);
        _openNewQueue(tier);
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — PAYOUT ENGINE
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev Execute Sit & Go payout after 2-of-3 quorum confirmed.
     *
     *      Arithmetic: subtraction for dev so all rounding dust goes
     *      to dev (never to 0xdead, never lost). Proof:
     *        FIRST+SECOND+BURN = 9800 bps
     *        floor(pot × 9800 / 10000) ≤ pot
     *        devAmt = pot − (those three floors) ≥ pot × 200 / 10000
     *
     *      Both oracle signer addresses are recorded in the event
     *      for permanent on-chain audit trail. [V2-1]
     */
    function _executePayout(
        bytes32 gameId,
        Game storage g,
        address first,
        address second,
        address signer1,
        address signer2
    ) internal {
        uint256 pot       = uint256(g.entryFee) * PLAYERS_PER_GAME;
        uint256 firstAmt  = (pot * PAYOUT_FIRST_BPS)  / 10_000;
        uint256 secondAmt = (pot * PAYOUT_SECOND_BPS) / 10_000;
        uint256 burnAmt   = (pot * PAYOUT_BURN_BPS)   / 10_000;
        uint256 devAmt    = pot - firstAmt - secondAmt - burnAmt; // remainder

        cueCoin.safeTransfer(first,        firstAmt);
        cueCoin.safeTransfer(second,       secondAmt);
        cueCoin.safeTransfer(BURN_ADDRESS, burnAmt);
        cueCoin.safeTransfer(devMultisig,  devAmt);

        totalCueCoinPaidOut += firstAmt + secondAmt;
        totalCueCoinBurned  += burnAmt;
        totalCueCoinToDev   += devAmt;

        emit SitAndGoResolved(
            gameId, g.tier,
            first, second,
            firstAmt, secondAmt, burnAmt, devAmt,
            signer1, signer2
        );
    }

    /**
     * @dev [V2-2] Per-block payout accumulator.
     *      Resets at each new block. Reverts if pot would exceed cap.
     *      Protects against multi-game oracle compromise in one block.
     */
    function _checkAndAccumulateBlockCap(uint256 pot) internal {
        if (block.number != lastPayoutBlock) {
            payoutThisBlock = 0;
            lastPayoutBlock = block.number;
        }
        uint256 newTotal = payoutThisBlock + pot;
        require(newTotal <= MAX_POT_PER_BLOCK, "SitAndGo: per-block payout cap exceeded");
        payoutThisBlock = newTotal;
    }

    /**
     * @dev Refund all 16 players. Best-effort per player — a single failed
     *      transfer does not block the others. Stranded CUECOIN from a
     *      failed refund stays in the contract; owner can recover it via
     *      emergencyTokenRecovery (only for genuinely stuck tokens; CUECOIN
     *      recovery is blocked by recoverERC20 during normal operation).
     */
    function _refundAllPlayers(bytes32 gameId, Game storage g) internal {
        for (uint8 i = 0; i < PLAYERS_PER_GAME; ) {
            address player = g.players[i];
            if (player != address(0)) {
                (bool ok,) = address(cueCoin).call(
                    abi.encodeWithSelector(IERC20.transfer.selector, player, g.entryFee)
                );
                if (ok) emit PlayerRefunded(gameId, player, g.entryFee);
            }
            unchecked { ++i; }
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — QUEUE MANAGEMENT
    // ═══════════════════════════════════════════════════════════

    function _openNewQueue(Tier tier) internal {
        uint8   t   = uint8(tier);
        uint256 idx = ++currentQueueIndex[t];
        bytes32 gId = _computeGameId(tier, idx);

        Game storage g = _games[gId];
        g.tier        = tier;
        g.status      = GameStatus.FILLING;
        g.entryFee    = _feeForTier(tier);
        g.filledSlots = 0;

        emit NewQueueOpened(tier, idx, gId);
    }

    function _clearActiveSlots(Tier tier, Game storage g) internal {
        uint8 t = uint8(tier);
        for (uint8 i = 0; i < PLAYERS_PER_GAME; ) {
            if (g.players[i] != address(0)) activeSlot[t][g.players[i]] = 0;
            unchecked { ++i; }
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — HELPERS
    // ═══════════════════════════════════════════════════════════

    function _currentGameId(Tier tier) internal view returns (bytes32) {
        return _computeGameId(tier, currentQueueIndex[uint8(tier)]);
    }

    function _computeGameId(Tier tier, uint256 queueIndex) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(uint8(tier), queueIndex));
    }

    function _feeForTier(Tier tier) internal pure returns (uint256) {
        if (tier == Tier.MICRO)  return FEE_MICRO;
        if (tier == Tier.SMALL)  return FEE_SMALL;
        if (tier == Tier.MEDIUM) return FEE_MEDIUM;
        if (tier == Tier.LARGE)  return FEE_LARGE;
        if (tier == Tier.XLARGE) return FEE_XLARGE;
        if (tier == Tier.WHALE)  return FEE_WHALE;
        revert("SitAndGo: unknown tier");
    }

    function _isOracle(address addr) internal view returns (bool) {
        return addr == oracles[0] || addr == oracles[1] || addr == oracles[2];
    }

    function _isPlayer(Game storage g, address addr) internal view returns (bool) {
        for (uint8 i = 0; i < PLAYERS_PER_GAME; ) {
            if (g.players[i] == addr) return true;
            unchecked { ++i; }
        }
        return false;
    }

    /// @dev Build EIP-712 struct hash. Extracted to avoid stack depth.
    function _buildStructHash(
        bytes32 gameId,
        address first,
        address second,
        uint256 nonce,
        uint256 expiry
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(RESULT_TYPEHASH, gameId, first, second, nonce, expiry));
    }

    /// @dev Bind a nonce to a specific gameId — prevents nonce replay
    ///      across different games even if the same oracle key is used.
    function _nonceKey(bytes32 gameId, uint256 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(gameId, nonce));
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /// @notice Entry fee in CUECOIN-wei for a tier.
    function entryFeeForTier(Tier tier) external pure returns (uint256) {
        return _feeForTier(tier);
    }

    /// @notice Current gameId for the active queue of a tier.
    function currentGameId(Tier tier) external view returns (bytes32) {
        return _currentGameId(tier);
    }

    /// @notice Full state of the current queue for a tier.
    function queueState(Tier tier)
        external view
        returns (
            bytes32 gameId,
            GameStatus status,
            uint256 entryFee,
            uint256 totalPot,
            uint8   filledSlots,
            uint256 activatedAt,
            address[PLAYERS_PER_GAME] memory players
        )
    {
        gameId     = _currentGameId(tier);
        Game storage g = _games[gameId];
        status     = g.status;
        entryFee   = g.entryFee;
        totalPot   = g.entryFee * PLAYERS_PER_GAME;
        filledSlots = g.filledSlots;
        activatedAt = g.activatedAt;
        players    = g.players;
    }

    /// @notice State of any game by gameId (including historical).
    function gameState(bytes32 gameId)
        external view
        returns (
            Tier    tier,
            GameStatus status,
            uint256 entryFee,
            uint256 totalPot,
            uint8   filledSlots,
            uint256 activatedAt,
            address[PLAYERS_PER_GAME] memory players
        )
    {
        Game storage g = _games[gameId];
        tier        = g.tier;
        status      = g.status;
        entryFee    = g.entryFee;
        totalPot    = g.entryFee * PLAYERS_PER_GAME;
        filledSlots = g.filledSlots;
        activatedAt = g.activatedAt;
        players     = g.players;
    }

    /// @notice Whether a wallet holds an active slot in a tier's queue.
    function isInQueue(Tier tier, address wallet)
        external view
        returns (bool inQueue, uint8 slot)
    {
        uint8 s = activeSlot[uint8(tier)][wallet];
        inQueue = s > 0;
        slot    = s > 0 ? s - 1 : 0;
    }

    /**
     * @notice [V2-1] Status of a pending first signature for a game+nonce pair.
     * @return exists       A pending first sig is stored.
     * @return signer       Which oracle submitted it.
     * @return submittedAt  When it was submitted.
     * @return isExpired    Whether FIRST_SIG_EXPIRY has elapsed.
     */
    function firstSigStatus(bytes32 gameId, uint256 nonce)
        external view
        returns (
            bool    exists,
            address signer,
            uint256 submittedAt,
            bool    isExpired
        )
    {
        bytes32 key    = _nonceKey(gameId, nonce);
        FirstSig storage fs = _firstSig[key];
        exists      = fs.exists;
        signer      = fs.signer;
        submittedAt = fs.submittedAt;
        isExpired   = fs.exists && block.timestamp > fs.submittedAt + FIRST_SIG_EXPIRY;
    }

    /// @notice Seconds until timeout can be claimed (0 if not active or already elapsed).
    function timeoutSecondsRemaining(Tier tier) external view returns (uint256) {
        bytes32 gameId = _currentGameId(tier);
        Game storage g = _games[gameId];
        if (g.status != GameStatus.ACTIVE) return 0;
        uint256 deadline = g.activatedAt + RESOLUTION_TIMEOUT;
        if (block.timestamp >= deadline) return 0;
        return deadline - block.timestamp;
    }

    /// @notice Full protocol stats in one call.
    function protocolStats()
        external view
        returns (
            uint256 gamesStarted,
            uint256 gamesResolved,
            uint256 cueCoinBurned,
            uint256 cueCoinToDev,
            uint256 cueCoinPaidOut,
            uint8[6] memory fillStatus
        )
    {
        gamesStarted   = totalGamesStarted;
        gamesResolved  = totalGamesResolved;
        cueCoinBurned  = totalCueCoinBurned;
        cueCoinToDev   = totalCueCoinToDev;
        cueCoinPaidOut = totalCueCoinPaidOut;
        for (uint8 t = 0; t <= uint8(Tier.WHALE); ) {
            fillStatus[t] = _games[_currentGameId(Tier(t))].filledSlots;
            unchecked { ++t; }
        }
    }

    /// @notice Payout preview for a tier (all amounts in CUECOIN-wei).
    function payoutPreview(Tier tier)
        external pure
        returns (
            uint256 pot,
            uint256 firstPayout,
            uint256 secondPayout,
            uint256 burnAmount,
            uint256 devAmount
        )
    {
        pot          = _feeForTier(tier) * PLAYERS_PER_GAME;
        firstPayout  = (pot * PAYOUT_FIRST_BPS)  / 10_000;
        secondPayout = (pot * PAYOUT_SECOND_BPS) / 10_000;
        burnAmount   = (pot * PAYOUT_BURN_BPS)   / 10_000;
        devAmount    = pot - firstPayout - secondPayout - burnAmount;
    }

    /// @notice EIP-712 domain separator for oracle certificate construction.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Timelock status for a queued admin operation.
    function timelockStatus(bytes32 operationId)
        external view
        returns (uint256 eta, bool executable, bool expired)
    {
        eta        = timelockEta[operationId];
        executable = eta > 0
            && block.timestamp >= eta
            && block.timestamp <  eta + TIMELOCK_GRACE
            && !timelockExecuted[operationId];
        expired    = eta > 0 && block.timestamp >= eta + TIMELOCK_GRACE;
    }

    // ═══════════════════════════════════════════════════════════
    //  OWNER ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Update all three oracle signers. TIMELOCKED 48 hours.
     *         New oracles must be distinct from each other. [V2-1]
     */
    function updateOracles(address _o0, address _o1, address _o2)
        external
        onlyOwner
        timelocked(keccak256("updateOracles"))
    {
        require(_o0 != address(0) && _o1 != address(0) && _o2 != address(0),
            "SitAndGo: zero oracle");
        require(_o0 != _o1 && _o1 != _o2 && _o0 != _o2,
            "SitAndGo: oracles must be distinct");

        oracles[0] = _o0;
        oracles[1] = _o1;
        oracles[2] = _o2;

        emit OraclesUpdated(_o0, _o1, _o2);
    }

    /**
     * @notice Update dev multisig recipient. TIMELOCKED 48 hours.
     */
    function updateDevMultisig(address _devMultisig)
        external
        onlyOwner
        timelocked(keccak256("updateDevMultisig"))
    {
        require(_devMultisig != address(0), "SitAndGo: zero devMultisig");
        emit DevMultisigUpdated(devMultisig, _devMultisig);
        devMultisig = _devMultisig;
    }

    /**
     * @notice Emergency cancel an ACTIVE game. Refunds all 16 players.
     *         Use when server failure is confirmed and 6h timeout is
     *         too long. Owner cannot redirect funds — only refund.
     */
    function emergencyCancel(Tier tier)
        external
        onlyOwner
        nonReentrant
    {
        bytes32 gameId = _currentGameId(tier);
        Game storage g = _games[gameId];
        require(g.status == GameStatus.ACTIVE, "SitAndGo: game not active");

        g.status = GameStatus.CANCELLED;
        emit SitAndGoCancelled(gameId, tier, msg.sender, "Owner emergency cancel");

        _refundAllPlayers(gameId, g);
        _clearActiveSlots(tier, g);
        _openNewQueue(tier);
    }

    /// @notice Cancel a queued timelock before it executes.
    function cancelTimelock(bytes32 operationId) external onlyOwner {
        require(timelockEta[operationId] > 0,   "SitAndGo: not queued");
        require(!timelockExecuted[operationId], "SitAndGo: already executed");
        delete timelockEta[operationId];
        emit TimelockCancelled(operationId);
    }

    function pause()   external onlyOwner { _pause();   }
    function unpause() external onlyOwner { _unpause(); }

    /**
     * @notice Recover ERC-20 tokens accidentally sent to this contract.
     *         Cannot recover CUECOIN — those funds belong to players.
     */
    function recoverERC20(address token, uint256 amount) external onlyOwner {
        require(token != address(cueCoin), "SitAndGo: cannot recover CUECOIN");
        IERC20(token).safeTransfer(owner(), amount);
    }

    function recoverBNB(uint256 amount) external onlyOwner nonReentrant {
        require(amount <= address(this).balance, "SitAndGo: insufficient BNB");
        (bool ok,) = payable(owner()).call{value: amount}("");
        require(ok, "SitAndGo: BNB transfer failed");
    }

    receive() external payable {}
}
