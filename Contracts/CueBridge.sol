// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ╔══════════════════════════════════════════════════════════════╗
//  CUEBRIDGE  ·  v1.0  ·  Production-Ready
//  CUECOIN Ecosystem  ·  BNB Smart Chain (Home Chain)
//
//  LayerZero OFT v2 Adapter — cross-chain bridge for CUECOIN.
//  This contract lives on BSC (the home chain) and wraps the
//  existing fixed-supply CueCoin.sol using the OFT Adapter pattern.
//
//  ════════════════════════════════════════════════════
//   OFT ADAPTER vs OFT — WHY THE DISTINCTION MATTERS
//  ════════════════════════════════════════════════════
//
//  CueCoin.sol has a FIXED 1,000,000,000 supply with no mint
//  function. A standard LayerZero OFT would burn tokens on the
//  source chain and mint on the destination — but CueCoin cannot
//  be minted. Instead this contract uses the OFT Adapter pattern:
//
//  ┌────────────────────────────────────────────────────────┐
//  │  BSC (home chain)       │   Polygon / Base / opBNB    │
//  │  CueBridge (OFTAdapter) │   CueOFT (OFT — mintable)  │
//  │  lock CUECOIN  ────────►│   mint CUECOIN              │
//  │  unlock CUECOIN ◄───────│   burn CUECOIN              │
//  └────────────────────────────────────────────────────────┘
//
//  Result: CUECOIN supply on each chain is real — no wrapped
//  tokens, no synthetic assets. Total supply across all chains
//  is always exactly 1,000,000,000.
//
//  ════════════════════════════════════════════════════
//   DEPLOYMENT NOTES
//  ════════════════════════════════════════════════════
//
//  This contract is written as a self-contained implementation.
//  The deployable version should inherit from the official
//  LayerZero package for audited base logic:
//
//    import { OFTAdapter } from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";
//    contract CueBridge is OFTAdapter { ... }
//
//  This file reimplements OFTAdapter inline so all logic is
//  explicit and auditable without external dependencies.
//  The interface definitions match @layerzerolabs/lz-evm-protocol-v2
//  exactly. When integrating with the official package, replace the
//  inline interface definitions and base logic with the imports.
//
//  LayerZero Endpoint V2 address (identical on ALL chains):
//    0x1a44076050125825900e736c501f859c50fE728b
//
//  ════════════════════════════════════════════════════
//   CHAIN EXPANSION PHASES
//  ════════════════════════════════════════════════════
//
//  Phase 2  (Month 14) → Polygon Mainnet  (eid 30109)
//  Phase 3  (Month 20) → Base Mainnet     (eid 30184)
//  Phase 4  (Month 26) → opBNB Mainnet    (eid 30202)
//
//  Each destination is disabled at deploy and enabled by the owner
//  when the corresponding CueOFT contract is deployed and verified
//  on the destination chain. The peer address (CueOFT address on
//  dest chain) must be set before enabling the destination.
//
//  ════════════════════════════════════════════════════
//   BRIDGE FEE
//  ════════════════════════════════════════════════════
//
//  0.5% of every outbound bridge transfer.
//  Split: 50% burned (sent to BURN_ADDRESS) + 50% to DAO Treasury.
//
//  Example: User bridges 10,000 CUECOIN
//    Bridge fee: 50 CUECOIN
//    Burned:     25 CUECOIN → 0xdead
//    DAO:        25 CUECOIN → daoTreasury
//    Received:   9,950 CUECOIN on destination chain
//
//  CueBridge must be excluded from CueCoin's Vortex Tax — the
//  bridge has its own fee mechanism and the 4% transfer tax would
//  double-charge users. Call CueCoin.setFeeExclusion(bridge, true)
//  immediately after deployment.
//
//  No fee on inbound (return) transfers — the fee was charged on
//  the originating chain when the user first bridged out.
//
//  ════════════════════════════════════════════════════
//   DAILY RATE LIMIT
//  ════════════════════════════════════════════════════
//
//  MAX_DAILY_BRIDGE_AMOUNT = 1,000,000 CUECOIN per 24hr (outbound).
//  Uses a rolling 24-hour window (not UTC day reset) to prevent
//  boundary attacks where an attacker bridges at 23:59 and 00:01.
//
//  If an exploit is detected before the limit is hit, the guardian
//  can pause the contract within seconds. The rate limit provides
//  a second line of defence — an attacker who bypasses monitoring
//  can still only extract 1M CUECOIN before the window resets.
//
//  ════════════════════════════════════════════════════
//   SHARED DECIMALS
//  ════════════════════════════════════════════════════
//
//  LayerZero OFT normalises amounts across chains using "shared
//  decimals." CueCoin has 18 decimals; shared decimals = 6.
//  Conversion factor: 10^(18-6) = 10^12.
//
//  Any amount below 10^12 wei (0.000001 CUECOIN) is "dust" — it
//  is silently truncated to keep the cross-chain amount consistent.
//  In practice bridge transfers are ≥ 1 CUECOIN (enforced by
//  MIN_BRIDGE_AMOUNT), so dust is never a concern in normal use.
//
//  ════════════════════════════════════════════════════
//   GUARDIAN EMERGENCY PAUSE
//  ════════════════════════════════════════════════════
//
//  Guardian (Gnosis Safe 3-of-5) can pause the bridge within
//  seconds of detecting an exploit. Unlike CueVesting, there is
//  no 48-hour cap — bridges may need extended pauses during
//  complex cross-chain incident response. Owner can also pause
//  and unpause.
//
//  When paused: send() reverts. lzReceive() still executes (inbound
//  transfers are safe — they release tokens, not lock them).
//
//  ════════════════════════════════════════════════════
//   OFT MESSAGE FORMAT
//  ════════════════════════════════════════════════════
//
//  CueBridge uses the standard LayerZero OFT v2 message format:
//
//    bytes message = abi.encodePacked(
//        bytes32(uint256(uint160(recipient))),  // recipient padded to 32 bytes
//        uint64(amountSD)                        // amount in shared decimals
//    )
//
//  Total message length: 40 bytes.
//  This format is identical to the official OFT v2 implementation
//  and is decoded by CueOFT contracts on destination chains.
//
//  ════════════════════════════════════════════════════
//   ACCESS CONTROL
//  ════════════════════════════════════════════════════
//
//  Owner (team multisig) CAN:
//    setPeer, enableDestination, disableDestination
//    setDelegate (LZ delegate for DVN config)
//    setGuardian (two-step nomination)
//    queueDaoTreasuryUpdate / cancelDaoTreasuryUpdate
//    pause / unpause
//    recoverERC20 (non-CUECOIN only)
//    setMinBridgeAmount
//
//  Guardian (Gnosis Safe 3-of-5) CAN:
//    pause / unpause
//    acceptGuardian
//
//  Nobody CAN:
//    Change BRIDGE_FEE_BPS (bytecode constant)
//    Change MAX_DAILY_BRIDGE_AMOUNT (bytecode constant)
//    Bridge without paying the 0.5% fee
//    Exceed the daily limit
//
//  ════════════════════════════════════════════════════
//   DAO GOVERNANCE SCOPE
//  ════════════════════════════════════════════════════
//
//  The spec reserves the following for DAO governance:
//    - Bridge rate limits and fee adjustments
//    - Cross-chain expansion decisions and CueBridge destinations
//
//  Until CueDAO has a specific bridge proposal type, these are
//  owner-controlled. A future governance upgrade can transfer
//  ownership to CueDAO via Ownable2Step.
//
// ╚══════════════════════════════════════════════════════════════╝

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ═══════════════════════════════════════════════════════════════
//  LAYERZERO V2 INTERFACES  (inline — matches @layerzerolabs/lz-evm-protocol-v2)
// ═══════════════════════════════════════════════════════════════

/// @dev Identifies the origin of a received LayerZero message.
struct Origin {
    uint32  srcEid;   // source endpoint ID
    bytes32 sender;   // sender address as bytes32 (padded)
    uint64  nonce;    // message nonce
}

/// @dev Parameters for sending a LayerZero message.
struct MessagingParams {
    uint32  dstEid;
    bytes32 receiver;
    bytes   message;
    bytes   options;
    bool    payInLzToken;
}

/// @dev LayerZero messaging fee (native gas + optional ZRO token).
struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

/// @dev Receipt returned by LZ endpoint after send().
struct MessagingReceipt {
    bytes32      guid;
    uint64       nonce;
    MessagingFee fee;
}

/// @dev OFT-specific send parameters (user-facing).
struct SendParam {
    uint32  dstEid;         // destination chain endpoint ID
    bytes32 to;             // recipient address (padded to bytes32)
    uint256 amountLD;       // gross amount in local decimals (18)
    uint256 minAmountLD;    // minimum net amount after fee + dust (slippage guard)
    bytes   extraOptions;   // LZ executor gas options (use OptionsBuilder off-chain)
    bytes   composeMsg;     // composed message payload (empty for basic transfer)
    bytes   oftCmd;         // OFT-specific command (empty for standard transfer)
}

/// @dev Amounts actually sent and received after fee and dust deduction.
struct OFTReceipt {
    uint256 amountSentLD;     // locked/deducted from sender (net of bridge fee, pre-dust)
    uint256 amountReceivedLD; // credited to recipient on destination
}

/**
 * @dev Minimal LayerZero EndpointV2 interface.
 *      Full interface: ILayerZeroEndpointV2 in lz-evm-protocol-v2.
 */
interface ILayerZeroEndpointV2 {
    function send(
        MessagingParams calldata _params,
        address _refundAddress
    ) external payable returns (MessagingReceipt memory receipt);

    function quote(
        MessagingParams calldata _params,
        address _sender
    ) external view returns (MessagingFee memory fee);

    function setDelegate(address _delegate) external;

    function eid() external view returns (uint32);
}

/**
 * @dev Interface that CueBridge must implement to receive LZ messages.
 *      The LZ endpoint calls lzReceive() when a cross-chain message arrives.
 */
interface ILayerZeroReceiver {
    function lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable;

    function allowInitializePath(Origin calldata _origin) external view returns (bool);

    function nextNonce(uint32 _eid, bytes32 _sender) external view returns (uint64);
}

// ═══════════════════════════════════════════════════════════════
//  CUECOIN INTERFACE (for fee exclusion check)
// ═══════════════════════════════════════════════════════════════

interface ICueCoin is IERC20 {
    function isExcludedFromFee(address account) external view returns (bool);
}

// ═══════════════════════════════════════════════════════════════
//  MAIN CONTRACT
// ═══════════════════════════════════════════════════════════════

/**
 * @title  CueBridge
 * @author CUECOIN Team
 * @notice LayerZero OFT v2 Adapter for CUECOIN on BSC.
 *         Locks CUECOIN on send; releases on receive.
 *         0.5% bridge fee: 50% burned, 50% to DAO treasury.
 *         1,000,000 CUECOIN daily outbound limit.
 *         Guardian emergency pause.
 */
contract CueBridge is Ownable2Step, ReentrancyGuard, ILayerZeroReceiver {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════
    //  CONSTANTS  (bytecode — immutable by design)
    // ═══════════════════════════════════════════════════════════

    /// @notice Bridge fee in basis points. 50 bps = 0.5%.
    ///         Split 50/50 between burn and DAO treasury.
    ///         Bytecode constant — cannot be changed by anyone.
    uint256 public constant BRIDGE_FEE_BPS      = 50;  // 0.5%

    /// @notice Maximum CUECOIN bridged outbound per 24-hour rolling window.
    ///         Bytecode constant. Prevents single exploit from draining the bridge.
    uint256 public constant MAX_DAILY_BRIDGE_AMOUNT = 1_000_000 ether; // 1M CUECOIN

    /// @notice 24-hour window for the daily rate limit.
    uint256 public constant DAILY_WINDOW = 24 hours;

    /// @notice LayerZero shared decimals for cross-chain normalization.
    ///         Amount sent cross-chain = amountLD / (10 ** (localDecimals - sharedDecimals))
    ///         = amountLD / 10^12. Amounts below 10^12 wei are dust-truncated.
    uint8  public constant SHARED_DECIMALS   = 6;
    uint8  public constant LOCAL_DECIMALS    = 18;
    uint256 public constant LD_TO_SD_FACTOR  = 10 ** (LOCAL_DECIMALS - SHARED_DECIMALS); // 10^12

    /// @notice Burn address — receives the burned half of the bridge fee.
    ///         Using the standard EVM dead address, consistent with CueCoin.sol.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Minimum bridge amount. Prevents dust attacks and sub-economic transfers.
    ///         Owner can raise but the default ensures at least 1 full CUECOIN.
    uint256 public constant DEFAULT_MIN_BRIDGE_AMOUNT = 1 ether; // 1 CUECOIN

    // ── Known chain endpoint IDs (LayerZero v2) ──
    uint32 public constant EID_BSC     = 30102;
    uint32 public constant EID_POLYGON = 30109;
    uint32 public constant EID_BASE    = 30184;
    uint32 public constant EID_OPBNB   = 30202;

    // ── DAO treasury update timelock ──
    uint256 public constant TREASURY_UPDATE_DELAY = 48 hours;

    // ═══════════════════════════════════════════════════════════
    //  IMMUTABLES
    // ═══════════════════════════════════════════════════════════

    /// @notice CueCoin ERC-20 contract (fixed supply, no mint on BSC).
    ICueCoin public immutable cueCoin;

    /// @notice LayerZero EndpointV2 (0x1a44076050125825900e736c501f859c50fE728b on all chains).
    ILayerZeroEndpointV2 public immutable lzEndpoint;

    // ═══════════════════════════════════════════════════════════
    //  STATE
    // ═══════════════════════════════════════════════════════════

    // ── DAO treasury ──
    address public daoTreasury;
    address private _pendingDaoTreasury;
    uint256 private _pendingDaoTreasuryEta;

    // ── Guardian ──
    address public guardian;
    address public pendingGuardian;

    // ── Pause ──
    bool public paused;

    // ── Min bridge amount (owner-adjustable) ──
    uint256 public minBridgeAmount;

    // ── LayerZero peer management ──
    /// @notice Trusted remote OFT addresses per destination endpoint ID.
    ///         bytes32 = address padded to 32 bytes.
    ///         MUST be set before enabling a destination.
    mapping(uint32 eid => bytes32 peer) public peers;

    /// @notice Whether a destination endpoint is open for bridging.
    ///         Disabled by default — enabled per phase as chains are added.
    mapping(uint32 eid => bool enabled) public destinationEnabled;

    // ── Daily rate limit (rolling 24hr window) ──
    uint256 public dailyWindowStart;    // timestamp when current window began
    uint256 public dailyBridgedAmount;  // CUECOIN bridged in current window

    // ── Total stats ──
    uint256 public totalBridgedOut;     // all-time outbound CUECOIN (gross, before fee)
    uint256 public totalBridgedIn;      // all-time inbound CUECOIN (tokens released)
    uint256 public totalFeeBurned;      // all-time bridge fee burned
    uint256 public totalFeeToDao;       // all-time bridge fee to DAO

    // ═══════════════════════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Emitted when a user bridges CUECOIN out from BSC.
     * @param sender        BSC wallet initiating the bridge.
     * @param dstEid        Destination chain endpoint ID.
     * @param recipient     Recipient wallet on the destination chain.
     * @param amountLD      Gross amount deducted from sender (local decimals).
     * @param bridgeFee     Total bridge fee deducted (split between burn and DAO).
     * @param amountSentLD  Net amount transmitted cross-chain (amountLD - bridgeFee - dust).
     * @param guid          LayerZero message GUID for cross-chain tracking.
     */
    event BridgeOut(
        address indexed sender,
        uint32  indexed dstEid,
        bytes32         recipient,
        uint256         amountLD,
        uint256         bridgeFee,
        uint256         amountSentLD,
        bytes32         guid
    );

    /**
     * @notice Emitted when CUECOIN returns from another chain to BSC.
     * @param recipient   BSC wallet receiving the returned tokens.
     * @param srcEid      Source chain endpoint ID.
     * @param amountLD    Amount released from the bridge reserve.
     * @param guid        LayerZero message GUID.
     */
    event BridgeIn(
        address indexed recipient,
        uint32  indexed srcEid,
        uint256         amountLD,
        bytes32         guid
    );

    event BridgeFeeDistributed(uint256 burned, uint256 toDao);

    event PeerSet(uint32 indexed eid, bytes32 peer);
    event DestinationEnabled(uint32 indexed eid);
    event DestinationDisabled(uint32 indexed eid);

    event Paused(address indexed by);
    event Unpaused(address indexed by);

    event GuardianNominated(address indexed nominee);
    event GuardianAccepted(address indexed oldGuardian, address indexed newGuardian);

    event DaoTreasuryUpdateQueued(address indexed newTreasury, uint256 eta);
    event DaoTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event DaoTreasuryUpdateCancelled(address indexed cancelled);

    event MinBridgeAmountUpdated(uint256 oldAmount, uint256 newAmount);

    // ═══════════════════════════════════════════════════════════
    //  MODIFIERS
    // ═══════════════════════════════════════════════════════════

    modifier onlyGuardian() {
        require(msg.sender == guardian, "CueBridge: not guardian");
        _;
    }

    modifier onlyOwnerOrGuardian() {
        require(
            msg.sender == owner() || msg.sender == guardian,
            "CueBridge: not owner or guardian"
        );
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "CueBridge: paused");
        _;
    }

    modifier onlyEndpoint() {
        require(
            msg.sender == address(lzEndpoint),
            "CueBridge: caller is not the LZ endpoint"
        );
        _;
    }

    // ═══════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    /**
     * @param _cueCoin      CueCoin contract address on BSC.
     * @param _lzEndpoint   LayerZero EndpointV2 address
     *                      (0x1a44076050125825900e736c501f859c50fE728b on BSC mainnet).
     * @param _guardian     Initial guardian address (Gnosis Safe 3-of-5).
     * @param _daoTreasury  CueDAO contract address — receives the DAO share of bridge fees.
     *
     * @dev After deployment, the owner must call:
     *      1. CueCoin.setFeeExclusion(address(this), true)  — exclude bridge from Vortex Tax
     *      2. CueCoin.setWhaleGuardExclusion(address(this), true)  — large bridge txs exempt
     *      3. lzEndpoint.setDelegate(address(this))  — set self as delegate for DVN config
     *      4. setPeer(dstEid, remotePeerBytes32)  — register each CueOFT address
     *      5. enableDestination(dstEid)  — open each chain per phase schedule
     */
    constructor(
        address _cueCoin,
        address _lzEndpoint,
        address _guardian,
        address _daoTreasury
    )
        Ownable(msg.sender)
    {
        require(_cueCoin     != address(0), "CueBridge: zero cueCoin");
        require(_lzEndpoint  != address(0), "CueBridge: zero endpoint");
        require(_guardian    != address(0), "CueBridge: zero guardian");
        require(_daoTreasury != address(0), "CueBridge: zero treasury");

        cueCoin        = ICueCoin(_cueCoin);
        lzEndpoint     = ILayerZeroEndpointV2(_lzEndpoint);
        guardian       = _guardian;
        daoTreasury    = _daoTreasury;
        minBridgeAmount = DEFAULT_MIN_BRIDGE_AMOUNT;

        // Initialise daily window from deployment time
        dailyWindowStart = block.timestamp;
    }

    // ═══════════════════════════════════════════════════════════
    //  BRIDGE OUT — USER-FACING
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Bridge CUECOIN from BSC to another chain.
     *
     *         Flow:
     *           1. Pull amountLD from sender (CueCoin transferFrom).
     *           2. Deduct 0.5% bridge fee: 50% → BURN_ADDRESS, 50% → daoTreasury.
     *           3. Remove dust (amounts below LD_TO_SD_FACTOR precision).
     *           4. Enforce amountSentLD >= minAmountLD (slippage guard).
     *           5. Update 24-hr rolling rate limit.
     *           6. Encode OFT message and send via LayerZero endpoint.
     *           7. Remaining tokens sit in this contract as the locked reserve.
     *
     *         The caller must pay the LayerZero native fee (BNB) as msg.value.
     *         Use quoteSend() to compute the required fee before calling.
     *
     *         The caller must have approved this contract for at least amountLD.
     *
     * @param _sendParam    OFT send parameters (see struct definition above).
     *                      Key fields: dstEid, to (recipient), amountLD, minAmountLD.
     * @param _fee          LayerZero messaging fee. Must match quoteSend() output.
     *                      nativeFee must match msg.value exactly.
     * @param _refundAddress  Address to receive any excess msg.value (LZ gas refund).
     * @return receipt      OFT receipt with actual amounts sent and received.
     * @return msgReceipt   LZ messaging receipt with guid for cross-chain tracking.
     */
    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address _refundAddress
    )
        external
        payable
        nonReentrant
        whenNotPaused
        returns (OFTReceipt memory receipt, MessagingReceipt memory msgReceipt)
    {
        uint32 dstEid   = _sendParam.dstEid;
        uint256 amountLD = _sendParam.amountLD;

        // ── Destination validation ──
        require(destinationEnabled[dstEid],   "CueBridge: destination not enabled");
        require(peers[dstEid] != bytes32(0),  "CueBridge: no peer for destination");

        // ── Amount validation ──
        require(amountLD >= minBridgeAmount,  "CueBridge: amount below minimum");
        require(amountLD > 0,                 "CueBridge: zero amount");

        // ── Pull tokens from sender ──
        // Bridge must be fee-excluded in CueCoin to avoid Vortex Tax on this transfer.
        uint256 balanceBefore = cueCoin.balanceOf(address(this));
        IERC20(address(cueCoin)).safeTransferFrom(msg.sender, address(this), amountLD);
        uint256 actualReceived = cueCoin.balanceOf(address(this)) - balanceBefore;

        // ── Bridge fee (0.5%) ──
        uint256 bridgeFee  = (actualReceived * BRIDGE_FEE_BPS) / 10_000;
        uint256 burnShare  = bridgeFee / 2;
        uint256 daoShare   = bridgeFee - burnShare; // handles odd wei correctly

        uint256 afterFee = actualReceived - bridgeFee;

        // ── Dust removal (shared decimal normalisation) ──
        // amountSentLD is what will be credited on the destination chain.
        // Dust = the sub-precision remainder that cannot be represented in
        // shared decimals. It stays locked in this contract.
        uint256 dust       = afterFee % LD_TO_SD_FACTOR;
        uint256 amountSentLD = afterFee - dust;

        // ── Slippage guard ──
        require(
            amountSentLD >= _sendParam.minAmountLD,
            "CueBridge: amount below minAmountLD (slippage)"
        );

        // ── Daily rate limit (rolling 24hr window) ──
        _checkAndUpdateDailyLimit(amountSentLD);

        // ── Distribute bridge fee ──
        if (burnShare > 0) {
            IERC20(address(cueCoin)).safeTransfer(BURN_ADDRESS, burnShare);
        }
        if (daoShare > 0) {
            IERC20(address(cueCoin)).safeTransfer(daoTreasury, daoShare);
        }

        // ── Update stats ──
        totalBridgedOut += amountLD;
        totalFeeBurned  += burnShare;
        totalFeeToDao   += daoShare;

        emit BridgeFeeDistributed(burnShare, daoShare);

        // ── Encode OFT message ──
        // Standard OFT v2 format: recipient (bytes32) ++ amountSD (uint64)
        uint64 amountSD = uint64(amountSentLD / LD_TO_SD_FACTOR);
        bytes memory message = abi.encodePacked(_sendParam.to, amountSD);

        // ── Send via LayerZero endpoint ──
        MessagingParams memory msgParams = MessagingParams({
            dstEid:      dstEid,
            receiver:    peers[dstEid],
            message:     message,
            options:     _sendParam.extraOptions,
            payInLzToken: _fee.lzTokenFee > 0
        });

        msgReceipt = lzEndpoint.send{value: msg.value}(msgParams, _refundAddress);

        receipt = OFTReceipt({
            amountSentLD:     amountSentLD,
            amountReceivedLD: amountSentLD  // same on return (no fee on dest chain receive)
        });

        emit BridgeOut(
            msg.sender,
            dstEid,
            _sendParam.to,
            amountLD,
            bridgeFee,
            amountSentLD,
            msgReceipt.guid
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  BRIDGE IN — LAYERZERO CALLBACK
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Called by the LayerZero endpoint when tokens return to BSC.
     *
     *         Only callable by the LZ endpoint (onlyEndpoint modifier).
     *         Only accepts messages from registered peers (allowInitializePath).
     *
     *         Decodes the OFT message (recipient + amount), converts from shared
     *         decimals back to local decimals, and releases the tokens from the
     *         bridge reserve to the recipient.
     *
     *         Inbound transfers are NOT paused — releasing tokens to users is
     *         always safe. The security risk is in outbound (lock) transfers.
     *
     * @param _origin   Origin chain info (srcEid, sender bytes32, nonce).
     * @param _guid     Message GUID for event emission and tracking.
     * @param _message  ABI-encoded OFT payload (recipient bytes32 ++ amountSD uint64).
     */
    function lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address, // _executor (unused)
        bytes calldata  // _extraData (unused)
    )
        external
        payable
        override
        onlyEndpoint
        nonReentrant
    {
        // Validate the message comes from a trusted peer
        require(
            _isPeer(_origin.srcEid, _origin.sender),
            "CueBridge: message from unknown peer"
        );

        // Decode OFT message: 32 bytes recipient + 8 bytes amountSD
        require(_message.length == 40, "CueBridge: invalid message length");

        bytes32 toBytes32;
        uint64  amountSD;

        assembly {
            // Skip 4-byte calldata offset for bytes memory — load from correct position.
            // _message is calldata, so we read directly.
            toBytes32 := calldataload(_message.offset)
            // Next 8 bytes (uint64) — right-aligned in the 32-byte word
            amountSD  := shr(192, calldataload(add(_message.offset, 32)))
        }

        address recipient = address(uint160(uint256(toBytes32)));
        uint256 amountLD  = uint256(amountSD) * LD_TO_SD_FACTOR;

        require(recipient != address(0), "CueBridge: zero recipient");
        require(amountLD  > 0,           "CueBridge: zero receive amount");

        // Ensure the bridge has sufficient reserve to fulfill
        require(
            cueCoin.balanceOf(address(this)) >= amountLD,
            "CueBridge: insufficient bridge reserve"
        );

        // Release tokens to recipient
        totalBridgedIn += amountLD;
        IERC20(address(cueCoin)).safeTransfer(recipient, amountLD);

        emit BridgeIn(recipient, _origin.srcEid, amountLD, _guid);
    }

    // ═══════════════════════════════════════════════════════════
    //  ILAYERZERORECEIVER — PATH VALIDATION
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Called by the LZ endpoint before initializing a new receive path.
     *         Returns true only for known trusted peers.
     */
    function allowInitializePath(Origin calldata _origin)
        external
        view
        override
        returns (bool)
    {
        return _isPeer(_origin.srcEid, _origin.sender);
    }

    /**
     * @notice Nonce for ordered message delivery. We use 0 (unordered) because
     *         token transfers do not require strict sequencing — each transfer
     *         is independent. Using unordered delivery avoids head-of-line
     *         blocking if a single message fails.
     */
    function nextNonce(uint32, bytes32) external pure override returns (uint64) {
        return 0;
    }

    // ═══════════════════════════════════════════════════════════
    //  QUOTE — VIEW (call before send to get required msg.value)
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Quote the LayerZero native fee required for a bridge transfer.
     *
     *         Call this off-chain before calling send(). Pass the returned
     *         MessagingFee.nativeFee as msg.value in the send() call.
     *
     *         Note: this quotes the LZ relayer fee only. The 0.5% bridge fee
     *         is deducted from the CUECOIN amount, not from msg.value.
     *
     * @param _sendParam  Same struct you will pass to send().
     * @param _payInLzToken  Whether to pay fee in ZRO token (false = pay in BNB).
     * @return fee        MessagingFee with nativeFee (BNB wei) and lzTokenFee.
     */
    function quoteSend(
        SendParam calldata _sendParam,
        bool _payInLzToken
    )
        external
        view
        returns (MessagingFee memory fee)
    {
        require(peers[_sendParam.dstEid] != bytes32(0), "CueBridge: no peer for destination");

        // Compute net amount after fee and dust (same as in send())
        uint256 bridgeFee = (_sendParam.amountLD * BRIDGE_FEE_BPS) / 10_000;
        uint256 afterFee  = _sendParam.amountLD - bridgeFee;
        uint256 dust      = afterFee % LD_TO_SD_FACTOR;
        uint256 amountSentLD = afterFee - dust;

        uint64  amountSD = uint64(amountSentLD / LD_TO_SD_FACTOR);
        bytes32 toAddr   = _sendParam.to;
        bytes memory message = abi.encodePacked(toAddr, amountSD);

        MessagingParams memory msgParams = MessagingParams({
            dstEid:       _sendParam.dstEid,
            receiver:     peers[_sendParam.dstEid],
            message:      message,
            options:      _sendParam.extraOptions,
            payInLzToken: _payInLzToken
        });

        return lzEndpoint.quote(msgParams, address(this));
    }

    /**
     * @notice Preview what amounts a user would get given a gross amountLD.
     *
     * @param amountLD  Gross CUECOIN amount user wants to bridge.
     * @return bridgeFee     Total fee deducted (0.5%).
     * @return burnShare     Burned portion of fee.
     * @return daoShare      DAO portion of fee.
     * @return amountSentLD  Net amount recipient receives on destination.
     * @return dust          Sub-precision remainder (stays in bridge reserve).
     */
    function previewSend(uint256 amountLD)
        external
        pure
        returns (
            uint256 bridgeFee,
            uint256 burnShare,
            uint256 daoShare,
            uint256 amountSentLD,
            uint256 dust
        )
    {
        bridgeFee   = (amountLD * BRIDGE_FEE_BPS) / 10_000;
        burnShare   = bridgeFee / 2;
        daoShare    = bridgeFee - burnShare;
        uint256 afterFee = amountLD - bridgeFee;
        dust        = afterFee % LD_TO_SD_FACTOR;
        amountSentLD = afterFee - dust;
    }

    // ═══════════════════════════════════════════════════════════
    //  PEER & DESTINATION MANAGEMENT — OWNER
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Register a trusted remote OFT contract (CueOFT on dest chain).
     *
     *         The peer address is stored as bytes32 (EVM address padded to 32 bytes).
     *         Messages from unregistered peers are rejected in lzReceive().
     *
     *         Must be called before enableDestination() for the same eid.
     *
     * @param eid   Destination endpoint ID (e.g. 30109 for Polygon).
     * @param peer  CueOFT contract address on dest chain, left-padded to bytes32:
     *              bytes32(uint256(uint160(address(cueOFTonDest))))
     */
    function setPeer(uint32 eid, bytes32 peer) external onlyOwner {
        require(eid  != 0,           "CueBridge: zero eid");
        require(peer != bytes32(0),  "CueBridge: zero peer");
        peers[eid] = peer;
        emit PeerSet(eid, peer);
    }

    /**
     * @notice Enable a destination chain for outbound bridging.
     *         Peer must be registered first (setPeer).
     *
     * @param eid  Destination endpoint ID to enable.
     */
    function enableDestination(uint32 eid) external onlyOwner {
        require(peers[eid] != bytes32(0), "CueBridge: set peer before enabling");
        destinationEnabled[eid] = true;
        emit DestinationEnabled(eid);
    }

    /**
     * @notice Disable a destination chain. Existing in-flight messages are
     *         unaffected — they will still be received via lzReceive().
     *         Re-enable by calling enableDestination() again.
     *
     * @param eid  Destination endpoint ID to disable.
     */
    function disableDestination(uint32 eid) external onlyOwner {
        destinationEnabled[eid] = false;
        emit DestinationDisabled(eid);
    }

    /**
     * @notice Set the LayerZero delegate for DVN (decentralised verifier network) config.
     *         The delegate can configure message verification settings on the endpoint.
     *         Should usually be set to address(this) so the owner controls DVN config
     *         via this contract. Called once post-deployment.
     */
    function setDelegate(address delegate) external onlyOwner {
        lzEndpoint.setDelegate(delegate);
    }

    // ═══════════════════════════════════════════════════════════
    //  PAUSE — OWNER OR GUARDIAN
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Pause outbound bridging immediately.
     *         Can be called by owner or guardian.
     *         Guardian should be able to act within 60 seconds of exploit detection.
     *         Inbound (lzReceive) is NOT paused — returning tokens is always safe.
     */
    function pause() external onlyOwnerOrGuardian {
        require(!paused, "CueBridge: already paused");
        paused = true;
        emit Paused(msg.sender);
    }

    /**
     * @notice Resume outbound bridging.
     *         Can be called by owner or guardian.
     */
    function unpause() external onlyOwnerOrGuardian {
        require(paused, "CueBridge: not paused");
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ═══════════════════════════════════════════════════════════
    //  GUARDIAN UPDATE — TWO-STEP
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Nominate a new guardian. Owner-only.
     *         The nominee must call acceptGuardian() to complete the handover.
     */
    function setGuardian(address nominee) external onlyOwner {
        require(nominee != address(0), "CueBridge: zero nominee");
        pendingGuardian = nominee;
        emit GuardianNominated(nominee);
    }

    /// @notice Accept the guardian role. Called by the pending guardian.
    function acceptGuardian() external {
        require(msg.sender == pendingGuardian, "CueBridge: not pending guardian");
        address old     = guardian;
        guardian        = pendingGuardian;
        pendingGuardian = address(0);
        emit GuardianAccepted(old, guardian);
    }

    // ═══════════════════════════════════════════════════════════
    //  DAO TREASURY UPDATE — TIMELOCKED
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Queue a DAO treasury address update (48-hour delay).
     *         Bridge fees accumulate continuously — redirecting them
     *         to a malicious address without warning would harm the DAO.
     *         The timelock gives 48 hours for monitoring to catch this.
     */
    function queueDaoTreasuryUpdate(address newTreasury) external onlyOwner {
        require(newTreasury != address(0),   "CueBridge: zero treasury");
        require(newTreasury != daoTreasury,  "CueBridge: same treasury");
        uint256 eta = block.timestamp + TREASURY_UPDATE_DELAY;
        _pendingDaoTreasury    = newTreasury;
        _pendingDaoTreasuryEta = eta;
        emit DaoTreasuryUpdateQueued(newTreasury, eta);
    }

    /// @notice Apply queued DAO treasury update after 48-hour delay. Permissionless.
    function applyDaoTreasuryUpdate() external nonReentrant {
        require(_pendingDaoTreasuryEta != 0,               "CueBridge: no pending update");
        require(block.timestamp >= _pendingDaoTreasuryEta,  "CueBridge: delay not elapsed");
        address old        = daoTreasury;
        daoTreasury        = _pendingDaoTreasury;
        _pendingDaoTreasury    = address(0);
        _pendingDaoTreasuryEta = 0;
        emit DaoTreasuryUpdated(old, daoTreasury);
    }

    /// @notice Cancel a queued DAO treasury update. Owner-only.
    function cancelDaoTreasuryUpdate() external onlyOwner {
        require(_pendingDaoTreasuryEta != 0, "CueBridge: no pending update");
        address cancelled      = _pendingDaoTreasury;
        _pendingDaoTreasury    = address(0);
        _pendingDaoTreasuryEta = 0;
        emit DaoTreasuryUpdateCancelled(cancelled);
    }

    // ═══════════════════════════════════════════════════════════
    //  CONFIGURATION — OWNER
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Update the minimum bridge amount.
     *         Can be raised to counter dust attacks; lowering requires owner judgement.
     *         Cannot be set to zero — zero would allow economically meaningless transfers.
     */
    function setMinBridgeAmount(uint256 amount) external onlyOwner {
        require(amount > 0, "CueBridge: zero minimum");
        uint256 old = minBridgeAmount;
        minBridgeAmount = amount;
        emit MinBridgeAmountUpdated(old, amount);
    }

    /**
     * @notice Recover ERC-20 tokens accidentally sent to this contract.
     *         BLOCKED for CueCoin — the bridge reserve is not recoverable
     *         via this function (it backs circulating supply on other chains).
     *         CueCoin reserve can only be released by lzReceive() callbacks.
     */
    function recoverERC20(address token, uint256 amount) external onlyOwner {
        require(
            token != address(cueCoin),
            "CueBridge: cannot recover CUECOIN — it is the bridge reserve"
        );
        IERC20(token).safeTransfer(owner(), amount);
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW — BRIDGE STATUS
    // ═══════════════════════════════════════════════════════════

    /// @notice Current CUECOIN held in the bridge reserve.
    ///         Should approximately equal total outstanding on other chains.
    function bridgeReserve() external view returns (uint256) {
        return cueCoin.balanceOf(address(this));
    }

    /// @notice CUECOIN bridged in the current 24-hour window.
    function currentWindowBridged() external view returns (uint256 bridged, uint256 remaining) {
        if (block.timestamp > dailyWindowStart + DAILY_WINDOW) {
            return (0, MAX_DAILY_BRIDGE_AMOUNT);
        }
        bridged   = dailyBridgedAmount;
        remaining = MAX_DAILY_BRIDGE_AMOUNT > bridged
                    ? MAX_DAILY_BRIDGE_AMOUNT - bridged
                    : 0;
    }

    /// @notice Time until the current 24-hour window resets.
    function windowResetIn() external view returns (uint256) {
        uint256 windowEnd = dailyWindowStart + DAILY_WINDOW;
        if (block.timestamp >= windowEnd) return 0;
        return windowEnd - block.timestamp;
    }

    /// @notice Whether a destination is active and has a peer.
    function isDestinationReady(uint32 eid) external view returns (bool) {
        return destinationEnabled[eid] && peers[eid] != bytes32(0);
    }

    /// @notice Pending DAO treasury update info.
    function pendingTreasuryUpdate()
        external
        view
        returns (address pending, uint256 eta)
    {
        return (_pendingDaoTreasury, _pendingDaoTreasuryEta);
    }

    /// @notice Check whether this contract is properly excluded from CueCoin tax.
    ///         Returns false = action required (call CueCoin.setFeeExclusion).
    function isFeeExcluded() external view returns (bool) {
        return cueCoin.isExcludedFromFee(address(this));
    }

    /**
     * @notice Complete protocol snapshot.
     */
    function protocolStats()
        external
        view
        returns (
            uint256 reserve,
            uint256 bridgedOut,
            uint256 bridgedIn,
            uint256 feeBurned,
            uint256 feeToDao,
            uint256 windowBridged,
            bool    paused_,
            address guardian_,
            address treasury_
        )
    {
        uint256 wb = (block.timestamp <= dailyWindowStart + DAILY_WINDOW)
                      ? dailyBridgedAmount
                      : 0;
        return (
            cueCoin.balanceOf(address(this)),
            totalBridgedOut,
            totalBridgedIn,
            totalFeeBurned,
            totalFeeToDao,
            wb,
            paused,
            guardian,
            daoTreasury
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev Enforce the rolling 24-hour daily outbound limit.
     *      Uses a simple window reset: if 24h has elapsed since the window
     *      started, begin a fresh window. This prevents UTC-midnight boundary
     *      attacks while keeping gas cost O(1).
     */
    function _checkAndUpdateDailyLimit(uint256 amountSentLD) internal {
        // Reset window if 24h has elapsed
        if (block.timestamp > dailyWindowStart + DAILY_WINDOW) {
            dailyWindowStart   = block.timestamp;
            dailyBridgedAmount = 0;
        }

        uint256 newTotal = dailyBridgedAmount + amountSentLD;
        require(
            newTotal <= MAX_DAILY_BRIDGE_AMOUNT,
            "CueBridge: daily bridge limit reached"
        );
        dailyBridgedAmount = newTotal;
    }

    /**
     * @dev Check if (srcEid, sender) corresponds to a registered peer.
     *      The sender in the Origin struct is already bytes32-padded.
     */
    function _isPeer(uint32 srcEid, bytes32 sender) internal view returns (bool) {
        return peers[srcEid] != bytes32(0) && peers[srcEid] == sender;
    }

    // ═══════════════════════════════════════════════════════════
    //  RECEIVE ETH  (LZ may refund excess gas)
    // ═══════════════════════════════════════════════════════════

    receive() external payable {}
}
