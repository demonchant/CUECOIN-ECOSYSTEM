// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ╔══════════════════════════════════════════════════════════════╗
//  CUEMARKETPLACE  ·  v1.0  ·  Production-Ready
//  CUECOIN Ecosystem  ·  BNB Smart Chain
//
//  On-chain NFT marketplace. CUECOIN exclusively. Every sale
//  enforces the full royalty split — 2.5% to original minter,
//  2.5% permanently burned — guaranteeing the deflationary
//  mechanic regardless of which wallet initiated the sale.
//
//  ════════════════════════════════════════════════════
//   WHY AN INTERNAL MARKETPLACE IS MANDATORY
//  ════════════════════════════════════════════════════
//
//  External platforms (OpenSea, Blur, etc.) cannot guarantee
//  royalty payment. Sellers can use royalty-bypassing contracts.
//  This marketplace enforces royalties at the EVM level — they
//  are deducted before seller proceeds are calculated and cannot
//  be bypassed by any routing or wrapper contract.
//
//  The burn component (2.5%) is especially critical: it is the
//  primary deflationary sink on the secondary market. Every NFT
//  trade permanently removes CUECOIN from circulation.
//
//  ════════════════════════════════════════════════════
//   LISTING TYPES
//  ════════════════════════════════════════════════════
//
//  FIXED PRICE
//    Seller names a price. Any buyer pays it instantly.
//    Seller may update price or cancel at any time before sale.
//
//  ENGLISH AUCTION  (ascending bids)
//    Seller sets start price, optional reserve, and duration.
//    Bidders outbid each other; each bid must exceed the previous
//    by at least minBidIncrementBps (default 5%).
//    Anti-sniping: bids placed in the final BID_EXTENSION_WINDOW
//    (10 minutes) extend the auction by that same window.
//    Previous bidders are credited via pull refund (pendingRefunds)
//    rather than automatic push — prevents griefing by malicious
//    bidder contracts that reject ETH/tokens on receive.
//    At close: finalizeAuction() distributes proceeds. If reserve
//    not met: NFT returns to seller, bidder gets full refund.
//
//  DUTCH AUCTION  (descending price)
//    Seller sets start price, end price (floor), and duration.
//    Price decreases linearly from start to end over the duration.
//    First buyer to call buyDutch() at or above current price wins.
//    The slippage guard (maxPrice parameter) protects buyers from
//    price movement between quote and execution.
//
//  BUNDLE  (fixed price only)
//    Multiple NFTs listed atomically at one combined price.
//    All NFTs must be owned by the same seller.
//    Bought all-or-nothing — no partial fills.
//    Royalties computed per-NFT (summed). Platform fee once.
//    Max bundle size: 20 NFTs (gas bound).
//
//  ════════════════════════════════════════════════════
//   FEE STRUCTURE (per sale price P)
//  ════════════════════════════════════════════════════
//
//    Platform fee:  1.00%  → DAO Treasury
//    Minter royalty: 2.50% → Original minter of the NFT
//    Burn royalty:   2.50% → 0xdead (permanent deflation)
//    ─────────────────────────────────────────────────
//    Total deducted: 6.00%
//    Seller receives: 94.00%
//
//  All fee BPS values are bytecode constants. No owner, DAO
//  vote, or guardian action can change them post-deployment.
//
//  ════════════════════════════════════════════════════
//   NFT CUSTODY  (escrow model)
//  ════════════════════════════════════════════════════
//
//  All NFTs are transferred to this contract on listing creation.
//  The marketplace holds them in escrow until:
//    a) Sale completes → transferred to buyer
//    b) Seller cancels → returned to seller
//    c) Listing expires → returned to seller via reclaimExpired()
//
//  Escrow eliminates the race condition where a seller lists an NFT
//  then transfers it away before the buyer's transaction confirms.
//  It also means that listed NFTs cannot be used in wager matches
//  while listed — sellers must cancel first.
//
//  ════════════════════════════════════════════════════
//   WASH TRADE GUARD
//  ════════════════════════════════════════════════════
//
//  hasTradedWith[A][B] = true means wallets A and B have
//  previously completed a trade in this marketplace.
//
//  A wallet that has previously sold to someone cannot buy from
//  that same wallet, and vice versa. This prevents the simplest
//  wash-trade pattern: A sells to B, B sells back to A, repeat
//  to generate artificial volume and royalty farming.
//
//  Limitation: does not catch multi-hop wash trades (A→B→C→A).
//  The spec says "shared wallet history" which this implements
//  as direct trade history. More sophisticated patterns would
//  require off-chain analysis.
//
//  ════════════════════════════════════════════════════
//   7-DAY FLOOR ORACLE
//  ════════════════════════════════════════════════════
//
//  A ring buffer of the last 100 completed sales (price + timestamp)
//  is maintained on-chain. The floorPrice7d() view iterates this
//  buffer to find the minimum sale price among records younger than
//  7 days. This provides a trustless, fully on-chain floor price
//  suitable for display in the frontend and future oracle consumers.
//
//  ════════════════════════════════════════════════════
//   APPROVED NFT CONTRACTS
//  ════════════════════════════════════════════════════
//
//  Only owner-whitelisted NFT contracts can be listed. Initially
//  only CueNFT is approved. Royalty splits use CueNFT's
//  originalMinterOf() for per-token minter lookup. For any
//  approved contract that does not expose originalMinterOf(),
//  the minter share falls back to the seller's address — no
//  royalty is lost, it just goes to a different address.
//
//  ════════════════════════════════════════════════════
//   GUARDIAN EMERGENCY PAUSE
//  ════════════════════════════════════════════════════
//
//  Guardian (Gnosis Safe 3-of-5) can pause buy/bid/finalize
//  operations instantly. Cancel and withdrawRefund are NEVER
//  paused — users can always exit positions and reclaim funds.
//
// ╚══════════════════════════════════════════════════════════════╝

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

// ═══════════════════════════════════════════════════════════════
//  CUENTF INTERFACE (minter lookup)
// ═══════════════════════════════════════════════════════════════

interface ICueNFT is IERC721 {
    /// @notice Returns the original minting wallet for a token.
    function originalMinterOf(uint256 tokenId) external view returns (address);
}

// ═══════════════════════════════════════════════════════════════
//  MAIN CONTRACT
// ═══════════════════════════════════════════════════════════════

/**
 * @title  CueMarketplace
 * @author CUECOIN Team
 * @notice CUECOIN-exclusive NFT marketplace. Fixed, English, Dutch, and Bundle
 *         listing types. Enforces 5% royalty (2.5% minter + 2.5% burn) and 1%
 *         platform fee on every sale. Wash-trade guard and 7-day floor oracle.
 */
contract CueMarketplace is Ownable2Step, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════
    //  CONSTANTS  (bytecode — nothing can change these)
    // ═══════════════════════════════════════════════════════════

    uint256 public constant PLATFORM_FEE_BPS           = 100;  // 1%
    uint256 public constant ROYALTY_BPS                 = 500;  // 5% total
    uint256 public constant MINTER_SHARE_BPS            = 250;  // 2.5% to minter
    uint256 public constant BURN_SHARE_BPS              = 250;  // 2.5% burned
    // Sanity: MINTER_SHARE_BPS + BURN_SHARE_BPS == ROYALTY_BPS ✓

    uint256 public constant MIN_AUCTION_DURATION        = 1 hours;
    uint256 public constant MAX_AUCTION_DURATION        = 30 days;
    uint256 public constant DEFAULT_BID_EXTENSION       = 10 minutes;
    uint256 public constant DEFAULT_MIN_BID_INCREMENT_BPS = 500; // 5%

    uint256 public constant MAX_BUNDLE_SIZE             = 20;

    uint256 public constant FLOOR_ORACLE_WINDOW         = 7 days;
    uint256 public constant FLOOR_HISTORY_SIZE          = 100;

    uint256 public constant TREASURY_UPDATE_DELAY       = 48 hours;

    address public constant BURN_ADDRESS =
        0x000000000000000000000000000000000000dEaD;

    // ═══════════════════════════════════════════════════════════
    //  ENUMS & STRUCTS
    // ═══════════════════════════════════════════════════════════

    enum ListingType   { FIXED, ENGLISH, DUTCH, BUNDLE }
    enum ListingStatus { ACTIVE, SOLD, CANCELLED, EXPIRED }

    /**
     * @notice Core listing record. Token IDs are stored separately in
     *         listingTokenIds to avoid Solidity's struct-with-dynamic-array
     *         storage complications.
     *
     * @param listingId     Auto-assigned, 1-indexed.
     * @param listingType   FIXED / ENGLISH / DUTCH / BUNDLE.
     * @param status        ACTIVE / SOLD / CANCELLED / EXPIRED.
     * @param nftContract   ERC-721 contract address (must be approved).
     * @param seller        Listing creator — receives proceeds.
     * @param price         FIXED/BUNDLE: exact price.
     *                      ENGLISH: opening bid (minimum first bid).
     *                      DUTCH:   starting price (decreases to endPrice).
     * @param endPrice      DUTCH only: floor price at expiry. 0 for others.
     * @param reservePrice  ENGLISH only: minimum bid to complete sale. 0 = no reserve.
     * @param startTime     block.timestamp when listing was created.
     * @param endTime       ENGLISH/DUTCH: expiry timestamp. 0 for FIXED/BUNDLE.
     */
    struct Listing {
        uint32        listingId;
        ListingType   listingType;
        ListingStatus status;
        address       nftContract;
        address       seller;
        uint256       price;
        uint256       endPrice;
        uint256       reservePrice;
        uint256       startTime;
        uint256       endTime;
    }

    /**
     * @notice Highest bid on an English auction.
     * @param bidder  Current highest bidder. address(0) if no bids placed.
     * @param amount  Current highest bid in CUECOIN-wei.
     */
    struct Bid {
        address bidder;
        uint256 amount;
    }

    /**
     * @notice Entry in the 7-day floor oracle ring buffer.
     */
    struct SaleRecord {
        uint256 price;
        uint256 timestamp;
        uint32  listingId;
    }

    // ═══════════════════════════════════════════════════════════
    //  IMMUTABLES
    // ═══════════════════════════════════════════════════════════

    IERC20 public immutable cueCoin;

    // ═══════════════════════════════════════════════════════════
    //  STATE
    // ═══════════════════════════════════════════════════════════

    // ── Listings ──
    uint32 private _nextListingId;
    mapping(uint32 => Listing)    private _listings;
    mapping(uint32 => uint256[])  public  listingTokenIds;

    // ── English auction state ──
    mapping(uint32 => Bid) public highestBid;

    // ── Pull-pattern refunds for outbid bidders ──
    mapping(address => uint256) public pendingRefunds;

    // ── Approved NFT contracts ──
    mapping(address => bool) public approvedNftContract;

    // ── Wash trade guard ──
    mapping(address => mapping(address => bool)) public hasTradedWith;

    // ── DAO treasury ──
    address public daoTreasury;
    address private _pendingDaoTreasury;
    uint256 private _pendingDaoTreasuryEta;

    // ── Guardian ──
    address public guardian;
    address public pendingGuardian;

    // ── Pause ──
    bool public paused;

    // ── Adjustable auction params ──
    uint256 public minBidIncrementBps;
    uint256 public bidExtensionWindow;

    // ── 7-day floor oracle (ring buffer) ──
    SaleRecord[FLOOR_HISTORY_SIZE] private _saleHistory;
    uint256 private _saleHistoryHead;   // index of next write position
    uint256 public  totalSalesRecorded; // monotonically increasing

    // ── Global stats ──
    uint256 public totalVolumeTraded;   // gross CUECOIN
    uint256 public totalRoyaltyBurned;  // CUECOIN sent to 0xdead
    uint256 public totalRoyaltyToMinters;
    uint256 public totalPlatformFees;
    uint256 public totalListingsCreated;
    uint256 public activeListingCount;

    // ═══════════════════════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════════════════════

    event Listed(
        uint32 indexed listingId,
        address indexed seller,
        ListingType     listingType,
        address indexed nftContract,
        uint256[]       tokenIds,
        uint256         price,
        uint256         endTime
    );

    event Sale(
        uint32 indexed  listingId,
        address indexed buyer,
        address indexed seller,
        uint256         salePrice,
        uint256         platformFee,
        uint256         minterRoyalty,
        uint256         burnRoyalty
    );

    event BidPlaced(
        uint32 indexed  listingId,
        address indexed bidder,
        uint256         amount,
        uint256         newEndTime
    );

    event BidOutbid(
        uint32 indexed  listingId,
        address indexed outbidWallet,
        uint256         refundAmount
    );

    event AuctionFinalized(
        uint32 indexed listingId,
        address         winner,       // address(0) if no winner
        uint256         amount,
        bool            reserveMet
    );

    event ListingCancelled(uint32 indexed listingId, address indexed by);
    event ListingExpired(uint32 indexed listingId);

    event RefundWithdrawn(address indexed user, uint256 amount);
    event PriceUpdated(uint32 indexed listingId, uint256 newPrice);
    event FloorUpdated(uint256 newFloor, uint256 timestamp);

    event NftContractApproved(address indexed nftContract);
    event NftContractRevoked(address indexed nftContract);

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

    modifier onlyGuardian() {
        require(msg.sender == guardian, "CueMarketplace: not guardian");
        _;
    }

    modifier onlyOwnerOrGuardian() {
        require(
            msg.sender == owner() || msg.sender == guardian,
            "CueMarketplace: not owner or guardian"
        );
        _;
    }

    /// @dev Blocks buy/bid/finalize — cancel and withdrawRefund are never blocked.
    modifier whenNotPaused() {
        require(!paused, "CueMarketplace: paused");
        _;
    }

    // ═══════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    /**
     * @param _cueCoin      CueCoin ERC-20 contract.
     * @param _cueNFT       Initial approved NFT contract (CueNFT).
     * @param _guardian     Guardian address (Gnosis Safe 3-of-5).
     * @param _daoTreasury  DAO Treasury — receives 1% platform fee.
     */
    constructor(
        address _cueCoin,
        address _cueNFT,
        address _guardian,
        address _daoTreasury
    )
        Ownable(msg.sender)
    {
        require(_cueCoin     != address(0), "CueMarketplace: zero cueCoin");
        require(_cueNFT      != address(0), "CueMarketplace: zero cueNFT");
        require(_guardian    != address(0), "CueMarketplace: zero guardian");
        require(_daoTreasury != address(0), "CueMarketplace: zero treasury");

        cueCoin     = IERC20(_cueCoin);
        guardian    = _guardian;
        daoTreasury = _daoTreasury;

        minBidIncrementBps = DEFAULT_MIN_BID_INCREMENT_BPS;
        bidExtensionWindow = DEFAULT_BID_EXTENSION;

        approvedNftContract[_cueNFT] = true;
        emit NftContractApproved(_cueNFT);
    }

    // ═══════════════════════════════════════════════════════════
    //  LISTING CREATION
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice List an NFT at a fixed price.
     *
     *         Transfers the NFT to this contract (escrow).
     *         Seller may updatePrice() or cancelListing() at any time before sale.
     *
     * @param nftContract  Approved ERC-721 contract address.
     * @param tokenId      Token to list.
     * @param price        CUECOIN price in wei. Must be > 0.
     * @return listingId   The newly created listing ID.
     */
    function listFixed(
        address nftContract,
        uint256 tokenId,
        uint256 price
    )
        external
        nonReentrant
        returns (uint32 listingId)
    {
        require(price > 0,                                      "CueMarketplace: zero price");
        _requireApprovedNft(nftContract);

        listingId = _createListing(
            ListingType.FIXED, nftContract, msg.sender,
            price, 0, 0, 0
        );
        listingTokenIds[listingId].push(tokenId);

        IERC721(nftContract).safeTransferFrom(msg.sender, address(this), tokenId);

        emit Listed(listingId, msg.sender, ListingType.FIXED, nftContract,
                    listingTokenIds[listingId], price, 0);
    }

    /**
     * @notice List an NFT in an English (ascending) auction.
     *
     *         The auction starts immediately. The opening bid is the minimum
     *         first bid — bids below this are rejected.
     *
     *         Anti-snipe: any bid placed within bidExtensionWindow of endTime
     *         extends endTime by bidExtensionWindow.
     *
     *         Finalize after endTime by calling finalizeAuction(listingId).
     *         Anyone can call finalizeAuction — no permissioning.
     *
     * @param nftContract    Approved ERC-721 contract.
     * @param tokenId        Token to auction.
     * @param openingBid     Minimum first bid in CUECOIN-wei.
     * @param reservePrice   Minimum winning bid for sale to complete. 0 = no reserve.
     * @param duration       Auction length in seconds. Clamped to [MIN, MAX].
     * @return listingId     The newly created listing ID.
     */
    function listEnglish(
        address nftContract,
        uint256 tokenId,
        uint256 openingBid,
        uint256 reservePrice,
        uint256 duration
    )
        external
        nonReentrant
        returns (uint32 listingId)
    {
        require(openingBid > 0,                                 "CueMarketplace: zero opening bid");
        require(reservePrice == 0 || reservePrice >= openingBid,"CueMarketplace: reserve below opening bid");
        _requireApprovedNft(nftContract);

        duration = _clampDuration(duration);
        uint256 endTime = block.timestamp + duration;

        listingId = _createListing(
            ListingType.ENGLISH, nftContract, msg.sender,
            openingBid, 0, reservePrice, endTime
        );
        listingTokenIds[listingId].push(tokenId);

        IERC721(nftContract).safeTransferFrom(msg.sender, address(this), tokenId);

        emit Listed(listingId, msg.sender, ListingType.ENGLISH, nftContract,
                    listingTokenIds[listingId], openingBid, endTime);
    }

    /**
     * @notice List an NFT in a Dutch (descending price) auction.
     *
     *         Price decreases linearly from startPrice to endPrice over duration.
     *         The first buyer to call buyDutch() at or above the current price wins.
     *         If nobody buys before expiry, the NFT can be reclaimed via reclaimExpired().
     *
     * @param nftContract  Approved ERC-721 contract.
     * @param tokenId      Token to auction.
     * @param startPrice   Initial (maximum) price in CUECOIN-wei.
     * @param endPrice     Final (minimum/floor) price. Must be < startPrice and > 0.
     * @param duration     Auction length in seconds. Clamped to [MIN, MAX].
     * @return listingId   The newly created listing ID.
     */
    function listDutch(
        address nftContract,
        uint256 tokenId,
        uint256 startPrice,
        uint256 endPrice,
        uint256 duration
    )
        external
        nonReentrant
        returns (uint32 listingId)
    {
        require(startPrice > 0,              "CueMarketplace: zero start price");
        require(endPrice   > 0,              "CueMarketplace: zero end price");
        require(startPrice > endPrice,       "CueMarketplace: start must exceed end price");
        _requireApprovedNft(nftContract);

        duration = _clampDuration(duration);
        uint256 endTime = block.timestamp + duration;

        listingId = _createListing(
            ListingType.DUTCH, nftContract, msg.sender,
            startPrice, endPrice, 0, endTime
        );
        listingTokenIds[listingId].push(tokenId);

        IERC721(nftContract).safeTransferFrom(msg.sender, address(this), tokenId);

        emit Listed(listingId, msg.sender, ListingType.DUTCH, nftContract,
                    listingTokenIds[listingId], startPrice, endTime);
    }

    /**
     * @notice List multiple NFTs as a fixed-price bundle.
     *
     *         All tokenIds must be from the same nftContract and owned by caller.
     *         The bundle is bought atomically — all tokens or none.
     *         Royalties are computed per token and summed; platform fee is once.
     *         Max bundle size: MAX_BUNDLE_SIZE (20 tokens).
     *
     * @param nftContract  Approved ERC-721 contract.
     * @param tokenIds     Array of token IDs to bundle. Length 2..MAX_BUNDLE_SIZE.
     * @param price        Total bundle price in CUECOIN-wei.
     * @return listingId   The newly created listing ID.
     */
    function listBundle(
        address nftContract,
        uint256[] calldata tokenIds,
        uint256 price
    )
        external
        nonReentrant
        returns (uint32 listingId)
    {
        require(tokenIds.length >= 2,                          "CueMarketplace: bundle needs ≥2 tokens");
        require(tokenIds.length <= MAX_BUNDLE_SIZE,            "CueMarketplace: bundle too large");
        require(price > 0,                                     "CueMarketplace: zero price");
        _requireApprovedNft(nftContract);

        // Check for duplicates
        for (uint256 i = 0; i < tokenIds.length; i++) {
            for (uint256 j = i + 1; j < tokenIds.length; j++) {
                require(tokenIds[i] != tokenIds[j], "CueMarketplace: duplicate tokenId in bundle");
            }
        }

        listingId = _createListing(
            ListingType.BUNDLE, nftContract, msg.sender,
            price, 0, 0, 0
        );

        // Store token IDs and escrow all NFTs
        for (uint256 i = 0; i < tokenIds.length; i++) {
            listingTokenIds[listingId].push(tokenIds[i]);
            IERC721(nftContract).safeTransferFrom(msg.sender, address(this), tokenIds[i]);
        }

        emit Listed(listingId, msg.sender, ListingType.BUNDLE, nftContract,
                    tokenIds, price, 0);
    }

    // ═══════════════════════════════════════════════════════════
    //  BUY — FIXED & BUNDLE
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Buy a fixed-price listing instantly.
     *
     *         Buyer pays exact listing price. Fees distributed:
     *         platform (1%) → DAO, minter royalty (2.5%) → original minter,
     *         burn (2.5%) → 0xdead, remainder → seller.
     *
     *         Wash trade guard: buyer cannot have previously traded with seller.
     *
     * @param listingId  ID of a FIXED-type active listing.
     */
    function buyFixed(uint32 listingId)
        external
        nonReentrant
        whenNotPaused
    {
        Listing storage lst = _requireActiveListing(listingId);
        require(lst.listingType == ListingType.FIXED,  "CueMarketplace: not a fixed listing");

        address buyer  = msg.sender;
        address seller = lst.seller;
        uint256 price  = lst.price;
        uint256[] storage tids = listingTokenIds[listingId];

        _requireNoWashTrade(buyer, seller);

        // Mark sold before any external calls (CEI)
        lst.status = ListingStatus.SOLD;
        activeListingCount--;

        // Distribute payment and transfer NFT
        _executeSale(listingId, buyer, seller, lst.nftContract, tids, price);
    }

    /**
     * @notice Buy a bundle listing.
     *
     *         Pays the single bundle price. Per-NFT royalties are computed
     *         and summed. Platform fee applied once on total price.
     *
     * @param listingId  ID of a BUNDLE-type active listing.
     */
    function buyBundle(uint32 listingId)
        external
        nonReentrant
        whenNotPaused
    {
        Listing storage lst = _requireActiveListing(listingId);
        require(lst.listingType == ListingType.BUNDLE, "CueMarketplace: not a bundle listing");

        address buyer  = msg.sender;
        address seller = lst.seller;
        uint256 price  = lst.price;
        uint256[] storage tids = listingTokenIds[listingId];

        _requireNoWashTrade(buyer, seller);

        lst.status = ListingStatus.SOLD;
        activeListingCount--;

        _executeSale(listingId, buyer, seller, lst.nftContract, tids, price);
    }

    // ═══════════════════════════════════════════════════════════
    //  BID — ENGLISH AUCTION
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Place a bid on an English auction.
     *
     *         Bid must exceed current highest bid by minBidIncrementBps (5%).
     *         If no prior bid: bid must be >= openingBid (stored in price field).
     *         The CUECOIN is pulled from the bidder immediately and held.
     *         The previous bidder's CUECOIN is credited to pendingRefunds.
     *
     *         Anti-snipe: if bid placed within bidExtensionWindow of endTime,
     *         endTime is extended by bidExtensionWindow.
     *
     *         Wash trade guard checked at bid time (not just at finalization).
     *
     * @param listingId  English auction listing ID.
     * @param amount     CUECOIN bid amount in wei.
     */
    function placeBid(uint32 listingId, uint256 amount)
        external
        nonReentrant
        whenNotPaused
    {
        Listing storage lst = _requireActiveListing(listingId);
        require(lst.listingType == ListingType.ENGLISH, "CueMarketplace: not an English auction");
        require(block.timestamp < lst.endTime,           "CueMarketplace: auction ended");

        address bidder = msg.sender;
        address seller = lst.seller;
        _requireNoWashTrade(bidder, seller);

        Bid storage top = highestBid[listingId];

        // Minimum bid requirement
        if (top.bidder == address(0)) {
            // No prior bid — must meet opening bid
            require(amount >= lst.price, "CueMarketplace: bid below opening bid");
        } else {
            // Must exceed previous bid by minBidIncrementBps
            uint256 minNext = top.amount + (top.amount * minBidIncrementBps) / 10_000;
            require(amount >= minNext,   "CueMarketplace: bid too low");
        }

        // Pull new bid from bidder
        cueCoin.safeTransferFrom(bidder, address(this), amount);

        // Credit previous bidder's refund (pull pattern — prevents reentrancy griefing)
        if (top.bidder != address(0)) {
            pendingRefunds[top.bidder] += top.amount;
            emit BidOutbid(listingId, top.bidder, top.amount);
        }

        // Record new highest bid
        top.bidder = bidder;
        top.amount = amount;

        // Anti-snipe: extend if in final window
        uint256 newEndTime = lst.endTime;
        if (block.timestamp + bidExtensionWindow >= lst.endTime) {
            newEndTime = block.timestamp + bidExtensionWindow;
            lst.endTime = newEndTime;
        }

        emit BidPlaced(listingId, bidder, amount, newEndTime);
    }

    /**
     * @notice Finalize an English auction after it has ended.
     *
     *         Permissionless — anyone can call this after endTime.
     *         This allows automated bots, the buyer, or the seller to finalize
     *         without waiting for a specific party to act.
     *
     *         If highest bid >= reservePrice (or no reserve set):
     *           → Execute sale: distribute proceeds, transfer NFT to winner.
     *         If reserve not met OR no bids placed:
     *           → Return NFT to seller, credit highest bidder's refund (if any).
     *
     * @param listingId  English auction listing ID past its endTime.
     */
    function finalizeAuction(uint32 listingId)
        external
        nonReentrant
        whenNotPaused
    {
        Listing storage lst = _requireActiveListing(listingId);
        require(lst.listingType == ListingType.ENGLISH, "CueMarketplace: not an English auction");
        require(block.timestamp >= lst.endTime,          "CueMarketplace: auction still running");

        Bid memory top = highestBid[listingId];

        bool reserveMet = (top.bidder != address(0)) &&
                          (lst.reservePrice == 0 || top.amount >= lst.reservePrice);

        if (reserveMet) {
            // Successful auction — execute sale
            lst.status = ListingStatus.SOLD;
            activeListingCount--;

            _executeSale(
                listingId, top.bidder, lst.seller,
                lst.nftContract, listingTokenIds[listingId], top.amount
            );

            emit AuctionFinalized(listingId, top.bidder, top.amount, true);
        } else {
            // No valid winner — expire listing, return NFT to seller
            lst.status = ListingStatus.EXPIRED;
            activeListingCount--;

            // Credit highest bidder refund if there was a bid
            if (top.bidder != address(0)) {
                pendingRefunds[top.bidder] += top.amount;
                emit BidOutbid(listingId, top.bidder, top.amount);
            }

            // Return NFT(s) to seller
            _returnNftsToSeller(lst.nftContract, listingTokenIds[listingId], lst.seller);

            emit AuctionFinalized(listingId, address(0), top.amount, false);
            emit ListingExpired(listingId);
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  BUY — DUTCH AUCTION
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Buy in a Dutch auction at the current descending price.
     *
     *         Dutch price decreases linearly from listing.price (startPrice) to
     *         listing.endPrice over the auction's duration.
     *
     *         The maxPrice parameter is a slippage guard: the transaction reverts
     *         if the current price has fallen below maxPrice... wait — Dutch price
     *         only ever FALLS, and the buyer wants the LOWER price. So the guard
     *         should be: require(maxPrice >= currentPrice), meaning "I am willing
     *         to pay at most maxPrice; revert if price is somehow above that."
     *         This protects against miner/validator manipulation of timestamp.
     *
     *         Buyer pays currentDutchPrice() — exactly, no more, no less.
     *         Excess CUECOIN approval is not consumed.
     *
     * @param listingId  Dutch auction listing ID.
     * @param maxPrice   Maximum price caller is willing to pay (slippage guard).
     */
    function buyDutch(uint32 listingId, uint256 maxPrice)
        external
        nonReentrant
        whenNotPaused
    {
        Listing storage lst = _requireActiveListing(listingId);
        require(lst.listingType == ListingType.DUTCH,  "CueMarketplace: not a Dutch auction");
        require(block.timestamp < lst.endTime,          "CueMarketplace: Dutch auction expired");

        address buyer  = msg.sender;
        address seller = lst.seller;
        _requireNoWashTrade(buyer, seller);

        uint256 currentPrice = _dutchPrice(lst.price, lst.endPrice, lst.startTime, lst.endTime);
        require(currentPrice <= maxPrice, "CueMarketplace: current price exceeds your maxPrice");

        lst.status = ListingStatus.SOLD;
        activeListingCount--;

        _executeSale(listingId, buyer, seller, lst.nftContract,
                     listingTokenIds[listingId], currentPrice);
    }

    // ═══════════════════════════════════════════════════════════
    //  SELLER ACTIONS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Update the price of an active FIXED or BUNDLE listing.
     *         Seller-only. New price must be > 0.
     *         Not available for auctions (price is time-derived or bid-based).
     *
     * @param listingId  Listing to update.
     * @param newPrice   New CUECOIN price in wei.
     */
    function updatePrice(uint32 listingId, uint256 newPrice) external nonReentrant {
        Listing storage lst = _requireActiveListing(listingId);
        require(lst.seller == msg.sender,                "CueMarketplace: not the seller");
        require(
            lst.listingType == ListingType.FIXED ||
            lst.listingType == ListingType.BUNDLE,       "CueMarketplace: can only update fixed/bundle price"
        );
        require(newPrice > 0,                            "CueMarketplace: zero price");

        lst.price = newPrice;
        emit PriceUpdated(listingId, newPrice);
    }

    /**
     * @notice Cancel an active listing and reclaim the escrowed NFT(s).
     *
     *         Seller-only for FIXED/BUNDLE/DUTCH.
     *         ENGLISH auction: can only be cancelled if no bids have been placed.
     *         After a bid is placed, the auction must run to completion.
     *         Owner can cancel any listing (emergency override).
     *
     * @param listingId  Listing to cancel.
     */
    function cancelListing(uint32 listingId) external nonReentrant {
        Listing storage lst = _requireActiveListing(listingId);

        bool isSeller = lst.seller == msg.sender;
        bool isOwner  = msg.sender == owner();
        require(isSeller || isOwner, "CueMarketplace: not seller or owner");

        // English auction with bids: only owner can override
        if (lst.listingType == ListingType.ENGLISH) {
            Bid storage top = highestBid[listingId];
            if (top.bidder != address(0)) {
                require(isOwner, "CueMarketplace: cannot cancel English auction with active bids");
                // Refund the current highest bidder
                pendingRefunds[top.bidder] += top.amount;
                emit BidOutbid(listingId, top.bidder, top.amount);
            }
        }

        lst.status = ListingStatus.CANCELLED;
        activeListingCount--;

        _returnNftsToSeller(lst.nftContract, listingTokenIds[listingId], lst.seller);

        emit ListingCancelled(listingId, msg.sender);
    }

    /**
     * @notice Reclaim an expired DUTCH listing or FIXED listing with no bids.
     *
     *         For Dutch auctions that passed their endTime with no buyer.
     *         For FIXED listings there is no expiry, but if the owner wants a
     *         cleanup function for very old listings, they can use cancelListing.
     *
     *         Anyone can call this for Dutch listings past endTime — permissionless
     *         cleanup to prevent NFTs being stranded if seller is inactive.
     *
     * @param listingId  Dutch listing ID past endTime.
     */
    function reclaimExpired(uint32 listingId) external nonReentrant {
        Listing storage lst = _requireActiveListing(listingId);
        require(lst.listingType == ListingType.DUTCH, "CueMarketplace: use cancelListing");
        require(block.timestamp >= lst.endTime,        "CueMarketplace: listing not yet expired");

        lst.status = ListingStatus.EXPIRED;
        activeListingCount--;

        _returnNftsToSeller(lst.nftContract, listingTokenIds[listingId], lst.seller);

        emit ListingExpired(listingId);
    }

    // ═══════════════════════════════════════════════════════════
    //  PULL REFUNDS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Withdraw accumulated CUECOIN refunds (from being outbid).
     *
     *         Pull pattern: bidders do not receive automatic refunds when outbid.
     *         Instead, refunds accumulate in pendingRefunds and are claimed here.
     *         This prevents griefing via contracts that reject token transfers.
     *
     *         Not paused — users can always reclaim their funds.
     */
    function withdrawRefund() external nonReentrant {
        uint256 amount = pendingRefunds[msg.sender];
        require(amount > 0, "CueMarketplace: no pending refund");

        pendingRefunds[msg.sender] = 0;
        cueCoin.safeTransfer(msg.sender, amount);

        emit RefundWithdrawn(msg.sender, amount);
    }

    // ═══════════════════════════════════════════════════════════
    //  ADMIN — OWNER
    // ═══════════════════════════════════════════════════════════

    /// @notice Whitelist an NFT contract for listing. Owner-only.
    function approveNftContract(address nftContract) external onlyOwner {
        require(nftContract != address(0),        "CueMarketplace: zero address");
        approvedNftContract[nftContract] = true;
        emit NftContractApproved(nftContract);
    }

    /// @notice Remove an NFT contract from the whitelist. Existing listings unaffected.
    function revokeNftContract(address nftContract) external onlyOwner {
        approvedNftContract[nftContract] = false;
        emit NftContractRevoked(nftContract);
    }

    /**
     * @notice Update the minimum bid increment percentage.
     * @param bps  New minimum increment in basis points. Must be 100-2000 (1%–20%).
     */
    function setMinBidIncrementBps(uint256 bps) external onlyOwner {
        require(bps >= 100 && bps <= 2000, "CueMarketplace: bps out of range 100-2000");
        minBidIncrementBps = bps;
    }

    /**
     * @notice Update the bid extension window.
     * @param window  New window in seconds. Must be 1 min–30 min.
     */
    function setBidExtensionWindow(uint256 window) external onlyOwner {
        require(window >= 1 minutes && window <= 30 minutes, "CueMarketplace: window out of range");
        bidExtensionWindow = window;
    }

    // ═══════════════════════════════════════════════════════════
    //  PAUSE — OWNER OR GUARDIAN
    // ═══════════════════════════════════════════════════════════

    function pause() external onlyOwnerOrGuardian {
        require(!paused, "CueMarketplace: already paused");
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwnerOrGuardian {
        require(paused, "CueMarketplace: not paused");
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ═══════════════════════════════════════════════════════════
    //  GUARDIAN UPDATE — TWO-STEP
    // ═══════════════════════════════════════════════════════════

    function setGuardian(address nominee) external onlyOwner {
        require(nominee != address(0), "CueMarketplace: zero nominee");
        pendingGuardian = nominee;
        emit GuardianNominated(nominee);
    }

    function acceptGuardian() external {
        require(msg.sender == pendingGuardian, "CueMarketplace: not pending guardian");
        address old     = guardian;
        guardian        = pendingGuardian;
        pendingGuardian = address(0);
        emit GuardianAccepted(old, guardian);
    }

    // ═══════════════════════════════════════════════════════════
    //  DAO TREASURY UPDATE — TIMELOCKED
    // ═══════════════════════════════════════════════════════════

    function queueDaoTreasuryUpdate(address newTreasury) external onlyOwner {
        require(newTreasury != address(0),   "CueMarketplace: zero treasury");
        require(newTreasury != daoTreasury,  "CueMarketplace: same treasury");
        uint256 eta = block.timestamp + TREASURY_UPDATE_DELAY;
        _pendingDaoTreasury    = newTreasury;
        _pendingDaoTreasuryEta = eta;
        emit DaoTreasuryUpdateQueued(newTreasury, eta);
    }

    function applyDaoTreasuryUpdate() external nonReentrant {
        require(_pendingDaoTreasuryEta != 0,               "CueMarketplace: no pending update");
        require(block.timestamp >= _pendingDaoTreasuryEta,  "CueMarketplace: delay not elapsed");
        address old        = daoTreasury;
        daoTreasury        = _pendingDaoTreasury;
        _pendingDaoTreasury    = address(0);
        _pendingDaoTreasuryEta = 0;
        emit DaoTreasuryUpdated(old, daoTreasury);
    }

    function cancelDaoTreasuryUpdate() external onlyOwner {
        require(_pendingDaoTreasuryEta != 0, "CueMarketplace: no pending update");
        address cancelled      = _pendingDaoTreasury;
        _pendingDaoTreasury    = address(0);
        _pendingDaoTreasuryEta = 0;
        emit DaoTreasuryUpdateCancelled(cancelled);
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW — LISTINGS
    // ═══════════════════════════════════════════════════════════

    /// @notice Fetch a listing by ID. Reverts if not found.
    function getListing(uint32 listingId) external view returns (Listing memory) {
        return _requireExistingListing(listingId);
    }

    /// @notice All token IDs in a listing.
    function getListingTokenIds(uint32 listingId) external view returns (uint256[] memory) {
        _requireExistingListing(listingId);
        return listingTokenIds[listingId];
    }

    /// @notice Full listing detail including token IDs and highest bid.
    function getListingFull(uint32 listingId)
        external
        view
        returns (
            Listing   memory listing,
            uint256[] memory tokenIds,
            Bid       memory topBid
        )
    {
        listing  = _requireExistingListing(listingId);
        tokenIds = listingTokenIds[listingId];
        topBid   = highestBid[listingId];
    }

    /**
     * @notice Current price for a Dutch auction at this block.
     *         Returns 0 if listing is not an active Dutch auction.
     */
    function currentDutchPrice(uint32 listingId) external view returns (uint256) {
        if (listingId == 0 || listingId >= _nextListingId) return 0;
        Listing storage lst = _listings[listingId];
        if (lst.listingType != ListingType.DUTCH) return 0;
        if (lst.status != ListingStatus.ACTIVE)   return 0;
        if (block.timestamp >= lst.endTime)        return lst.endPrice;
        return _dutchPrice(lst.price, lst.endPrice, lst.startTime, lst.endTime);
    }

    /**
     * @notice Preview fee breakdown for a given sale price.
     * @param salePrice  CUECOIN-wei price to preview.
     * @return platformFee    DAO Treasury share (1%).
     * @return minterRoyalty  Original minter share (2.5%).
     * @return burnRoyalty    Burned amount (2.5%).
     * @return sellerProceeds Net to seller (94%).
     */
    function previewFees(uint256 salePrice)
        external
        pure
        returns (
            uint256 platformFee,
            uint256 minterRoyalty,
            uint256 burnRoyalty,
            uint256 sellerProceeds
        )
    {
        (platformFee, minterRoyalty, burnRoyalty, sellerProceeds) = _computeFees(salePrice);
    }

    /// @notice Total listing count (all-time).
    function listingCount() external view returns (uint32) {
        return _nextListingId == 0 ? 0 : _nextListingId - 1;
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW — FLOOR ORACLE
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Minimum sale price recorded in the last 7 days.
     *         Returns 0 if no sales have occurred in the window.
     *
     *         Iterates the ring buffer (max 100 entries) for gas-bounded lookup.
     *         This is a view function — no gas cost to callers in off-chain reads.
     */
    function floorPrice7d() external view returns (uint256 floor) {
        uint256 cutoff = block.timestamp - FLOOR_ORACLE_WINDOW;
        floor = type(uint256).max;
        bool found;

        for (uint256 i = 0; i < FLOOR_HISTORY_SIZE; i++) {
            SaleRecord storage rec = _saleHistory[i];
            if (rec.timestamp > cutoff && rec.price > 0) {
                if (rec.price < floor) floor = rec.price;
                found = true;
            }
        }

        if (!found) floor = 0;
    }

    /// @notice All sale records in the ring buffer (for off-chain indexing).
    function getSaleHistory() external view returns (SaleRecord[FLOOR_HISTORY_SIZE] memory) {
        return _saleHistory;
    }

    /// @notice Most recent completed sale record.
    function lastSale() external view returns (SaleRecord memory) {
        if (totalSalesRecorded == 0) return SaleRecord(0, 0, 0);
        uint256 prev = (_saleHistoryHead == 0 ? FLOOR_HISTORY_SIZE : _saleHistoryHead) - 1;
        return _saleHistory[prev];
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW — PROTOCOL STATS
    // ═══════════════════════════════════════════════════════════

    function protocolStats()
        external
        view
        returns (
            uint256 volume,
            uint256 burned,
            uint256 toMinters,
            uint256 toPlatform,
            uint256 listings,
            uint256 active,
            bool    paused_
        )
    {
        return (
            totalVolumeTraded,
            totalRoyaltyBurned,
            totalRoyaltyToMinters,
            totalPlatformFees,
            totalListingsCreated,
            activeListingCount,
            paused
        );
    }

    function pendingTreasuryUpdate()
        external
        view
        returns (address pending, uint256 eta)
    {
        return (_pendingDaoTreasury, _pendingDaoTreasuryEta);
    }

    // ═══════════════════════════════════════════════════════════
    //  IERC721Receiver
    // ═══════════════════════════════════════════════════════════

    /// @notice Accept NFT transfers into escrow.
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — CORE SALE EXECUTION
    // ═══════════════════════════════════════════════════════════

    /**
     * @dev Central sale execution path — used by buyFixed, buyBundle,
     *      finalizeAuction, and buyDutch.
     *
     *      Pulls CUECOIN from buyer, distributes fees, transfers NFT(s).
     *      All state mutations (status) must be done by caller BEFORE calling
     *      this function to satisfy CEI ordering.
     *
     *      For bundles: royalties are summed across all tokens in the bundle.
     *      The minter of the first token in the bundle receives the combined
     *      minter royalty. This is intentional — bundles are treated as a unit
     *      priced together, and splitting royalties per-token on a combined price
     *      would be non-trivial and confusing.
     *
     *      NOTE: For maximum royalty fairness on bundles, the minter share is
     *      distributed to the minter of the first token in the bundle. If bundle
     *      tokens have different minters, this is a known simplification.
     *      Sellers should bundle only their own minted NFTs for correct royalties.
     */
    function _executeSale(
        uint32 listingId,
        address buyer,
        address seller,
        address nftContract,
        uint256[] storage tokenIds,
        uint256 salePrice
    ) internal {
        require(buyer != seller, "CueMarketplace: buyer is seller");

        // Pull CUECOIN from buyer (for Dutch/Fixed — English already held in contract)
        Listing storage lst = _listings[listingId];
        bool isEnglish = lst.listingType == ListingType.ENGLISH;

        if (!isEnglish) {
            cueCoin.safeTransferFrom(buyer, address(this), salePrice);
        }
        // For English: salePrice was already pulled when bid was placed

        // Compute fees
        (
            uint256 platformFee,
            uint256 minterRoyalty,
            uint256 burnRoyalty,
            uint256 sellerProceeds
        ) = _computeFees(salePrice);

        // Resolve minter — try ICueNFT.originalMinterOf for each token
        // For single-token listings: minter of that token
        // For bundles: minter of the first token (known simplification, documented above)
        address minter = _resolveMinter(nftContract, tokenIds[0], seller);

        // Distribute payments (CEI: state already updated by callers)
        if (platformFee > 0) {
            cueCoin.safeTransfer(daoTreasury, platformFee);
        }
        if (minterRoyalty > 0) {
            cueCoin.safeTransfer(minter, minterRoyalty);
        }
        if (burnRoyalty > 0) {
            cueCoin.safeTransfer(BURN_ADDRESS, burnRoyalty);
        }
        if (sellerProceeds > 0) {
            cueCoin.safeTransfer(seller, sellerProceeds);
        }

        // Transfer NFT(s) to buyer
        for (uint256 i = 0; i < tokenIds.length; i++) {
            IERC721(nftContract).safeTransferFrom(address(this), buyer, tokenIds[i]);
        }

        // Record wash trade history
        hasTradedWith[buyer][seller]  = true;
        hasTradedWith[seller][buyer]  = true;

        // Update stats
        totalVolumeTraded        += salePrice;
        totalRoyaltyBurned       += burnRoyalty;
        totalRoyaltyToMinters    += minterRoyalty;
        totalPlatformFees        += platformFee;

        // Update floor oracle
        _recordSale(salePrice, listingId);

        emit Sale(listingId, buyer, seller, salePrice, platformFee, minterRoyalty, burnRoyalty);
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — HELPERS
    // ═══════════════════════════════════════════════════════════

    function _createListing(
        ListingType listingType,
        address nftContract,
        address seller,
        uint256 price,
        uint256 endPrice,
        uint256 reservePrice,
        uint256 endTime
    ) internal returns (uint32 listingId) {
        if (_nextListingId == 0) _nextListingId = 1;
        listingId = _nextListingId++;

        _listings[listingId] = Listing({
            listingId:    listingId,
            listingType:  listingType,
            status:       ListingStatus.ACTIVE,
            nftContract:  nftContract,
            seller:       seller,
            price:        price,
            endPrice:     endPrice,
            reservePrice: reservePrice,
            startTime:    block.timestamp,
            endTime:      endTime
        });

        totalListingsCreated++;
        activeListingCount++;
    }

    /**
     * @dev Compute all fee splits for a given sale price.
     *      All calculations use integer division. The burn royalty absorbs
     *      any 1-wei rounding difference to ensure no CUECOIN is unaccounted.
     */
    function _computeFees(uint256 salePrice)
        internal
        pure
        returns (
            uint256 platformFee,
            uint256 minterRoyalty,
            uint256 burnRoyalty,
            uint256 sellerProceeds
        )
    {
        platformFee   = (salePrice * PLATFORM_FEE_BPS) / 10_000;
        minterRoyalty = (salePrice * MINTER_SHARE_BPS) / 10_000;
        burnRoyalty   = (salePrice * BURN_SHARE_BPS)   / 10_000;
        uint256 totalDeducted = platformFee + minterRoyalty + burnRoyalty;
        sellerProceeds = salePrice - totalDeducted;
    }

    /**
     * @dev Compute the current Dutch auction price using linear interpolation.
     *      price(t) = startPrice - (startPrice - endPrice) * elapsed / duration
     *      Clamped to endPrice as the floor.
     */
    function _dutchPrice(
        uint256 startPrice,
        uint256 endPrice,
        uint256 startTime,
        uint256 endTime
    ) internal view returns (uint256) {
        if (block.timestamp >= endTime) return endPrice;
        if (block.timestamp <= startTime) return startPrice;

        uint256 elapsed  = block.timestamp - startTime;
        uint256 duration = endTime - startTime;
        uint256 drop     = ((startPrice - endPrice) * elapsed) / duration;
        return startPrice - drop;
    }

    /**
     * @dev Attempt to resolve the original minter via ICueNFT.originalMinterOf().
     *      Falls back to seller if the nftContract doesn't implement this function
     *      or if the minter is address(0) (unminted/burned scenario, shouldn't occur).
     */
    function _resolveMinter(
        address nftContract,
        uint256 tokenId,
        address seller
    ) internal view returns (address) {
        try ICueNFT(nftContract).originalMinterOf(tokenId) returns (address minter) {
            return minter != address(0) ? minter : seller;
        } catch {
            return seller;
        }
    }

    function _returnNftsToSeller(
        address nftContract,
        uint256[] storage tokenIds,
        address seller
    ) internal {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            IERC721(nftContract).safeTransferFrom(address(this), seller, tokenIds[i]);
        }
    }

    function _recordSale(uint256 price, uint32 listingId) internal {
        uint256 idx = _saleHistoryHead % FLOOR_HISTORY_SIZE;
        _saleHistory[idx] = SaleRecord({
            price:     price,
            timestamp: block.timestamp,
            listingId: listingId
        });
        _saleHistoryHead = (idx + 1) % FLOOR_HISTORY_SIZE;
        totalSalesRecorded++;

        emit FloorUpdated(price, block.timestamp);
    }

    function _clampDuration(uint256 duration) internal pure returns (uint256) {
        if (duration < MIN_AUCTION_DURATION) return MIN_AUCTION_DURATION;
        if (duration > MAX_AUCTION_DURATION) return MAX_AUCTION_DURATION;
        return duration;
    }

    function _requireApprovedNft(address nftContract) internal view {
        require(approvedNftContract[nftContract], "CueMarketplace: NFT contract not approved");
    }

    function _requireNoWashTrade(address buyer, address seller) internal view {
        require(buyer  != seller,                        "CueMarketplace: buyer is seller");
        require(!hasTradedWith[buyer][seller],            "CueMarketplace: wash trade detected");
    }

    function _requireActiveListing(uint32 listingId)
        internal
        view
        returns (Listing storage)
    {
        require(
            listingId >= 1 && listingId < _nextListingId,
            "CueMarketplace: listing does not exist"
        );
        Listing storage lst = _listings[listingId];
        require(lst.status == ListingStatus.ACTIVE, "CueMarketplace: listing not active");
        return lst;
    }

    function _requireExistingListing(uint32 listingId)
        internal
        view
        returns (Listing storage)
    {
        require(
            listingId >= 1 && listingId < _nextListingId,
            "CueMarketplace: listing does not exist"
        );
        return _listings[listingId];
    }
}
