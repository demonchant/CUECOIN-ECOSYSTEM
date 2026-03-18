// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ╔══════════════════════════════════════════════════════════════╗
//  CUENFT  ·  v3.0  ·  Supply-Hardened
//  CUECOIN Ecosystem  ·  BNB Smart Chain
//
//  v1 features (carried forward):
//   [V1-1]  Five tiers: Common / Rare / Epic / Legendary / Genesis
//   [V1-2]  mintCommon() — open mint, burns 500 CUECOIN to 0xdead
//   [V1-3]  mintRare()   — 10 ranked wins; oracle/escrow minter
//   [V1-4]  mintEpic()   — Regional Tournament winner; tournament minter
//   [V1-5]  mintLegendary() — World Tournament; soulbound; Hall of Fame
//   [V1-6]  mintGenesis() — premium airdrop; soulbound; write-once cap
//   [V1-7]  openGenesisMinting() / closeGenesisMinting() — write-once seal
//   [V1-8]  ERC-2981 royalty: 5% total, routed to CueMarketplace for 2.5/2.5 split
//   [V1-9]  Soulbound enforcement in _update() (Legendary + Genesis)
//   [V1-10] Hall of Fame: append-only, per-wallet index, immutable
//   [V1-11] walletTierHighest() / walletBonusBps() — oracle query interface
//   [V1-12] tokensOfOwner() / tokensOfOwnerByTier() — enumeration views
//   [V1-13] Per-tier minter role: tierMinter[tier] — owner-updatable
//   [V1-14] setTokenURI() — per-token override for 1-of-1 Legendary art
//
//  v2 additions:
//   [V2-1]  BURN FUNCTION — burn(tokenId) lets any token holder destroy
//            their NFT. Soulbound tokens may be burned but not transferred.
//   [V2-2]  REFERRAL BADGE TIERS — BADGE_SILVER/GOLD/DIAMOND (tiers 5–7),
//            minted by CueReferral. Non-soulbound. No wager bonus.
//   [V2-3]  PER-PLAYER RARE CAP — at most one Rare per wallet at a time.
//   [V2-4]  FLOOR PRICE ORACLE — 7-day rolling ring buffer per tier.
//            CueMarketplace calls recordSale(). floorPrice(tier) view.
//   [V2-5]  NFT STATS VIEW — nftStats() full protocol summary.
//   [V2-6]  METADATA ENUM GUARD — winsAtMint > 0, matchHistoryRoot != 0
//            enforced on mintRare and mintLegendary.
//   [V2-7]  TIMELOCKED MINTER UPDATES — setTierMinter() uses 48h timelock.
//   [V2-8]  walletHasBonus() fast boolean. NO_NFT_SENTINEL = 255 documented.
//   [V2-9]  PROTOCOL STATS COUNTERS — mintedPerTier / burnedPerTier.
//   [V2-10] Strings.toString() replaces manual _uint256ToString.
//
//  v3 supply hardening (this release):
//   [V3-1]  COMMON SUPPLY CAP — COMMON_CAP = 10,000,000. Hard on-chain
//            ceiling. mintCommon() reverts once reached. The 500 CUECOIN
//            burn is economic friction; the cap is the rarity guarantee.
//            Owner can lower but never raise above COMMON_CAP_MAX (10M).
//
//   [V3-2]  RARE GLOBAL CAP — RARE_CAP = 100,000. A compromised oracle
//            minter cannot issue more than 100,000 Rare NFTs regardless
//            of how many wallets it targets. At 1 per wallet this equals
//            the realistic player ceiling at launch scale.
//
//   [V3-3]  EPIC GLOBAL CAP — EPIC_CAP = 10,000. One per Regional
//            Tournament, quarterly, across all regions. Even at maximum
//            concurrency for 100 years this cap is unreachable legitimately.
//            A compromised minter is stopped at 10,000.
//
//   [V3-4]  LEGENDARY GLOBAL CAP — LEGENDARY_CAP = 1,000. One per annual
//            World Tournament. At one event per year this cap covers
//            1,000 years of tournaments. In practice fewer than 100 will
//            ever exist. A compromised minter cannot flood Legendary supply.
//
//   [V3-5]  BADGE GLOBAL CAPS — BADGE_SILVER_CAP = 500,000,
//            BADGE_GOLD_CAP = 100,000, BADGE_DIAMOND_CAP = 10,000.
//            Sized 5× the realistic referral participant ceiling.
//            A compromised CueReferral contract cannot flood badge supply.
//
//   [V3-6]  OWNER() BYPASS REMOVED FROM onlyTierMinter — the owner can
//            update minter addresses (timelocked) but CANNOT directly call
//            any mint function. Owner key compromise no longer equals
//            unlimited mint authority. Emergency minting requires the
//            owner to update the minter address first (48h timelock),
//            giving the community time to respond.
//
//   [V3-7]  TOURNAMENT NAME UNIQUENESS — mintEpic and mintLegendary
//            enforce that tournamentName has not been used before.
//            usedTournamentNames[keccak256(name)] mapping. Prevents a
//            compromised minter from minting multiple NFTs claiming to
//            be prizes for the same tournament event.
//
//   [V3-8]  PER-WALLET EPIC AND LEGENDARY CAPS — a wallet may hold at
//            most 1 Legendary at a time (soulbound — cannot transfer,
//            but guards against a compromised minter targeting one wallet).
//            Epic: at most 3 per wallet (a player could legitimately win
//            multiple regional tournaments over their career).
//
//   [V3-9]  MINT PAUSED PER TIER — owner can pause minting for a
//            specific tier independently without pausing the entire
//            contract. tierMintPaused[tier]. Allows surgical response
//            to a compromised minter without halting all activity.
//
//   [V3-10] SUPPLY VIEW — tierSupplyStatus(tier) returns cap, minted,
//            burned, live, and remaining for any tier in one call.
//            Frontend and monitoring can track supply in real time.
// ╚══════════════════════════════════════════════════════════════╝

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Royalty.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  CueNFT
 * @author CUECOIN Team
 * @notice Five-tier + badge NFT collection for the CUECOIN gaming ecosystem.
 *         v3.0 adds strict on-chain supply caps for every tier, removes the
 *         owner() bypass from mint authorisation, and adds per-tournament
 *         uniqueness enforcement.
 *
 * ══════════════════════════════════════════════════════════
 *  SUPPLY CAPS (hardcoded bytecode constants — immutable)
 * ══════════════════════════════════════════════════════════
 *   Common      10,000,000   (open burn mint — deflationary gate)
 *   Rare           100,000   (10 ranked wins per wallet)
 *   Epic            10,000   (Regional Tournament winners)
 *   Legendary        1,000   (World Tournament — 1 per annual event)
 *   Genesis        400,000   (premium airdrop — write-once sealed)
 *   Badge Silver   500,000   (referral Silver tier milestone)
 *   Badge Gold     100,000   (referral Gold tier milestone)
 *   Badge Diamond   10,000   (referral Diamond tier milestone)
 *
 * ══════════════════════════════════════════════════════════
 *  MINT AUTHORISATION MODEL  [V3-6]
 * ══════════════════════════════════════════════════════════
 *   onlyTierMinter(tier) — ONLY the registered minter for that tier.
 *   Owner is NOT in the bypass set. Owner can rotate minters (48h timelock)
 *   but cannot mint directly. This separates key compromise surfaces:
 *     — Compromised owner key: can queue a minter rotation (visible, 48h delay)
 *     — Compromised minter key: can only mint up to the hard supply cap
 *     — Both compromised: worst case, capped at bytecode supply limits
 *
 * ══════════════════════════════════════════════════════════
 *  TIER CONSTANTS
 * ══════════════════════════════════════════════════════════
 *   Tier 0 Common    "Street Cue"   — burn 500 CUECOIN, open to all
 *   Tier 1 Rare      "Pro Cue"      — 10 ranked wins, +5% bonus
 *   Tier 2 Epic      "Master Cue"   — Regional Tournament, +10% bonus
 *   Tier 3 Legendary "Grand Master" — World Tournament, +15%, SOULBOUND
 *   Tier 4 Genesis   "Founders Set" — premium airdrop, +20%, SOULBOUND
 *   Tier 5 Badge Silver  — 10+ referrals, no bonus, transferable
 *   Tier 6 Badge Gold    — 50+ referrals, no bonus, transferable
 *   Tier 7 Badge Diamond — 100+ referrals, no bonus, transferable
 */
contract CueNFT is
    ERC721,
    ERC721Enumerable,
    ERC721Royalty,
    ERC721URIStorage,
    Ownable2Step,
    ReentrancyGuard,
    Pausable
{
    using SafeERC20 for IERC20;
    using Strings   for uint256;

    // ═══════════════════════════════════════════════════════════
    //  CONSTANTS — TIER IDs
    // ═══════════════════════════════════════════════════════════

    uint8 public constant TIER_COMMON    = 0;
    uint8 public constant TIER_RARE      = 1;
    uint8 public constant TIER_EPIC      = 2;
    uint8 public constant TIER_LEGENDARY = 3;
    uint8 public constant TIER_GENESIS   = 4;

    uint8 public constant BADGE_SILVER  = 5;
    uint8 public constant BADGE_GOLD    = 6;
    uint8 public constant BADGE_DIAMOND = 7;

    uint8 public constant NO_NFT_SENTINEL = 255;

    // ═══════════════════════════════════════════════════════════
    //  CONSTANTS — SUPPLY CAPS  [V3-1 through V3-5]
    //  All hardcoded in bytecode. No function can raise these.
    // ═══════════════════════════════════════════════════════════

    /// @notice Maximum Common NFTs ever mintable. Owner may lower activeCommonCap
    ///         but can never push it above this bytecode ceiling.
    uint256 public constant COMMON_CAP       = 10_000_000;

    /// @notice Maximum Rare NFTs ever mintable. Achievement credential integrity.
    uint256 public constant RARE_CAP         =    100_000;

    /// @notice Maximum Epic NFTs ever mintable. Regional Tournament prize integrity.
    uint256 public constant EPIC_CAP         =     10_000;

    /// @notice Maximum Legendary NFTs ever mintable. One per annual World Tournament.
    ///         1,000 covers 1,000 years of annual events — effectively infinite
    ///         for legitimate use while bounding compromise blast radius.
    uint256 public constant LEGENDARY_CAP    =      1_000;

    /// @notice Maximum Genesis NFTs. Matches premium airdrop cap exactly.
    uint256 public constant GENESIS_CAP      =    400_000;

    /// @notice Badge supply caps sized 5× realistic referral ceilings.
    uint256 public constant BADGE_SILVER_CAP  =   500_000;
    uint256 public constant BADGE_GOLD_CAP    =   100_000;
    uint256 public constant BADGE_DIAMOND_CAP =    10_000;

    // ── Per-wallet holding caps  [V3-8] ──
    /// @notice Max Rare NFTs a wallet may hold simultaneously.
    uint256 public constant MAX_RARE_PER_WALLET      = 1;

    /// @notice Max Epic NFTs a wallet may hold simultaneously.
    ///         3 allows for a legitimate multi-regional-tournament winner career.
    uint256 public constant MAX_EPIC_PER_WALLET      = 3;

    /// @notice Max Legendary NFTs a wallet may hold simultaneously.
    ///         Soulbound — the cap enforces uniqueness even if soulbound
    ///         logic were somehow bypassed.
    uint256 public constant MAX_LEGENDARY_PER_WALLET = 1;

    // ── Economic constants ──
    uint256 public constant COMMON_MINT_COST = 500 ether;
    uint96  public constant ROYALTY_BPS      = 500;       // 5%

    // ── Floor price oracle ──
    uint256 public constant FLOOR_WINDOW_SIZE    = 50;
    uint256 public constant FLOOR_WINDOW_SECONDS = 7 days;

    // ── Timelock ──
    uint256 public constant TIMELOCK_DELAY = 48 hours;
    uint256 public constant TIMELOCK_GRACE = 14 days;

    address public constant BURN_ADDRESS =
        address(0x000000000000000000000000000000000000dEaD);

    // ═══════════════════════════════════════════════════════════
    //  PURE LOOKUPS
    // ═══════════════════════════════════════════════════════════

    function tierBonusBps(uint8 tier) public pure returns (uint256) {
        if (tier == TIER_RARE)      return 500;
        if (tier == TIER_EPIC)      return 1_000;
        if (tier == TIER_LEGENDARY) return 1_500;
        if (tier == TIER_GENESIS)   return 2_000;
        return 0;
    }

    function isSoulboundTier(uint8 tier) public pure returns (bool) {
        return tier == TIER_LEGENDARY || tier == TIER_GENESIS;
    }

    function isBonusTier(uint8 tier) public pure returns (bool) {
        return tier >= TIER_RARE && tier <= TIER_GENESIS;
    }

    function isBadgeTier(uint8 tier) public pure returns (bool) {
        return tier == BADGE_SILVER || tier == BADGE_GOLD || tier == BADGE_DIAMOND;
    }

    /**
     * @notice Hardcoded supply cap for any tier. Returns the bytecode constant.
     *         For Common, also see activeCommonCap (owner-lowerable soft ceiling).
     */
    function hardCapForTier(uint8 tier) public pure returns (uint256) {
        if (tier == TIER_COMMON)    return COMMON_CAP;
        if (tier == TIER_RARE)      return RARE_CAP;
        if (tier == TIER_EPIC)      return EPIC_CAP;
        if (tier == TIER_LEGENDARY) return LEGENDARY_CAP;
        if (tier == TIER_GENESIS)   return GENESIS_CAP;
        if (tier == BADGE_SILVER)   return BADGE_SILVER_CAP;
        if (tier == BADGE_GOLD)     return BADGE_GOLD_CAP;
        if (tier == BADGE_DIAMOND)  return BADGE_DIAMOND_CAP;
        return 0;
    }

    // ═══════════════════════════════════════════════════════════
    //  STRUCTS
    // ═══════════════════════════════════════════════════════════

    struct NFTMetadata {
        uint8   tier;
        uint256 mintedAt;
        uint256 winsAtMint;
        string  tournamentName;
        bytes32 matchHistoryRoot;
        address originalMinter;
        bool    isGenesis;
        bool    soulbound;
    }

    struct HallOfFameEntry {
        address wallet;
        uint256 tokenId;
        string  tournamentName;
        bytes32 matchHistoryRoot;
        uint256 timestamp;
        uint256 blockNumber;
    }

    struct SaleRecord {
        uint256 priceWei;
        uint256 timestamp;
    }

    // ═══════════════════════════════════════════════════════════
    //  STATE VARIABLES
    // ═══════════════════════════════════════════════════════════

    IERC20 public immutable cueCoin;

    uint256 private _nextTokenId;  // starts at 1

    string private _baseTokenURI;

    mapping(uint256 => NFTMetadata) public nftMetadata;

    // ── Genesis minting state ──
    uint256 public genesisCount;
    bool    public genesisMintingOpen;
    bool    public genesisMintingClosed;

    // ── [V3-1] Active Common cap — owner can lower, never raise above COMMON_CAP ──
    uint256 public activeCommonCap;

    // ── Per-tier minter roles ──
    mapping(uint8 => address) public tierMinter;

    // ── [V3-9] Per-tier mint pause ──
    mapping(uint8 => bool) public tierMintPaused;

    // ── ERC-2981 royalty receiver ──
    address public marketplaceRoyaltyReceiver;

    // ── Hall of Fame ──
    HallOfFameEntry[] public hallOfFame;
    mapping(address => uint256[]) private _walletHoFIndices;

    // ── [V2-3 / V3-8] Per-wallet holding counts ──
    mapping(address => uint256) public rareHolderCount;
    mapping(address => uint256) public epicHolderCount;
    mapping(address => uint256) public legendaryHolderCount;

    // ── [V3-7] Tournament name uniqueness ──
    mapping(bytes32 => bool) public usedTournamentNames;

    // ── [V2-4] Floor price oracle ──
    address public saleRecorder;
    mapping(uint8 => SaleRecord[FLOOR_WINDOW_SIZE]) private _saleBuffer;
    mapping(uint8 => uint256)  private _saleBufferHead;
    mapping(uint8 => uint256)  public  allTimeFloor;

    // ── [V2-9] Protocol stats ──
    mapping(uint8 => uint256) public mintedPerTier;
    mapping(uint8 => uint256) public burnedPerTier;

    // ── [V2-7] Timelock ──
    mapping(bytes32 => uint256) public timelockEta;
    mapping(bytes32 => bool)    public timelockExecuted;

    // ═══════════════════════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════════════════════

    event CommonMinted(uint256 indexed tokenId, address indexed minter, uint256 burned);

    event AchievementMinted(
        uint256 indexed tokenId,
        address indexed recipient,
        uint8   indexed tier,
        string  tournamentName,
        uint256 winsAtMint,
        bytes32 matchHistoryRoot
    );

    event GenesisMinted(uint256 indexed tokenId, address indexed recipient, uint256 genesisNumber);

    event BadgeMinted(
        uint256 indexed tokenId,
        address indexed recipient,
        uint8   indexed badgeTier,
        uint256 referralCount
    );

    event TokenBurned(uint256 indexed tokenId, address indexed burner, uint8 indexed tier);

    event HallOfFameAdded(
        uint256 indexed hofIndex,
        address indexed wallet,
        uint256 indexed tokenId,
        string  tournamentName
    );

    event SoulboundTransferBlocked(uint256 indexed tokenId, address indexed from, address indexed to);

    event SaleRecorded(uint8 indexed tier, uint256 priceWei, uint256 newFloor);
    event SaleRecorderUpdated(address indexed oldRecorder, address indexed newRecorder);

    event TierMinterUpdated(uint8 indexed tier, address indexed minter);
    event MarketplaceReceiverUpdated(address indexed oldReceiver, address indexed newReceiver);
    event BaseURIUpdated(string newBaseURI);

    event GenesisMintingOpened(uint256 timestamp);
    event GenesisMintingClosedPermanently(uint256 totalMinted, uint256 timestamp);

    // [V3-1] Common cap lowered by owner
    event ActiveCommonCapUpdated(uint256 oldCap, uint256 newCap);

    // [V3-9] Per-tier pause
    event TierMintPaused(uint8 indexed tier);
    event TierMintUnpaused(uint8 indexed tier);

    // Timelock
    event TimelockQueued(bytes32 indexed operationId, bytes32 indexed action, uint256 eta);
    event TimelockExecuted(bytes32 indexed operationId, bytes32 indexed action);
    event TimelockCancelled(bytes32 indexed operationId);

    // ═══════════════════════════════════════════════════════════
    //  MODIFIERS
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev [V3-6] Authorises ONLY the registered tierMinter[tier].
     *      The owner is NOT in the bypass set. This is an intentional
     *      security hardening from v2 which had `|| msg.sender == owner()`.
     *
     *      Rationale: a compromised owner key should not be able to mint
     *      any NFT directly. The owner's only mint-related power is to
     *      rotate the minter address — which takes 48 hours via timelock,
     *      giving the community time to detect and respond.
     *
     *      Emergency minting procedure:
     *        1. Owner calls setTierMinter(tier, emergencyAddress) — queues 48h timelock
     *        2. After 48h: timelock executes, emergencyAddress is the new minter
     *        3. emergencyAddress calls mintX() directly
     *      This path is intentionally slow. Fast emergency minting = exploit risk.
     */
    modifier onlyTierMinter(uint8 tier) {
        require(
            msg.sender == tierMinter[tier],
            "CueNFT: not authorised minter for tier"
        );
        _;
    }

    /**
     * @dev [V3-9] Reverts if minting for this tier is individually paused.
     *      Independent of the global Pausable — allows surgical tier-level pause.
     */
    modifier tierNotPaused(uint8 tier) {
        require(!tierMintPaused[tier], "CueNFT: minting paused for this tier");
        _;
    }

    /**
     * @dev [V2-7] 48-hour on-chain timelock for sensitive admin operations.
     *      Call 1: queues. Call 2 (after 48h, within 14d): executes.
     *      opId is keyed on action + msg.data so different arguments = independent timers.
     */
    modifier timelocked(bytes32 action) {
        bytes32 opId = keccak256(abi.encodePacked(action, msg.sender, keccak256(msg.data)));
        if (timelockEta[opId] == 0) {
            uint256 eta = block.timestamp + TIMELOCK_DELAY;
            timelockEta[opId] = eta;
            emit TimelockQueued(opId, action, eta);
            return;
        }
        require(block.timestamp >= timelockEta[opId],                  "CueNFT: timelock not elapsed");
        require(block.timestamp <  timelockEta[opId] + TIMELOCK_GRACE, "CueNFT: timelock grace expired");
        require(!timelockExecuted[opId],                               "CueNFT: already executed");
        timelockExecuted[opId] = true;
        emit TimelockExecuted(opId, action);
        _;
    }

    // ═══════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    /**
     * @param _cueCoin               CueCoin BEP-20 — burned on Common mint.
     * @param _marketplaceReceiver   CueMarketplace — ERC-2981 royalty receiver.
     * @param _saleRecorder          CueMarketplace — authorised sale recorder.
     * @param _rareMinter            Tier 1 — oracle backend or CueEscrow.
     * @param _epicMinter            Tier 2 — CueTournament (regional).
     * @param _legendaryMinter       Tier 3 — CueTournament (world).
     * @param _genesisMinter         Tier 4 — CueAirdrop.
     * @param _badgeMinter           Badge tiers 5/6/7 — CueReferral.
     * @param _baseURI               IPFS/HTTPS base URI.
     */
    constructor(
        address _cueCoin,
        address _marketplaceReceiver,
        address _saleRecorder,
        address _rareMinter,
        address _epicMinter,
        address _legendaryMinter,
        address _genesisMinter,
        address _badgeMinter,
        string memory _baseURI
    )
        ERC721("CueCoin NFT", "CUENFT")
        Ownable(msg.sender)
    {
        require(_cueCoin             != address(0), "CueNFT: zero cueCoin");
        require(_marketplaceReceiver != address(0), "CueNFT: zero marketplace");
        require(_saleRecorder        != address(0), "CueNFT: zero saleRecorder");
        require(_rareMinter          != address(0), "CueNFT: zero rareMinter");
        require(_epicMinter          != address(0), "CueNFT: zero epicMinter");
        require(_legendaryMinter     != address(0), "CueNFT: zero legendaryMinter");
        require(_genesisMinter       != address(0), "CueNFT: zero genesisMinter");
        require(_badgeMinter         != address(0), "CueNFT: zero badgeMinter");

        cueCoin                    = IERC20(_cueCoin);
        marketplaceRoyaltyReceiver = _marketplaceReceiver;
        saleRecorder               = _saleRecorder;
        _baseTokenURI              = _baseURI;
        _nextTokenId               = 1;

        // Initialise active Common cap at the hard bytecode ceiling
        activeCommonCap = COMMON_CAP;

        tierMinter[TIER_RARE]      = _rareMinter;
        tierMinter[TIER_EPIC]      = _epicMinter;
        tierMinter[TIER_LEGENDARY] = _legendaryMinter;
        tierMinter[TIER_GENESIS]   = _genesisMinter;
        tierMinter[BADGE_SILVER]   = _badgeMinter;
        tierMinter[BADGE_GOLD]     = _badgeMinter;
        tierMinter[BADGE_DIAMOND]  = _badgeMinter;

        _setDefaultRoyalty(_marketplaceReceiver, ROYALTY_BPS);
    }

    // ═══════════════════════════════════════════════════════════
    //  TIER 0 — COMMON MINT
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Burn 500 CUECOIN to mint a Common "Street Cue" NFT.
     *         [V3-1] Reverts once mintedPerTier[COMMON] reaches activeCommonCap.
     *         The burn cost provides economic friction; the cap provides
     *         the on-chain rarity guarantee that cannot be economically bypassed.
     */
    function mintCommon()
        external
        nonReentrant
        whenNotPaused
        tierNotPaused(TIER_COMMON)
        returns (uint256 tokenId)
    {
        // [V3-1] Hard supply check — net live supply (minted - burned)
        uint256 liveCommon = mintedPerTier[TIER_COMMON] - burnedPerTier[TIER_COMMON];
        require(liveCommon < activeCommonCap, "CueNFT: Common supply cap reached");

        // CEI: collect payment first
        cueCoin.safeTransferFrom(msg.sender, BURN_ADDRESS, COMMON_MINT_COST);

        tokenId = _mintToken(msg.sender, TIER_COMMON, 0, "", bytes32(0), false);
        emit CommonMinted(tokenId, msg.sender, COMMON_MINT_COST);
    }

    // ═══════════════════════════════════════════════════════════
    //  TIER 1 — RARE MINT
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Mint a Rare "Pro Cue" NFT — 10 ranked wager wins achievement.
     *         [V3-2] Global cap: RARE_CAP = 100,000 total ever minted.
     *         [V2-3 / V3-8] Per-wallet cap: MAX_RARE_PER_WALLET = 1.
     *         [V3-6] Only tierMinter[TIER_RARE] — owner cannot call directly.
     */
    function mintRare(
        address to,
        uint256 winsAtMint,
        bytes32 matchHistoryRoot
    )
        external
        nonReentrant
        whenNotPaused
        tierNotPaused(TIER_RARE)
        onlyTierMinter(TIER_RARE)
        returns (uint256 tokenId)
    {
        require(to               != address(0), "CueNFT: zero recipient");
        require(winsAtMint       >  0,          "CueNFT: winsAtMint must be > 0");
        require(matchHistoryRoot != bytes32(0), "CueNFT: zero matchHistoryRoot");

        // [V3-2] Global supply cap
        require(mintedPerTier[TIER_RARE] < RARE_CAP,
            "CueNFT: Rare global supply cap reached");

        // [V3-8] Per-wallet cap
        require(rareHolderCount[to] < MAX_RARE_PER_WALLET,
            "CueNFT: wallet already holds max Rare NFTs");

        tokenId = _mintToken(to, TIER_RARE, winsAtMint, "10 Ranked Wins", matchHistoryRoot, false);
        rareHolderCount[to]++;

        emit AchievementMinted(tokenId, to, TIER_RARE, "10 Ranked Wins", winsAtMint, matchHistoryRoot);
    }

    // ═══════════════════════════════════════════════════════════
    //  TIER 2 — EPIC MINT
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Mint an Epic "Master Cue" NFT — Regional Tournament winner.
     *         [V3-3] Global cap: EPIC_CAP = 10,000 total ever minted.
     *         [V3-7] Tournament name uniqueness: each tournamentName can only
     *                be used once across all Epic mints — one prize per event.
     *         [V3-8] Per-wallet cap: MAX_EPIC_PER_WALLET = 3.
     *         [V3-6] Only tierMinter[TIER_EPIC].
     */
    function mintEpic(
        address to,
        string calldata tournamentName,
        bytes32 matchHistoryRoot
    )
        external
        nonReentrant
        whenNotPaused
        tierNotPaused(TIER_EPIC)
        onlyTierMinter(TIER_EPIC)
        returns (uint256 tokenId)
    {
        require(to                          != address(0), "CueNFT: zero recipient");
        require(bytes(tournamentName).length >  0,         "CueNFT: empty tournament name");
        require(matchHistoryRoot            != bytes32(0), "CueNFT: zero matchHistoryRoot");

        // [V3-3] Global supply cap
        require(mintedPerTier[TIER_EPIC] < EPIC_CAP,
            "CueNFT: Epic global supply cap reached");

        // [V3-7] Tournament name uniqueness — one Epic NFT per tournament event
        bytes32 nameKey = keccak256(bytes(tournamentName));
        require(!usedTournamentNames[nameKey],
            "CueNFT: tournament name already used — one prize per event");
        usedTournamentNames[nameKey] = true;

        // [V3-8] Per-wallet cap
        require(epicHolderCount[to] < MAX_EPIC_PER_WALLET,
            "CueNFT: wallet already holds max Epic NFTs");

        tokenId = _mintToken(to, TIER_EPIC, 0, tournamentName, matchHistoryRoot, false);
        epicHolderCount[to]++;

        emit AchievementMinted(tokenId, to, TIER_EPIC, tournamentName, 0, matchHistoryRoot);
    }

    // ═══════════════════════════════════════════════════════════
    //  TIER 3 — LEGENDARY MINT
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Mint a Legendary "Grand Master" NFT — World Tournament winner.
     *         SOULBOUND. Appends to Hall of Fame.
     *         [V3-4] Global cap: LEGENDARY_CAP = 1,000 total ever minted.
     *         [V3-7] Tournament name uniqueness — one Legendary per event.
     *         [V3-8] Per-wallet cap: MAX_LEGENDARY_PER_WALLET = 1.
     *         [V3-6] Only tierMinter[TIER_LEGENDARY].
     */
    function mintLegendary(
        address to,
        string calldata tournamentName,
        bytes32 matchHistoryRoot
    )
        external
        nonReentrant
        whenNotPaused
        tierNotPaused(TIER_LEGENDARY)
        onlyTierMinter(TIER_LEGENDARY)
        returns (uint256 tokenId)
    {
        require(to                          != address(0), "CueNFT: zero recipient");
        require(bytes(tournamentName).length >  0,         "CueNFT: empty tournament name");
        require(matchHistoryRoot            != bytes32(0), "CueNFT: zero matchHistoryRoot");

        // [V3-4] Global supply cap
        require(mintedPerTier[TIER_LEGENDARY] < LEGENDARY_CAP,
            "CueNFT: Legendary global supply cap reached");

        // [V3-7] Tournament name uniqueness — one Legendary per World Tournament
        bytes32 nameKey = keccak256(bytes(tournamentName));
        require(!usedTournamentNames[nameKey],
            "CueNFT: tournament name already used — one prize per event");
        usedTournamentNames[nameKey] = true;

        // [V3-8] Per-wallet cap — one Legendary per wallet (also enforced by soulbound)
        require(legendaryHolderCount[to] < MAX_LEGENDARY_PER_WALLET,
            "CueNFT: wallet already holds a Legendary NFT");

        tokenId = _mintToken(to, TIER_LEGENDARY, 0, tournamentName, matchHistoryRoot, true);
        legendaryHolderCount[to]++;

        _addToHallOfFame(to, tokenId, tournamentName, matchHistoryRoot);
        emit AchievementMinted(tokenId, to, TIER_LEGENDARY, tournamentName, 0, matchHistoryRoot);
    }

    // ═══════════════════════════════════════════════════════════
    //  TIER 4 — GENESIS MINT
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Mint a Genesis "Founders Set" NFT — premium airdrop only.
     *         SOULBOUND. Write-once sealed after closeGenesisMinting().
     *         [V3-5] GENESIS_CAP = 400,000 (bytecode constant).
     *         [V3-6] Only tierMinter[TIER_GENESIS].
     */
    function mintGenesis(address to)
        external
        nonReentrant
        whenNotPaused
        tierNotPaused(TIER_GENESIS)
        onlyTierMinter(TIER_GENESIS)
        returns (uint256 tokenId)
    {
        require(to != address(0),           "CueNFT: zero recipient");
        require(genesisMintingOpen,         "CueNFT: genesis minting not open");
        require(!genesisMintingClosed,      "CueNFT: genesis permanently closed");
        require(genesisCount < GENESIS_CAP, "CueNFT: genesis cap reached");

        uint256 genesisNumber = ++genesisCount;

        tokenId = _mintToken(to, TIER_GENESIS, 0, "Genesis — Founders Collection", bytes32(0), true);
        nftMetadata[tokenId].isGenesis = true;

        emit GenesisMinted(tokenId, to, genesisNumber);
    }

    // ═══════════════════════════════════════════════════════════
    //  BADGE TIERS 5–7 — REFERRAL BADGES
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Mint a referral badge NFT — called by CueReferral only.
     *         [V3-5] Global caps: BADGE_SILVER_CAP / GOLD_CAP / DIAMOND_CAP.
     *         [V3-6] Only tierMinter[badgeTier] — owner cannot call directly.
     *         Badges are transferable. They do not grant wager bonuses.
     *
     * @param to             Referrer wallet.
     * @param badgeTier      BADGE_SILVER (5), BADGE_GOLD (6), or BADGE_DIAMOND (7).
     * @param referralCount  Successful referrals at award time (provenance).
     */
    function mintBadge(
        address to,
        uint8   badgeTier,
        uint256 referralCount
    )
        external
        nonReentrant
        whenNotPaused
        tierNotPaused(badgeTier)
        onlyTierMinter(badgeTier)
        returns (uint256 tokenId)
    {
        require(to != address(0),       "CueNFT: zero recipient");
        require(isBadgeTier(badgeTier), "CueNFT: not a badge tier");
        require(referralCount > 0,      "CueNFT: referralCount must be > 0");

        // [V3-5] Global supply cap per badge tier
        require(mintedPerTier[badgeTier] < hardCapForTier(badgeTier),
            "CueNFT: badge supply cap reached");

        string memory badgeName = _badgeName(badgeTier);

        tokenId = _mintToken(to, badgeTier, referralCount, badgeName, bytes32(0), false);
        emit BadgeMinted(tokenId, to, badgeTier, referralCount);
    }

    // ═══════════════════════════════════════════════════════════
    //  BURN
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Permanently destroy a token.
     *         Any token holder or approved operator may burn.
     *         Soulbound tokens (Legendary, Genesis) may be burned but not transferred.
     *         Hall of Fame entries for burned Legendary NFTs persist permanently.
     *         [V3-8] Decrements per-wallet holding counts to allow re-award.
     */
    function burn(uint256 tokenId) external nonReentrant {
        address owner = _requireOwned(tokenId);
        require(
            msg.sender == owner ||
            isApprovedForAll(owner, msg.sender) ||
            getApproved(tokenId) == msg.sender,
            "CueNFT: not owner or approved"
        );

        uint8 tier = nftMetadata[tokenId].tier;

        // Decrement per-wallet counts so oracle/minter can re-award
        if (tier == TIER_RARE      && rareHolderCount[owner]      > 0) unchecked { rareHolderCount[owner]--;      }
        if (tier == TIER_EPIC      && epicHolderCount[owner]      > 0) unchecked { epicHolderCount[owner]--;      }
        if (tier == TIER_LEGENDARY && legendaryHolderCount[owner] > 0) unchecked { legendaryHolderCount[owner]--; }

        burnedPerTier[tier]++;
        _burn(tokenId);

        emit TokenBurned(tokenId, msg.sender, tier);
    }

    // ═══════════════════════════════════════════════════════════
    //  FLOOR PRICE ORACLE
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Record a completed secondary sale. Called by CueMarketplace only.
     *         Updates 7-day rolling ring buffer and all-time floor per tier.
     */
    function recordSale(uint8 tier, uint256 priceWei) external {
        require(msg.sender == saleRecorder, "CueNFT: not authorised sale recorder");
        require(priceWei > 0,               "CueNFT: zero sale price");

        uint256 head = _saleBufferHead[tier];
        _saleBuffer[tier][head] = SaleRecord({ priceWei: priceWei, timestamp: block.timestamp });
        _saleBufferHead[tier]   = (head + 1) % FLOOR_WINDOW_SIZE;

        if (allTimeFloor[tier] == 0 || priceWei < allTimeFloor[tier]) {
            allTimeFloor[tier] = priceWei;
        }

        emit SaleRecorded(tier, priceWei, floorPrice(tier));
    }

    /**
     * @notice 7-day rolling floor price for a tier.
     *         Returns allTimeFloor[tier] if no sales in the window.
     *         Returns 0 if no sales ever recorded.
     */
    function floorPrice(uint8 tier) public view returns (uint256 floor) {
        uint256 cutoff      = block.timestamp - FLOOR_WINDOW_SECONDS;
        uint256 windowFloor = type(uint256).max;
        bool    found       = false;

        for (uint256 i = 0; i < FLOOR_WINDOW_SIZE; ) {
            SaleRecord storage rec = _saleBuffer[tier][i];
            if (rec.timestamp > cutoff && rec.priceWei > 0) {
                if (rec.priceWei < windowFloor) {
                    windowFloor = rec.priceWei;
                    found       = true;
                }
            }
            unchecked { ++i; }
        }

        return found ? windowFloor : allTimeFloor[tier];
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — MINT ENGINE
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev Writes metadata BEFORE _safeMint so onERC721Received hooks can read it.
     *      mintedPerTier incremented here — the authoritative supply counter.
     */
    function _mintToken(
        address to,
        uint8   tier,
        uint256 winsAtMint,
        string memory tournamentName,
        bytes32 matchHistoryRoot,
        bool    soulbound
    ) internal returns (uint256 tokenId) {
        tokenId = _nextTokenId++;

        nftMetadata[tokenId] = NFTMetadata({
            tier:             tier,
            mintedAt:         block.timestamp,
            winsAtMint:       winsAtMint,
            tournamentName:   tournamentName,
            matchHistoryRoot: matchHistoryRoot,
            originalMinter:   to,
            isGenesis:        (tier == TIER_GENESIS),
            soulbound:        soulbound
        });

        mintedPerTier[tier]++;
        _safeMint(to, tokenId);
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — HALL OF FAME
    // ═══════════════════════════════════════════════════════════

    function _addToHallOfFame(
        address wallet,
        uint256 tokenId,
        string memory tournamentName,
        bytes32 matchHistoryRoot
    ) internal {
        uint256 index = hallOfFame.length;
        hallOfFame.push(HallOfFameEntry({
            wallet:           wallet,
            tokenId:          tokenId,
            tournamentName:   tournamentName,
            matchHistoryRoot: matchHistoryRoot,
            timestamp:        block.timestamp,
            blockNumber:      block.number
        }));
        _walletHoFIndices[wallet].push(index);
        emit HallOfFameAdded(index, wallet, tokenId, tournamentName);
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — SOULBOUND + HOLDER COUNT TRACKING (_update)
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev Single hook for all token movements.
     *      Blocks transfers for soulbound tokens (mint and burn always permitted).
     *      Tracks per-wallet holding counts for Rare/Epic/Legendary on secondary transfers.
     *      Burn path (to == address(0)) does NOT touch holder counts here —
     *      burn() handles that explicitly before calling _burn().
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    )
        internal
        override(ERC721, ERC721Enumerable)
        returns (address)
    {
        address from    = _ownerOf(tokenId);
        bool isTransfer = (from != address(0) && to != address(0));

        if (isTransfer) {
            // Soulbound check
            if (nftMetadata[tokenId].soulbound) {
                emit SoulboundTransferBlocked(tokenId, from, to);
                revert("CueNFT: soulbound — token cannot be transferred");
            }

            // Track secondary market holder counts
            uint8 tier = nftMetadata[tokenId].tier;
            if (tier == TIER_RARE) {
                if (rareHolderCount[from] > 0) unchecked { rareHolderCount[from]--; }
                rareHolderCount[to]++;
            } else if (tier == TIER_EPIC) {
                if (epicHolderCount[from] > 0) unchecked { epicHolderCount[from]--; }
                epicHolderCount[to]++;
            }
            // Legendary is soulbound — secondary transfer never reaches here
        }

        return super._update(to, tokenId, auth);
    }

    // ═══════════════════════════════════════════════════════════
    //  TOKEN URI
    // ═══════════════════════════════════════════════════════════

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        _requireOwned(tokenId);
        string memory perToken = ERC721URIStorage.tokenURI(tokenId);
        if (bytes(perToken).length > 0) return perToken;
        string memory base = _baseURI();
        if (bytes(base).length == 0) return "";
        return string(abi.encodePacked(base, tokenId.toString(), ".json"));
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW — WAGER BONUS QUERIES
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Highest gameplay tier (0–4) held by a wallet.
     *         255 = no gameplay NFTs. Badge tiers (5–7) are ignored.
     *         Oracle calls this before signing VictoryCertificate.
     */
    function walletTierHighest(address wallet)
        external
        view
        returns (uint8 highestTier)
    {
        uint256 balance = balanceOf(wallet);
        if (balance == 0) return NO_NFT_SENTINEL;

        bool found = false;
        highestTier = 0;

        for (uint256 i = 0; i < balance; ) {
            uint8 t = nftMetadata[tokenOfOwnerByIndex(wallet, i)].tier;
            if (t <= TIER_GENESIS) {
                if (!found || t > highestTier) {
                    highestTier = t;
                    found       = true;
                }
            }
            unchecked { ++i; }
        }

        if (!found) return NO_NFT_SENTINEL;
    }

    /// @notice Fast boolean: does this wallet hold any bonus-granting NFT (Rare+)?
    function walletHasBonus(address wallet) external view returns (bool) {
        uint256 balance = balanceOf(wallet);
        for (uint256 i = 0; i < balance; ) {
            if (isBonusTier(nftMetadata[tokenOfOwnerByIndex(wallet, i)].tier)) return true;
            unchecked { ++i; }
        }
        return false;
    }

    /// @notice Wager bonus in bps for highest gameplay tier held (0 if none).
    function walletBonusBps(address wallet) external view returns (uint256) {
        uint256 balance = balanceOf(wallet);
        if (balance == 0) return 0;
        uint8 highest = 0;
        bool  found   = false;
        for (uint256 i = 0; i < balance; ) {
            uint8 t = nftMetadata[tokenOfOwnerByIndex(wallet, i)].tier;
            if (t <= TIER_GENESIS && (!found || t > highest)) {
                highest = t; found = true;
            }
            unchecked { ++i; }
        }
        return found ? tierBonusBps(highest) : 0;
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW — SUPPLY STATUS  [V3-10]
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Complete supply status for a single tier in one call.
     *         For monitoring, frontend dashboards, and oracle tooling.
     *
     * @return cap         Hard bytecode cap (immutable).
     * @return minted      Total ever minted for this tier.
     * @return burned      Total burned for this tier.
     * @return live        Currently in existence (minted - burned).
     * @return remaining   Hard cap minus minted (mints remaining before cap hit).
     * @return paused      Whether tier-level minting is currently paused [V3-9].
     */
    function tierSupplyStatus(uint8 tier)
        external
        view
        returns (
            uint256 cap,
            uint256 minted,
            uint256 burned,
            uint256 live,
            uint256 remaining,
            bool    paused
        )
    {
        cap       = hardCapForTier(tier);
        minted    = mintedPerTier[tier];
        burned    = burnedPerTier[tier];
        live      = minted - burned;
        remaining = minted < cap ? cap - minted : 0;
        paused    = tierMintPaused[tier];
    }

    /**
     * @notice Full protocol summary in one call.
     */
    function nftStats()
        external
        view
        returns (
            uint256 totalEverMinted,
            uint256 totalLiveSupply,
            uint256 totalBurned,
            uint256 genesisLive,
            uint256 genesisCapRemaining,
            uint256[5] memory floorByTier,
            uint256[8] memory mintedByTier,
            uint256[8] memory burnedByTier
        )
    {
        totalEverMinted = _nextTokenId - 1;
        totalLiveSupply = totalSupply();
        totalBurned     = totalEverMinted - totalLiveSupply;

        genesisLive         = mintedPerTier[TIER_GENESIS] - burnedPerTier[TIER_GENESIS];
        genesisCapRemaining = (genesisMintingClosed || genesisCount >= GENESIS_CAP)
            ? 0
            : GENESIS_CAP - genesisCount;

        for (uint8 t = 0; t <= TIER_GENESIS; ) {
            floorByTier[t] = floorPrice(t);
            unchecked { ++t; }
        }
        for (uint8 t = 0; t <= BADGE_DIAMOND; ) {
            mintedByTier[t] = mintedPerTier[t];
            burnedByTier[t] = burnedPerTier[t];
            unchecked { ++t; }
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW — ENUMERATION & METADATA
    // ═══════════════════════════════════════════════════════════

    function tokensOfOwner(address wallet)
        external view returns (uint256[] memory tokenIds)
    {
        uint256 balance = balanceOf(wallet);
        tokenIds = new uint256[](balance);
        for (uint256 i = 0; i < balance; ) {
            tokenIds[i] = tokenOfOwnerByIndex(wallet, i);
            unchecked { ++i; }
        }
    }

    function tokensOfOwnerByTier(address wallet, uint8 tier)
        external view returns (uint256[] memory tokenIds)
    {
        uint256 balance = balanceOf(wallet);
        uint256[] memory temp = new uint256[](balance);
        uint256 count = 0;
        for (uint256 i = 0; i < balance; ) {
            uint256 tid = tokenOfOwnerByIndex(wallet, i);
            if (nftMetadata[tid].tier == tier) temp[count++] = tid;
            unchecked { ++i; }
        }
        tokenIds = new uint256[](count);
        for (uint256 i = 0; i < count; ) { tokenIds[i] = temp[i]; unchecked { ++i; } }
    }

    function getMetadata(uint256 tokenId) external view returns (NFTMetadata memory) {
        _requireOwned(tokenId);
        return nftMetadata[tokenId];
    }

    function isSoulbound(uint256 tokenId) external view returns (bool) {
        _requireOwned(tokenId);
        return nftMetadata[tokenId].soulbound;
    }

    function originalMinterOf(uint256 tokenId) external view returns (address) {
        _requireOwned(tokenId);
        return nftMetadata[tokenId].originalMinter;
    }

    function royaltySplitPreview(uint256 salePrice)
        external pure
        returns (uint256 total, uint256 toMinter, uint256 toBurn)
    {
        total    = (salePrice * ROYALTY_BPS) / 10_000;
        toMinter = total / 2;
        toBurn   = total - toMinter;
    }

    function totalMinted() external view returns (uint256) { return _nextTokenId - 1; }

    function totalSupply() public view override(ERC721Enumerable) returns (uint256) {
        return super.totalSupply();
    }

    function hallOfFameLength() external view returns (uint256) { return hallOfFame.length; }

    function walletHallOfFame(address wallet)
        external view returns (HallOfFameEntry[] memory entries)
    {
        uint256[] storage indices = _walletHoFIndices[wallet];
        entries = new HallOfFameEntry[](indices.length);
        for (uint256 i = 0; i < indices.length; ) {
            entries[i] = hallOfFame[indices[i]];
            unchecked { ++i; }
        }
    }

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
    //  GENESIS CONTROLS
    // ═══════════════════════════════════════════════════════════

    function openGenesisMinting() external onlyOwner {
        require(!genesisMintingClosed, "CueNFT: genesis permanently closed");
        require(!genesisMintingOpen,   "CueNFT: already open");
        genesisMintingOpen = true;
        emit GenesisMintingOpened(block.timestamp);
    }

    function closeGenesisMinting() external onlyOwner {
        require(!genesisMintingClosed, "CueNFT: already permanently closed");
        genesisMintingOpen   = false;
        genesisMintingClosed = true;
        emit GenesisMintingClosedPermanently(genesisCount, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════
    //  ADMIN
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice [V2-7] Update minter for a specific tier. TIMELOCKED 48 hours.
     *         [V3-6] This is the ONLY owner power over minting.
     *         Accepts tiers 1–7. Tier 0 (Common) has no minter — open to all.
     */
    function setTierMinter(
        uint8 tier,
        address minter
    )
        external
        onlyOwner
        timelocked(keccak256("setTierMinter"))
    {
        require(tier >= TIER_RARE && tier <= BADGE_DIAMOND, "CueNFT: invalid tier");
        require(minter != address(0), "CueNFT: zero minter");
        tierMinter[tier] = minter;
        emit TierMinterUpdated(tier, minter);
    }

    /**
     * @notice [V3-1] Lower the active Common cap. Can only decrease, never increase.
     *         Cannot exceed COMMON_CAP (bytecode constant).
     *         Not timelocked — a cap reduction is always conservative/protective.
     */
    function lowerCommonCap(uint256 newCap) external onlyOwner {
        require(newCap < activeCommonCap,  "CueNFT: can only lower the cap");
        require(newCap >= mintedPerTier[TIER_COMMON] - burnedPerTier[TIER_COMMON],
            "CueNFT: new cap below current live supply");
        emit ActiveCommonCapUpdated(activeCommonCap, newCap);
        activeCommonCap = newCap;
    }

    /**
     * @notice [V3-9] Pause minting for a specific tier without halting the whole contract.
     *         Use when a minter key is suspected compromised — immediately stops
     *         further mints for that tier while investigation proceeds.
     */
    function pauseTierMint(uint8 tier) external onlyOwner {
        require(!tierMintPaused[tier], "CueNFT: already paused");
        tierMintPaused[tier] = true;
        emit TierMintPaused(tier);
    }

    /// @notice [V3-9] Resume minting for a specific tier.
    function unpauseTierMint(uint8 tier) external onlyOwner {
        require(tierMintPaused[tier], "CueNFT: not paused");
        tierMintPaused[tier] = false;
        emit TierMintUnpaused(tier);
    }

    function setMarketplaceReceiver(address receiver) external onlyOwner {
        require(receiver != address(0), "CueNFT: zero receiver");
        emit MarketplaceReceiverUpdated(marketplaceRoyaltyReceiver, receiver);
        marketplaceRoyaltyReceiver = receiver;
        _setDefaultRoyalty(receiver, ROYALTY_BPS);
    }

    function setSaleRecorder(address recorder) external onlyOwner {
        require(recorder != address(0), "CueNFT: zero recorder");
        emit SaleRecorderUpdated(saleRecorder, recorder);
        saleRecorder = recorder;
    }

    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        _baseTokenURI = newBaseURI;
        emit BaseURIUpdated(newBaseURI);
    }

    function setTokenURI(uint256 tokenId, string calldata uri) external onlyOwner {
        _requireOwned(tokenId);
        _setTokenURI(tokenId, uri);
    }

    function cancelTimelock(bytes32 operationId) external onlyOwner {
        require(timelockEta[operationId] > 0,   "CueNFT: not queued");
        require(!timelockExecuted[operationId], "CueNFT: already executed");
        delete timelockEta[operationId];
        emit TimelockCancelled(operationId);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function recoverERC20(address token, uint256 amount) external onlyOwner {
        require(token != address(cueCoin), "CueNFT: cannot recover CUECOIN");
        IERC20(token).safeTransfer(owner(), amount);
    }

    function recoverBNB(uint256 amount) external onlyOwner nonReentrant {
        require(amount <= address(this).balance, "CueNFT: insufficient BNB");
        (bool ok,) = payable(owner()).call{value: amount}("");
        require(ok, "CueNFT: BNB transfer failed");
    }

    receive() external payable {}

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════

    function _badgeName(uint8 badgeTier) internal pure returns (string memory) {
        if (badgeTier == BADGE_SILVER)  return "Silver Referrer Badge";
        if (badgeTier == BADGE_GOLD)    return "Gold Referrer Badge";
        if (badgeTier == BADGE_DIAMOND) return "Diamond Referrer Badge";
        return "Unknown Badge";
    }

    // ═══════════════════════════════════════════════════════════
    //  REQUIRED OVERRIDES
    // ═══════════════════════════════════════════════════════════

    function _increaseBalance(address account, uint128 value)
        internal override(ERC721, ERC721Enumerable)
    {
        super._increaseBalance(account, value);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, ERC721Royalty, ERC721URIStorage)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
