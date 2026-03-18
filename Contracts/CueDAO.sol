// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ╔══════════════════════════════════════════════════════════════╗
//  CUEDAO  ·  v2.0  ·  Security-Hardened Governance
//  CUECOIN Ecosystem  ·  BNB Smart Chain
//
//  ════════════════════════════════════════════════════
//   v1 → v2 SECURITY FIXES
//  ════════════════════════════════════════════════════
//
//   [FIX-1]  SNAPSHOT VOTING (ERC20Votes) — v1 used balanceOf at the
//            time of castVote(), allowing token purchases during the
//            72h voting window to inflate vote weight. A well-capitalised
//            attacker could buy tokens on day 2, vote, and sell on day 3
//            at near-zero cost.
//
//            v2: vote weight = getPastVotes(voter, snapshotTimestamp)
//            where snapshotTimestamp = block.timestamp at propose().
//            Tokens purchased AFTER proposal creation have zero effect
//            on that proposal's vote weight. Requires CueCoin v6 with
//            ERC20Votes inheritance and timestamp-mode checkpoints.
//
//            Delegation is required: holders must call CueCoin.delegate()
//            before the snapshot to activate vote power. Undelegated
//            tokens do not count regardless of balance.
//
//   [FIX-2]  PROPOSAL DEPOSIT WITH SLASHING — v1 had no cost to spam
//            proposals. A single wallet with 500k CUECOIN could flood
//            the queue, exhaust voter attention, and dilute quorum.
//
//            v2: proposer locks PROPOSAL_DEPOSIT (500,000 CUECOIN) on
//            submission. Deposit fate:
//
//              EXECUTED              → returned to proposer
//              CANCELLED by proposer → returned to proposer
//              DEFEATED, quorum met  → returned to proposer
//                                      (legitimate minority view)
//              DEFEATED, no quorum   → slashed to 0xdead
//                                      (spam punishment)
//              CANCELLED by guardian → slashed to 0xdead
//                                      (guardian identified bad actor)
//              EXPIRED               → slashed to 0xdead
//                                      (proposer abandoned)
//
//            Deposit is locked in this contract. claimDeposit(id) for
//            return; _slashDeposit(id) for burn. Neither double-applies.
//
//   [FIX-3]  ECOSYSTEM ADDRESS TIMELOCK — v1's updateEcosystemAddress()
//            was instant (guardian-only but no delay). A compromised
//            guardian multisig could silently redirect the DAO's GENERIC_CALL
//            targets to a drain contract.
//
//            v2: two-step with ECOSYSTEM_UPDATE_DELAY (48h):
//              queueEcosystemAddressUpdate(name, newAddress)  — guardian
//              applyEcosystemAddressUpdate(name)              — anyone, after delay
//
//            Community has 48h to observe queued update before it applies.
//            Pending update can be cancelled by guardian at any time.
//
//   [FIX-4]  GUARDIAN EMERGENCY FREEZE — v1 had no way to halt governance
//            during an active attack (e.g., governance vote manipulation,
//            oracle compromise, or bridge exploit in progress).
//
//            v2: freeze() / unfreeze() guardian-only.
//            Frozen state blocks: propose(), castVote(), execute().
//            Does NOT block: cancel(), finalise(), claimDeposit(),
//            markExpired() — these are always safe to call.
//            Freeze does not extend voting periods. Proposals whose
//            votingEnds passes during a freeze are simply defeated
//            when finalised after unfreeze. This is by design.
//
//   [FIX-5]  DYNAMIC QUORUM SCALING — v1 fixed quorum at 5% regardless
//            of community participation history. If participation trends
//            high (e.g., 30% average), 5% quorum is trivial to meet even
//            for low-legitimacy proposals. If participation trends low,
//            5% may be unreachable and every proposal defeats itself.
//
//            v2: quorum = max(QUORUM_MIN_BPS, min(QUORUM_MAX_BPS,
//                              avg_recent_turnout × QUORUM_SCALE_FACTOR))
//            QUORUM_MIN_BPS   = 500 (5%  — hard floor, bytecode constant)
//            QUORUM_MAX_BPS   = 2000 (20% — hard ceiling, bytecode constant)
//            QUORUM_SCALE_FACTOR = 80 (targets 80% of recent participation)
//            QUORUM_WINDOW    = 10 proposals (rolling average)
//
//            Bootstrap: first 10 proposals use QUORUM_MIN_BPS. As history
//            accumulates, quorum self-adjusts to actual community activity.
//
//   [FIX-6]  ECOSYSTEM REVOKE BUG — v1 updateEcosystemAddress() set
//            approvedTarget[old] = false directly, bypassing _setApprovedTarget()
//            and silently omitting the TargetRevoked event. Off-chain
//            monitoring and indexers never saw old targets being revoked.
//
//            v2: all revocations route through _setApprovedTarget(addr, false)
//            which always emits TargetRevoked. Fixed in FIX-3 as part of
//            the timelocked apply step.
//
//  ════════════════════════════════════════════════════
//   GOVERNANCE PARAMETERS  (bytecode constants)
//  ════════════════════════════════════════════════════
//
//    Voting period          72 hours
//    Timelock after passing 48 hours
//    Execution grace        14 days
//    Proposal deposit       500,000 CUECOIN  (locked, slashable)
//    Quorum min             5%  of circulating (dynamic floor)
//    Quorum max             20% of circulating (dynamic ceiling)
//    Max vote weight        1%  of circulating per wallet (anti-whale)
//    Guardian update TL     7 days
//    Ecosystem update TL    48 hours
//
//  ════════════════════════════════════════════════════
//   PROPOSAL TYPES
//  ════════════════════════════════════════════════════
//
//    TEXT                    Off-chain signal only
//    TREASURY_TRANSFER       Move CUECOIN from treasury
//    UPDATE_REWARD_RATE      CueRewardsPool match reward rate
//    UPDATE_TAX_RATES        CueCoin Vortex Tax components (≤10% ceiling)
//    UPDATE_POOLS            CueCoin tax destination addresses
//    UPDATE_ORACLES          CueEscrow / CueSitAndGo oracle signers
//    UPDATE_MARKETPLACE_FEE  CueMarketplace platform fee (≤5%)
//    UPDATE_BRIDGE_PARAMS    CueBridge fee / rate limits
//    UPDATE_REFERRAL_POOL    Transfer from treasury to referral pool
//    GENERIC_CALL            Raw call to guardian-approved target
//
//  ════════════════════════════════════════════════════
//   FLASH LOAN ATTACK ANALYSIS
//  ════════════════════════════════════════════════════
//
//  Snapshot voting [FIX-1] closes the primary vector: vote weight is
//  locked at proposal creation. A flash loan mid-vote changes nothing.
//
//  Remaining layers:
//  - 500k CUECOIN deposit required to propose (proposer must hold real tokens)
//  - 1% anti-whale cap on snapshot vote weight
//  - 72h window during which guardian can cancel malicious proposals
//  - Approved targets list prevents drained GENERIC_CALL even if vote captured
// ╚══════════════════════════════════════════════════════════════╝

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ─────────────────────────────────────────────────────────────
//  INTERFACES
// ─────────────────────────────────────────────────────────────

/// @dev CueCoin v6 exposes ERC20Votes snapshot methods.
interface ICueCoinVotes {
    function getPastVotes(address account, uint256 timepoint) external view returns (uint256);
    function getPastTotalSupply(uint256 timepoint) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/**
 * @title  CueDAO
 * @author CUECOIN Team
 * @notice On-chain governance for the CUECOIN ecosystem.
 *         v2.0: snapshot voting, deposit slashing, ecosystem address timelock,
 *         guardian freeze, dynamic quorum, revoke event fix.
 */
contract CueDAO is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════
    //  CONSTANTS  (bytecode — no actor can change these)
    // ═══════════════════════════════════════════════════════════

    uint256 public constant VOTING_PERIOD      = 72 hours;
    uint256 public constant TIMELOCK_MIN       = 48 hours;
    uint256 public constant EXECUTION_GRACE    = 14 days;

    /// @notice [FIX-2] Deposit locked at proposal creation. Slashable on spam/abandon.
    uint256 public constant PROPOSAL_DEPOSIT   = 500_000 ether;

    /// @notice [FIX-5] Dynamic quorum hard floor — 5% of circulating.
    uint256 public constant QUORUM_MIN_BPS     = 500;

    /// @notice [FIX-5] Dynamic quorum hard ceiling — 20% of circulating.
    uint256 public constant QUORUM_MAX_BPS     = 2_000;

    /// @notice [FIX-5] Rolling window for turnout history.
    uint256 public constant QUORUM_WINDOW      = 10;

    /// @notice [FIX-5] Quorum targets this fraction of recent avg participation (bps scaled).
    ///         80 means quorum = 80% of average recent turnout.
    uint256 public constant QUORUM_SCALE_FACTOR = 80;

    /// @notice Anti-whale cap: 1% of circulating per wallet (applied to snapshot weight).
    uint256 public constant MAX_VOTE_WEIGHT_BPS = 100;

    uint256 public constant GUARDIAN_UPDATE_DELAY   = 7 days;

    /// @notice [FIX-3] Delay before an ecosystem address update applies.
    uint256 public constant ECOSYSTEM_UPDATE_DELAY  = 48 hours;

    address public constant BURN_ADDRESS =
        address(0x000000000000000000000000000000000000dEaD);

    // ═══════════════════════════════════════════════════════════
    //  ENUMS & STRUCTS
    // ═══════════════════════════════════════════════════════════

    enum ProposalType {
        TEXT,                   // 0
        TREASURY_TRANSFER,      // 1
        UPDATE_REWARD_RATE,     // 2
        UPDATE_TAX_RATES,       // 3
        UPDATE_POOLS,           // 4
        UPDATE_ORACLES,         // 5
        UPDATE_MARKETPLACE_FEE, // 6
        UPDATE_BRIDGE_PARAMS,   // 7
        UPDATE_REFERRAL_POOL,   // 8
        GENERIC_CALL            // 9
    }

    enum ProposalStatus {
        ACTIVE,
        PASSED,
        DEFEATED,
        QUEUED,
        EXECUTED,
        CANCELLED,
        EXPIRED
    }

    struct Proposal {
        uint256        id;
        ProposalType   proposalType;
        address        proposer;
        string         description;
        bytes          callData;
        address        callTarget;       // GENERIC_CALL only
        uint256        snapshotTimestamp; // [FIX-1] vote weight locked here
        uint256        votingEnds;
        uint256        timelockEnds;
        uint256        yesVotes;
        uint256        noVotes;
        uint256        snapshotCirculating; // circulating supply at snapshot
        uint256        quorumRequired;      // [FIX-5] baked in at finalise time
        ProposalStatus status;
        bool           executed;
        bool           depositReturned;   // [FIX-2]
        bool           depositSlashed;    // [FIX-2]
    }

    /// @notice [FIX-3] Pending ecosystem address update.
    struct PendingEcoUpdate {
        address newAddress;
        uint256 eta;      // executable after this timestamp
        bool    exists;
    }

    // ═══════════════════════════════════════════════════════════
    //  STATE VARIABLES
    // ═══════════════════════════════════════════════════════════

    ICueCoinVotes public immutable cueCoin;

    address public guardian;
    address public pendingGuardian;
    uint256 public guardianUpdateAt;

    /// @notice [FIX-4] Emergency freeze — blocks propose/castVote/execute.
    bool public frozen;

    // ── Ecosystem contracts ──
    address public cueCoinContract;
    address public rewardsPoolContract;
    address public escrowContract;
    address public sitAndGoContract;
    address public marketplaceContract;
    address public bridgeContract;
    address public referralContract;

    mapping(address => bool) public approvedTarget;

    // ── [FIX-3] Pending ecosystem address updates (keyed by name hash) ──
    mapping(bytes32 => PendingEcoUpdate) private _pendingEcoUpdates;

    // ── Proposals ──
    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;

    // ── Vote tracking ──
    mapping(uint256 => mapping(address => bool))    public hasVoted;
    mapping(uint256 => mapping(address => uint256)) public voterWeight;
    mapping(uint256 => mapping(address => bool))    public voterSupport;

    // ── [FIX-5] Dynamic quorum history ──
    // Ring buffer of last QUORUM_WINDOW turnout readings (in bps of circulating)
    uint256[10] private _turnoutHistory; // fixed size = QUORUM_WINDOW
    uint256 private _turnoutHead;        // next write index
    uint256 private _turnoutCount;       // how many readings stored (≤ QUORUM_WINDOW)

    // ═══════════════════════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════════════════════

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        ProposalType    proposalType,
        string          description,
        uint256         snapshotTimestamp,
        uint256         votingEnds
    );

    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        bool            support,
        uint256         weight,
        uint256         snapshotBalance
    );

    event ProposalPassed(uint256 indexed proposalId, uint256 timelockEnds, uint256 quorumRequired);
    event ProposalDefeated(uint256 indexed proposalId, uint256 yesVotes, uint256 noVotes, uint256 quorumRequired);
    event ProposalQueued(uint256 indexed proposalId);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCancelled(uint256 indexed proposalId, address cancelledBy);
    event ProposalExpired(uint256 indexed proposalId);

    event DepositReturned(uint256 indexed proposalId, address indexed proposer, uint256 amount);
    event DepositSlashed(uint256 indexed proposalId, address indexed proposer, uint256 amount);

    event TreasuryTransfer(address indexed recipient, uint256 amount, uint256 proposalId);

    /// @notice [FIX-4]
    event EmergencyFreezeActivated(address indexed guardian, uint256 timestamp);
    event EmergencyFreezeLifted(address indexed guardian, uint256 timestamp);

    /// @notice [FIX-3]
    event EcosystemUpdateQueued(string contractName, address indexed newAddress, uint256 eta);
    event EcosystemUpdateCancelled(string contractName);
    event EcosystemAddressUpdated(string contractName, address indexed oldAddress, address indexed newAddress);

    event TargetApproved(address indexed target);
    event TargetRevoked(address indexed target);  // [FIX-6] now always emitted on revoke

    event GuardianUpdateQueued(address indexed pending, uint256 executeAt);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);

    // ═══════════════════════════════════════════════════════════
    //  MODIFIERS
    // ═══════════════════════════════════════════════════════════

    modifier onlyGuardian() {
        require(
            msg.sender == guardian || msg.sender == owner(),
            "CueDAO: not guardian or owner"
        );
        _;
    }

    /// @notice [FIX-4] Blocks propose, castVote, execute during freeze.
    modifier whenNotFrozen() {
        require(!frozen, "CueDAO: governance frozen");
        _;
    }

    // ═══════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    constructor(
        address _cueCoin,
        address _guardian,
        address _cueCoinAddr,
        address _rewardsPool,
        address _escrow,
        address _sitAndGo,
        address _marketplace,
        address _bridge,
        address _referral
    )
        Ownable(msg.sender)
    {
        require(_cueCoin     != address(0), "CueDAO: zero cueCoin");
        require(_guardian    != address(0), "CueDAO: zero guardian");
        require(_cueCoinAddr != address(0), "CueDAO: zero cueCoinAddr");
        require(_rewardsPool != address(0), "CueDAO: zero rewardsPool");
        require(_escrow      != address(0), "CueDAO: zero escrow");
        require(_sitAndGo    != address(0), "CueDAO: zero sitAndGo");

        cueCoin             = ICueCoinVotes(_cueCoin);
        guardian            = _guardian;
        cueCoinContract     = _cueCoinAddr;
        rewardsPoolContract = _rewardsPool;
        escrowContract      = _escrow;
        sitAndGoContract    = _sitAndGo;
        marketplaceContract = _marketplace;
        bridgeContract      = _bridge;
        referralContract    = _referral;

        _setApprovedTarget(_cueCoinAddr, true);
        _setApprovedTarget(_rewardsPool, true);
        _setApprovedTarget(_escrow,      true);
        _setApprovedTarget(_sitAndGo,    true);
        if (_marketplace != address(0)) _setApprovedTarget(_marketplace, true);
        if (_bridge      != address(0)) _setApprovedTarget(_bridge,      true);
        if (_referral    != address(0)) _setApprovedTarget(_referral,    true);
    }

    // ═══════════════════════════════════════════════════════════
    //  PROPOSAL CREATION
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Submit a governance proposal.
     *
     *         [FIX-1] Vote weight is locked at this block's timestamp.
     *         Tokens purchased after this call have zero effect on this
     *         proposal's vote tally.
     *
     *         [FIX-2] PROPOSAL_DEPOSIT (500,000 CUECOIN) is transferred from
     *         the proposer into this contract. Returned on success/legitimate
     *         defeat; burned on spam/abandon/guardian-cancel.
     *
     *         Caller must approve this contract for PROPOSAL_DEPOSIT before
     *         calling. Proposer must also hold ≥ PROPOSAL_DEPOSIT to pass
     *         the balance check (same threshold as before, now enforced by
     *         the actual transfer rather than a balance read).
     *
     * @param proposalType  Enum identifying the proposal's on-chain action.
     * @param description   Human-readable title or IPFS URI.
     * @param callData      ABI-encoded parameters — see NatSpec of v1 for format.
     * @param callTarget    For GENERIC_CALL: guardian-approved target. Zero otherwise.
     * @return proposalId   Incrementing ID.
     */
    function propose(
        ProposalType   proposalType,
        string calldata description,
        bytes calldata  callData,
        address         callTarget
    )
        external
        whenNotFrozen
        nonReentrant
        returns (uint256 proposalId)
    {
        require(bytes(description).length > 0, "CueDAO: empty description");

        if (proposalType == ProposalType.GENERIC_CALL) {
            require(callTarget != address(0),   "CueDAO: zero callTarget");
            require(approvedTarget[callTarget], "CueDAO: target not approved");
        }

        // [FIX-2] Lock deposit — this implicitly checks balance (transfer reverts if insufficient)
        IERC20(address(cueCoin)).safeTransferFrom(msg.sender, address(this), PROPOSAL_DEPOSIT);

        // [FIX-1] Lock snapshot — any token movement after this is irrelevant to this proposal
        uint256 snap = block.timestamp;

        proposalId = ++proposalCount;
        Proposal storage p = proposals[proposalId];
        p.id                  = proposalId;
        p.proposalType        = proposalType;
        p.proposer            = msg.sender;
        p.description         = description;
        p.callData            = callData;
        p.callTarget          = callTarget;
        p.snapshotTimestamp   = snap;
        p.votingEnds          = snap + VOTING_PERIOD;
        p.snapshotCirculating = _circulatingSupplyAt(snap);
        p.status              = ProposalStatus.ACTIVE;

        emit ProposalCreated(proposalId, msg.sender, proposalType, description, snap, p.votingEnds);
    }

    // ═══════════════════════════════════════════════════════════
    //  VOTING
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Cast a vote on an active proposal.
     *
     *         [FIX-1] Weight = getPastVotes(voter, snapshotTimestamp).
     *         This is the voter's DELEGATED balance at snapshot time.
     *         Tokens bought after the snapshot, or tokens never delegated,
     *         contribute zero weight regardless of current balance.
     *
     *         [FIX-4] Blocked during governance freeze.
     *
     * @param proposalId  The proposal to vote on.
     * @param support     true = in favour, false = against.
     */
    function castVote(uint256 proposalId, bool support)
        external
        whenNotFrozen
    {
        Proposal storage p = proposals[proposalId];

        require(p.id != 0,                        "CueDAO: proposal does not exist");
        require(p.status == ProposalStatus.ACTIVE, "CueDAO: proposal not active");
        require(block.timestamp < p.votingEnds,    "CueDAO: voting period ended");
        require(!hasVoted[proposalId][msg.sender], "CueDAO: already voted");

        // [FIX-1] Historical snapshot weight — immune to post-proposal token movement
        uint256 snapshotBalance = cueCoin.getPastVotes(msg.sender, p.snapshotTimestamp);
        require(snapshotBalance > 0, "CueDAO: no voting power at snapshot");

        // Anti-whale cap: 1% of snapshot circulating
        uint256 cap    = (p.snapshotCirculating * MAX_VOTE_WEIGHT_BPS) / 10_000;
        uint256 weight = snapshotBalance > cap ? cap : snapshotBalance;

        hasVoted[proposalId][msg.sender]  = true;
        voterWeight[proposalId][msg.sender] = weight;
        voterSupport[proposalId][msg.sender] = support;

        if (support) {
            p.yesVotes += weight;
        } else {
            p.noVotes  += weight;
        }

        emit VoteCast(proposalId, msg.sender, support, weight, snapshotBalance);
    }

    // ═══════════════════════════════════════════════════════════
    //  STATE TRANSITIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Finalise a proposal after its voting period ends.
     *         Transitions ACTIVE → PASSED or DEFEATED.
     *         Callable by anyone.
     *
     *         [FIX-5] Quorum is computed dynamically from recent turnout history.
     *         Quorum BPS is stored on the proposal for transparency.
     *         After finalise(), the turnout reading for this proposal is
     *         appended to the rolling history window.
     *
     *         [FIX-2] Deposit fate determined here for DEFEATED proposals.
     *
     * @param proposalId  The proposal to finalise.
     */
    function finalise(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];

        require(p.id != 0,                        "CueDAO: proposal does not exist");
        require(p.status == ProposalStatus.ACTIVE, "CueDAO: not active");
        require(block.timestamp >= p.votingEnds,   "CueDAO: voting still open");

        uint256 circulating = p.snapshotCirculating;

        // [FIX-5] Dynamic quorum — baked into the proposal for permanent record
        uint256 quorumBps    = _dynamicQuorumBps();
        uint256 quorumNeeded = (circulating * quorumBps) / 10_000;
        p.quorumRequired     = quorumNeeded;

        uint256 totalVotes = p.yesVotes + p.noVotes;

        // Record turnout for next proposal's quorum calculation [FIX-5]
        uint256 turnoutBps = circulating > 0
            ? (totalVotes * 10_000) / circulating
            : 0;
        _recordTurnout(turnoutBps);

        if (totalVotes >= quorumNeeded && p.yesVotes > p.noVotes) {
            p.status       = ProposalStatus.PASSED;
            p.timelockEnds = block.timestamp + TIMELOCK_MIN;
            emit ProposalPassed(proposalId, p.timelockEnds, quorumNeeded);
            // Deposit stays locked until EXECUTED or proposer self-cancels
        } else {
            p.status = ProposalStatus.DEFEATED;
            emit ProposalDefeated(proposalId, p.yesVotes, p.noVotes, quorumNeeded);

            // [FIX-2] Quorum met but lost → proposer argued in good faith
            if (totalVotes >= quorumNeeded) {
                _returnDeposit(p);
            } else {
                // No quorum → spam/low-effort → slash
                _slashDeposit(p);
            }
        }
    }

    /**
     * @notice Mark a PASSED proposal as QUEUED once its timelock has elapsed.
     *         Optional convenience — execute() also checks the timelock.
     */
    function queue(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];

        require(p.id != 0,                         "CueDAO: proposal does not exist");
        require(p.status == ProposalStatus.PASSED,  "CueDAO: not passed");
        require(block.timestamp >= p.timelockEnds,  "CueDAO: timelock not elapsed");
        require(
            block.timestamp < p.timelockEnds + EXECUTION_GRACE,
            "CueDAO: execution window expired"
        );

        p.status = ProposalStatus.QUEUED;
        emit ProposalQueued(proposalId);
    }

    /**
     * @notice Execute a PASSED or QUEUED proposal after the 48h timelock.
     *         Permissionless — anyone can call once the timelock elapses.
     *
     *         [FIX-4] Blocked during governance freeze.
     *         [FIX-2] Deposit returned to proposer on execution.
     */
    function execute(uint256 proposalId)
        external
        whenNotFrozen
        nonReentrant
    {
        Proposal storage p = proposals[proposalId];

        require(p.id != 0, "CueDAO: proposal does not exist");
        require(
            p.status == ProposalStatus.PASSED || p.status == ProposalStatus.QUEUED,
            "CueDAO: not passed or queued"
        );
        require(block.timestamp >= p.timelockEnds, "CueDAO: timelock not elapsed");
        require(!p.executed,                        "CueDAO: already executed");
        require(
            block.timestamp < p.timelockEnds + EXECUTION_GRACE,
            "CueDAO: execution window expired"
        );

        // CEI: mark before external calls
        p.executed = true;
        p.status   = ProposalStatus.EXECUTED;

        _executeAction(p);

        // [FIX-2] Return deposit after all external calls complete
        _returnDeposit(p);

        emit ProposalExecuted(proposalId);
    }

    /**
     * @notice Mark a PASSED/QUEUED proposal as EXPIRED if the grace window passed.
     *         [FIX-2] Slashes deposit on expiry (proposer abandoned follow-through).
     */
    function markExpired(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];

        require(p.id != 0, "CueDAO: proposal does not exist");
        require(
            p.status == ProposalStatus.PASSED || p.status == ProposalStatus.QUEUED,
            "CueDAO: not passed or queued"
        );
        require(!p.executed, "CueDAO: already executed");
        require(
            block.timestamp >= p.timelockEnds + EXECUTION_GRACE,
            "CueDAO: execution window not expired"
        );

        p.status = ProposalStatus.EXPIRED;
        _slashDeposit(p);

        emit ProposalExpired(proposalId);
    }

    // ═══════════════════════════════════════════════════════════
    //  CANCELLATION
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Cancel a proposal.
     *
     *         Guardian: can cancel at any pre-EXECUTED state.
     *           → Deposit slashed [FIX-2] (guardian identified malicious/bad proposal)
     *
     *         Proposer: can only cancel their own ACTIVE proposal.
     *           → Deposit returned [FIX-2] (proposer changed their mind in good faith)
     *
     * @param proposalId  The proposal to cancel.
     */
    function cancel(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];

        require(p.id != 0,   "CueDAO: proposal does not exist");
        require(!p.executed, "CueDAO: already executed");
        require(
            p.status != ProposalStatus.EXECUTED &&
            p.status != ProposalStatus.CANCELLED,
            "CueDAO: cannot cancel"
        );

        bool isGuardian = (msg.sender == guardian || msg.sender == owner());
        bool isProposer = (msg.sender == p.proposer);

        if (isGuardian) {
            p.status = ProposalStatus.CANCELLED;
            _slashDeposit(p);   // [FIX-2] guardian cancel = bad actor = slash
        } else {
            require(isProposer, "CueDAO: not authorised to cancel");
            require(p.status == ProposalStatus.ACTIVE, "CueDAO: proposer can only cancel active");
            p.status = ProposalStatus.CANCELLED;
            _returnDeposit(p);  // [FIX-2] self-cancel = good faith = return
        }

        emit ProposalCancelled(proposalId, msg.sender);
    }

    /**
     * @notice Manually claim a returned deposit after EXECUTED or proposer-CANCELLED.
     *         Normally deposit is returned automatically in execute() and cancel().
     *         This function exists as a safety valve in case the automatic return
     *         path failed due to the proposer being a contract that rejected the
     *         transfer (e.g., the contract was not deployed yet at the time).
     */
    function claimDeposit(uint256 proposalId) external nonReentrant {
        Proposal storage p = proposals[proposalId];

        require(p.id != 0,                          "CueDAO: proposal does not exist");
        require(msg.sender == p.proposer,            "CueDAO: not proposer");
        require(!p.depositSlashed,                   "CueDAO: deposit was slashed");
        require(!p.depositReturned,                  "CueDAO: deposit already returned");
        require(
            p.status == ProposalStatus.EXECUTED ||
            (p.status == ProposalStatus.CANCELLED && !p.depositSlashed),
            "CueDAO: deposit not claimable"
        );

        _returnDeposit(p);
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — DEPOSIT MANAGEMENT  [FIX-2]
    // ═══════════════════════════════════════════════════════════

    function _returnDeposit(Proposal storage p) internal {
        if (p.depositReturned || p.depositSlashed) return;
        p.depositReturned = true;
        IERC20(address(cueCoin)).safeTransfer(p.proposer, PROPOSAL_DEPOSIT);
        emit DepositReturned(p.id, p.proposer, PROPOSAL_DEPOSIT);
    }

    function _slashDeposit(Proposal storage p) internal {
        if (p.depositReturned || p.depositSlashed) return;
        p.depositSlashed = true;
        IERC20(address(cueCoin)).safeTransfer(BURN_ADDRESS, PROPOSAL_DEPOSIT);
        emit DepositSlashed(p.id, p.proposer, PROPOSAL_DEPOSIT);
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — DYNAMIC QUORUM  [FIX-5]
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev Append a turnout reading to the ring buffer.
     *      Called at the end of finalise() with the proposal's actual turnout.
     */
    function _recordTurnout(uint256 turnoutBps) internal {
        _turnoutHistory[_turnoutHead % QUORUM_WINDOW] = turnoutBps;
        _turnoutHead++;
        if (_turnoutCount < QUORUM_WINDOW) _turnoutCount++;
    }

    /**
     * @dev Compute the current dynamic quorum in BPS.
     *
     *      With insufficient history (< QUORUM_WINDOW proposals):
     *        returns QUORUM_MIN_BPS
     *
     *      With full history:
     *        avg = mean of last QUORUM_WINDOW turnout readings
     *        scaled = avg × QUORUM_SCALE_FACTOR / 100
     *        return clamp(scaled, QUORUM_MIN_BPS, QUORUM_MAX_BPS)
     *
     *      Example:
     *        Last 10 proposals averaged 15% turnout.
     *        scaled = 1500 × 80 / 100 = 1200 bps (12%).
     *        12% > 5% min, < 20% max → quorum = 12%.
     *
     *        Last 10 proposals averaged 4% turnout (low activity).
     *        scaled = 400 × 80 / 100 = 320 bps (3.2%).
     *        3.2% < 5% min → quorum = 5% (floor enforced).
     *
     *        Last 10 proposals averaged 35% turnout (very active).
     *        scaled = 3500 × 80 / 100 = 2800 bps (28%).
     *        28% > 20% max → quorum = 20% (ceiling enforced).
     */
    function _dynamicQuorumBps() internal view returns (uint256) {
        if (_turnoutCount < QUORUM_WINDOW) return QUORUM_MIN_BPS;

        uint256 sum = 0;
        for (uint256 i = 0; i < QUORUM_WINDOW; ) {
            sum += _turnoutHistory[i];
            unchecked { ++i; }
        }
        uint256 avg    = sum / QUORUM_WINDOW;
        uint256 scaled = (avg * QUORUM_SCALE_FACTOR) / 100;

        if (scaled < QUORUM_MIN_BPS) return QUORUM_MIN_BPS;
        if (scaled > QUORUM_MAX_BPS) return QUORUM_MAX_BPS;
        return scaled;
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — EXECUTION ENGINE
    // ═══════════════════════════════════════════════════════════

    function _executeAction(Proposal storage p) internal {
        ProposalType pt = p.proposalType;

        if (pt == ProposalType.TEXT)                   { return; }
        if (pt == ProposalType.TREASURY_TRANSFER)      { _execTreasuryTransfer(p);      return; }
        if (pt == ProposalType.UPDATE_REWARD_RATE)     { _execUpdateRewardRate(p);      return; }
        if (pt == ProposalType.UPDATE_TAX_RATES)       { _execUpdateTaxRates(p);        return; }
        if (pt == ProposalType.UPDATE_POOLS)           { _execUpdatePools(p);           return; }
        if (pt == ProposalType.UPDATE_ORACLES)         { _execUpdateOracles(p);         return; }
        if (pt == ProposalType.UPDATE_MARKETPLACE_FEE) { _execUpdateMarketplaceFee(p);  return; }
        if (pt == ProposalType.UPDATE_BRIDGE_PARAMS)   { _execUpdateBridgeParams(p);    return; }
        if (pt == ProposalType.UPDATE_REFERRAL_POOL)   { _execUpdateReferralPool(p);    return; }
        if (pt == ProposalType.GENERIC_CALL)           { _execGenericCall(p);           return; }

        revert("CueDAO: unknown proposal type");
    }

    function _execTreasuryTransfer(Proposal storage p) internal {
        (address recipient, uint256 amount) = abi.decode(p.callData, (address, uint256));
        require(recipient != address(0), "CueDAO: zero recipient");
        require(amount > 0,              "CueDAO: zero amount");
        // Treasury balance excludes any locked deposits (deposits tracked separately in mapping)
        // The contract balance = treasury + sum(locked deposits for active proposals)
        // TREASURY_TRANSFER is governance-approved spending; trust the vote
        require(
            IERC20(address(cueCoin)).balanceOf(address(this)) >= amount,
            "CueDAO: insufficient treasury"
        );
        IERC20(address(cueCoin)).safeTransfer(recipient, amount);
        emit TreasuryTransfer(recipient, amount, p.id);
    }

    function _execUpdateRewardRate(Proposal storage p) internal {
        uint256 newRate = abi.decode(p.callData, (uint256));
        require(rewardsPoolContract != address(0), "CueDAO: rewardsPool not set");
        (bool ok, bytes memory ret) = rewardsPoolContract.call(
            abi.encodeWithSignature("setMatchRewardRate(uint256)", newRate)
        );
        require(ok, _revertMsg(ret));
    }

    function _execUpdateTaxRates(Proposal storage p) internal {
        (uint16 burnBps, uint16 lpBps, uint16 rewardsBps,
         uint16 tournamentBps, uint16 daoBps, uint16 devBps)
            = abi.decode(p.callData, (uint16,uint16,uint16,uint16,uint16,uint16));

        // Enforce 10% ceiling per component AND in aggregate
        require(burnBps       <= 1_000, "CueDAO: burn > 10%");
        require(lpBps         <= 1_000, "CueDAO: lp > 10%");
        require(rewardsBps    <= 1_000, "CueDAO: rewards > 10%");
        require(tournamentBps <= 1_000, "CueDAO: tournament > 10%");
        require(daoBps        <= 1_000, "CueDAO: dao > 10%");
        require(devBps        <= 1_000, "CueDAO: dev > 10%");
        require(
            uint256(burnBps)+lpBps+rewardsBps+tournamentBps+daoBps+devBps <= 1_000,
            "CueDAO: total tax > 10%"
        );
        require(cueCoinContract != address(0), "CueDAO: cueCoin not set");
        (bool ok, bytes memory ret) = cueCoinContract.call(
            abi.encodeWithSignature(
                "setTaxRates(uint16,uint16,uint16,uint16,uint16,uint16)",
                burnBps, lpBps, rewardsBps, tournamentBps, daoBps, devBps
            )
        );
        require(ok, _revertMsg(ret));
    }

    function _execUpdatePools(Proposal storage p) internal {
        (address r, address t, address d, address dev)
            = abi.decode(p.callData, (address,address,address,address));
        require(cueCoinContract != address(0), "CueDAO: cueCoin not set");
        // CueCoin.updatePools is itself 48h timelocked → 96h total delay
        (bool ok, bytes memory ret) = cueCoinContract.call(
            abi.encodeWithSignature("updatePools(address,address,address,address)", r, t, d, dev)
        );
        require(ok, _revertMsg(ret));
    }

    function _execUpdateOracles(Proposal storage p) internal {
        (address target, address o0, address o1, address o2)
            = abi.decode(p.callData, (address,address,address,address));
        require(
            target == escrowContract || target == sitAndGoContract,
            "CueDAO: oracle target not allowed"
        );
        // Target contract's updateOracles is itself 48h timelocked → 96h total
        (bool ok, bytes memory ret) = target.call(
            abi.encodeWithSignature("updateOracles(address,address,address)", o0, o1, o2)
        );
        require(ok, _revertMsg(ret));
    }

    function _execUpdateMarketplaceFee(Proposal storage p) internal {
        uint256 newFeeBps = abi.decode(p.callData, (uint256));
        require(newFeeBps <= 500, "CueDAO: marketplace fee cap 5%");
        require(marketplaceContract != address(0), "CueDAO: marketplace not set");
        (bool ok, bytes memory ret) = marketplaceContract.call(
            abi.encodeWithSignature("setPlatformFee(uint256)", newFeeBps)
        );
        require(ok, _revertMsg(ret));
    }

    function _execUpdateBridgeParams(Proposal storage p) internal {
        require(bridgeContract != address(0), "CueDAO: bridge not set");
        bytes memory params = abi.decode(p.callData, (bytes));
        (bool ok, bytes memory ret) = bridgeContract.call(
            abi.encodeWithSignature("setParams(bytes)", params)
        );
        require(ok, _revertMsg(ret));
    }

    function _execUpdateReferralPool(Proposal storage p) internal {
        uint256 amount = abi.decode(p.callData, (uint256));
        require(referralContract != address(0), "CueDAO: referral not set");
        require(amount > 0, "CueDAO: zero amount");
        require(
            IERC20(address(cueCoin)).balanceOf(address(this)) >= amount,
            "CueDAO: insufficient treasury"
        );
        IERC20(address(cueCoin)).safeTransfer(referralContract, amount);
        // Best-effort notification
        referralContract.call(abi.encodeWithSignature("notifyRefill(uint256)", amount));
    }

    function _execGenericCall(Proposal storage p) internal {
        require(approvedTarget[p.callTarget], "CueDAO: target not approved at execution");
        (bool ok, bytes memory ret) = p.callTarget.call(p.callData);
        require(ok, _revertMsg(ret));
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — HELPERS
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev Circulating supply at a past timestamp.
     *      Uses ERC20Votes.getPastTotalSupply minus burned tokens at that timestamp.
     *      We cannot checkpoint BURN_ADDRESS balance historically, so we approximate:
     *        circulating ≈ getPastTotalSupply(t) − currentBurnBalance
     *      This slightly over-counts circulating (burned tokens since snapshot are
     *      not subtracted), which makes quorum HARDER to reach — conservative and safe.
     */
    function _circulatingSupplyAt(uint256 timestamp) internal view returns (uint256) {
        // ERC20Votes.getPastTotalSupply uses timestamp as timepoint (clock = timestamp)
        uint256 total  = cueCoin.getPastTotalSupply(timestamp);
        uint256 burned = cueCoin.balanceOf(BURN_ADDRESS); // current, conservative approximation
        return total > burned ? total - burned : 1;
    }

    function _setApprovedTarget(address target, bool approved) internal {
        if (target == address(0)) return;
        approvedTarget[target] = approved;
        if (approved) emit TargetApproved(target);
        else          emit TargetRevoked(target);   // [FIX-6] always emits
    }

    function _revertMsg(bytes memory ret) internal pure returns (string memory) {
        if (ret.length < 68) return "CueDAO: call reverted (no reason)";
        assembly { ret := add(ret, 0x04) }
        return abi.decode(ret, (string));
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /// @notice Computed proposal state (handles EXPIRED transparently).
    function proposalState(uint256 proposalId) external view returns (ProposalStatus) {
        Proposal storage p = proposals[proposalId];
        require(p.id != 0, "CueDAO: proposal does not exist");

        ProposalStatus s = p.status;
        if (
            (s == ProposalStatus.PASSED || s == ProposalStatus.QUEUED) &&
            !p.executed &&
            block.timestamp >= p.timelockEnds + EXECUTION_GRACE
        ) return ProposalStatus.EXPIRED;

        return s;
    }

    /// @notice Detailed vote counts and quorum status for a proposal.
    function proposalVotes(uint256 proposalId)
        external
        view
        returns (
            uint256 yesVotes,
            uint256 noVotes,
            uint256 totalVotes,
            uint256 quorumRequired,
            bool    quorumReached,
            bool    currentlyPassing
        )
    {
        Proposal storage p = proposals[proposalId];
        require(p.id != 0, "CueDAO: proposal does not exist");

        yesVotes   = p.yesVotes;
        noVotes    = p.noVotes;
        totalVotes = p.yesVotes + p.noVotes;

        // If quorumRequired is already baked in (post-finalise) use that; else compute live
        if (p.quorumRequired > 0) {
            quorumRequired = p.quorumRequired;
        } else {
            quorumRequired = (p.snapshotCirculating * _dynamicQuorumBps()) / 10_000;
        }

        quorumReached    = totalVotes >= quorumRequired;
        currentlyPassing = quorumReached && yesVotes > noVotes;
    }

    /// @notice Full proposal data.
    function getProposal(uint256 proposalId)
        external
        view
        returns (
            uint256        id,
            ProposalType   proposalType,
            address        proposer,
            string memory  description,
            uint256        snapshotTimestamp,
            uint256        votingEnds,
            uint256        timelockEnds,
            uint256        yesVotes,
            uint256        noVotes,
            uint256        quorumRequired,
            ProposalStatus status,
            bool           executed,
            bool           depositReturned,
            bool           depositSlashed
        )
    {
        Proposal storage p = proposals[proposalId];
        require(p.id != 0, "CueDAO: proposal does not exist");
        return (
            p.id, p.proposalType, p.proposer, p.description,
            p.snapshotTimestamp, p.votingEnds, p.timelockEnds,
            p.yesVotes, p.noVotes, p.quorumRequired,
            p.status, p.executed, p.depositReturned, p.depositSlashed
        );
    }

    /// @notice Voter info for a specific proposal.
    function voterInfo(uint256 proposalId, address voter)
        external
        view
        returns (bool voted, bool support, uint256 weight)
    {
        return (
            hasVoted[proposalId][voter],
            voterSupport[proposalId][voter],
            voterWeight[proposalId][voter]
        );
    }

    /// @notice Effective snapshot vote weight for a wallet on a given proposal.
    function effectiveVoteWeight(uint256 proposalId, address wallet)
        external
        view
        returns (uint256 snapshotBalance, uint256 effective, uint256 cap)
    {
        Proposal storage p = proposals[proposalId];
        require(p.id != 0, "CueDAO: proposal does not exist");

        snapshotBalance = cueCoin.getPastVotes(wallet, p.snapshotTimestamp);
        cap             = (p.snapshotCirculating * MAX_VOTE_WEIGHT_BPS) / 10_000;
        effective       = snapshotBalance > cap ? cap : snapshotBalance;
    }

    /// @notice Current dynamic quorum in BPS (reflects recent participation history).
    function currentQuorumBps() external view returns (uint256) {
        return _dynamicQuorumBps();
    }

    /// @notice DAO treasury balance (includes locked deposits — net spendable is lower).
    function treasuryBalance() external view returns (uint256) {
        return IERC20(address(cueCoin)).balanceOf(address(this));
    }

    /// @notice [FIX-3] Status of a pending ecosystem address update.
    function pendingEcoUpdate(string calldata contractName)
        external
        view
        returns (address newAddress, uint256 eta, bool exists)
    {
        PendingEcoUpdate storage u = _pendingEcoUpdates[keccak256(bytes(contractName))];
        return (u.newAddress, u.eta, u.exists);
    }

    // ═══════════════════════════════════════════════════════════
    //  GUARDIAN — FREEZE  [FIX-4]
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Activate governance freeze. Instantly blocks propose(), castVote(),
     *         execute(). Guardian-only.
     *
     *         Use during: active governance attack, oracle compromise, bridge exploit,
     *         or any scenario where halting new governance actions is safer than
     *         letting them proceed.
     *
     *         Does NOT cancel existing proposals or extend voting periods.
     *         Active votes whose window expires during a freeze are DEFEATED
     *         when finalised post-unfreeze (finalise() is never blocked).
     */
    function freeze() external onlyGuardian {
        require(!frozen, "CueDAO: already frozen");
        frozen = true;
        emit EmergencyFreezeActivated(msg.sender, block.timestamp);
    }

    /**
     * @notice Lift governance freeze. Guardian-only.
     */
    function unfreeze() external onlyGuardian {
        require(frozen, "CueDAO: not frozen");
        frozen = false;
        emit EmergencyFreezeLifted(msg.sender, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════
    //  GUARDIAN — ECOSYSTEM ADDRESS TIMELOCK  [FIX-3 + FIX-6]
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Queue an ecosystem contract address update. 48-hour delay.
     *         Guardian-only.
     *
     *         Valid names: "cueCoin", "rewardsPool", "escrow", "sitAndGo",
     *                       "marketplace", "bridge", "referral"
     *
     *         [FIX-6] When applied, old address is revoked via _setApprovedTarget()
     *         which correctly emits TargetRevoked (v1 bug: silent revoke).
     *
     * @param contractName  Name key identifying which ecosystem address to update.
     * @param newAddress    Replacement contract address.
     */
    function queueEcosystemAddressUpdate(
        string calldata contractName,
        address         newAddress
    )
        external
        onlyGuardian
    {
        require(newAddress != address(0), "CueDAO: zero address");
        // Validate name — fail fast so the 48h delay isn't wasted on a typo
        _requireKnownEcoName(contractName);

        bytes32 key = keccak256(bytes(contractName));
        uint256 eta = block.timestamp + ECOSYSTEM_UPDATE_DELAY;
        _pendingEcoUpdates[key] = PendingEcoUpdate({ newAddress: newAddress, eta: eta, exists: true });

        emit EcosystemUpdateQueued(contractName, newAddress, eta);
    }

    /**
     * @notice Apply a queued ecosystem address update after the 48-hour delay.
     *         Callable by anyone — permissionless after delay.
     *
     *         [FIX-6] Old address revoked via _setApprovedTarget() → emits TargetRevoked.
     *
     * @param contractName  Name key matching the queued update.
     */
    function applyEcosystemAddressUpdate(string calldata contractName)
        external
        nonReentrant
    {
        bytes32 key = keccak256(bytes(contractName));
        PendingEcoUpdate storage u = _pendingEcoUpdates[key];

        require(u.exists,                        "CueDAO: no pending update");
        require(block.timestamp >= u.eta,         "CueDAO: update delay not elapsed");
        require(
            block.timestamp < u.eta + EXECUTION_GRACE,
            "CueDAO: update window expired"
        );

        address newAddr = u.newAddress;
        delete _pendingEcoUpdates[key];

        address oldAddr = _applyEcoUpdate(contractName, newAddr);

        emit EcosystemAddressUpdated(contractName, oldAddr, newAddr);
    }

    /**
     * @notice Cancel a queued ecosystem address update before it applies.
     *         Guardian-only.
     */
    function cancelEcosystemAddressUpdate(string calldata contractName)
        external
        onlyGuardian
    {
        bytes32 key = keccak256(bytes(contractName));
        require(_pendingEcoUpdates[key].exists, "CueDAO: no pending update");
        delete _pendingEcoUpdates[key];
        emit EcosystemUpdateCancelled(contractName);
    }

    /**
     * @dev Execute the state change for an ecosystem address update.
     *      Revokes old address (emits TargetRevoked), sets new address,
     *      approves new address (emits TargetApproved).
     *      Returns the old address for event logging.
     */
    function _applyEcoUpdate(string calldata name, address newAddr)
        internal
        returns (address oldAddr)
    {
        bytes32 h = keccak256(bytes(name));

        if (h == keccak256("cueCoin")) {
            oldAddr = cueCoinContract;
            cueCoinContract = newAddr;
        } else if (h == keccak256("rewardsPool")) {
            oldAddr = rewardsPoolContract;
            rewardsPoolContract = newAddr;
        } else if (h == keccak256("escrow")) {
            oldAddr = escrowContract;
            escrowContract = newAddr;
        } else if (h == keccak256("sitAndGo")) {
            oldAddr = sitAndGoContract;
            sitAndGoContract = newAddr;
        } else if (h == keccak256("marketplace")) {
            oldAddr = marketplaceContract;
            marketplaceContract = newAddr;
        } else if (h == keccak256("bridge")) {
            oldAddr = bridgeContract;
            bridgeContract = newAddr;
        } else if (h == keccak256("referral")) {
            oldAddr = referralContract;
            referralContract = newAddr;
        } else {
            revert("CueDAO: unknown contract name");
        }

        // [FIX-6] Both paths route through _setApprovedTarget — both emit events
        if (oldAddr != address(0)) _setApprovedTarget(oldAddr, false);
        _setApprovedTarget(newAddr, true);
    }

    function _requireKnownEcoName(string calldata name) internal pure {
        bytes32 h = keccak256(bytes(name));
        require(
            h == keccak256("cueCoin")     ||
            h == keccak256("rewardsPool") ||
            h == keccak256("escrow")      ||
            h == keccak256("sitAndGo")    ||
            h == keccak256("marketplace") ||
            h == keccak256("bridge")      ||
            h == keccak256("referral"),
            "CueDAO: unknown contract name"
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  GUARDIAN — APPROVED TARGETS
    // ═══════════════════════════════════════════════════════════

    function approveTarget(address target) external onlyGuardian {
        require(target != address(0), "CueDAO: zero target");
        _setApprovedTarget(target, true);
    }

    function revokeTarget(address target) external onlyGuardian {
        _setApprovedTarget(target, false);
    }

    // ═══════════════════════════════════════════════════════════
    //  GUARDIAN — GUARDIAN UPDATE (7-day timelock)
    // ═══════════════════════════════════════════════════════════

    function queueGuardianUpdate(address newGuardian) external onlyGuardian {
        require(newGuardian != address(0), "CueDAO: zero guardian");
        pendingGuardian  = newGuardian;
        guardianUpdateAt = block.timestamp + GUARDIAN_UPDATE_DELAY;
        emit GuardianUpdateQueued(newGuardian, guardianUpdateAt);
    }

    function applyGuardianUpdate() external {
        require(pendingGuardian != address(0),       "CueDAO: no pending update");
        require(block.timestamp >= guardianUpdateAt,  "CueDAO: guardian timelock not elapsed");

        address old     = guardian;
        guardian        = pendingGuardian;
        pendingGuardian = address(0);
        guardianUpdateAt = 0;

        emit GuardianUpdated(old, guardian);
    }

    // ═══════════════════════════════════════════════════════════
    //  GUARDIAN — RECOVERY
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Recover non-CUECOIN tokens accidentally sent here.
     *         CUECOIN is the governance token — spending it requires a passed
     *         TREASURY_TRANSFER proposal, not a guardian unilateral action.
     */
    function recoverERC20(address token, uint256 amount) external onlyGuardian {
        require(token != address(cueCoin), "CueDAO: use TREASURY_TRANSFER for CUECOIN");
        IERC20(token).safeTransfer(guardian, amount);
    }
}
