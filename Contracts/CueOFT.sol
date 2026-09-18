// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

struct CueOrigin {
    uint32 srcEid;
    bytes32 sender;
    uint64 nonce;
}

struct CueMessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

struct CueMessagingParams {
    uint32 dstEid;
    bytes32 receiver;
    bytes message;
    bytes options;
    bool payInLzToken;
}

struct CueMessagingReceipt {
    bytes32 guid;
    uint64 nonce;
    CueMessagingFee fee;
}

interface ICueLayerZeroEndpoint {
    function quote(CueMessagingParams calldata params, address sender)
        external view returns (CueMessagingFee memory);

    function send(CueMessagingParams calldata params, address refundAddress)
        external payable returns (CueMessagingReceipt memory);

    function setDelegate(address delegate) external;
}

contract CueOFT is ERC20, Ownable2Step, ReentrancyGuard {
    uint256 public constant PEER_UPDATE_DELAY = 48 hours;
    uint8 public constant SHARED_DECIMALS = 6;
    uint256 public constant DECIMAL_FACTOR = 1e12;

    ICueLayerZeroEndpoint public immutable endpoint;
    address public guardian;
    bool public paused;

    mapping(uint32 => bytes32) public peers;
    mapping(uint32 => bytes32) public pendingPeers;
    mapping(uint32 => uint256) public pendingPeerEta;
    mapping(bytes32 => bool) public processedGuids;

    event PeerQueued(uint32 indexed eid, bytes32 peer, uint256 eta);
    event PeerApplied(uint32 indexed eid, bytes32 peer);
    event Sent(address indexed sender, uint32 indexed dstEid, bytes32 recipient, uint256 amount, bytes32 guid);
    event Received(address indexed recipient, uint32 indexed srcEid, uint256 amount, bytes32 guid);
    event Paused(address indexed account);
    event Unpaused(address indexed account);

    modifier onlyEndpoint() {
        require(msg.sender == address(endpoint), "CueOFT: caller is not endpoint");
        _;
    }

    modifier onlyOwnerOrGuardian() {
        require(msg.sender == owner() || msg.sender == guardian,
            "CueOFT: caller is not authorized");
        _;
    }

    constructor(address endpointAddress, address guardianAddress)
        ERC20("CueCoin", "CUE")
        Ownable(msg.sender)
    {
        require(endpointAddress != address(0), "CueOFT: zero endpoint");
        require(guardianAddress != address(0), "CueOFT: zero guardian");
        endpoint = ICueLayerZeroEndpoint(endpointAddress);
        guardian = guardianAddress;
    }

    function queuePeer(uint32 eid, bytes32 peer) external onlyOwner {
        require(eid != 0 && peer != bytes32(0), "CueOFT: invalid peer");
        pendingPeers[eid] = peer;
        pendingPeerEta[eid] = block.timestamp + PEER_UPDATE_DELAY;
        emit PeerQueued(eid, peer, pendingPeerEta[eid]);
    }

    function applyPeer(uint32 eid) external {
        uint256 eta = pendingPeerEta[eid];
        require(eta != 0, "CueOFT: no pending peer");
        require(block.timestamp >= eta, "CueOFT: peer delay active");
        bytes32 peer = pendingPeers[eid];
        delete pendingPeers[eid];
        delete pendingPeerEta[eid];
        peers[eid] = peer;
        emit PeerApplied(eid, peer);
    }

    function quoteSend(
        uint32 dstEid,
        bytes32 recipient,
        uint256 amount,
        bytes calldata options
    ) external view returns (CueMessagingFee memory) {
        return endpoint.quote(_params(dstEid, recipient, amount, options), address(this));
    }

    function send(
        uint32 dstEid,
        bytes32 recipient,
        uint256 amount,
        bytes calldata options,
        address refundAddress
    ) external payable nonReentrant returns (bytes32 guid) {
        require(!paused, "CueOFT: paused");
        require(peers[dstEid] != bytes32(0), "CueOFT: unknown destination");
        require(recipient != bytes32(0), "CueOFT: zero recipient");
        uint256 cleanAmount = amount - (amount % DECIMAL_FACTOR);
        require(cleanAmount > 0, "CueOFT: amount below shared precision");
        _burn(msg.sender, cleanAmount);
        CueMessagingReceipt memory receipt = endpoint.send{value: msg.value}(
            _params(dstEid, recipient, cleanAmount, options),
            refundAddress
        );
        guid = receipt.guid;
        emit Sent(msg.sender, dstEid, recipient, cleanAmount, guid);
    }

    function lzReceive(
        CueOrigin calldata origin,
        bytes32 guid,
        bytes calldata message,
        address,
        bytes calldata
    ) external payable onlyEndpoint nonReentrant {
        require(!paused, "CueOFT: paused");
        require(peers[origin.srcEid] == origin.sender, "CueOFT: unknown peer");
        require(!processedGuids[guid], "CueOFT: message already processed");
        require(message.length == 40, "CueOFT: invalid message");

        bytes32 recipientBytes;
        uint64 amountShared;
        assembly ("memory-safe") {
            recipientBytes := calldataload(message.offset)
            amountShared := shr(192, calldataload(add(message.offset, 32)))
        }
        address recipient = address(uint160(uint256(recipientBytes)));
        require(recipient != address(0), "CueOFT: zero recipient");

        uint256 amount = uint256(amountShared) * DECIMAL_FACTOR;
        processedGuids[guid] = true;
        _mint(recipient, amount);
        emit Received(recipient, origin.srcEid, amount, guid);
    }

    function pause() external onlyOwnerOrGuardian {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function setGuardian(address newGuardian) external onlyOwner {
        require(newGuardian != address(0), "CueOFT: zero guardian");
        guardian = newGuardian;
    }

    function setDelegate(address delegate) external onlyOwner {
        endpoint.setDelegate(delegate);
    }

    function _params(
        uint32 dstEid,
        bytes32 recipient,
        uint256 amount,
        bytes calldata options
    ) internal view returns (CueMessagingParams memory) {
        require(amount / DECIMAL_FACTOR <= type(uint64).max,
            "CueOFT: amount exceeds shared precision");
        uint64 amountShared = uint64(amount / DECIMAL_FACTOR);
        return CueMessagingParams({
            dstEid: dstEid,
            receiver: peers[dstEid],
            message: abi.encodePacked(recipient, amountShared),
            options: options,
            payInLzToken: false
        });
    }
}
