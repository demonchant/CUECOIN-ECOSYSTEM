const ERC20_ABI = [
  "function approve(address spender,uint256 amount) returns (bool)",
  "function allowance(address owner,address spender) view returns (uint256)",
  "function balanceOf(address owner) view returns (uint256)"
];

const ESCROW_ABI = [
  "function createMatch(uint256 wagerPerPlayer,uint8 tier) returns (bytes32)",
  "function createPrivateMatch(uint256 wagerPerPlayer,uint8 tier,address targetPlayerB) returns (bytes32)",
  "function joinMatch(bytes32 matchId)",
  "function cancelMatch(bytes32 matchId)",
  "function claimTimeout(bytes32 matchId)",
  "function proposeMutualCancel(bytes32 matchId)",
  "function confirmMutualCancel(bytes32 matchId)",
  "function previewPayout(bytes32 matchId,uint256 nftBonusBps) view returns (uint256,uint256,uint256,uint256)"
];

const SIT_AND_GO_ABI = [
  "function join(uint8 tier)",
  "function withdraw(uint8 tier)",
  "function entryFeeForTier(uint8 tier) pure returns (uint256)",
  "function queueState(uint8 tier) view returns (bytes32,uint8,uint8,uint256,uint256)"
];

const TOURNAMENT_ABI = [
  "function register(uint32 tournamentId)",
  "function claimRefund(uint32 tournamentId)",
  "function previewPrizes(uint256 totalPot) pure returns (uint256,uint256,uint256,uint256)"
];

function addressConfigured(value) {
  return Boolean(value && window.ethers?.isAddress(value) && value !== window.ethers.ZeroAddress);
}

function config() {
  return window.CUE_CONFIG || {};
}

function requiredAddress(mode) {
  if (mode === "wager") return config().escrowAddress;
  if (mode === "sitAndGo") return config().sitAndGoAddress;
  if (mode === "tournament") return config().tournamentAddress;
  if (mode === "ranked") return config().rewardsPoolAddress;
  return "practice";
}

export function deploymentStatus(mode) {
  if (mode === "practice") return { ready: true, label: "Local practice" };
  const tokenReady = addressConfigured(config().cueCoinAddress);
  const contractReady = addressConfigured(requiredAddress(mode));
  const backendReady = Boolean(config().gameApiUrl);
  return {
    ready: tokenReady && contractReady && backendReady,
    tokenReady,
    contractReady,
    backendReady,
    label: tokenReady && contractReady && backendReady ? "Live contracts ready" : "Deployment locked"
  };
}

async function switchToBsc() {
  const chainId = `0x${Number(config().chainId || 56).toString(16)}`;
  try {
    await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId }] });
  } catch (error) {
    if (error.code !== 4902) throw error;
    await window.ethereum.request({
      method: "wallet_addEthereumChain",
      params: [{
        chainId,
        chainName: config().chainName || "BNB Smart Chain",
        nativeCurrency: config().nativeCurrency || { name: "BNB", symbol: "BNB", decimals: 18 },
        rpcUrls: config().rpcUrls,
        blockExplorerUrls: [config().explorerUrl]
      }]
    });
  }
}

export async function connectGameWallet() {
  if (!window.ethereum || !window.ethers) throw new Error("Install a compatible wallet to connect.");
  await switchToBsc();
  const provider = new window.ethers.BrowserProvider(window.ethereum);
  await provider.send("eth_requestAccounts", []);
  const signer = await provider.getSigner();
  return { provider, signer, address: await signer.getAddress() };
}

async function approveExact(signer, spender, amount) {
  const token = new window.ethers.Contract(config().cueCoinAddress, ERC20_ABI, signer);
  const owner = await signer.getAddress();
  const allowance = await token.allowance(owner, spender);
  if (allowance >= amount) return null;
  const transaction = await token.approve(spender, amount);
  await transaction.wait();
  return transaction.hash;
}

export async function enterPaidMode({ mode, amountCue, tier, targetAddress, tournamentId }, signer) {
  const status = deploymentStatus(mode);
  if (!status.ready) throw new Error("Paid play remains locked until contracts and the authoritative game service are configured.");
  const amount = window.ethers.parseUnits(String(amountCue), 18);
  const spender = requiredAddress(mode);
  await approveExact(signer, spender, amount);

  if (mode === "wager") {
    const escrow = new window.ethers.Contract(spender, ESCROW_ABI, signer);
    const transaction = targetAddress
      ? await escrow.createPrivateMatch(amount, tier, targetAddress)
      : await escrow.createMatch(amount, tier);
    return transaction.wait();
  }
  if (mode === "sitAndGo") {
    const queue = new window.ethers.Contract(spender, SIT_AND_GO_ABI, signer);
    return (await queue.join(tier)).wait();
  }
  if (mode === "tournament") {
    if (!Number.isInteger(Number(tournamentId)) || Number(tournamentId) <= 0) throw new Error("Enter a valid published tournament ID.");
    const tournament = new window.ethers.Contract(spender, TOURNAMENT_ABI, signer);
    return (await tournament.register(Number(tournamentId))).wait();
  }
  throw new Error("This mode does not require a CUE entry transaction.");
}

export async function hashTranscript(transcript) {
  const bytes = new TextEncoder().encode(JSON.stringify(transcript));
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return `0x${[...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

export const CONTRACT_FLOW = Object.freeze({
  practice: ["Local rack", "No token action"],
  ranked: ["Server match", "Oracle verified result", "CueRewardsPool winner reward"],
  wager: ["Approve CUE", "CueEscrow lock", "Oracle certificate", "Escrow settlement"],
  sitAndGo: ["Approve CUE", "CueSitAndGo queue", "Two oracle signatures", "Queue settlement"],
  tournament: ["Approve CUE", "CueTournament registration", "Oracle bracket results", "Tournament prizes"]
});
