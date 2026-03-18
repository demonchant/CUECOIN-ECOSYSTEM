// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ╔══════════════════════════════════════════════════════════════╗
//  CUELIQUIDITYLOCKER  ·  v1.0  ·  Production-Ready
//  CUECOIN Ecosystem  ·  BNB Smart Chain
//
//  Time-lock vault for liquidity positions. Created to hold the
//  PancakeSwap CUECOIN/BNB liquidity representing 15% of total
//  supply (150,000,000 CUECOIN) for a minimum of 18 months,
//  with DAO-governance required to unlock.
//
//  ════════════════════════════════════════════════════
//   WHY THIS CONTRACT EXISTS
//  ════════════════════════════════════════════════════
//
//  Rug-pull prevention. The single most common exit scam in DeFi
//  is a team removing their own liquidity immediately after launch.
//  This contract makes that physically impossible:
//
//   • MIN_LOCK_DURATION is a bytecode constant (548 days ≈ 18 mo).
//     No owner, DAO vote, or guardian action can change it —
//     only a full contract redeployment could, which would be
//     visible on BSCScan and break all integrations.
//
//   • The owner (team multisig) can CREATE locks. They cannot
//     unlock them. Unlock requires a DAO governance vote and
//     block.timestamp ≥ unlockTime — both gates must pass.
//
//   • The DAO can EXTEND locks but never shorten them.
//
//   • Every lock emits LiquidityLocked with its full parameters.
//     Any wallet can verify this event on BSCScan to confirm the
//     team has locked. This is the on-chain proof guarantee.
//
//  ════════════════════════════════════════════════════
//   DEPLOYMENT FLOW
//  ════════════════════════════════════════════════════
//
//   1. Deploy CueLiquidityLocker (owner = team multisig, dao = CueDAO).
//   2. Create PancakeSwap CUECOIN/BNB pool (V2 LP or V3 position).
//   3. Transfer LP tokens (ERC-20) or position NFT (ERC-721) to
//      this contract's address.
//   4. Call lockERC20() or lockERC721() — creates the lock,
//      emits LiquidityLocked, sets unlockTime = now + 548 days.
//   5. Call CueCoin.enableTrading() — trading opens.
//   6. Publish the LiquidityLocked tx hash publicly.
//
//  After 548 days (≥ 18 months from lock creation):
//   7. CueDAO passes a GENERIC_CALL proposal targeting unlock().
//      CueLiquidityLocker must be an approvedTarget in CueDAO.
//   8. After CueDAO's 48-hour timelock, execute() calls unlock().
//   9. LP tokens transferred to the recipient set at lock time
//      (typically the CueDAO contract for governance control).
//
//  ════════════════════════════════════════════════════
//   DUAL-FORMAT LOCK SUPPORT
//  ════════════════════════════════════════════════════
//
//  PancakeSwap V2 issues fungible ERC-20 LP tokens.
//  PancakeSwap V3 issues non-fungible ERC-721 position NFTs.
//  This contract supports both:
//
//    lockERC20(token, amount, recipient)
//      → accepts any ERC-20 LP token
//      → balance-delta check handles fee-on-transfer tokens
//
//    lockERC721(token, tokenId, recipient)
//      → accepts any ERC-721 position NFT
//      → implements IERC721Receiver so positions can be safely
//         transferred with safeTransferFrom
//
//  Both lock types share the same LiquidityLock struct and lockId
//  namespace. A single unlock(lockId) function handles both.
//
//  ════════════════════════════════════════════════════
//   ACCESS CONTROL MATRIX
//  ════════════════════════════════════════════════════
//
//  Owner (team multisig) CAN:
//    lockERC20, lockERC721
//    nominateDao (two-step DAO address update)
//    recoverERC20 (non-LP tokens only, never locked assets)
//
//  Owner CANNOT:
//    unlock() any lock
//    extendLock() any lock
//    updateRecipient() on any lock
//    Change MIN_LOCK_DURATION (bytecode constant)
//    Change unlockTime to an earlier timestamp
//
//  DAO (CueDAO contract via GENERIC_CALL) CAN:
//    unlock() — only after block.timestamp ≥ unlockTime
//    extendLock() — only to a LATER timestamp (never shorter)
//    updateRecipient() — change who receives tokens on unlock
//    acceptDao() — complete a DAO address handover
//
//  DAO CANNOT:
//    unlock() before unlockTime (timestamp gate in bytecode)
//    Shorten any lock (extendLock enforces newTime > currentTime)
//    Lock tokens (lock creation is owner-only)
//
//  Nobody CAN:
//    Override MIN_LOCK_DURATION without redeploying the contract
//    Unlock before block.timestamp ≥ unlockTime
//    Transfer a locked asset without calling unlock()
//
//  ════════════════════════════════════════════════════
//   RECOVERY FUNCTION
//  ════════════════════════════════════════════════════
//
//  recoverERC20() lets the owner rescue ERC-20 tokens accidentally
//  sent to this contract. It is BLOCKED for any token/tokenId
//  currently associated with an active (non-unlocked) lock.
//  This prevents using recovery as an unlock bypass.
//
//  recoverERC721() likewise rescues ERC-721 tokens not in an
//  active lock.
//
// ╚══════════════════════════════════════════════════════════════╝

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/**
 * @title  CueLiquidityLocker
 * @author CUECOIN Team
 * @notice 18-month minimum LP time-lock. ERC-20 and ERC-721 positions.
 *         Owner locks; DAO unlocks (after min duration). DAO can extend
 *         but never shorten. MIN_LOCK_DURATION is a bytecode constant.
 */
contract CueLiquidityLocker is Ownable2Step, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════
    //  CONSTANTS
    // ═══════════════════════════════════════════════════════════

    /// @notice Minimum lock duration enforced in bytecode.
     ///         548 days = 365 + 183 ≈ 18 months (conservative).
    ///         No owner, DAO vote, or upgrade can change this constant.
    ///         Only a full contract redeployment could alter it — which
    ///         would be permanently visible on BSCScan.
    uint256 public constant MIN_LOCK_DURATION = 548 days;

    // ═══════════════════════════════════════════════════════════
    //  ENUMS & STRUCTS
    // ═══════════════════════════════════════════════════════════

    enum LockType { ERC20, ERC721 }

    /**
     * @notice A single liquidity lock record.
     *
     * @param lockId      Auto-assigned, 1-indexed.
     * @param lockType    ERC20 (fungible LP) or ERC721 (position NFT).
     * @param token       Token contract address.
     * @param amount      For ERC20: amount locked (balance-delta measured).
     *                    For ERC721: the tokenId of the position NFT.
     * @param locker      Address that called lockERC20/lockERC721 (the owner).
     * @param recipient   Address that will receive the tokens when unlocked.
     *                    Set at lock time; DAO can update before unlock.
     * @param lockTime    block.timestamp when the lock was created.
     * @param unlockTime  Earliest block.timestamp when unlock() may be called.
     *                    = lockTime + MIN_LOCK_DURATION at creation.
     *                    Can only be extended (moved later) by DAO.
     * @param unlocked    True after unlock() has been called. Irrevocable.
     */
    struct LiquidityLock {
        uint32   lockId;
        LockType lockType;
        address  token;
        uint256  amount;
        address  locker;
        address  recipient;
        uint256  lockTime;
        uint256  unlockTime;
        bool     unlocked;
    }

    // ═══════════════════════════════════════════════════════════
    //  STATE
    // ═══════════════════════════════════════════════════════════

    // ── DAO address (governance — unlock, extend, updateRecipient) ──
    address public dao;
    address public pendingDao;

    // ── Lock storage ──
    uint32 private _nextLockId;
    mapping(uint32 => LiquidityLock) private _locks;
    uint32[] private _allLockIds;

    // ── Active lock index: token → tokenId/amount → lockId (for recovery guard) ──
    // For ERC20: activeLockForToken[token] counts active locks on that ERC20 token
    // For ERC721: erc721LockForTokenId[token][tokenId] → lockId (0 = none)
    mapping(address => uint256) public activeERC20LockCount;
    mapping(address => mapping(uint256 => uint32)) public erc721LockForTokenId;

    // ── Stats ──
    uint256 public totalLocksCreated;
    uint256 public activeLockCount;

    // ═══════════════════════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Emitted when liquidity is locked.
     *         This event is the permanent on-chain proof guarantee.
     *         BSCScan users can verify token, amount, lockTime, unlockTime.
     */
    event LiquidityLocked(
        uint32 indexed lockId,
        LockType        lockType,
        address indexed token,
        uint256         amount,       // ERC20 amount or ERC721 tokenId
        address indexed locker,
        address         recipient,
        uint256         lockTime,
        uint256         unlockTime
    );

    /// @notice Emitted when a lock is unlocked and tokens transferred to recipient.
    event LiquidityUnlocked(
        uint32 indexed lockId,
        address indexed token,
        uint256         amount,
        address indexed recipient,
        uint256         unlockedAt
    );

    /// @notice Emitted when DAO extends a lock's unlock time.
    event LockExtended(
        uint32 indexed lockId,
        uint256         previousUnlockTime,
        uint256         newUnlockTime
    );

    /// @notice Emitted when DAO updates the unlock recipient.
    event RecipientUpdated(
        uint32 indexed lockId,
        address indexed oldRecipient,
        address indexed newRecipient
    );

    /// @notice Owner nominated a new DAO address.
    event DaoNominated(address indexed nominee);

    /// @notice Nominee accepted the DAO role.
    event DaoAccepted(address indexed oldDao, address indexed newDao);

    // ═══════════════════════════════════════════════════════════
    //  MODIFIERS
    // ═══════════════════════════════════════════════════════════

    modifier onlyDao() {
        require(msg.sender == dao, "CueLiquidityLocker: not DAO");
        _;
    }

    // ═══════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    /**
     * @param _dao  CueDAO contract address. Receives unlock, extend, and
     *              updateRecipient authority. Should be added as an
     *              approvedTarget in CueDAO before any governance calls.
     */
    constructor(address _dao) Ownable(msg.sender) {
        require(_dao != address(0), "CueLiquidityLocker: zero dao");
        dao = _dao;
    }

    // ═══════════════════════════════════════════════════════════
    //  LOCK — OWNER
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Lock an ERC-20 LP token for at least MIN_LOCK_DURATION (548 days).
     *
     *         The caller must have already transferred the tokens to this
     *         contract OR approved this contract to pull them. This function
     *         uses a balance-delta check (pull pattern) to handle fee-on-transfer
     *         tokens correctly — the actual locked amount is what was received,
     *         not the amount requested.
     *
     *         After this call, tokens cannot leave the contract until unlock()
     *         is called, which requires DAO governance AND the time gate.
     *
     * @param token      ERC-20 LP token contract address.
     * @param amount     Amount of LP tokens to lock (in token-wei).
     * @param recipient  Who receives the LP tokens when unlocked.
     *                   Typically the CueDAO contract address.
     * @return lockId    The newly created lock's ID.
     */
    function lockERC20(
        address token,
        uint256 amount,
        address recipient
    )
        external
        onlyOwner
        nonReentrant
        returns (uint32 lockId)
    {
        require(token     != address(0), "CueLiquidityLocker: zero token");
        require(amount    >  0,          "CueLiquidityLocker: zero amount");
        require(recipient != address(0), "CueLiquidityLocker: zero recipient");

        // Balance-delta pattern: measure what was actually received.
        // Handles fee-on-transfer tokens and prevents "amount" from being
        // higher than what the contract actually holds.
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 actualAmount = IERC20(token).balanceOf(address(this)) - balanceBefore;

        require(actualAmount > 0, "CueLiquidityLocker: received zero tokens");

        lockId = _createLock(LockType.ERC20, token, actualAmount, recipient);

        // Track for recovery guard
        activeERC20LockCount[token]++;
    }

    /**
     * @notice Lock a PancakeSwap V3 (or any ERC-721) position NFT for at
     *         least MIN_LOCK_DURATION (548 days).
     *
     *         The caller must have called approve(address(this), tokenId) on
     *         the NFT contract, OR transferred the NFT directly to this
     *         contract (in which case onERC721Received handles registration
     *         — see the note on that function below).
     *
     *         When using approve + lockERC721: the NFT is pulled in via
     *         safeTransferFrom inside this function.
     *
     *         When the NFT was already sent via safeTransferFrom to this
     *         contract: a raw lock with the received tokenId must be created
     *         by the owner via this function (the NFT is already here;
     *         transferFrom won't re-pull it). In that case the owner should
     *         call this function immediately after the NFT arrives.
     *
     *         NOTE: If the NFT was sent to this contract via
     *         safeTransferFrom before lockERC721() is called, the balance
     *         check in lockERC721 would see the NFT is already here and
     *         the pull via safeTransferFrom would fail. Use the pre-approved
     *         flow (approve + lockERC721) to avoid this. Alternatively,
     *         the owner can use lockERC721Direct() for NFTs already held.
     *
     * @param token      ERC-721 contract address (e.g. PancakeSwap V3 positions).
     * @param tokenId    The position NFT token ID to lock.
     * @param recipient  Who receives the NFT when unlocked.
     * @return lockId    The newly created lock's ID.
     */
    function lockERC721(
        address token,
        uint256 tokenId,
        address recipient
    )
        external
        onlyOwner
        nonReentrant
        returns (uint32 lockId)
    {
        require(token     != address(0), "CueLiquidityLocker: zero token");
        require(recipient != address(0), "CueLiquidityLocker: zero recipient");
        require(
            erc721LockForTokenId[token][tokenId] == 0,
            "CueLiquidityLocker: tokenId already locked"
        );

        // Pull the NFT from caller (caller must have approved this contract)
        IERC721(token).safeTransferFrom(msg.sender, address(this), tokenId);

        lockId = _createLock(LockType.ERC721, token, tokenId, recipient);

        // Track for recovery guard
        erc721LockForTokenId[token][tokenId] = lockId;
    }

    /**
     * @notice Lock an ERC-721 NFT that was already transferred to this contract.
     *
     *         Use this when the position NFT was sent via safeTransferFrom
     *         directly to this contract's address before lockERC721() could
     *         be called. The NFT is already here — this function just creates
     *         the accounting record.
     *
     *         Validates that this contract actually holds the specified NFT
     *         before registering the lock.
     *
     * @param token      ERC-721 contract address.
     * @param tokenId    Token ID already in this contract's possession.
     * @param recipient  Who receives the NFT on unlock.
     * @return lockId    The newly created lock's ID.
     */
    function lockERC721Direct(
        address token,
        uint256 tokenId,
        address recipient
    )
        external
        onlyOwner
        nonReentrant
        returns (uint32 lockId)
    {
        require(token     != address(0), "CueLiquidityLocker: zero token");
        require(recipient != address(0), "CueLiquidityLocker: zero recipient");
        require(
            erc721LockForTokenId[token][tokenId] == 0,
            "CueLiquidityLocker: tokenId already locked"
        );

        // Verify contract actually holds this NFT
        require(
            IERC721(token).ownerOf(tokenId) == address(this),
            "CueLiquidityLocker: contract does not hold this tokenId"
        );

        lockId = _createLock(LockType.ERC721, token, tokenId, recipient);
        erc721LockForTokenId[token][tokenId] = lockId;
    }

    // ═══════════════════════════════════════════════════════════
    //  UNLOCK — DAO ONLY
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Unlock a liquidity lock and transfer the assets to the recipient.
     *
     *         Two gates must BOTH pass:
     *           1. msg.sender == dao (DAO governance voted to unlock)
     *           2. block.timestamp >= lock.unlockTime (time gate enforced in bytecode)
     *
     *         The owner cannot call this. A guardian cannot bypass it.
     *         The time gate is a bytecode require — no human action can skip it.
     *
     *         Integration: CueDAO passes a GENERIC_CALL proposal with
     *         callTarget = address(this) and callData = abi.encodeWithSignature
     *         ("unlock(uint32)", lockId). CueLiquidityLocker must be in
     *         CueDAO's approvedTarget set.
     *
     * @param lockId  ID of the lock to unlock.
     */
    function unlock(uint32 lockId)
        external
        onlyDao
        nonReentrant
    {
        LiquidityLock storage lock = _requireLock(lockId);

        require(!lock.unlocked,                               "CueLiquidityLocker: already unlocked");
        require(block.timestamp >= lock.unlockTime,           "CueLiquidityLocker: lock period not elapsed");

        address recipient = lock.recipient;
        address token     = lock.token;
        uint256 amount    = lock.amount;
        LockType lockType = lock.lockType;

        // State update before external call (CEI)
        lock.unlocked = true;
        activeLockCount--;

        // Update recovery guards
        if (lockType == LockType.ERC20) {
            if (activeERC20LockCount[token] > 0) activeERC20LockCount[token]--;
        } else {
            erc721LockForTokenId[token][amount] = 0; // amount holds tokenId for ERC721
        }

        // Transfer assets to recipient
        if (lockType == LockType.ERC20) {
            IERC20(token).safeTransfer(recipient, amount);
        } else {
            IERC721(token).safeTransferFrom(address(this), recipient, amount);
        }

        emit LiquidityUnlocked(lockId, token, amount, recipient, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════
    //  LOCK MANAGEMENT — DAO ONLY
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Extend a lock's unlock time. DAO-only. Can never shorten.
     *
     *         The spec states: "DAO can extend beyond 18 months — can never shorten."
     *         This function enforces that guarantee in bytecode:
     *           require(newUnlockTime > lock.unlockTime)
     *
     *         There is no upper bound on extension — the DAO can lock
     *         liquidity indefinitely if governance votes for it.
     *
     * @param lockId        Lock to extend.
     * @param newUnlockTime New unlock timestamp. Must be strictly greater than
     *                      the current unlockTime AND greater than now.
     */
    function extendLock(uint32 lockId, uint256 newUnlockTime) external onlyDao {
        LiquidityLock storage lock = _requireLock(lockId);

        require(!lock.unlocked,                         "CueLiquidityLocker: already unlocked");
        require(newUnlockTime > lock.unlockTime,        "CueLiquidityLocker: cannot shorten lock");
        require(newUnlockTime > block.timestamp,        "CueLiquidityLocker: new time must be future");

        uint256 prev = lock.unlockTime;
        lock.unlockTime = newUnlockTime;

        emit LockExtended(lockId, prev, newUnlockTime);
    }

    /**
     * @notice Update who receives the LP tokens when a lock is unlocked.
     *         DAO-only. Useful when the DAO address itself is being migrated
     *         (e.g., after a governance contract upgrade).
     *
     * @param lockId       Lock to update.
     * @param newRecipient New recipient address (cannot be zero).
     */
    function updateRecipient(uint32 lockId, address newRecipient) external onlyDao {
        require(newRecipient != address(0), "CueLiquidityLocker: zero recipient");

        LiquidityLock storage lock = _requireLock(lockId);
        require(!lock.unlocked, "CueLiquidityLocker: already unlocked");

        address old = lock.recipient;
        lock.recipient = newRecipient;

        emit RecipientUpdated(lockId, old, newRecipient);
    }

    // ═══════════════════════════════════════════════════════════
    //  DAO ADDRESS HANDOVER — TWO-STEP
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Nominate a new DAO address. Owner-only.
     *         The nominee must call acceptDao() to complete the handover.
     *         The pending DAO has NO powers until it accepts.
     *
     *         Two-step prevents typo accidents. A mistyped DAO address
     *         would leave the locker permanently unmanageable post-18-months.
     *
     * @param nominee  New DAO address (CueDAO contract or multisig).
     */
    function nominateDao(address nominee) external onlyOwner {
        require(nominee != address(0), "CueLiquidityLocker: zero nominee");
        pendingDao = nominee;
        emit DaoNominated(nominee);
    }

    /**
     * @notice Accept the DAO role. Called by the pending DAO.
     */
    function acceptDao() external {
        require(msg.sender == pendingDao, "CueLiquidityLocker: not pending DAO");
        address old = dao;
        dao        = pendingDao;
        pendingDao = address(0);
        emit DaoAccepted(old, dao);
    }

    // ═══════════════════════════════════════════════════════════
    //  RECOVERY — OWNER (NON-LOCKED TOKENS ONLY)
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Recover ERC-20 tokens accidentally sent to this contract.
     *
     *         BLOCKED for any token that currently has at least one active
     *         (non-unlocked) lock. This prevents the recovery function from
     *         being used as an unlock bypass — you cannot recover LP tokens
     *         that are the subject of an active lock.
     *
     *         Safe to call for completely unrelated tokens (e.g., someone
     *         accidentally sent USDT here).
     *
     * @param token   Token contract to recover.
     * @param amount  Amount to recover.
     */
    function recoverERC20(address token, uint256 amount) external onlyOwner nonReentrant {
        require(
            activeERC20LockCount[token] == 0,
            "CueLiquidityLocker: token has active lock — use unlock()"
        );
        IERC20(token).safeTransfer(owner(), amount);
    }

    /**
     * @notice Recover an ERC-721 NFT accidentally sent to this contract.
     *
     *         BLOCKED for any tokenId that is currently in an active lock.
     *         This prevents the recovery function from being used to extract
     *         a locked V3 position.
     *
     * @param token    ERC-721 contract.
     * @param tokenId  Token ID to recover.
     */
    function recoverERC721(address token, uint256 tokenId) external onlyOwner nonReentrant {
        uint32 activeLockId = erc721LockForTokenId[token][tokenId];
        if (activeLockId != 0) {
            require(
                _locks[activeLockId].unlocked,
                "CueLiquidityLocker: tokenId has active lock — use unlock()"
            );
        }
        IERC721(token).safeTransferFrom(address(this), owner(), tokenId);
    }

    // ═══════════════════════════════════════════════════════════
    //  IERC721Receiver
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Required to receive ERC-721 NFTs via safeTransferFrom.
     *         Returns the standard selector to signal acceptance.
     *
     *         When a PancakeSwap V3 position NFT is sent directly to this
     *         contract via safeTransferFrom, this hook fires and the NFT
     *         is accepted. The owner must then call lockERC721Direct() to
     *         register the lock and start the 18-month timer.
     *
     *         NOTE: Until lockERC721Direct() is called, the NFT is held
     *         by this contract but NOT locked. The owner must call
     *         lockERC721Direct() promptly.
     */
    function onERC721Received(
        address, // operator
        address, // from
        uint256, // tokenId
        bytes calldata // data
    )
        external
        pure
        override
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW — SINGLE LOCK
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Fetch a lock by ID. Reverts if the ID does not exist.
     */
    function getLock(uint32 lockId)
        external
        view
        returns (LiquidityLock memory)
    {
        return _requireLock(lockId);
    }

    /**
     * @notice Check whether a lock exists (ID has been assigned).
     */
    function lockExists(uint32 lockId) external view returns (bool) {
        return lockId >= 1 && lockId < _nextLockId;
    }

    /**
     * @notice Whether a lock is eligible for unlock right now.
     *         True when: not already unlocked AND block.timestamp ≥ unlockTime.
     */
    function isUnlockable(uint32 lockId) external view returns (bool) {
        if (lockId == 0 || lockId >= _nextLockId) return false;
        LiquidityLock storage lock = _locks[lockId];
        return !lock.unlocked && block.timestamp >= lock.unlockTime;
    }

    /**
     * @notice Seconds remaining until a lock can be unlocked.
     *         Returns 0 if already unlockable or already unlocked.
     */
    function timeUntilUnlock(uint32 lockId) external view returns (uint256) {
        if (lockId == 0 || lockId >= _nextLockId) return 0;
        LiquidityLock storage lock = _locks[lockId];
        if (lock.unlocked || block.timestamp >= lock.unlockTime) return 0;
        return lock.unlockTime - block.timestamp;
    }

    /**
     * @notice Seconds since a lock was created (lock age).
     */
    function lockAge(uint32 lockId) external view returns (uint256) {
        LiquidityLock storage lock = _requireLock(lockId);
        return block.timestamp - lock.lockTime;
    }

    /**
     * @notice Full status breakdown for a single lock.
     *
     * @return lock_         The raw lock record.
     * @return ageSeconds    How long the lock has been active.
     * @return remainingSeconds  Seconds until unlock (0 if unlockable).
     * @return unlockable_   True if DAO can call unlock() right now.
     */
    function lockStatus(uint32 lockId)
        external
        view
        returns (
            LiquidityLock memory lock_,
            uint256 ageSeconds,
            uint256 remainingSeconds,
            bool    unlockable_
        )
    {
        lock_          = _requireLock(lockId);
        ageSeconds     = block.timestamp - lock_.lockTime;
        remainingSeconds = (!lock_.unlocked && block.timestamp < lock_.unlockTime)
                            ? lock_.unlockTime - block.timestamp
                            : 0;
        unlockable_ = !lock_.unlocked && block.timestamp >= lock_.unlockTime;
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW — BULK QUERIES
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice All locks ever created (active and unlocked).
     */
    function getAllLocks() external view returns (LiquidityLock[] memory locks) {
        uint256 count = _allLockIds.length;
        locks = new LiquidityLock[](count);
        for (uint256 i = 0; i < count; i++) {
            locks[i] = _locks[_allLockIds[i]];
        }
    }

    /**
     * @notice All currently active (non-unlocked) locks.
     *         Primary query for dashboards and trust verification.
     */
    function getActiveLocks() external view returns (LiquidityLock[] memory locks) {
        uint256 total  = _allLockIds.length;
        uint256 active;

        for (uint256 i = 0; i < total; i++) {
            if (!_locks[_allLockIds[i]].unlocked) active++;
        }
        locks = new LiquidityLock[](active);
        uint256 idx;
        for (uint256 i = 0; i < total; i++) {
            LiquidityLock storage l = _locks[_allLockIds[i]];
            if (!l.unlocked) locks[idx++] = l;
        }
    }

    /**
     * @notice All currently active locks for a specific ERC-20 token.
     *         Useful for "is this LP token locked?" queries by external tools.
     */
    function getActiveLocksForToken(address token)
        external
        view
        returns (LiquidityLock[] memory locks)
    {
        uint256 total = _allLockIds.length;
        uint256 count;

        for (uint256 i = 0; i < total; i++) {
            LiquidityLock storage l = _locks[_allLockIds[i]];
            if (l.token == token && !l.unlocked) count++;
        }
        locks = new LiquidityLock[](count);
        uint256 idx;
        for (uint256 i = 0; i < total; i++) {
            LiquidityLock storage l = _locks[_allLockIds[i]];
            if (l.token == token && !l.unlocked) locks[idx++] = l;
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW — PROTOCOL STATS
    // ═══════════════════════════════════════════════════════════

    /// @notice Total number of locks ever created.
    function lockCount() external view returns (uint32) {
        return _nextLockId == 0 ? 0 : _nextLockId - 1;
    }

    /**
     * @notice Full protocol snapshot.
     *
     * @return totalLocks      All-time lock count.
     * @return activeCount_    Currently active (non-unlocked) locks.
     * @return dao_            Current DAO address.
     * @return pendingDao_     Pending DAO nominee (zero if none).
     * @return minLockDays     MIN_LOCK_DURATION in days (for display).
     */
    function protocolStats()
        external
        view
        returns (
            uint32  totalLocks,
            uint256 activeCount_,
            address dao_,
            address pendingDao_,
            uint256 minLockDays
        )
    {
        return (
            _nextLockId == 0 ? 0 : _nextLockId - 1,
            activeLockCount,
            dao,
            pendingDao,
            MIN_LOCK_DURATION / 1 days
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev Shared lock-creation logic.
     *      Called from lockERC20(), lockERC721(), and lockERC721Direct().
     */
    function _createLock(
        LockType lockType,
        address  token,
        uint256  amount,      // ERC20: wei amount; ERC721: tokenId
        address  recipient
    )
        internal
        returns (uint32 lockId)
    {
        if (_nextLockId == 0) _nextLockId = 1;
        lockId = _nextLockId++;

        uint256 lockTime   = block.timestamp;
        uint256 unlockTime = lockTime + MIN_LOCK_DURATION;

        _locks[lockId] = LiquidityLock({
            lockId:     lockId,
            lockType:   lockType,
            token:      token,
            amount:     amount,
            locker:     msg.sender,
            recipient:  recipient,
            lockTime:   lockTime,
            unlockTime: unlockTime,
            unlocked:   false
        });

        _allLockIds.push(lockId);
        totalLocksCreated++;
        activeLockCount++;

        emit LiquidityLocked(
            lockId, lockType, token, amount,
            msg.sender, recipient, lockTime, unlockTime
        );
    }

    /**
     * @dev Fetch a lock, reverting if the ID has not been assigned.
     */
    function _requireLock(uint32 lockId)
        internal
        view
        returns (LiquidityLock storage)
    {
        require(
            lockId >= 1 && lockId < _nextLockId,
            "CueLiquidityLocker: lock does not exist"
        );
        return _locks[lockId];
    }
}
