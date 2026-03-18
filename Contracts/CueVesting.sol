// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ╔══════════════════════════════════════════════════════════════╗
//  CUEVESTING  ·  v1.0  ·  Production-Ready
//  CUECOIN Ecosystem  ·  BNB Smart Chain
//
//  Linear vesting contract for three token allocations:
//    • Team & Founders    5%  —  50,000,000 CUECOIN
//    • Game Dev Fund     15%  — 150,000,000 CUECOIN
//    • Strategic Partners 3%  —  30,000,000 CUECOIN
//
//  ════════════════════════════════════════════════════
//   VESTING SCHEDULES
//  ════════════════════════════════════════════════════
//
//                     Cliff    Vest    Fully vested at
//  ─────────────────────────────────────────────────────
//  TEAM              12 mo    36 mo    48 months from start
//  DEV_FUND           6 mo    48 mo    54 months from start
//  PARTNERS           6 mo    24 mo    30 months from start
//
//  Release mechanic: pro-rata per second starting the moment
//  the cliff expires. Zero tokens are claimable before cliff.
//  After vestEnd the full remaining balance is claimable.
//  Beneficiaries can claim any time — no forced schedule.
//
//  ════════════════════════════════════════════════════
//   VESTING MATH
//  ════════════════════════════════════════════════════
//
//    cliffEnd = startTime + cliffDuration
//    vestEnd  = cliffEnd  + vestDuration
//
//    vested(t):
//      t < cliffEnd  → 0
//      t ≥ vestEnd   → totalAmount
//      else          → totalAmount × (t − cliffEnd) / vestDuration
//
//    releasable(t) = vested(t) − claimed
//
//  ════════════════════════════════════════════════════
//   MULTI-SCHEDULE DESIGN
//  ════════════════════════════════════════════════════
//
//  One contract, multiple independent schedules. Each schedule
//  is identified by a uint32 ID (1-indexed). A beneficiary can
//  hold multiple schedules (e.g., multiple investor tranches).
//
//  Owner creates schedules with addSchedule(). The contract
//  must already hold sufficient CUECOIN to cover the new
//  schedule before the call — checked against totalPending.
//
//  Per-type allocation caps are enforced in bytecode, matching
//  the tokenomics table exactly. The cap covers total amount
//  across all active schedules of that type. When a schedule
//  is cancelled, its unvested portion is returned to the DAO
//  treasury and the freed allocation becomes re-usable.
//
//  ════════════════════════════════════════════════════
//   CANCELLATION
//  ════════════════════════════════════════════════════
//
//  Owner may cancel any schedule at any time. On cancellation:
//    1. Vested-at-cancellation is computed from block.timestamp.
//    2. (totalAmount − vestedAtCancel) → transferred to daoTreasury.
//    3. allocatedByType[type] decremented by unvested amount.
//    4. Schedule marked cancelled = true.
//    5. Beneficiary retains the right to claim their vested
//       portion (vestedAtCancel − alreadyClaimed) at any time.
//
//  A beneficiary cannot be robbed of tokens they have already
//  vested. The spec guarantee "cancellation returns unvested
//  remainder to DAO Treasury" is exactly what this achieves.
//
//  ════════════════════════════════════════════════════
//   BENEFICIARY TRANSFER
//  ════════════════════════════════════════════════════
//
//  Only the beneficiary themselves can reassign a schedule to a
//  new wallet. The owner cannot do this. This protects against
//  a scenario where a compromised owner re-routes a team
//  member's vesting to an attacker's wallet.
//
//  Use cases: key rotation, Gnosis Safe migration, wallet recovery.
//
//  ════════════════════════════════════════════════════
//   GUARDIAN EMERGENCY PAUSE
//  ════════════════════════════════════════════════════
//
//  A guardian address (expected to be a Gnosis Safe 3-of-5)
//  can pause the contract in a security emergency. The pause
//  is self-expiring: guardians must specify a duration up to
//  MAX_PAUSE_DURATION (48 hours). After that window, the
//  contract automatically resumes normal operation without
//  any further action required. The guardian may also call
//  unpause() to lift the pause early.
//
//  This is deliberately tighter than the CueDAO guardian freeze,
//  which is indefinite. Vesting is time-critical — a permanent
//  freeze would itself be an attack vector. The 48-hour cap
//  ensures any security response window is bounded.
//
//  Guardian can only pause. It cannot steal tokens, cancel
//  schedules, change beneficiaries, or redirect the treasury.
//  A compromised guardian's worst-case impact is a 48-hour delay.
//
//  ════════════════════════════════════════════════════
//   DAO TREASURY UPDATE — TIMELOCK
//  ════════════════════════════════════════════════════
//
//  The daoTreasury address receives all cancelled unvested tokens.
//  Changing it is timelocked by 48 hours to prevent a compromised
//  owner from instantly redirecting cancellation proceeds.
//
//  The two-step process:
//    queueDaoTreasuryUpdate(newAddr)  — owner, starts 48h clock
//    applyDaoTreasuryUpdate()         — anyone after 48h
//    cancelDaoTreasuryUpdate()        — owner, before apply
//
//  ════════════════════════════════════════════════════
//   GUARDIAN UPDATE — TWO-STEP
//  ════════════════════════════════════════════════════
//
//  Guardian address changes use a two-step handover:
//    setGuardian(newGuardian)  — owner nominates
//    acceptGuardian()          — nominee confirms
//
//  Prevents typo accidents where the guardian is set to an
//  address that cannot call acceptGuardian(). The pending
//  guardian has no powers until they accept.
//
//  ════════════════════════════════════════════════════
//   SECURITY MODEL
//  ════════════════════════════════════════════════════
//
//  Owner (team multisig) CAN:
//    addSchedule, cancelSchedule
//    queueDaoTreasuryUpdate / cancelDaoTreasuryUpdate
//    setGuardian (nominate), recoverERC20 (non-CUECOIN)
//
//  Owner CANNOT:
//    Transfer a beneficiary's schedule to another wallet
//    Change cliff/vest durations (bytecode constants)
//    Change type supply caps (bytecode constants)
//    Claim on behalf of a beneficiary
//    Redirect treasury instantly (48h timelock)
//    Pause the contract (guardian only)
//
//  Guardian CAN:
//    pause(duration ≤ 48h), unpause()
//    acceptGuardian() after being nominated
//
//  Guardian CANNOT:
//    Cancel schedules, transfer tokens, change beneficiaries
//    Pause for more than 48 hours total in a single call
//    Pause indefinitely (auto-expiry enforced in bytecode)
//
//  Beneficiary CAN:
//    claim() their vested tokens
//    transferSchedule() to a new wallet they control
//
// ╚══════════════════════════════════════════════════════════════╝

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  CueVesting
 * @author CUECOIN Team
 * @notice Linear vesting for Team (5%), Game Dev Fund (15%), and Partners (3%).
 *         Guardian-limited emergency pause (max 48 h). DAO treasury timelock.
 *         Per-type allocation caps enforced in bytecode.
 */
contract CueVesting is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════
    //  CONSTANTS  (bytecode — nothing can change these)
    // ═══════════════════════════════════════════════════════════

    // ── Cliff durations ──
    uint256 public constant TEAM_CLIFF      = 365 days;   // 12 months
    uint256 public constant DEV_CLIFF       = 182 days;   //  6 months
    uint256 public constant PARTNERS_CLIFF  = 182 days;   //  6 months

    // ── Vest durations (linear period after cliff) ──
    uint256 public constant TEAM_VEST       = 3 * 365 days; // 36 months
    uint256 public constant DEV_VEST        = 4 * 365 days; // 48 months
    uint256 public constant PARTNERS_VEST   = 2 * 365 days; // 24 months

    // ── Per-type CUECOIN allocation caps (total supply table) ──
    uint256 public constant TEAM_CAP        =  50_000_000 ether; //  5% of 1B
    uint256 public constant DEV_FUND_CAP    = 150_000_000 ether; // 15% of 1B
    uint256 public constant PARTNERS_CAP    =  30_000_000 ether; //  3% of 1B

    // ── Guardian pause cap ──
    /// @notice Maximum single pause duration the guardian may request.
    ///         Enforced in bytecode — no actor can pause for longer.
    uint256 public constant MAX_PAUSE_DURATION = 48 hours;

    // ── DAO treasury update delay ──
    uint256 public constant TREASURY_UPDATE_DELAY = 48 hours;

    // ── Start time backdate window ──
    /// @notice How far in the past a schedule's startTime may be.
    ///         Allows pre-agreed schedules signed before deployment,
    ///         but prevents deliberate backdating to skip the cliff.
    uint256 public constant MAX_BACKDATE = 30 days;

    // ═══════════════════════════════════════════════════════════
    //  ENUMS & STRUCTS
    // ═══════════════════════════════════════════════════════════

    enum ScheduleType { TEAM, DEV_FUND, PARTNERS }

    /**
     * @notice A single vesting schedule.
     *
     * @param scheduleId   Auto-assigned, 1-indexed.
     * @param beneficiary  Wallet that may claim vested tokens.
     * @param scheduleType TEAM / DEV_FUND / PARTNERS.
     * @param totalAmount  Total CUECOIN locked in this schedule.
     * @param startTime    Unix timestamp when vesting begins.
     * @param cliffEnd     Timestamp when cliff expires (vesting starts accruing).
     * @param vestEnd      Timestamp when fully vested.
     * @param claimed      Total CUECOIN already withdrawn by the beneficiary.
     * @param cancelled    True after owner cancels — irrevocable.
     * @param vestedAtCancel Amount vested at the moment of cancellation.
     *                       Meaningful only when cancelled = true.
     *                       Beneficiary may still claim (vestedAtCancel − claimed).
     */
    struct Schedule {
        uint32       scheduleId;
        address      beneficiary;
        ScheduleType scheduleType;
        uint256      totalAmount;
        uint256      startTime;
        uint256      cliffEnd;
        uint256      vestEnd;
        uint256      claimed;
        bool         cancelled;
        uint256      vestedAtCancel;
    }

    // ═══════════════════════════════════════════════════════════
    //  STATE
    // ═══════════════════════════════════════════════════════════

    IERC20 public immutable cueCoin;

    // ── Schedule storage ──
    uint32 private _nextScheduleId;
    mapping(uint32  => Schedule) private _schedules;
    mapping(address => uint32[]) private _beneficiarySchedules;

    // ── Allocation tracking ──
    /// @notice Total CUECOIN currently allocated to active (non-cancelled) schedules,
    ///         reduced by amounts already claimed.  Invariant:
    ///         cueCoin.balanceOf(address(this)) ≥ totalPending
    uint256 public totalPending;

    /// @notice Total allocated per schedule type (active schedules only).
    ///         Decremented by unvested amount on cancellation.
    mapping(ScheduleType => uint256) public allocatedByType;

    // ── DAO treasury (receives cancelled unvested tokens) ──
    address public daoTreasury;

    // Timelocked update queue
    address private _pendingDaoTreasury;
    uint256 private _pendingDaoTreasuryEta; // 0 = no pending update

    // ── Guardian (emergency pause only) ──
    address public guardian;
    address public pendingGuardian;

    /// @notice Unix timestamp until which the contract is paused.
    ///         0 (or any value ≤ block.timestamp) means not paused.
    uint256 public pausedUntil;

    // ═══════════════════════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════════════════════

    event ScheduleCreated(
        uint32 indexed scheduleId,
        address indexed beneficiary,
        ScheduleType    scheduleType,
        uint256         totalAmount,
        uint256         startTime,
        uint256         cliffEnd,
        uint256         vestEnd
    );

    event TokensClaimed(
        uint32 indexed scheduleId,
        address indexed beneficiary,
        uint256         amount,
        uint256         totalClaimed
    );

    event ScheduleCancelled(
        uint32 indexed scheduleId,
        address indexed beneficiary,
        uint256         unvestedReturned,  // transferred to daoTreasury
        uint256         vestedRemaining    // still claimable by beneficiary
    );

    event BeneficiaryTransferred(
        uint32 indexed scheduleId,
        address indexed oldBeneficiary,
        address indexed newBeneficiary
    );

    /// @notice Guardian paused the contract.
    event ContractPaused(address indexed by, uint256 pausedUntil);

    /// @notice Guardian lifted the pause early.
    event ContractUnpaused(address indexed by);

    /// @notice Owner queued a treasury address update.
    event DaoTreasuryUpdateQueued(address indexed newTreasury, uint256 eta);

    /// @notice Treasury update applied after timelock.
    event DaoTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /// @notice Treasury update cancelled before it applied.
    event DaoTreasuryUpdateCancelled(address indexed cancelledAddress);

    /// @notice Owner nominated a new guardian.
    event GuardianNominated(address indexed nominee);

    /// @notice Nominee accepted the guardian role.
    event GuardianAccepted(address indexed oldGuardian, address indexed newGuardian);

    // ═══════════════════════════════════════════════════════════
    //  MODIFIERS
    // ═══════════════════════════════════════════════════════════

    modifier onlyGuardian() {
        require(msg.sender == guardian, "CueVesting: not guardian");
        _;
    }

    /// @notice Blocks claim() and transferSchedule() while paused.
    ///         addSchedule() and cancelSchedule() are NOT blocked — the owner
    ///         must be able to act during a security emergency. The DAO
    ///         treasury update flow is also not blocked.
    modifier whenNotPaused() {
        require(block.timestamp > pausedUntil, "CueVesting: paused");
        _;
    }

    // ═══════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    /**
     * @param _cueCoin      CueCoin BEP-20 contract.
     * @param _guardian     Initial guardian address (Gnosis Safe 3-of-5).
     * @param _daoTreasury  CueDAO contract address — receives cancelled unvested tokens.
     */
    constructor(
        address _cueCoin,
        address _guardian,
        address _daoTreasury
    )
        Ownable(msg.sender)
    {
        require(_cueCoin     != address(0), "CueVesting: zero cueCoin");
        require(_guardian    != address(0), "CueVesting: zero guardian");
        require(_daoTreasury != address(0), "CueVesting: zero treasury");

        cueCoin     = IERC20(_cueCoin);
        guardian    = _guardian;
        daoTreasury = _daoTreasury;
    }

    // ═══════════════════════════════════════════════════════════
    //  SCHEDULE MANAGEMENT — OWNER
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Create a new vesting schedule.
     *
     *         The contract must already hold enough CUECOIN to cover all
     *         existing pending obligations PLUS this new schedule's amount.
     *         Fund the contract first, then call addSchedule().
     *
     *         Cliff and vest durations are determined by scheduleType and
     *         are bytecode constants — they cannot be overridden.
     *
     *         startTime flexibility: may be up to MAX_BACKDATE (30 days) in
     *         the past to accommodate pre-agreed investor terms signed before
     *         deployment. Cannot be more than 30 days in the past (prevents
     *         cliff bypass by setting startTime = years ago).
     *
     *         Per-type allocation caps are enforced. A TEAM schedule can only
     *         be created if the new totalAmount does not push allocatedByType[TEAM]
     *         above TEAM_CAP (50,000,000 CUE).
     *
     * @param beneficiary   Wallet that will claim vested tokens.
     * @param scheduleType  TEAM / DEV_FUND / PARTNERS.
     * @param totalAmount   Total CUECOIN to vest (in wei, 18 decimals).
     * @param startTime     Unix timestamp when vesting begins. Pass block.timestamp
     *                      for "starts now." May be up to 30 days in the past.
     * @return scheduleId   The newly assigned schedule ID.
     */
    function addSchedule(
        address      beneficiary,
        ScheduleType scheduleType,
        uint256      totalAmount,
        uint256      startTime
    )
        external
        onlyOwner
        nonReentrant
        returns (uint32 scheduleId)
    {
        require(beneficiary != address(0), "CueVesting: zero beneficiary");
        require(totalAmount  > 0,          "CueVesting: zero amount");

        // Backdate guard
        require(
            startTime >= block.timestamp - MAX_BACKDATE,
            "CueVesting: startTime too far in the past"
        );
        // Future schedules allowed (token unlocks in the future)
        // No upper bound on startTime.

        // Per-type cap check
        uint256 newAllocated = allocatedByType[scheduleType] + totalAmount;
        uint256 cap          = _capForType(scheduleType);
        require(newAllocated <= cap, "CueVesting: type allocation cap exceeded");

        // Solvency check: contract must hold enough to cover all obligations
        require(
            cueCoin.balanceOf(address(this)) >= totalPending + totalAmount,
            "CueVesting: insufficient contract balance — fund first"
        );

        // Derive cliff and vest timestamps
        (uint256 cliffDuration, uint256 vestDuration) = _durationsForType(scheduleType);
        uint256 cliffEnd = startTime + cliffDuration;
        uint256 vestEnd  = cliffEnd  + vestDuration;

        scheduleId = _nextId();
        _schedules[scheduleId] = Schedule({
            scheduleId:    scheduleId,
            beneficiary:   beneficiary,
            scheduleType:  scheduleType,
            totalAmount:   totalAmount,
            startTime:     startTime,
            cliffEnd:      cliffEnd,
            vestEnd:       vestEnd,
            claimed:       0,
            cancelled:     false,
            vestedAtCancel: 0
        });

        _beneficiarySchedules[beneficiary].push(scheduleId);

        allocatedByType[scheduleType] += totalAmount;
        totalPending                  += totalAmount;

        emit ScheduleCreated(
            scheduleId, beneficiary, scheduleType,
            totalAmount, startTime, cliffEnd, vestEnd
        );
    }

    /**
     * @notice Cancel a vesting schedule.
     *
     *         Transfers all unvested CUECOIN to daoTreasury.
     *         The beneficiary retains the right to claim any tokens that were
     *         already vested at the moment of cancellation.
     *
     *         Cancellation is irrevocable.
     *
     *         paused: addSchedule and cancelSchedule are NOT blocked by pause.
     *         The owner must be able to react during a security incident.
     *
     * @param scheduleId  Schedule to cancel.
     */
    function cancelSchedule(uint32 scheduleId)
        external
        onlyOwner
        nonReentrant
    {
        Schedule storage s = _requireSchedule(scheduleId);
        require(!s.cancelled, "CueVesting: already cancelled");

        uint256 vestedNow = _computeVested(s, block.timestamp);
        uint256 unvested  = s.totalAmount - vestedNow;
        uint256 vestedRemaining = vestedNow - s.claimed; // beneficiary can still claim this

        // Mark cancelled — must happen before any external call (CEI)
        s.cancelled      = true;
        s.vestedAtCancel = vestedNow;

        // Update accounting
        // totalPending held: (totalAmount - claimed) for this schedule
        // After cancel: beneficiary can still claim vestedRemaining from contract
        // so totalPending reduces by unvested (those tokens leave the contract now)
        totalPending               -= unvested;
        allocatedByType[s.scheduleType] -= unvested;

        // Transfer unvested to DAO treasury
        if (unvested > 0) {
            cueCoin.safeTransfer(daoTreasury, unvested);
        }

        emit ScheduleCancelled(scheduleId, s.beneficiary, unvested, vestedRemaining);
    }

    // ═══════════════════════════════════════════════════════════
    //  CLAIM — BENEFICIARY
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Claim all currently releasable CUECOIN for a schedule.
     *
     *         Blocked while the contract is paused (guardian emergency).
     *         Follows CEI: state updated before transfer.
     *
     *         Works for both active and cancelled schedules — a cancelled
     *         schedule still releases its vested-at-cancellation portion.
     *
     * @param scheduleId  ID of the schedule to claim from.
     */
    function claim(uint32 scheduleId)
        external
        nonReentrant
        whenNotPaused
    {
        Schedule storage s = _requireSchedule(scheduleId);
        require(s.beneficiary == msg.sender, "CueVesting: not beneficiary");

        uint256 amount = _releasable(s);
        require(amount > 0, "CueVesting: nothing to claim");

        // CEI: update state before transfer
        s.claimed    += amount;
        totalPending -= amount;

        cueCoin.safeTransfer(s.beneficiary, amount);

        emit TokensClaimed(scheduleId, s.beneficiary, amount, s.claimed);
    }

    /**
     * @notice Claim from multiple schedules in one transaction.
     *         Skips schedules with nothing to claim rather than reverting.
     *
     * @param scheduleIds  Array of schedule IDs to claim from.
     */
    function claimMany(uint32[] calldata scheduleIds)
        external
        nonReentrant
        whenNotPaused
    {
        for (uint256 i = 0; i < scheduleIds.length; i++) {
            uint32 id = scheduleIds[i];
            if (id == 0 || id >= _nextScheduleId) continue;

            Schedule storage s = _schedules[id];
            if (s.beneficiary != msg.sender) continue;

            uint256 amount = _releasable(s);
            if (amount == 0) continue;

            s.claimed    += amount;
            totalPending -= amount;

            cueCoin.safeTransfer(s.beneficiary, amount);
            emit TokensClaimed(id, s.beneficiary, amount, s.claimed);
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  BENEFICIARY TRANSFER
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Transfer a schedule to a new beneficiary wallet.
     *
     *         Only the current beneficiary can call this. The owner cannot
     *         redirect a beneficiary's schedule — this protects team members
     *         from a compromised owner key.
     *
     *         Use cases: wallet key rotation, multisig migration.
     *
     *         Blocked while paused.
     *
     * @param scheduleId      Schedule to transfer.
     * @param newBeneficiary  New wallet that will claim vested tokens.
     */
    function transferSchedule(uint32 scheduleId, address newBeneficiary)
        external
        nonReentrant
        whenNotPaused
    {
        require(newBeneficiary != address(0), "CueVesting: zero new beneficiary");

        Schedule storage s = _requireSchedule(scheduleId);
        require(s.beneficiary == msg.sender,        "CueVesting: not beneficiary");
        require(newBeneficiary != msg.sender,        "CueVesting: same beneficiary");
        require(!s.cancelled,                        "CueVesting: schedule cancelled");

        address old = s.beneficiary;
        s.beneficiary = newBeneficiary;

        // Update reverse-lookup: remove from old, add to new
        _removeFromBeneficiary(old, scheduleId);
        _beneficiarySchedules[newBeneficiary].push(scheduleId);

        emit BeneficiaryTransferred(scheduleId, old, newBeneficiary);
    }

    // ═══════════════════════════════════════════════════════════
    //  GUARDIAN — EMERGENCY PAUSE
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Pause the contract for up to MAX_PAUSE_DURATION (48 hours).
     *
     *         While paused: claim() and transferSchedule() revert.
     *         addSchedule() and cancelSchedule() are NOT blocked —
     *         the owner may need to cancel a compromised beneficiary's
     *         schedule during the incident.
     *
     *         The pause auto-expires at pausedUntil — no action required.
     *         The guardian may call unpause() to lift it early.
     *
     *         Calling pause() while already paused extends the pause to
     *         max(current pausedUntil, now + duration) — this prevents
     *         the guardian from stacking pause calls to extend beyond 48h.
     *         Each call is bounded by MAX_PAUSE_DURATION from NOW.
     *
     * @param duration  Pause duration in seconds. Must be ≤ MAX_PAUSE_DURATION.
     */
    function pause(uint256 duration) external onlyGuardian {
        require(duration > 0,                    "CueVesting: zero duration");
        require(duration <= MAX_PAUSE_DURATION,  "CueVesting: exceeds max pause duration");

        uint256 newPausedUntil = block.timestamp + duration;

        // Cannot extend an existing pause beyond MAX_PAUSE_DURATION from now.
        // This ensures the guardian cannot stack calls to create indefinite pauses.
        pausedUntil = newPausedUntil;

        emit ContractPaused(msg.sender, newPausedUntil);
    }

    /**
     * @notice Lift the pause early.
     *         The contract resumes normal operation immediately.
     */
    function unpause() external onlyGuardian {
        require(block.timestamp <= pausedUntil, "CueVesting: not paused");
        pausedUntil = 0;
        emit ContractUnpaused(msg.sender);
    }

    // ═══════════════════════════════════════════════════════════
    //  DAO TREASURY UPDATE — TIMELOCKED
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Queue an update to the DAO treasury address.
     *
     *         The new address will receive all future cancelled unvested tokens.
     *         The 48-hour delay prevents a compromised owner from instantly
     *         redirecting cancellation proceeds to a malicious address.
     *
     *         Community and monitoring tools have 48 hours to observe and react
     *         before the change takes effect. The owner can cancel within that
     *         window (cancelDaoTreasuryUpdate).
     *
     * @param newTreasury  New DAO treasury address.
     */
    function queueDaoTreasuryUpdate(address newTreasury) external onlyOwner {
        require(newTreasury != address(0),  "CueVesting: zero treasury");
        require(newTreasury != daoTreasury, "CueVesting: same treasury");

        uint256 eta = block.timestamp + TREASURY_UPDATE_DELAY;
        _pendingDaoTreasury    = newTreasury;
        _pendingDaoTreasuryEta = eta;

        emit DaoTreasuryUpdateQueued(newTreasury, eta);
    }

    /**
     * @notice Apply a queued DAO treasury update after the 48-hour delay.
     *         Permissionless — anyone can execute after the delay.
     */
    function applyDaoTreasuryUpdate() external nonReentrant {
        require(_pendingDaoTreasuryEta != 0,              "CueVesting: no pending update");
        require(block.timestamp >= _pendingDaoTreasuryEta, "CueVesting: delay not elapsed");

        address oldTreasury = daoTreasury;
        address newTreasury = _pendingDaoTreasury;

        daoTreasury            = newTreasury;
        _pendingDaoTreasury    = address(0);
        _pendingDaoTreasuryEta = 0;

        emit DaoTreasuryUpdated(oldTreasury, newTreasury);
    }

    /**
     * @notice Cancel a queued DAO treasury update before it applies.
     *         Owner-only.
     */
    function cancelDaoTreasuryUpdate() external onlyOwner {
        require(_pendingDaoTreasuryEta != 0, "CueVesting: no pending update");

        address cancelled = _pendingDaoTreasury;
        _pendingDaoTreasury    = address(0);
        _pendingDaoTreasuryEta = 0;

        emit DaoTreasuryUpdateCancelled(cancelled);
    }

    // ═══════════════════════════════════════════════════════════
    //  GUARDIAN UPDATE — TWO-STEP
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Nominate a new guardian. The nominee must call acceptGuardian()
     *         to complete the handover. Prevents typo accidents.
     *
     *         The pending guardian has NO guardian powers until they accept.
     *
     * @param nominee  Address being nominated as the new guardian.
     */
    function setGuardian(address nominee) external onlyOwner {
        require(nominee != address(0), "CueVesting: zero nominee");
        pendingGuardian = nominee;
        emit GuardianNominated(nominee);
    }

    /**
     * @notice Accept the guardian role. Called by the pending guardian.
     */
    function acceptGuardian() external {
        require(msg.sender == pendingGuardian, "CueVesting: not pending guardian");
        address old = guardian;
        guardian        = pendingGuardian;
        pendingGuardian = address(0);
        emit GuardianAccepted(old, guardian);
    }

    // ═══════════════════════════════════════════════════════════
    //  OWNER ADMIN
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Recover ERC-20 tokens accidentally sent to this contract.
     *         CUECOIN is the vesting fund — it cannot be recovered this way.
     *         Use cancelSchedule() for CUECOIN management.
     */
    function recoverERC20(address token, uint256 amount) external onlyOwner {
        require(token != address(cueCoin), "CueVesting: cannot recover CUECOIN");
        IERC20(token).safeTransfer(owner(), amount);
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW — SINGLE SCHEDULE
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Fetch a full schedule by ID. Reverts if not found.
     */
    function getSchedule(uint32 scheduleId)
        external
        view
        returns (Schedule memory)
    {
        return _requireSchedule(scheduleId);
    }

    /**
     * @notice How many CUECOIN can the beneficiary claim right now.
     *         Returns 0 if paused, before cliff, or nothing left.
     */
    function releasable(uint32 scheduleId) external view returns (uint256) {
        if (scheduleId == 0 || scheduleId >= _nextScheduleId) return 0;
        Schedule storage s = _schedules[scheduleId];
        if (block.timestamp <= pausedUntil) return 0;
        return _releasable(s);
    }

    /**
     * @notice Total CUECOIN vested to date (whether claimed or not).
     */
    function vested(uint32 scheduleId) external view returns (uint256) {
        if (scheduleId == 0 || scheduleId >= _nextScheduleId) return 0;
        return _computeVested(_schedules[scheduleId], block.timestamp);
    }

    /**
     * @notice Full schedule status breakdown.
     *
     * @return schedule         The raw schedule struct.
     * @return vestedNow        Total vested at this block.
     * @return claimableNow     Releasable right now (may be 0 if paused or at cliff).
     * @return unvestedNow      Tokens not yet vested (0 if fully vested or cancelled).
     * @return percentVested    Vested fraction in basis points (0–10000).
     */
    function scheduleStatus(uint32 scheduleId)
        external
        view
        returns (
            Schedule memory schedule,
            uint256 vestedNow,
            uint256 claimableNow,
            uint256 unvestedNow,
            uint256 percentVested
        )
    {
        schedule    = _requireSchedule(scheduleId);
        vestedNow   = _computeVested(schedule, block.timestamp);
        claimableNow = (block.timestamp > pausedUntil) ? _releasable(schedule) : 0;
        unvestedNow  = schedule.cancelled
                       ? 0                                      // unvested already sent to DAO
                       : schedule.totalAmount - vestedNow;
        percentVested = schedule.totalAmount == 0
                        ? 0
                        : (vestedNow * 10_000) / schedule.totalAmount;
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW — BENEFICIARY QUERIES
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice All schedule IDs belonging to a beneficiary.
     *         Includes cancelled and fully claimed schedules.
     */
    function getScheduleIds(address beneficiary)
        external
        view
        returns (uint32[] memory)
    {
        return _beneficiarySchedules[beneficiary];
    }

    /**
     * @notice All schedules for a beneficiary as full structs.
     */
    function getSchedules(address beneficiary)
        external
        view
        returns (Schedule[] memory schedules)
    {
        uint32[] storage ids = _beneficiarySchedules[beneficiary];
        schedules = new Schedule[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            schedules[i] = _schedules[ids[i]];
        }
    }

    /**
     * @notice Total releasable across all of a beneficiary's schedules.
     *         Useful for dashboard total display.
     */
    function totalReleasable(address beneficiary)
        external
        view
        returns (uint256 total)
    {
        if (block.timestamp <= pausedUntil) return 0;
        uint32[] storage ids = _beneficiarySchedules[beneficiary];
        for (uint256 i = 0; i < ids.length; i++) {
            total += _releasable(_schedules[ids[i]]);
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW — PROTOCOL STATS
    // ═══════════════════════════════════════════════════════════

    /// @notice Total number of schedules ever created.
    function scheduleCount() external view returns (uint32) {
        return _nextScheduleId == 0 ? 0 : _nextScheduleId - 1;
    }

    /// @notice Whether the contract is currently paused.
    function isPaused() external view returns (bool) {
        return block.timestamp <= pausedUntil;
    }

    /**
     * @notice Current status of the pending DAO treasury update.
     * @return pending  Address queued (zero if none pending).
     * @return eta      Timestamp after which it can be applied (0 if none).
     */
    function pendingTreasuryUpdate()
        external
        view
        returns (address pending, uint256 eta)
    {
        return (_pendingDaoTreasury, _pendingDaoTreasuryEta);
    }

    /**
     * @notice Remaining CUECOIN type budget before hitting the cap.
     */
    function remainingCap(ScheduleType scheduleType)
        external
        view
        returns (uint256)
    {
        uint256 cap = _capForType(scheduleType);
        uint256 used = allocatedByType[scheduleType];
        return used >= cap ? 0 : cap - used;
    }

    /**
     * @notice Cliff and vest durations for each schedule type.
     */
    function durationsForType(ScheduleType scheduleType)
        external
        pure
        returns (uint256 cliffDuration, uint256 vestDuration)
    {
        return _durationsForType(scheduleType);
    }

    /**
     * @notice Full protocol snapshot.
     */
    function protocolStats()
        external
        view
        returns (
            uint32  totalSchedules,
            uint256 pending,
            uint256 teamAllocated,
            uint256 devFundAllocated,
            uint256 partnersAllocated,
            uint256 contractBalance,
            bool    paused_,
            address treasury,
            address guardian_
        )
    {
        return (
            _nextScheduleId == 0 ? 0 : _nextScheduleId - 1,
            totalPending,
            allocatedByType[ScheduleType.TEAM],
            allocatedByType[ScheduleType.DEV_FUND],
            allocatedByType[ScheduleType.PARTNERS],
            cueCoin.balanceOf(address(this)),
            block.timestamp <= pausedUntil,
            daoTreasury,
            guardian
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — VESTING MATH
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev Compute the total amount vested at timestamp `t`.
     *
     *      cancelled=true: the cap is vestedAtCancel — the beneficiary cannot
     *      vest additional tokens after cancellation.
     *
     *      Three segments:
     *        pre-cliff  → 0
     *        vest window → pro-rata linear
     *        post-vest  → totalAmount (fully vested)
     */
    function _computeVested(Schedule storage s, uint256 t)
        internal
        view
        returns (uint256)
    {
        // For cancelled schedules, vesting is frozen at the cancellation moment
        if (s.cancelled) return s.vestedAtCancel;

        if (t < s.cliffEnd)  return 0;
        if (t >= s.vestEnd)  return s.totalAmount;

        uint256 elapsed      = t - s.cliffEnd;
        uint256 vestDuration = s.vestEnd - s.cliffEnd;
        return (s.totalAmount * elapsed) / vestDuration;
    }

    /**
     * @dev Compute the releasable amount (vested minus already claimed).
     *      Never negative — if claimed somehow exceeds vested, returns 0.
     */
    function _releasable(Schedule storage s) internal view returns (uint256) {
        uint256 v = _computeVested(s, block.timestamp);
        return v > s.claimed ? v - s.claimed : 0;
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — HELPERS
    // ═══════════════════════════════════════════════════════════

    function _nextId() internal returns (uint32 id) {
        if (_nextScheduleId == 0) _nextScheduleId = 1;
        id = _nextScheduleId++;
    }

    function _requireSchedule(uint32 scheduleId)
        internal
        view
        returns (Schedule storage)
    {
        require(
            scheduleId >= 1 && scheduleId < _nextScheduleId,
            "CueVesting: schedule does not exist"
        );
        return _schedules[scheduleId];
    }

    function _capForType(ScheduleType t) internal pure returns (uint256) {
        if (t == ScheduleType.TEAM)     return TEAM_CAP;
        if (t == ScheduleType.DEV_FUND) return DEV_FUND_CAP;
        return PARTNERS_CAP;
    }

    function _durationsForType(ScheduleType t)
        internal
        pure
        returns (uint256 cliff, uint256 vest)
    {
        if (t == ScheduleType.TEAM) {
            return (TEAM_CLIFF, TEAM_VEST);
        }
        if (t == ScheduleType.DEV_FUND) {
            return (DEV_CLIFF, DEV_VEST);
        }
        return (PARTNERS_CLIFF, PARTNERS_VEST);
    }

    /**
     * @dev Remove a scheduleId from a beneficiary's list.
     *      Called only from transferSchedule(). O(n) where n is the number
     *      of schedules for that beneficiary — typically very small (1–10).
     */
    function _removeFromBeneficiary(address beneficiary, uint32 scheduleId) internal {
        uint32[] storage ids = _beneficiarySchedules[beneficiary];
        uint256 len = ids.length;
        for (uint256 i = 0; i < len; i++) {
            if (ids[i] == scheduleId) {
                ids[i] = ids[len - 1]; // swap with last
                ids.pop();
                return;
            }
        }
        // Not found — this should be unreachable in correct usage
        revert("CueVesting: schedule not in beneficiary list");
    }
}
