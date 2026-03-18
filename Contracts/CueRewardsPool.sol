// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ╔══════════════════════════════════════════════════════════════╗
//  CUEREWARDSPOOL  ·  v1.0  ·  Production-Ready
//  CUECOIN Ecosystem  ·  BNB Smart Chain
//
//  Play-to-Earn rewards treasury. Holds 200,000,000 CUECOIN
//  (20% of total supply) and perpetually topped-up by the 1%
//  Vortex Tax on every CueCoin transfer. Funds two distinct
//  economic incentives:
//
//    JOB 1 — MATCH REWARD
//      Every completed ranked match pays the winner 0.5 CUECOIN
//      (DAO adjustable, hard-capped at 5 CUECOIN per match).
//      NFT holders receive a multiplied reward:
//        Rare     (Pro Cue)     × 1.05 → 0.525 CUE
//        Epic     (Master Cue)  × 1.10 → 0.550 CUE
//        Legendary(Grand Master)× 1.15 → 0.575 CUE
//        Genesis  (Founders)    × 1.20 → 0.600 CUE
//      The NFT multiplier reads directly from CueNFT.walletBonusBps()
//      so it automatically tracks any future tier adjustments.
//
//    JOB 2 — NFT WAGER BONUS
//      When a player with a bonus-eligible NFT wins a wager match,
//      CueEscrow calls payNFTBonus(winner, bonusAmount). The bonus
//      amount is computed off-chain (or by the oracle) as:
//        Rare:      5% of winner's wager
//        Epic:     10% of winner's wager
//        Legendary:15% of winner's wager
//        Genesis:  20% of winner's wager
//      This pool pays the bonus without touching the match pot —
//      the loser always pays exactly their wager, no more.
//
//  ════════════════════════════════════════════════════
//   LINEAR RELEASE MODEL (rate-limited disbursement)
//  ════════════════════════════════════════════════════
//
//  Payouts are rate-limited by a time-accumulating budget:
//
//    pendingBudget += elapsed_seconds × ratePerSecond
//    pendingBudget  = min(pendingBudget, contractBalance)
//
//  The default rate targets 40,000,000 CUE/year — exactly the
//  5-year linear depletion of the 200M initial allocation:
//
//    DEFAULT_RATE = 40_000_000e18 / 31_536_000 ≈ 1.268 CUE/second
//
//  Every payout deducts from pendingBudget. If pendingBudget is
//  insufficient, the payout returns 0 (best-effort semantics —
//  callers must handle zero-return gracefully). Vortex Tax inflows
//  arrive directly as CUECOIN balance increases, which the budget
//  accumulator incorporates automatically at the current rate.
//
//  The rate is DAO-adjustable within the hard ceiling:
//    MAX_RATE = 200_000_000e18 / 31_536_000 ≈ 6.342 CUE/second
//  (Maximum depletion in 1 year — prevents catastrophic drain.)
//
//  ════════════════════════════════════════════════════
//   DEPLETION GUARD
//  ════════════════════════════════════════════════════
//
//  On every budget accrual, runway is computed:
//    runway = contractBalance / ratePerSecond (seconds)
//
//  If runway < 30 days (DEPLETION_RUNWAY):
//    1. ratePerSecond is halved automatically.
//    2. depletionGuardActive flag is set.
//    3. DepletionGuardTriggered event is emitted.
//
//  This buys the DAO time to respond without any human intervention.
//  The DAO can restore the rate (subject to MAX_RATE ceiling), add
//  funds, or accept the reduced rate via governance.
//
//  Once balance recovers (runway > 30 days again), the guard clears
//  automatically on the next accrual. The DAO can also manually
//  restore the rate at any time.
//
//  ════════════════════════════════════════════════════
//   CALLER AUTHORIZATION
//  ════════════════════════════════════════════════════
//
//  payMatchReward() and payNFTBonus() are restricted to
//  owner-whitelisted caller addresses:
//
//    authorizedCaller[address] = true
//
//  At minimum, CueEscrow.sol must be authorized after deploy.
//  The owner (team multisig / DAO after governance handover) manages
//  the whitelist. Multiple authorized callers are supported to
//  accommodate future game modes (e.g., CueSitAndGo tournaments).
//
//  payNFTBonus() is compatible with CueEscrow's existing low-level
//  call pattern:
//    rewardsPool.call(abi.encodeWithSignature(
//        "payNFTBonus(address,uint256)", winner, bonusAmount))
//  It returns the actual amount paid (uint256), which CueEscrow
//  decodes. If the pool is paused or depleted, it returns 0 without
//  reverting — CueEscrow absorbs this silently.
//
//  ════════════════════════════════════════════════════
//   PAUSE SEMANTICS
//  ════════════════════════════════════════════════════
//
//  Guardian (Gnosis Safe 3-of-5) or owner can pause instantly.
//  While paused:
//    payMatchReward() returns 0
//    payNFTBonus()    returns 0
//  This is intentional: a paused pool acts like a depleted pool
//  from the caller's perspective — no special handling required.
//  Admin functions and balance receipt are never paused.
//
//  ════════════════════════════════════════════════════
//   ACCESS CONTROL
//  ════════════════════════════════════════════════════
//
//  Owner (multisig / DAO via GENERIC_CALL) CAN:
//    addAuthorizedCaller / removeAuthorizedCaller
//    setMatchRewardPerGame (≤ MAX_MATCH_REWARD = 5 CUE)
//    setRatePerSecond (≤ MAX_RATE_PER_SECOND)
//    setCueNft (in case of CueNFT upgrade)
//    setGuardian (two-step)
//    queueDaoTreasuryUpdate / cancelDaoTreasuryUpdate
//    pause / unpause
//    recoverERC20 (non-CUECOIN only)
//
//  Guardian CAN:
//    pause / unpause
//    acceptGuardian
//
//  Authorized Callers CAN:
//    payMatchReward (when not paused, budget available)
//    payNFTBonus    (when not paused, budget available)
//
//  Nobody CAN:
//    Withdraw CUECOIN from the pool (only payouts via rate-limited calls)
//    Set ratePerSecond above MAX_RATE_PER_SECOND
//    Set matchRewardPerGame above MAX_MATCH_REWARD
//
// ╚══════════════════════════════════════════════════════════════╝

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ═══════════════════════════════════════════════════════════════
//  CUENTF INTERFACE (NFT multiplier lookup)
// ═══════════════════════════════════════════════════════════════

interface ICueNFT {
    /**
     * @notice Wager bonus in basis points for the highest bonus-eligible
     *         NFT tier held by wallet.
     *         Rare=500, Epic=1000, Legendary=1500, Genesis=2000. Returns 0
     *         if wallet holds no bonus-eligible NFT (Common/Badge tiers).
     */
    function walletBonusBps(address wallet) external view returns (uint256);
}

// ═══════════════════════════════════════════════════════════════
//  MAIN CONTRACT
// ═══════════════════════════════════════════════════════════════

/**
 * @title  CueRewardsPool
 * @author CUECOIN Team
 * @notice P2E rewards treasury. Rate-limited linear release. Funds both
 *         per-match CUECOIN rewards (NFT-multiplied) and NFT wager bonuses.
 *         Depletion guard halves the release rate automatically when runway
 *         falls below 30 days. Called by CueEscrow via low-level call.
 */
contract CueRewardsPool is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════
    //  CONSTANTS  (bytecode — nothing can change these)
    // ═══════════════════════════════════════════════════════════

    /// @notice Initial P2E allocation described in the whitepaper.
    ///         Not enforced on-chain as a hard cap — the contract simply
    ///         holds whatever CUECOIN is deposited (initial + Vortex Tax refills).
    uint256 public constant INITIAL_ALLOCATION = 200_000_000 ether;

    /// @notice Default match reward: 0.5 CUECOIN per ranked win.
    uint256 public constant DEFAULT_MATCH_REWARD = 0.5 ether;

    /// @notice DAO cannot set match reward above this value.
    uint256 public constant MAX_MATCH_REWARD     = 5 ether;

    /// @notice Default linear release rate: 40,000,000 CUE per year.
    ///         40_000_000e18 / 31_536_000 seconds ≈ 1.268 CUE/second.
    ///         This exactly depletes the initial 200M allocation in 5 years
    ///         assuming zero Vortex Tax top-ups.
    uint256 public constant DEFAULT_RATE_PER_SECOND =
        (40_000_000 ether) / 31_536_000;

    /// @notice Hard ceiling on release rate.
    ///         200M initial / 1 year — maximum possible drain speed.
    ///         DAO cannot set ratePerSecond above this.
    uint256 public constant MAX_RATE_PER_SECOND =
        (200_000_000 ether) / 31_536_000;

    /// @notice Runway threshold that triggers the depletion guard.
    uint256 public constant DEPLETION_RUNWAY = 30 days;

    /// @notice Timelock delay for DAO treasury address changes.
    uint256 public constant TREASURY_UPDATE_DELAY = 48 hours;

    // ── NFT tier bonus BPS (mirrors CueNFT.tierBonusBps — kept here
    //    for documentation clarity; actual values read from CueNFT live) ──
    // TIER_RARE      = 1 → 500 bps  (× 1.05)
    // TIER_EPIC      = 2 → 1000 bps (× 1.10)
    // TIER_LEGENDARY = 3 → 1500 bps (× 1.15)
    // TIER_GENESIS   = 4 → 2000 bps (× 1.20)

    // ═══════════════════════════════════════════════════════════
    //  IMMUTABLES
    // ═══════════════════════════════════════════════════════════

    IERC20 public immutable cueCoin;

    // ═══════════════════════════════════════════════════════════
    //  STATE — CONFIGURATION
    // ═══════════════════════════════════════════════════════════

    /// @notice CueNFT contract — queried for per-wallet bonus multipliers.
    ///         Owner-updatable in case of CueNFT upgrade.
    ICueNFT public cueNft;

    /// @notice Per-match base reward in CUECOIN-wei. DAO adjustable ≤ MAX_MATCH_REWARD.
    uint256 public matchRewardPerGame;

    /// @notice Current linear release rate in CUECOIN-wei per second.
    ///         DAO adjustable ≤ MAX_RATE_PER_SECOND.
    uint256 public ratePerSecond;

    // ═══════════════════════════════════════════════════════════
    //  STATE — BUDGET ACCUMULATOR
    // ═══════════════════════════════════════════════════════════

    /// @notice Accumulated but not yet disbursed CUECOIN budget.
    ///         Grows at ratePerSecond per second, capped at contract balance.
    ///         Payouts deduct from this. If pendingBudget is insufficient for
    ///         a requested payout, the call returns 0 without reverting.
    uint256 public pendingBudget;

    /// @notice block.timestamp of the last budget accrual. Updated on every
    ///         payout call and on explicit accrueBudget() calls.
    uint256 public lastBudgetUpdate;

    // ═══════════════════════════════════════════════════════════
    //  STATE — DEPLETION GUARD
    // ═══════════════════════════════════════════════════════════

    /// @notice True when the depletion guard has auto-halved the rate.
    ///         Cleared automatically when runway recovers above DEPLETION_RUNWAY.
    bool public depletionGuardActive;

    // ═══════════════════════════════════════════════════════════
    //  STATE — ACCESS CONTROL
    // ═══════════════════════════════════════════════════════════

    /// @notice Addresses authorised to call payMatchReward and payNFTBonus.
    ///         Includes CueEscrow and any future authorised game contracts.
    mapping(address => bool) public authorizedCaller;

    // ═══════════════════════════════════════════════════════════
    //  STATE — GUARDIAN & DAO TREASURY
    // ═══════════════════════════════════════════════════════════

    address public guardian;
    address public pendingGuardian;
    bool    public paused;

    address public daoTreasury;
    address private _pendingDaoTreasury;
    uint256 private _pendingDaoTreasuryEta;

    // ═══════════════════════════════════════════════════════════
    //  STATE — STATS
    // ═══════════════════════════════════════════════════════════

    uint256 public totalMatchRewardsPaid;  // CUE paid as match rewards (all-time)
    uint256 public totalNftBonusPaid;      // CUE paid as NFT wager bonuses (all-time)
    uint256 public totalDisbursed;         // Combined all-time disbursements
    uint256 public matchesRewarded;        // Count of payMatchReward calls that paid > 0
    uint256 public nftBonusPayments;       // Count of payNFTBonus calls that paid > 0

    // ═══════════════════════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════════════════════

    event MatchRewardPaid(
        address indexed winner,
        uint256         baseReward,
        uint256         nftMultiplierBps,
        uint256         actualReward
    );

    event NftBonusPaid(
        address indexed winner,
        uint256         requestedAmount,
        uint256         actualAmount
    );

    event BudgetAccrued(
        uint256 elapsed,
        uint256 accrued,
        uint256 newPendingBudget
    );

    event DepletionGuardTriggered(
        uint256 oldRatePerSecond,
        uint256 newRatePerSecond,
        uint256 runwaySeconds
    );

    event DepletionGuardCleared(uint256 runwaySeconds);

    event RateUpdated(uint256 oldRate, uint256 newRate);
    event MatchRewardUpdated(uint256 oldReward, uint256 newReward);

    event CallerAuthorized(address indexed caller);
    event CallerRevoked(address indexed caller);

    event CueNftUpdated(address indexed oldNft, address indexed newNft);

    event Paused(address indexed by);
    event Unpaused(address indexed by);

    event GuardianNominated(address indexed nominee);
    event GuardianAccepted(address indexed oldGuardian, address indexed newGuardian);

    event DaoTreasuryUpdateQueued(address indexed newTreasury, uint256 eta);
    event DaoTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event DaoTreasuryUpdateCancelled(address indexed cancelled);

    // ═══════════════════════════════════════════════════════════
    //  MODIFIERS
    // ═══════════════════════════════════════════════════════════

    modifier onlyOwnerOrGuardian() {
        require(
            msg.sender == owner() || msg.sender == guardian,
            "CueRewardsPool: not owner or guardian"
        );
        _;
    }

    modifier onlyAuthorized() {
        require(authorizedCaller[msg.sender], "CueRewardsPool: not authorized caller");
        _;
    }

    // ═══════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    /**
     * @param _cueCoin      CueCoin ERC-20 contract (immutable).
     * @param _cueNft       CueNFT — for reading per-wallet NFT multiplier.
     * @param _guardian     Guardian address (Gnosis Safe 3-of-5).
     * @param _daoTreasury  DAO Treasury address (for governance use; not
     *                      used as a payout destination by this contract).
     *
     * @dev Post-deploy steps:
     *   1. Transfer 200,000,000 CUECOIN to this contract from the allocation wallet.
     *   2. addAuthorizedCaller(address(cueEscrow))
     *   3. addAuthorizedCaller(address(cueSitAndGo)) — if applicable
     *   4. CueCoin.setFeeExclusion(address(this), true) — optional, prevents
     *      Vortex Tax on outbound payouts (since the pool IS the P2E destination,
     *      taxing payouts would double-count).
     *   5. Verify: poolRunway() > 30 days before going live.
     */
    constructor(
        address _cueCoin,
        address _cueNft,
        address _guardian,
        address _daoTreasury
    )
        Ownable(msg.sender)
    {
        require(_cueCoin     != address(0), "CueRewardsPool: zero cueCoin");
        require(_cueNft      != address(0), "CueRewardsPool: zero cueNft");
        require(_guardian    != address(0), "CueRewardsPool: zero guardian");
        require(_daoTreasury != address(0), "CueRewardsPool: zero treasury");

        cueCoin           = IERC20(_cueCoin);
        cueNft            = ICueNFT(_cueNft);
        guardian          = _guardian;
        daoTreasury       = _daoTreasury;

        matchRewardPerGame = DEFAULT_MATCH_REWARD;
        ratePerSecond      = DEFAULT_RATE_PER_SECOND;
        lastBudgetUpdate   = block.timestamp;
        // pendingBudget starts at 0 — accrues from first block onwards
    }

    // ═══════════════════════════════════════════════════════════
    //  PRIMARY PAYOUT FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Pay the per-match P2E reward to the winner of a ranked match.
     *
     *         The base reward is matchRewardPerGame (default 0.5 CUE).
     *         If the winner holds a bonus-eligible NFT, the reward is multiplied:
     *           actualReward = baseReward × (10000 + nftBonusBps) / 10000
     *           Rare     (500 bps) → × 1.05
     *           Epic     (1000 bps)→ × 1.10
     *           Legendary(1500 bps)→ × 1.15
     *           Genesis  (2000 bps)→ × 1.20
     *
     *         If the pool is paused, depleted, or the budget is insufficient,
     *         returns 0 without reverting. Callers must treat 0 as "not paid"
     *         and absorb it silently — the match outcome is already settled.
     *
     *         The NFT multiplier query (walletBonusBps) is wrapped in a
     *         try/catch — if CueNFT is unavailable or reverts, the base
     *         reward is paid without multiplier (graceful degradation).
     *
     * @param winner  Address of the match winner to reward.
     * @return actual  Actual CUECOIN-wei paid (0 if insufficient budget or paused).
     */
    function payMatchReward(address winner)
        external
        nonReentrant
        onlyAuthorized
        returns (uint256 actual)
    {
        if (paused || winner == address(0)) return 0;

        // Accrue budget and check depletion guard
        _accrueBudget();

        uint256 base = matchRewardPerGame;
        if (base == 0) return 0;

        // Determine NFT multiplier (best-effort — graceful on failure)
        uint256 nftBps = _safeWalletBonusBps(winner);

        // actualReward = base × (10000 + nftBps) / 10000
        // For no NFT: nftBps = 0 → actualReward = base × 10000 / 10000 = base
        uint256 reward = base + (base * nftBps) / 10_000;

        uint256 balance = cueCoin.balanceOf(address(this));

        // Check both budget and balance
        if (pendingBudget < reward || balance < reward) return 0;

        // CEI: update state before transfer
        pendingBudget         -= reward;
        totalMatchRewardsPaid += reward;
        totalDisbursed        += reward;
        matchesRewarded++;

        cueCoin.safeTransfer(winner, reward);

        emit MatchRewardPaid(winner, base, nftBps, reward);
        return reward;
    }

    /**
     * @notice Pay an NFT wager bonus to a match winner.
     *
     *         Called by CueEscrow via low-level call after a wager match
     *         is resolved. The bonusAmount is pre-computed by the oracle
     *         as a percentage of the winner's wager:
     *           Rare: 5%, Epic: 10%, Legendary: 15%, Genesis: 20%
     *
     *         This contract does NOT verify the NFT bonus percentage —
     *         it trusts the authorized caller (CueEscrow) to compute the
     *         correct amount. The rate-limited budget and authorized-caller
     *         whitelist protect against abuse.
     *
     *         Returns 0 without reverting if:
     *           - Pool is paused
     *           - pendingBudget < bonusAmount
     *           - Contract balance < bonusAmount
     *         CueEscrow absorbs these silently — the match payout is already done.
     *
     *         Compatible with CueEscrow's low-level call pattern:
     *           rewardsPool.call(
     *             abi.encodeWithSignature("payNFTBonus(address,uint256)", winner, amount))
     *         Return value is ABI-decoded as uint256 by CueEscrow.
     *
     * @param winner       Address to receive the bonus.
     * @param bonusAmount  CUECOIN-wei bonus to pay.
     * @return actual      Actual CUECOIN-wei paid (0 if unable to pay).
     */
    function payNFTBonus(address winner, uint256 bonusAmount)
        external
        nonReentrant
        onlyAuthorized
        returns (uint256 actual)
    {
        if (paused || winner == address(0) || bonusAmount == 0) return 0;

        // Accrue budget and check depletion guard
        _accrueBudget();

        uint256 balance = cueCoin.balanceOf(address(this));

        // Check both budget and balance
        if (pendingBudget < bonusAmount || balance < bonusAmount) return 0;

        // CEI: update state before transfer
        pendingBudget      -= bonusAmount;
        totalNftBonusPaid  += bonusAmount;
        totalDisbursed     += bonusAmount;
        nftBonusPayments++;

        cueCoin.safeTransfer(winner, bonusAmount);

        emit NftBonusPaid(winner, bonusAmount, bonusAmount);
        return bonusAmount;
    }

    // ═══════════════════════════════════════════════════════════
    //  BUDGET ACCRUAL (public — allows off-chain triggers)
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Manually trigger a budget accrual tick.
     *
     *         This is called automatically at the start of every payout.
     *         It can also be called externally by keepers or monitoring
     *         scripts to update pendingBudget and check the depletion guard
     *         without triggering a payout.
     *
     *         No access restriction — this is a read-equivalent operation
     *         that only updates internal state, never transfers tokens.
     */
    function accrueBudget() external nonReentrant {
        _accrueBudget();
    }

    // ═══════════════════════════════════════════════════════════
    //  ADMIN — OWNER
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Authorize a contract to call payMatchReward and payNFTBonus.
     *         Must include CueEscrow immediately after deploy.
     */
    function addAuthorizedCaller(address caller) external onlyOwner {
        require(caller != address(0),      "CueRewardsPool: zero address");
        require(!authorizedCaller[caller], "CueRewardsPool: already authorized");
        authorizedCaller[caller] = true;
        emit CallerAuthorized(caller);
    }

    /// @notice Remove an authorized caller.
    function removeAuthorizedCaller(address caller) external onlyOwner {
        require(authorizedCaller[caller], "CueRewardsPool: not authorized");
        authorizedCaller[caller] = false;
        emit CallerRevoked(caller);
    }

    /**
     * @notice Set the per-match base reward. DAO adjustable via GENERIC_CALL.
     *         Hard-capped at MAX_MATCH_REWARD (5 CUE). Cannot be set to 0
     *         (use pause() to halt payouts instead).
     *
     * @param newReward  New match reward in CUECOIN-wei.
     */
    function setMatchRewardPerGame(uint256 newReward) external onlyOwner {
        require(newReward > 0,               "CueRewardsPool: zero reward");
        require(newReward <= MAX_MATCH_REWARD,"CueRewardsPool: exceeds MAX_MATCH_REWARD");
        uint256 old = matchRewardPerGame;
        matchRewardPerGame = newReward;
        emit MatchRewardUpdated(old, newReward);
    }

    /**
     * @notice Set the linear release rate. DAO adjustable via GENERIC_CALL.
     *         Hard-capped at MAX_RATE_PER_SECOND.
     *
     *         Accrues the budget at the current rate before switching, so
     *         no budget is lost or gained at the transition boundary.
     *
     * @param newRate  New rate in CUECOIN-wei per second.
     */
    function setRatePerSecond(uint256 newRate) external onlyOwner nonReentrant {
        require(newRate > 0,                    "CueRewardsPool: zero rate");
        require(newRate <= MAX_RATE_PER_SECOND, "CueRewardsPool: exceeds MAX_RATE_PER_SECOND");
        // Accrue at old rate before updating
        _accrueBudget();
        uint256 old = ratePerSecond;
        ratePerSecond = newRate;
        emit RateUpdated(old, newRate);

        // Recheck depletion guard at new rate
        _checkDepletionGuard();
    }

    /**
     * @notice Update the CueNFT address (for contract upgrades).
     *         Immediately effective — NFT multipliers begin reading from new address.
     */
    function setCueNft(address newNft) external onlyOwner {
        require(newNft != address(0), "CueRewardsPool: zero address");
        address old = address(cueNft);
        cueNft = ICueNFT(newNft);
        emit CueNftUpdated(old, newNft);
    }

    /**
     * @notice Recover non-CUECOIN tokens sent here by mistake.
     *         CUECOIN cannot be recovered — it is the reward reserve.
     *         The only way CUECOIN leaves this contract is via rate-limited payouts.
     */
    function recoverERC20(address token, uint256 amount) external onlyOwner {
        require(
            token != address(cueCoin),
            "CueRewardsPool: cannot recover CUECOIN — it is the reward reserve"
        );
        IERC20(token).safeTransfer(owner(), amount);
    }

    // ═══════════════════════════════════════════════════════════
    //  PAUSE — OWNER OR GUARDIAN
    // ═══════════════════════════════════════════════════════════

    function pause() external onlyOwnerOrGuardian {
        require(!paused, "CueRewardsPool: already paused");
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwnerOrGuardian {
        require(paused, "CueRewardsPool: not paused");
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ═══════════════════════════════════════════════════════════
    //  GUARDIAN — TWO-STEP
    // ═══════════════════════════════════════════════════════════

    function setGuardian(address nominee) external onlyOwner {
        require(nominee != address(0), "CueRewardsPool: zero nominee");
        pendingGuardian = nominee;
        emit GuardianNominated(nominee);
    }

    function acceptGuardian() external {
        require(msg.sender == pendingGuardian, "CueRewardsPool: not pending guardian");
        address old     = guardian;
        guardian        = pendingGuardian;
        pendingGuardian = address(0);
        emit GuardianAccepted(old, guardian);
    }

    // ═══════════════════════════════════════════════════════════
    //  DAO TREASURY — TIMELOCKED
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Queue a DAO treasury address update (48-hour timelock).
     *         The treasury address is stored for governance reference —
     *         this contract does not send funds to the treasury, but it
     *         is useful for monitoring and future fee routing.
     */
    function queueDaoTreasuryUpdate(address newTreasury) external onlyOwner {
        require(newTreasury != address(0),  "CueRewardsPool: zero treasury");
        require(newTreasury != daoTreasury, "CueRewardsPool: same treasury");
        uint256 eta = block.timestamp + TREASURY_UPDATE_DELAY;
        _pendingDaoTreasury    = newTreasury;
        _pendingDaoTreasuryEta = eta;
        emit DaoTreasuryUpdateQueued(newTreasury, eta);
    }

    function applyDaoTreasuryUpdate() external nonReentrant {
        require(_pendingDaoTreasuryEta != 0,               "CueRewardsPool: no pending update");
        require(block.timestamp >= _pendingDaoTreasuryEta,  "CueRewardsPool: delay not elapsed");
        address old        = daoTreasury;
        daoTreasury        = _pendingDaoTreasury;
        _pendingDaoTreasury    = address(0);
        _pendingDaoTreasuryEta = 0;
        emit DaoTreasuryUpdated(old, daoTreasury);
    }

    function cancelDaoTreasuryUpdate() external onlyOwner {
        require(_pendingDaoTreasuryEta != 0, "CueRewardsPool: no pending update");
        address cancelled      = _pendingDaoTreasury;
        _pendingDaoTreasury    = address(0);
        _pendingDaoTreasuryEta = 0;
        emit DaoTreasuryUpdateCancelled(cancelled);
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW — POOL STATUS
    // ═══════════════════════════════════════════════════════════

    /// @notice Current CUECOIN balance held by the pool.
    function poolBalance() external view returns (uint256) {
        return cueCoin.balanceOf(address(this));
    }

    /**
     * @notice Estimated runway in seconds at the current release rate.
     *         runway = balance / ratePerSecond
     *         Returns type(uint256).max if ratePerSecond is 0 (infinite runway).
     */
    function poolRunway() external view returns (uint256) {
        if (ratePerSecond == 0) return type(uint256).max;
        uint256 balance = cueCoin.balanceOf(address(this));
        return balance / ratePerSecond;
    }

    /**
     * @notice Pending budget that has accrued but not yet been disbursed,
     *         computed as of this block (without modifying state).
     */
    function currentPendingBudget() external view returns (uint256) {
        uint256 balance  = cueCoin.balanceOf(address(this));
        uint256 elapsed  = block.timestamp - lastBudgetUpdate;
        uint256 accrued  = elapsed * ratePerSecond;
        uint256 newBudget = pendingBudget + accrued;
        // Cap at balance
        if (newBudget > balance) newBudget = balance;
        return newBudget;
    }

    /**
     * @notice Preview match reward for a specific wallet (including NFT multiplier).
     *         Reads live from CueNFT — reflects current NFT holdings.
     * @param winner  Wallet to preview reward for.
     * @return base         Base reward (matchRewardPerGame).
     * @return nftBps       NFT bonus in basis points (0 if no bonus NFT held).
     * @return totalReward  Actual reward that would be paid.
     */
    function previewMatchReward(address winner)
        external
        view
        returns (uint256 base, uint256 nftBps, uint256 totalReward)
    {
        base   = matchRewardPerGame;
        nftBps = _safeWalletBonusBpsView(winner);
        totalReward = base + (base * nftBps) / 10_000;
    }

    /**
     * @notice Full protocol snapshot.
     */
    function protocolStats()
        external
        view
        returns (
            uint256 balance,
            uint256 budget,
            uint256 rate,
            uint256 runway,
            uint256 matchReward,
            uint256 matchesPaid,
            uint256 nftBonusesPaid,
            uint256 disbursed,
            bool    guardActive,
            bool    paused_
        )
    {
        balance        = cueCoin.balanceOf(address(this));
        budget         = pendingBudget;
        rate           = ratePerSecond;
        runway         = ratePerSecond > 0 ? balance / ratePerSecond : type(uint256).max;
        matchReward    = matchRewardPerGame;
        matchesPaid    = matchesRewarded;
        nftBonusesPaid = nftBonusPayments;
        disbursed      = totalDisbursed;
        guardActive    = depletionGuardActive;
        paused_        = paused;
    }

    function pendingTreasuryUpdate()
        external
        view
        returns (address pending, uint256 eta)
    {
        return (_pendingDaoTreasury, _pendingDaoTreasuryEta);
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — BUDGET ACCRUAL & DEPLETION GUARD
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev Core budget accumulator. Called at the start of every payout.
     *
     *      Computes elapsed time since lastBudgetUpdate, multiplies by
     *      ratePerSecond, adds to pendingBudget, caps at contract balance.
     *      Then checks the depletion guard.
     *
     *      The cap at balance is critical: Vortex Tax inflows arrive as
     *      raw balance increases. The budget accumulator cannot budget
     *      more than what is physically held — this prevents pendingBudget
     *      from inflating beyond what can actually be paid out.
     */
    function _accrueBudget() internal {
        uint256 now_    = block.timestamp;
        uint256 elapsed = now_ - lastBudgetUpdate;

        if (elapsed == 0) return;

        lastBudgetUpdate = now_;

        uint256 accrued  = elapsed * ratePerSecond;
        uint256 balance  = cueCoin.balanceOf(address(this));

        uint256 newBudget = pendingBudget + accrued;
        // Cap: cannot budget more than is physically in the contract
        if (newBudget > balance) newBudget = balance;

        pendingBudget = newBudget;

        emit BudgetAccrued(elapsed, accrued, newBudget);

        _checkDepletionGuard();
    }

    /**
     * @dev Check whether the runway has fallen below DEPLETION_RUNWAY.
     *      If so, halve ratePerSecond and set depletionGuardActive.
     *      If guard is active but runway has recovered, clear the flag.
     *
     *      This is called after every budget accrual and after setRatePerSecond.
     *
     *      Note: The guard only halves once per trigger. If the rate is already
     *      very low and the pool is still nearly empty, the guard will fire again
     *      on the next accrual (if runway is still < 30 days), halving again.
     *      This continues until rate reaches 1 wei/second (effectively zero).
     *      This is correct behaviour — the pool should asymptotically approach
     *      zero emissions as it depletes, not cut off suddenly.
     */
    function _checkDepletionGuard() internal {
        if (ratePerSecond == 0) return;

        uint256 balance = cueCoin.balanceOf(address(this));
        uint256 runway  = balance / ratePerSecond; // seconds

        if (runway < DEPLETION_RUNWAY) {
            if (!depletionGuardActive) {
                depletionGuardActive = true;
            }
            uint256 oldRate    = ratePerSecond;
            uint256 newRate    = oldRate / 2;
            if (newRate == 0) newRate = 1; // minimum: 1 wei/second (non-zero rate)
            ratePerSecond = newRate;
            emit DepletionGuardTriggered(oldRate, newRate, runway);
        } else if (depletionGuardActive) {
            // Runway has recovered (Vortex Tax topped up the pool)
            depletionGuardActive = false;
            emit DepletionGuardCleared(runway);
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — NFT MULTIPLIER HELPERS
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev Read CueNFT.walletBonusBps() in a try/catch.
     *      If CueNFT is unavailable or reverts (e.g., during upgrade),
     *      returns 0 — the base reward is paid without multiplier.
     *      This prevents a CueNFT failure from blocking all match rewards.
     */
    function _safeWalletBonusBps(address wallet) internal view returns (uint256) {
        try cueNft.walletBonusBps(wallet) returns (uint256 bps) {
            return bps;
        } catch {
            return 0;
        }
    }

    /// @dev Pure view version for previewMatchReward — same logic as above.
    function _safeWalletBonusBpsView(address wallet) internal view returns (uint256) {
        try cueNft.walletBonusBps(wallet) returns (uint256 bps) {
            return bps;
        } catch {
            return 0;
        }
    }
}
