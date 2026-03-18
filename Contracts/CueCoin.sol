// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ╔══════════════════════════════════════════════════════════════╗
//  CUECOIN  ·  v6.0  ·  Governance-Ready
//  CUECOIN Ecosystem  ·  BNB Smart Chain
//
//  Native BEP-20 token of the CUECOIN skill-gaming ecosystem.
//  Fixed 1B supply. No mint. No backdoors. Self-sustaining economy.
//
//  v4 features (carried forward):
//   [V4-1]  Vortex Tax: 4% base — burn / auto-LP / P2E / tournament / DAO
//   [V4-2]  Velocity Shield: auto-triggers on 15% TWAP drop, 4h duration
//   [V4-3]  Whale Guard: +2% surcharge on tx > 0.1% supply, all burned
//   [V4-4]  Auto-LP Engine: accumulates LP slice, swaps + pairs on threshold
//   [V4-5]  Fee exclusion + whale guard exclusion maps
//   [V4-6]  One-time irreversible enableTrading()
//   [V4-7]  Chainlink Keeper oracle for TWAP price and LP depth
//   [V4-8]  Emergency rescueBNB / rescueTokens
//
//  v5 changes (this release):
//   [V5-1]  DEV MULTISIG DESTINATION — 0.25% of every transfer now routes
//            to the Game Development Multisig (operational payroll, servers,
//            contractors). DAO tax reduced from 0.50% to 0.25% accordingly.
//            Total Vortex Tax remains 4.00% — no change to token holders.
//
//            New split:
//              1.00% → Burn       (permanent deflation)
//              1.00% → Auto-LP    (PancakeSwap pool depth)
//              1.00% → P2E Pool   (wager rewards + NFT bonuses)
//              0.50% → Tournament (prize pool self-funding)
//              0.25% → DAO        (governance treasury)
//              0.25% → Dev Multisig (operations: payroll, infra, marketing)
//            ────────────────────────────────────────────
//              4.00% total
//
//   [V5-2]  TIMELOCKED POOL UPDATES — updatePools() is now timelocked
//            48 hours. rewardsPool, tournamentPool, daoTreasury, and
//            devMultisig are live tax destinations; a silent redirect is
//            a rug vector. The timelock gives the community 48h to detect
//            and respond to a malicious update before it executes.
//
//   [V5-3]  FEE EXCLUSION SYNC ON POOL UPDATE — when pool addresses are
//            updated (after timelock), old addresses are automatically
//            de-excluded and new addresses are automatically fee-excluded
//            and whale-guard-excluded. Prevents the new pool address from
//            paying tax on inbound transfers.
//
//   [V5-4]  TIMELOCKED ORACLE UPDATES — updatePriceOracle() and
//            updateLPOracle() are now timelocked 48 hours. These oracles
//            control the Velocity Shield trigger. A malicious oracle
//            update could immediately push a false 15% drop and raise
//            the effective tax to 8% on the next transfer. The timelock
//            prevents silent oracle substitution.
//
//   [V5-5]  VELOCITY SHIELD DEAD CODE REMOVED — the prior
//            _evaluateVelocityShield() contained a dead if(!shieldActive)
//            block (lines 538–546 in v4) that computed a dropThreshold
//            but never compared it to anything. Shield activation is
//            correctly and exclusively handled by pushPriceUpdate().
//            The dead block has been removed. The function now only
//            handles deactivation when the 4-hour window expires.
//
//   [V5-6]  SAFEERC20 FOR rescueTokens() — the prior implementation used
//            a raw minimal IERC20 interface. Non-standard tokens that
//            return false on transfer would silently fail. Now uses
//            SafeERC20.safeTransfer(). The duplicate IERC20 interface at
//            the bottom of the file has been removed.
//
//   [V5-7]  TaxDistributed EVENT UPDATED — includes devMultisigAmount
//            field so that all six tax destinations are fully observable
//            on-chain. Monitoring dashboards can track every wei.
//
//   [V5-8]  TIMELOCK CANCEL — owner can cancel a queued pool or oracle
//            update before it executes (e.g., if queued by mistake or
//            if a governance decision reverses).
//
//  v6 changes (this release):
//   [V6-1]  ERC20VOTES — CueCoin now inherits ERC20Permit + ERC20Votes
//            so CueDAO can use tamper-proof historical vote weights via
//            getPastVotes(voter, snapshotTimestamp). Late token purchases
//            after a proposal is created have zero effect on vote weight.
//            Delegation is required: holders call delegate(self) or
//            delegate(other) to activate vote power. Undelegated tokens
//            do not count. Uses timestamp clock (ERC-6372) for alignment
//            with CueDAO's timestamp-based voting periods.
//
//   [V6-2]  CLOCK MODE — clock() returns block.timestamp. CLOCK_MODE()
//            returns the ERC-6372 descriptor string. Compatible with
//            OpenZeppelin Governor and any standard governance tooling.
// ╚══════════════════════════════════════════════════════════════╝

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// ─────────────────────────────────────────────────────────────
//  DEX INTERFACES
// ─────────────────────────────────────────────────────────────

/// @dev PancakeSwap V2-compatible router.
interface IPancakeRouter {
    function factory() external pure returns (address);
    function WETH()    external pure returns (address);

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IPancakeFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

// ─────────────────────────────────────────────────────────────
//  MAIN CONTRACT
// ─────────────────────────────────────────────────────────────

/**
 * @title  CueCoin
 * @author CUECOIN Team
 * @notice Native BEP-20 token of the CUECOIN skill-based gaming ecosystem.
 *
 * ════════════════════════════════════════════════════
 *  VORTEX TAX  ·  BASE STATE  (4.00% total)
 * ════════════════════════════════════════════════════
 *   1.00%  →  Burn          (0xdead — permanent deflation)
 *   1.00%  →  Auto-LP       (deepens PancakeSwap pool automatically)
 *   1.00%  →  P2E Pool      (play-to-earn rewards + NFT wager bonuses)
 *   0.50%  →  Tournament    (self-funding prize pools)
 *   0.25%  →  DAO           (governance treasury)
 *   0.25%  →  Dev Multisig  (operations: payroll, servers, contractors)
 *   ──────────────────────────────────────────────────
 *   4.00%  total  [V5-1]
 *
 * ════════════════════════════════════════════════════
 *  VELOCITY SHIELD  ·  AUTO-TRIGGERED  (8% total)
 * ════════════════════════════════════════════════════
 *   Activates when:
 *     • TWAP price drops > 15% in 1 hour, AND
 *     • LP depth ≥ 50 BNB (prevents thin-market false triggers)
 *   Effect: +4% added to Auto-LP slice. Tax rises from 4% to 8%.
 *   Duration: exactly 4 hours. Auto-resets. Cannot be extended.
 *   NO human can trigger or extend the shield.
 *
 * ════════════════════════════════════════════════════
 *  WHALE GUARD  ·  AUTO-TRIGGERED  (+2% surcharge)
 * ════════════════════════════════════════════════════
 *   Any single tx > 0.1% of total supply (1,000,000 CUECOIN)
 *   pays +2% routed entirely to burn. Cannot be disabled.
 *   Vesting/airdrop/ecosystem contracts are exempt.
 *
 * ════════════════════════════════════════════════════
 *  HARD LIMITS  ·  BYTECODE CONSTANTS  ·  UNCHANGEABLE
 * ════════════════════════════════════════════════════
 *   Supply cap:       1,000,000,000 CUECOIN — no mint function exists
 *   Max tax:          10% — no combination of states can exceed this
 *   Burn address:     0xdead — hardcoded, not redirectable
 *   Shield LP min:    50 BNB — prevents thin-market false triggers
 *   Whale threshold:  0.1% of supply per transaction
 */
contract CueCoin is ERC20, ERC20Permit, ERC20Votes, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════
    //  IMMUTABLE CONSTANTS  (compiled into bytecode)
    // ═══════════════════════════════════════════════════════════

    /// @notice Hard supply cap — minted once in constructor, never again.
    uint256 public constant TOTAL_SUPPLY      = 1_000_000_000 ether;

    /// @notice Whale Guard threshold: 0.1% of total supply per transaction.
    uint256 public constant WHALE_THRESHOLD   = TOTAL_SUPPLY / 1_000;

    // ── Base tax components (basis points, 10_000 = 100%) ──
    uint16 public constant TAX_BURN_BASE       = 100;  // 1.00%
    uint16 public constant TAX_LP_BASE         = 100;  // 1.00%
    uint16 public constant TAX_REWARDS_BASE    = 100;  // 1.00%
    uint16 public constant TAX_TOURNAMENT_BASE =  50;  // 0.50%
    uint16 public constant TAX_DAO_BASE        =  25;  // 0.25%  [V5-1] reduced from 50
    uint16 public constant TAX_DEV_BASE        =  25;  // 0.25%  [V5-1] new destination
    uint16 public constant TAX_BASE_TOTAL      = 400;  // 4.00%  (unchanged)

    // ── Velocity Shield ──
    /// @notice Extra LP tax when shield is active (+4% → total 8%).
    uint16 public constant TAX_SHIELD_EXTRA    = 400;  // +4.00%

    /// @notice Shield active duration — auto-resets, cannot be extended.
    uint256 public constant SHIELD_DURATION    = 4 hours;

    /// @notice Minimum LP depth (BNB-wei) required before shield can fire.
    ///         Protects thin early markets from legitimate large trades.
    uint256 public constant MIN_LP_FOR_SHIELD  = 50 ether;

    /// @notice Price drop percentage that triggers shield (15%).
    uint256 public constant SHIELD_DROP_BPS    = 1_500; // 15.00%

    // ── Whale Guard ──
    /// @notice Additive surcharge on whale transactions — all goes to burn.
    uint16 public constant WHALE_SURCHARGE     = 200;   // +2.00%

    // ── Absolute tax ceiling ──
    /// @notice Maximum possible tax under any combination of active states.
    ///         Bytecode constant — no DAO vote or owner can exceed this.
    uint16 public constant MAX_TAX_BPS         = 1_000; // 10.00%

    // ── Auto-LP Engine ──
    /// @notice Pending LP tokens accumulate until this threshold, then
    ///         swapped and added to the pool in a single transaction.
    uint256 public constant LP_SWAP_THRESHOLD  = 100_000 ether;

    // ── Price oracle ──
    /// @notice Minimum interval between price oracle pushes.
    uint256 public constant PRICE_UPDATE_INTERVAL = 10 minutes;

    // ── Timelock [V5-2, V5-4] ──
    uint256 public constant TIMELOCK_DELAY = 48 hours;
    uint256 public constant TIMELOCK_GRACE = 14 days;

    // ── Addresses ──
    address public constant BURN_ADDRESS = address(0xdead);

    // ═══════════════════════════════════════════════════════════
    //  STATE VARIABLES
    // ═══════════════════════════════════════════════════════════

    // ── Tax destination addresses ──
    address public rewardsPool;     // P2E rewards + NFT bonuses
    address public tournamentPool;  // Tournament prize self-funding
    address public daoTreasury;     // Governance treasury
    address public devMultisig;     // [V5-1] Operations: payroll, infra, marketing

    // ── DEX ──
    IPancakeRouter public dexRouter;
    address        public liquidityPair;

    // ── Trading gate ──
    bool public tradingEnabled;

    // ── Re-entrancy guard for auto-LP swap ──
    bool private _inAutoSwap;

    // ── Velocity Shield state ──
    bool    public shieldActive;
    uint256 public shieldEndsAt;
    uint256 public lastRecordedPriceBNB; // CUECOIN price in BNB-wei (×1e18 scaled)
    uint256 public lastPriceTimestamp;
    uint256 public lpDepthBNB;           // BNB in LP — updated by Chainlink Keeper

    // ── Auto-LP pending balance ──
    uint256 public pendingLiquidityTokens;

    // ── Oracle roles ──
    /// @notice Chainlink Keeper — pushes 1-hour TWAP price updates.
    address public priceOracle;

    /// @notice Chainlink Keeper — pushes LP BNB depth updates.
    address public lpOracle;

    // ── Fee / whale exclusion ──
    mapping(address => bool) public isExcludedFromFee;
    mapping(address => bool) public isExcludedFromWhaleGuard;

    // ── [V5-2 / V5-4] Timelock state ──
    mapping(bytes32 => uint256) public timelockEta;
    mapping(bytes32 => bool)    public timelockExecuted;

    // ═══════════════════════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════════════════════

    event TradingEnabled(uint256 timestamp);

    event VelocityShieldActivated(
        uint256 indexed timestamp,
        uint256 endsAt,
        uint256 triggerPriceBNB,
        uint256 previousPriceBNB
    );
    event VelocityShieldDeactivated(uint256 indexed timestamp);

    event AutoLiquidityAdded(
        uint256 tokensSwapped,
        uint256 bnbReceived,
        uint256 tokensAddedToLP
    );
    event AutoLiquidityQueued(uint256 amount, uint256 pendingTotal);

    /// @notice [V5-7] Emitted on every taxable transfer — all six destinations tracked.
    event TaxDistributed(
        uint256 totalTaxBps,
        uint256 burnAmount,
        uint256 lpAmount,
        uint256 rewardsAmount,
        uint256 tournamentAmount,
        uint256 daoAmount,
        uint256 devAmount      // [V5-7]
    );

    event PriceUpdated(uint256 priceBNB, uint256 timestamp);
    event LPDepthUpdated(uint256 depthBNB, uint256 timestamp);

    event PriceOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event LPOracleUpdated(address indexed oldOracle, address indexed newOracle);

    event PoolAddressesUpdated(
        address indexed rewardsPool,
        address indexed tournamentPool,
        address indexed daoTreasury,
        address          devMultisig   // not indexed — 4th address
    );

    event FeeExclusionUpdated(address indexed account, bool excluded);
    event WhaleGuardExclusionUpdated(address indexed account, bool excluded);

    // [V5-2 / V5-4 / V5-8] Timelock events
    event TimelockQueued(bytes32 indexed operationId, bytes32 indexed action, uint256 eta);
    event TimelockExecuted(bytes32 indexed operationId, bytes32 indexed action);
    event TimelockCancelled(bytes32 indexed operationId);

    // ═══════════════════════════════════════════════════════════
    //  STRUCTS
    // ═══════════════════════════════════════════════════════════

    /// @dev Per-destination allocation breakdown for a single taxable transfer.
    struct TaxSplit {
        uint256 burnBps;
        uint256 lpBps;
        uint256 rewardsBps;
        uint256 tournamentBps;
        uint256 daoBps;
        uint256 devBps;        // [V5-1]
    }

    // ═══════════════════════════════════════════════════════════
    //  MODIFIERS
    // ═══════════════════════════════════════════════════════════

    modifier lockAutoSwap() {
        _inAutoSwap = true;
        _;
        _inAutoSwap = false;
    }

    modifier onlyPriceOracle() {
        require(msg.sender == priceOracle, "CueCoin: not price oracle");
        _;
    }

    modifier onlyLPOracle() {
        require(msg.sender == lpOracle, "CueCoin: not LP oracle");
        _;
    }

    /**
     * @dev [V5-2 / V5-4] 48-hour timelock for sensitive admin operations.
     *      Call 1: queues the operation, returns. Emits TimelockQueued.
     *      Call 2 (after 48h, within 14 days): executes function body.
     *      opId is keyed on action + caller + calldata so different arguments
     *      produce independent timers.
     */
    modifier timelocked(bytes32 action) {
        bytes32 opId = keccak256(abi.encodePacked(action, msg.sender, keccak256(msg.data)));
        if (timelockEta[opId] == 0) {
            uint256 eta = block.timestamp + TIMELOCK_DELAY;
            timelockEta[opId] = eta;
            emit TimelockQueued(opId, action, eta);
            return;
        }
        require(block.timestamp >= timelockEta[opId],                  "CueCoin: timelock not elapsed");
        require(block.timestamp <  timelockEta[opId] + TIMELOCK_GRACE, "CueCoin: timelock grace expired");
        require(!timelockExecuted[opId],                               "CueCoin: already executed");
        timelockExecuted[opId] = true;
        emit TimelockExecuted(opId, action);
        _;
    }

    // ═══════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Deploy CueCoin. Mints the full 1B supply to deployer.
     *         Deployer must immediately distribute allocations to vesting,
     *         airdrop, and other ecosystem contracts. No mint function exists
     *         after this constructor completes.
     *
     * @param _router         PancakeSwap V2-compatible router (BSC mainnet).
     * @param _rewardsPool    P2E rewards pool contract (CueRewardsPool.sol).
     * @param _tournamentPool Tournament prize pool (CueTournament.sol).
     * @param _daoTreasury    DAO governance treasury (CueDAO.sol).
     * @param _devMultisig    Game Dev Gnosis Safe — payroll, servers, marketing. [V5-1]
     * @param _priceOracle    Chainlink Keeper — TWAP price pusher.
     * @param _lpOracle       Chainlink Keeper — LP depth pusher.
     */
    constructor(
        address _router,
        address _rewardsPool,
        address _tournamentPool,
        address _daoTreasury,
        address _devMultisig,
        address _priceOracle,
        address _lpOracle
    )
        ERC20("CueCoin", "CUECOIN")
        ERC20Permit("CueCoin")
        Ownable(msg.sender)
    {
        require(_router         != address(0), "CueCoin: zero router");
        require(_rewardsPool    != address(0), "CueCoin: zero rewardsPool");
        require(_tournamentPool != address(0), "CueCoin: zero tournamentPool");
        require(_daoTreasury    != address(0), "CueCoin: zero daoTreasury");
        require(_devMultisig    != address(0), "CueCoin: zero devMultisig");
        require(_priceOracle    != address(0), "CueCoin: zero priceOracle");
        require(_lpOracle       != address(0), "CueCoin: zero lpOracle");

        dexRouter      = IPancakeRouter(_router);
        rewardsPool    = _rewardsPool;
        tournamentPool = _tournamentPool;
        daoTreasury    = _daoTreasury;
        devMultisig    = _devMultisig;
        priceOracle    = _priceOracle;
        lpOracle       = _lpOracle;

        // Create CUECOIN/BNB liquidity pair on PancakeSwap
        liquidityPair = IPancakeFactory(dexRouter.factory())
            .createPair(address(this), dexRouter.WETH());

        // ── Fee exclusions — system contracts never pay Vortex Tax ──
        _setFeeExclusion(msg.sender,        true);
        _setFeeExclusion(address(this),     true);
        _setFeeExclusion(_rewardsPool,      true);
        _setFeeExclusion(_tournamentPool,   true);
        _setFeeExclusion(_daoTreasury,      true);
        _setFeeExclusion(_devMultisig,      true);  // [V5-1]
        _setFeeExclusion(BURN_ADDRESS,      true);

        // ── Whale guard exclusions — large-allocation contracts at deploy ──
        _setWhaleExclusion(msg.sender,      true);
        _setWhaleExclusion(address(this),   true);
        _setWhaleExclusion(_rewardsPool,    true);
        _setWhaleExclusion(_tournamentPool, true);
        _setWhaleExclusion(_daoTreasury,    true);
        _setWhaleExclusion(_devMultisig,    true);  // [V5-1]

        // ── Mint — one time, full supply, to deployer ──
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    // ═══════════════════════════════════════════════════════════
    //  CORE TRANSFER HOOK
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev Overrides ERC20._update — single entry point for all token movements.
     *      Injects Vortex Tax on every eligible transfer.
     *
     *      Tax is NOT applied when:
     *        - Either address is fee-excluded (system contracts)
     *        - Called from within the auto-LP swap (_inAutoSwap guard)
     *        - This is a mint (from == address(0)) or burn (to == address(0))
     *
     *      Execution order on taxable transfers:
     *        1. Check trading gate
     *        2. Trigger auto-LP if threshold met (before tax to avoid recursion)
     *        3. Deactivate expired Velocity Shield if needed
     *        4. Compute tax bps and per-destination split
     *        5. Distribute tax tokens to all destinations
     *        6. Transfer net amount to recipient
     */
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override(ERC20, ERC20Votes) {

        bool excluded     = isExcludedFromFee[from] || isExcludedFromFee[to];
        bool isMintOrBurn = (from == address(0) || to == address(0));

        if (_inAutoSwap || excluded || isMintOrBurn) {
            super._update(from, to, amount);
            return;
        }

        require(tradingEnabled, "CueCoin: trading not enabled");
        require(amount > 0,     "CueCoin: zero transfer");

        // Trigger auto-LP on sells only (prevents sandwich attacks on buys)
        if (
            pendingLiquidityTokens >= LP_SWAP_THRESHOLD &&
            from != liquidityPair  &&
            !_inAutoSwap
        ) {
            _triggerAutoLiquidity();
        }

        // Deactivate expired Velocity Shield [V5-5]
        _evaluateVelocityShield();

        // Compute tax
        (uint256 taxBps, TaxSplit memory split) = _computeTax(from, amount);

        if (taxBps == 0) {
            super._update(from, to, amount);
            return;
        }

        uint256 totalTaxTokens = (amount * taxBps) / 10_000;
        uint256 netAmount      = amount - totalTaxTokens;

        require(netAmount > 0, "CueCoin: amount too small after tax");

        _applyTaxSplit(from, totalTaxTokens, split, taxBps);

        super._update(from, to, netAmount);
    }

    // ── ERC-6372 clock: timestamp mode (required by ERC20Votes) ──

    /**
     * @dev Returns block.timestamp as the clock value.
     *      ERC20Votes will store checkpoints indexed by timestamp.
     *      CueDAO uses block.timestamp for voting periods, so both
     *      systems operate in the same time domain.
     */
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    /**
     * @dev ERC-6372 clock mode descriptor.
     *      "mode=timestamp" signals to tooling that checkpoints are
     *      indexed by block.timestamp, not block.number.
     */
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp&from=default";
    }

    /**
     * @dev ERC20Permit and ERC20Votes both define nonces(). This override
     *      resolves the ambiguity by routing to ERC20Permit's implementation,
     *      which is the one used for delegateBySig and permit signatures.
     */
    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    // ═══════════════════════════════════════════════════════════
    //  TAX LOGIC
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev Compute total tax in basis points and per-destination allocation.
     *      Accounts for Velocity Shield (extra LP) and Whale Guard (extra burn).
     *
     *      Base state (no shield, no whale):
     *        burn=100 + lp=100 + rewards=100 + tournament=50 + dao=25 + dev=25 = 400 bps
     *
     *      Shield active:
     *        lp += 400 → total = 800 bps
     *
     *      Whale tx (no shield):
     *        burn += 200 → total = 600 bps
     *
     *      Shield + whale:
     *        lp += 400, burn += 200 → total = 1000 bps (hits MAX_TAX_BPS ceiling)
     *        Excess trimmed from burn slice proportionally.
     */
    function _computeTax(
        address from,
        uint256 amount
    ) internal view returns (uint256 taxBps, TaxSplit memory split) {

        bool shielded = shieldActive && block.timestamp < shieldEndsAt;
        bool isWhale  = (!isExcludedFromWhaleGuard[from]) && (amount > WHALE_THRESHOLD);

        split.burnBps       = TAX_BURN_BASE;
        split.lpBps         = TAX_LP_BASE + (shielded ? TAX_SHIELD_EXTRA : 0);
        split.rewardsBps    = TAX_REWARDS_BASE;
        split.tournamentBps = TAX_TOURNAMENT_BASE;
        split.daoBps        = TAX_DAO_BASE;
        split.devBps        = TAX_DEV_BASE;  // [V5-1]

        taxBps = TAX_BASE_TOTAL + (shielded ? TAX_SHIELD_EXTRA : 0);

        // Whale surcharge: all goes to burn
        if (isWhale) {
            split.burnBps += WHALE_SURCHARGE;
            taxBps        += WHALE_SURCHARGE;
        }

        // Hard ceiling — bytecode constant, no path can exceed 10%
        if (taxBps > MAX_TAX_BPS) {
            uint256 excess = taxBps - MAX_TAX_BPS;
            // Trim excess from burn (largest slice) first
            split.burnBps = split.burnBps > excess ? split.burnBps - excess : 0;
            taxBps        = MAX_TAX_BPS;
        }
    }

    /**
     * @dev Distribute tax tokens to all six destinations.
     *      Uses proportional arithmetic. Dev multisig gets its slice first;
     *      DAO receives the remainder to absorb all rounding dust — ensures
     *      no tokens are arithmetically lost.
     *
     *      Distribution order:
     *        1. Burn → 0xdead
     *        2. Auto-LP → this contract (batched, swapped on threshold)
     *        3. Rewards → rewardsPool
     *        4. Tournament → tournamentPool
     *        5. Dev → devMultisig
     *        6. DAO → daoTreasury (remainder — absorbs dust)
     */
    function _applyTaxSplit(
        address from,
        uint256 totalTaxTokens,
        TaxSplit memory split,
        uint256 taxBps
    ) internal {

        uint256 burnAmt       = _bpsOf(totalTaxTokens, split.burnBps,       taxBps);
        uint256 lpAmt         = _bpsOf(totalTaxTokens, split.lpBps,         taxBps);
        uint256 rewardsAmt    = _bpsOf(totalTaxTokens, split.rewardsBps,    taxBps);
        uint256 tournamentAmt = _bpsOf(totalTaxTokens, split.tournamentBps, taxBps);
        uint256 devAmt        = _bpsOf(totalTaxTokens, split.devBps,        taxBps); // [V5-1]

        // DAO receives remainder — absorbs all integer rounding dust
        uint256 daoAmt = totalTaxTokens - burnAmt - lpAmt - rewardsAmt - tournamentAmt - devAmt;

        // 1. Burn
        if (burnAmt > 0)       super._update(from, BURN_ADDRESS,  burnAmt);

        // 2. Auto-LP (accumulates on contract, flushed at threshold)
        if (lpAmt > 0) {
            super._update(from, address(this), lpAmt);
            pendingLiquidityTokens += lpAmt;
            emit AutoLiquidityQueued(lpAmt, pendingLiquidityTokens);
        }

        // 3. P2E Rewards Pool
        if (rewardsAmt > 0)    super._update(from, rewardsPool,    rewardsAmt);

        // 4. Tournament Pool
        if (tournamentAmt > 0) super._update(from, tournamentPool, tournamentAmt);

        // 5. Dev Multisig [V5-1]
        if (devAmt > 0)        super._update(from, devMultisig,    devAmt);

        // 6. DAO Treasury (remainder)
        if (daoAmt > 0)        super._update(from, daoTreasury,    daoAmt);

        emit TaxDistributed(taxBps, burnAmt, lpAmt, rewardsAmt, tournamentAmt, daoAmt, devAmt);
    }

    /// @dev Proportional calculation: (total × numerator) / denominator, rounded down.
    function _bpsOf(
        uint256 total,
        uint256 numerator,
        uint256 denominator
    ) internal pure returns (uint256) {
        if (denominator == 0 || numerator == 0) return 0;
        return (total * numerator) / denominator;
    }

    // ═══════════════════════════════════════════════════════════
    //  VELOCITY SHIELD  (AUTOMATIC — NOT OWNER-CONTROLLED)
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev [V5-5] Evaluates whether the Velocity Shield should deactivate.
     *      Called on every taxable transfer.
     *
     *      Shield ACTIVATION is handled exclusively by pushPriceUpdate()
     *      (the oracle push path). This function handles DEACTIVATION only —
     *      it resets the shield after the 4-hour window expires.
     *
     *      The prior v4 version had a dead if(!shieldActive) block here that
     *      computed a dropThreshold but never compared it to anything — it
     *      was unreachable dead code. Removed in v5 [V5-5].
     */
    function _evaluateVelocityShield() internal {
        if (shieldActive && block.timestamp >= shieldEndsAt) {
            shieldActive = false;
            emit VelocityShieldDeactivated(block.timestamp);
        }
    }

    /**
     * @notice Push a new 1-hour TWAP price reading from the Chainlink Keeper.
     *         The keeper computes TWAP off-chain using PancakeSwap observations,
     *         then calls this function. If the price represents a >15% drop AND
     *         LP depth ≥ 50 BNB, the Velocity Shield activates automatically.
     *
     *         Shield cannot be activated by anyone other than this oracle push.
     *         No owner function, no DAO vote, no on-chain spot price manipulation
     *         can trigger the shield.
     *
     * @param newPriceBNB  CUECOIN price in BNB-wei (e.g. 0.001 BNB = 1e15).
     */
    function pushPriceUpdate(uint256 newPriceBNB) external onlyPriceOracle {
        require(newPriceBNB > 0, "CueCoin: zero price");

        // Rate limiting — prevent keeper spam
        require(
            block.timestamp >= lastPriceTimestamp + PRICE_UPDATE_INTERVAL,
            "CueCoin: price update too frequent"
        );

        uint256 previousPrice = lastRecordedPriceBNB;
        lastRecordedPriceBNB  = newPriceBNB;
        lastPriceTimestamp    = block.timestamp;

        emit PriceUpdated(newPriceBNB, block.timestamp);

        // Deactivate expired shield
        if (shieldActive && block.timestamp >= shieldEndsAt) {
            shieldActive = false;
            emit VelocityShieldDeactivated(block.timestamp);
        }

        // Shield activation check — only if:
        //   1. Shield not already active
        //   2. A previous price exists to compare against
        //   3. LP depth meets the minimum (50 BNB)
        if (
            !shieldActive      &&
            previousPrice > 0  &&
            lpDepthBNB >= MIN_LP_FOR_SHIELD
        ) {
            // Drop threshold = 85% of previous price
            uint256 dropThreshold = previousPrice -
                (previousPrice * SHIELD_DROP_BPS / 10_000);

            if (newPriceBNB < dropThreshold) {
                shieldActive = true;
                shieldEndsAt = block.timestamp + SHIELD_DURATION;
                emit VelocityShieldActivated(
                    block.timestamp,
                    shieldEndsAt,
                    newPriceBNB,
                    previousPrice
                );
            }
        }
    }

    /**
     * @notice Push LP BNB depth reading from the Chainlink Keeper.
     *         Keeper reads the BNB reserve from PancakeSwap's CUECOIN/BNB pair.
     *         Used exclusively by the shield's LP depth guard.
     *
     * @param depthBNB  Current BNB in the liquidity pool (BNB-wei).
     */
    function pushLPDepthUpdate(uint256 depthBNB) external onlyLPOracle {
        lpDepthBNB = depthBNB;
        emit LPDepthUpdated(depthBNB, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════
    //  AUTO-LIQUIDITY ENGINE
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev Swap half the accumulated LP tokens for BNB, then pair them
     *      back into PancakeSwap. LP tokens resulting from this operation
     *      are sent to BURN_ADDRESS — permanently locked, never retrievable.
     *
     *      Only triggered when pendingLiquidityTokens >= LP_SWAP_THRESHOLD.
     *      Internally protected by lockAutoSwap to prevent re-entrant tax loops.
     *      DEX calls are wrapped in try/catch — a failed swap restores pending
     *      balance rather than permanently losing the tokens.
     */
    function _triggerAutoLiquidity() internal lockAutoSwap nonReentrant {
        uint256 contractBalance = balanceOf(address(this));
        uint256 toProcess       = pendingLiquidityTokens;

        // Safety: never process more than what the contract actually holds
        if (toProcess > contractBalance) toProcess = contractBalance;
        if (toProcess == 0) return;

        pendingLiquidityTokens = 0;

        uint256 half      = toProcess / 2;
        uint256 otherHalf = toProcess - half; // slightly more to avoid rounding loss

        // Step 1: Swap half for BNB
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = dexRouter.WETH();

        _approve(address(this), address(dexRouter), half);

        uint256 bnbBefore = address(this).balance;

        try dexRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            half,
            0,                       // accept any BNB — slippage fine for auto-LP
            path,
            address(this),
            block.timestamp + 300
        ) {
            uint256 bnbGained = address(this).balance - bnbBefore;

            if (bnbGained == 0) {
                // Swap returned no BNB — restore pending
                pendingLiquidityTokens = toProcess;
                return;
            }

            // Step 2: Add liquidity (tokens + BNB) to PancakeSwap
            _approve(address(this), address(dexRouter), otherHalf);

            try dexRouter.addLiquidityETH{value: bnbGained}(
                address(this),
                otherHalf,
                0,            // min tokens — 0 acceptable, auto-LP is not user-facing
                0,            // min BNB
                BURN_ADDRESS, // LP tokens permanently burned
                block.timestamp + 300
            ) returns (uint256 tokenUsed, uint256 bnbUsed, uint256) {
                emit AutoLiquidityAdded(half, bnbUsed, tokenUsed);

                // Return any unused tokens (from liquidity ratio rounding) to pending
                uint256 unused = otherHalf - tokenUsed;
                if (unused > 0) pendingLiquidityTokens += unused;

            } catch {
                // addLiquidityETH failed — restore all to pending
                pendingLiquidityTokens = toProcess;
            }

        } catch {
            // Swap failed — restore all to pending
            pendingLiquidityTokens = toProcess;
        }
    }

    /**
     * @notice Manually trigger the auto-LP engine.
     *         Callable by anyone — trustless, no privileged access required.
     *         Useful when the threshold was reached but auto-trigger didn't fire
     *         (e.g., no sell transactions occurred to trigger it naturally).
     */
    function triggerAutoLiquidity() external nonReentrant {
        require(pendingLiquidityTokens > 0, "CueCoin: no pending liquidity");
        require(!_inAutoSwap,               "CueCoin: auto-swap in progress");
        _triggerAutoLiquidity();
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Current effective tax rate in basis points for a given
     *         sender and transfer amount. Returns 0 for excluded addresses.
     */
    function currentTaxBps(address from, uint256 amount)
        external view returns (uint256 taxBps)
    {
        if (isExcludedFromFee[from]) return 0;
        (taxBps, ) = _computeTax(from, amount);
    }

    /**
     * @notice Whether the Velocity Shield is currently active and
     *         how many seconds remain until it deactivates.
     */
    function shieldStatus()
        external view
        returns (bool active, uint256 secondsRemaining)
    {
        active           = shieldActive && block.timestamp < shieldEndsAt;
        secondsRemaining = active ? shieldEndsAt - block.timestamp : 0;
    }

    /**
     * @notice Full breakdown of the current tax state.
     *         Useful for frontend display and keeper monitoring.
     */
    function taxState()
        external view
        returns (
            uint256 baseTax,
            uint256 shieldExtra,
            uint256 whaleExtra,
            uint256 maxPossible,
            bool    shieldCurrentlyActive,
            uint256 shieldExpiresAt
        )
    {
        baseTax               = TAX_BASE_TOTAL;
        shieldExtra           = (shieldActive && block.timestamp < shieldEndsAt)
                                    ? TAX_SHIELD_EXTRA : 0;
        whaleExtra            = WHALE_SURCHARGE; // informational — applies to whale txs only
        maxPossible           = MAX_TAX_BPS;
        shieldCurrentlyActive = shieldActive && block.timestamp < shieldEndsAt;
        shieldExpiresAt       = shieldEndsAt;
    }

    /**
     * @notice Current per-destination tax split in basis points.
     *         Returns the live split accounting for shield and whale states.
     *         Pass a representative sender and amount for whale-aware output.
     */
    function taxSplitPreview(address from, uint256 amount)
        external view
        returns (
            uint256 totalBps,
            uint256 burnBps,
            uint256 lpBps,
            uint256 rewardsBps,
            uint256 tournamentBps,
            uint256 daoBps,
            uint256 devBps
        )
    {
        if (isExcludedFromFee[from]) return (0, 0, 0, 0, 0, 0, 0);
        TaxSplit memory s;
        (totalBps, s) = _computeTax(from, amount);
        burnBps       = s.burnBps;
        lpBps         = s.lpBps;
        rewardsBps    = s.rewardsBps;
        tournamentBps = s.tournamentBps;
        daoBps        = s.daoBps;
        devBps        = s.devBps;
    }

    /**
     * @notice All tax destination addresses in one call.
     */
    function poolAddresses()
        external view
        returns (
            address rewards,
            address tournament,
            address dao,
            address dev
        )
    {
        rewards    = rewardsPool;
        tournament = tournamentPool;
        dao        = daoTreasury;
        dev        = devMultisig;
    }

    /**
     * @notice Estimated daily burn at a given daily wager volume.
     * @param dailyWagerVolume  Total CUECOIN wagered per day (18-decimal wei).
     * @return estimatedBurn    Estimated tokens burned per day from transfer tax.
     */
    function estimatedDailyBurn(uint256 dailyWagerVolume)
        external pure returns (uint256 estimatedBurn)
    {
        // Conservative: 1% burn tax on wager transfers only
        estimatedBurn = (dailyWagerVolume * TAX_BURN_BASE) / 10_000;
    }

    /**
     * @notice View ETA and status of a queued timelocked operation.
     */
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
    //  OWNER / DAO ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Enable trading. One-time, irreversible.
     *         Must be called by owner after LP is locked in CueLiquidityLocker.
     *         Once called, cannot be undone — trading is permanent.
     */
    function enableTrading() external onlyOwner {
        require(!tradingEnabled, "CueCoin: already enabled");
        tradingEnabled     = true;
        lastPriceTimestamp = block.timestamp;
        emit TradingEnabled(block.timestamp);
    }

    /**
     * @notice [V5-2] Update all four tax destination addresses. TIMELOCKED 48 hours.
     *
     *         All four must be set atomically to prevent partial-update issues.
     *         After the timelock executes:
     *           - Old addresses lose fee exclusion and whale guard exclusion [V5-3]
     *           - New addresses gain fee exclusion and whale guard exclusion [V5-3]
     *
     *         Rationale for timelock: these addresses are live tax destinations
     *         receiving a fraction of every single transfer. A silent redirect
     *         to attacker-controlled addresses would drain P2E rewards, tournament
     *         prizes, and operational funds. The 48h window lets token holders,
     *         the guardian multisig, and monitoring systems detect and respond.
     */
    function updatePools(
        address _rewards,
        address _tournament,
        address _dao,
        address _dev
    )
        external
        onlyOwner
        timelocked(keccak256("updatePools"))
    {
        require(_rewards    != address(0), "CueCoin: zero rewards");
        require(_tournament != address(0), "CueCoin: zero tournament");
        require(_dao        != address(0), "CueCoin: zero dao");
        require(_dev        != address(0), "CueCoin: zero dev");

        // [V5-3] Remove exclusions from old addresses
        _setFeeExclusion(rewardsPool,    false);
        _setFeeExclusion(tournamentPool, false);
        _setFeeExclusion(daoTreasury,    false);
        _setFeeExclusion(devMultisig,    false);
        _setWhaleExclusion(rewardsPool,    false);
        _setWhaleExclusion(tournamentPool, false);
        _setWhaleExclusion(daoTreasury,    false);
        _setWhaleExclusion(devMultisig,    false);

        // Update addresses
        rewardsPool    = _rewards;
        tournamentPool = _tournament;
        daoTreasury    = _dao;
        devMultisig    = _dev;

        // [V5-3] Add exclusions to new addresses
        _setFeeExclusion(_rewards,    true);
        _setFeeExclusion(_tournament, true);
        _setFeeExclusion(_dao,        true);
        _setFeeExclusion(_dev,        true);
        _setWhaleExclusion(_rewards,    true);
        _setWhaleExclusion(_tournament, true);
        _setWhaleExclusion(_dao,        true);
        _setWhaleExclusion(_dev,        true);

        emit PoolAddressesUpdated(_rewards, _tournament, _dao, _dev);
    }

    /**
     * @notice [V5-4] Update the Chainlink Keeper for TWAP price pushes. TIMELOCKED 48 hours.
     *
     *         Rationale: the price oracle controls the Velocity Shield trigger.
     *         A malicious oracle swap could immediately push a false 15% drop
     *         and activate the 8% tax on the next transfer. The 48h timelock
     *         prevents silent oracle substitution.
     */
    function updatePriceOracle(address _oracle)
        external
        onlyOwner
        timelocked(keccak256("updatePriceOracle"))
    {
        require(_oracle != address(0), "CueCoin: zero oracle");
        emit PriceOracleUpdated(priceOracle, _oracle);
        priceOracle = _oracle;
    }

    /**
     * @notice [V5-4] Update the Chainlink Keeper for LP depth pushes. TIMELOCKED 48 hours.
     *
     *         Rationale: LP depth controls whether the Velocity Shield can fire.
     *         A malicious LP oracle update could push a false 50+ BNB depth reading,
     *         enabling the shield to activate on the next price push.
     */
    function updateLPOracle(address _oracle)
        external
        onlyOwner
        timelocked(keccak256("updateLPOracle"))
    {
        require(_oracle != address(0), "CueCoin: zero oracle");
        emit LPOracleUpdated(lpOracle, _oracle);
        lpOracle = _oracle;
    }

    /**
     * @notice [V5-8] Cancel a queued timelocked operation before it executes.
     *         Use if a pool update or oracle update was queued by mistake, or if
     *         governance reverses the decision before the 48h window elapses.
     */
    function cancelTimelock(bytes32 operationId) external onlyOwner {
        require(timelockEta[operationId] > 0,   "CueCoin: not queued");
        require(!timelockExecuted[operationId], "CueCoin: already executed");
        delete timelockEta[operationId];
        emit TimelockCancelled(operationId);
    }

    /**
     * @notice Exclude or include an address from the Vortex Tax.
     *         Used for newly deployed ecosystem contracts (vesting, marketplace, etc.).
     */
    function setFeeExclusion(address account, bool excluded) external onlyOwner {
        _setFeeExclusion(account, excluded);
    }

    /**
     * @notice Exclude or include an address from the Whale Guard.
     *         Used for large-allocation contracts that must move tokens in bulk.
     */
    function setWhaleGuardExclusion(address account, bool excluded) external onlyOwner {
        _setWhaleExclusion(account, excluded);
    }

    // ── Internal exclusion helpers ──
    function _setFeeExclusion(address account, bool excluded) internal {
        isExcludedFromFee[account] = excluded;
        emit FeeExclusionUpdated(account, excluded);
    }

    function _setWhaleExclusion(address account, bool excluded) internal {
        isExcludedFromWhaleGuard[account] = excluded;
        emit WhaleGuardExclusionUpdated(account, excluded);
    }

    // ═══════════════════════════════════════════════════════════
    //  EMERGENCY FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Rescue BNB accidentally sent to this contract.
     *         Cannot remove BNB held for in-progress auto-LP swaps —
     *         only stranded/excess BNB beyond what auto-LP holds.
     */
    function rescueBNB(uint256 amount) external onlyOwner nonReentrant {
        require(amount <= address(this).balance, "CueCoin: insufficient BNB");
        (bool ok,) = payable(owner()).call{value: amount}("");
        require(ok, "CueCoin: BNB transfer failed");
    }

    /**
     * @notice [V5-6] Rescue ERC-20 tokens accidentally sent to this contract.
     *         CANNOT be used to rescue CUECOIN itself or LP tokens.
     *         Uses SafeERC20 — handles non-standard tokens that return false.
     */
    function rescueTokens(address token, uint256 amount) external onlyOwner {
        require(token != address(this), "CueCoin: cannot rescue own token");
        require(token != liquidityPair, "CueCoin: cannot rescue LP tokens");
        IERC20(token).safeTransfer(owner(), amount);
    }

    // ═══════════════════════════════════════════════════════════
    //  RECEIVE BNB  (required for auto-LP swap proceeds)
    // ═══════════════════════════════════════════════════════════

    receive() external payable {}
}
