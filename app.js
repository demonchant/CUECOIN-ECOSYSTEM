const config = window.CUE_CONFIG;

const AIRDROP_ABI = [
  "function claimOpen() view returns (bool)",
  "function premiumFeeWei() view returns (uint256)",
  "function standardFeeWei() view returns (uint256)",
  "function currentTosVersion() view returns (uint256)",
  "function tosVersionAccepted(address) view returns (uint256)",
  "function premiumClaimed(address) view returns (bool)",
  "function standardClaimed(address) view returns (bool)",
  "function acceptToS()",
  "function claimPremium(bytes32[] proof) payable",
  "function claimStandard(bytes32[] proof,uint256 totalCuecoin) payable",
  "function isPremiumEligible(address wallet) view returns (bool eligible,string reason)",
  "function isStandardEligible(address wallet) view returns (bool eligible,string reason)",
  "function unlockStatus(address user) view returns (uint256 totalLocked,uint256 totalUnlocked,uint256 remaining,uint256 gamesVerified,uint256 nextMilestone,uint256 percentUnlocked)",
  "function airdropStats() view returns (uint256 premiumClaims,uint256 premiumRemaining,uint256 standardClaims,uint256 standardRemaining,bool isOpen,bool isPremiumDeployed,uint256 contractBNBBalance,uint256 premiumBNBPending,uint256 standardBNBPending,uint256 contractCueCoinBalance,uint256 activeLocks,uint256 blockUnlockUsed,uint256 blockUnlockCap)"
];

const TASK_ABI = [
  "function getActiveTasks() view returns ((uint32 taskId,uint8 tier,uint8 verifierType,string name,string description,string ctaUrl,uint256 bonusAmount,bytes params,bool active,uint64 addedAt)[] tasks)"
];

const state = {
  mode: "standard",
  provider: null,
  signer: null,
  account: "",
  airdrop: null,
  fee: 0n,
  eligible: false,
  tosAccepted: false,
  busy: false
};

const byId = (id) => document.getElementById(id);
const ui = {
  connectButton: byId("connectButton"),
  connectLabel: byId("connectLabel"),
  heroConnect: byId("heroConnect"),
  standardTab: byId("standardTab"),
  premiumTab: byId("premiumTab"),
  claimStatus: byId("claimStatus"),
  awardAmount: byId("awardAmount"),
  claimFee: byId("claimFee"),
  claimDescription: byId("claimDescription"),
  walletState: byId("walletState"),
  proofPanel: byId("proofPanel"),
  proofInput: byId("proofInput"),
  proofHelp: byId("proofHelp"),
  termsCheckbox: byId("termsCheckbox"),
  termsLink: byId("termsLink"),
  claimButton: byId("claimButton"),
  inlineNotice: byId("inlineNotice"),
  taskGrid: byId("taskGrid"),
  taskIntro: byId("taskIntro"),
  unlockPercent: byId("unlockPercent"),
  unlockSummary: byId("unlockSummary"),
  unlockedAmount: byId("unlockedAmount"),
  gamesVerified: byId("gamesVerified"),
  nextMilestone: byId("nextMilestone"),
  contractLink: byId("contractLink"),
  toast: byId("toast")
};

function configuredAddress(value) {
  return Boolean(value && ethers.isAddress(value) && value !== ethers.ZeroAddress);
}

function shortAddress(value) {
  return `${value.slice(0, 6)}…${value.slice(-4)}`;
}

function showToast(message, error = false) {
  ui.toast.textContent = message;
  ui.toast.classList.toggle("error", error);
  ui.toast.classList.add("show");
  window.clearTimeout(showToast.timer);
  showToast.timer = window.setTimeout(() => ui.toast.classList.remove("show"), 5200);
}

function setNotice(message = "", type = "") {
  ui.inlineNotice.textContent = message;
  ui.inlineNotice.className = `inlineNotice ${type}`.trim();
}

function readableError(error) {
  const raw = error?.shortMessage || error?.reason || error?.info?.error?.message || error?.message || "Transaction failed";
  return raw.replace(/^execution reverted:\s*/i, "").replace(/^Error:\s*/i, "");
}

function updateMode(mode) {
  state.mode = mode;
  const standard = mode === "standard";
  ui.standardTab.classList.toggle("active", standard);
  ui.standardTab.setAttribute("aria-selected", String(standard));
  ui.premiumTab.classList.toggle("active", !standard);
  ui.premiumTab.setAttribute("aria-selected", String(!standard));
  ui.awardAmount.textContent = standard ? "50 to 80 CUE" : "250 CUE";
  ui.claimDescription.textContent = standard
    ? "Standard CUE is secured in the airdrop contract and unlocks as you complete verified games."
    : "Premium CUE is transferred immediately after a valid eligible claim.";
  refreshAccountState().catch((error) => setNotice(readableError(error), "error"));
}

async function ensureChain() {
  const wanted = `0x${config.chainId.toString(16)}`;
  const current = await window.ethereum.request({ method: "eth_chainId" });
  if (current.toLowerCase() === wanted.toLowerCase()) return;
  try {
    await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: wanted }] });
  } catch (error) {
    if (error.code !== 4902) throw error;
    await window.ethereum.request({
      method: "wallet_addEthereumChain",
      params: [{
        chainId: wanted,
        chainName: config.chainName,
        nativeCurrency: config.nativeCurrency,
        rpcUrls: config.rpcUrls,
        blockExplorerUrls: [config.explorerUrl]
      }]
    });
  }
}

async function connectWallet() {
  if (!window.ethereum) {
    showToast("Install a compatible wallet such as MetaMask to continue.", true);
    return;
  }
  try {
    await ensureChain();
    state.provider = new ethers.BrowserProvider(window.ethereum);
    await state.provider.send("eth_requestAccounts", []);
    state.signer = await state.provider.getSigner();
    state.account = await state.signer.getAddress();
    if (configuredAddress(config.airdropAddress)) {
      state.airdrop = new ethers.Contract(config.airdropAddress, AIRDROP_ABI, state.signer);
    }
    ui.connectLabel.textContent = shortAddress(state.account);
    ui.heroConnect.textContent = "View claim status";
    ui.proofPanel.classList.remove("hidden");
    await refreshAccountState();
    document.querySelector("#claim").scrollIntoView({ behavior: "smooth", block: "center" });
  } catch (error) {
    showToast(readableError(error), true);
  }
}

async function loadProof() {
  if (!config.proofApiUrl || !state.account) return null;
  const base = config.proofApiUrl.replace(/\/$/, "");
  const response = await fetch(`${base}/proof/${state.account}?tier=${state.mode}`, { headers: { Accept: "application/json" } });
  if (response.status === 404) return null;
  if (!response.ok) throw new Error("The eligibility service is unavailable. Try again shortly.");
  const payload = await response.json();
  ui.proofInput.value = JSON.stringify(payload, null, 2);
  return parseProof();
}

function parseProof() {
  let payload;
  try {
    payload = JSON.parse(ui.proofInput.value);
  } catch {
    throw new Error("Paste a valid eligibility proof JSON object.");
  }
  if (!Array.isArray(payload.proof) || !payload.proof.every((item) => /^0x[0-9a-fA-F]{64}$/.test(item))) {
    throw new Error("The proof array is missing or invalid.");
  }
  if (state.mode === "standard") {
    const amount = payload.totalCuecoinWei || (payload.totalCuecoin ? ethers.parseEther(String(payload.totalCuecoin)) : null);
    if (amount === null) throw new Error("The standard proof must include totalCuecoin or totalCuecoinWei.");
    return { proof: payload.proof, amount: BigInt(amount) };
  }
  return { proof: payload.proof };
}

async function acceptTerms() {
  if (!config.termsUrl) throw new Error("The official terms URL has not been configured yet.");
  const tx = await state.airdrop.acceptToS();
  setNotice("Recording terms acceptance onchain…");
  await tx.wait();
  state.tosAccepted = true;
}

async function submitClaim() {
  if (state.busy) return;
  if (!state.airdrop) {
    showToast("The airdrop contract has not been configured for launch.", true);
    return;
  }
  state.busy = true;
  ui.claimButton.disabled = true;
  try {
    if (!ui.termsCheckbox.checked) throw new Error("Review and accept the current terms before claiming.");
    let payload = await loadProof();
    if (!payload && ui.proofInput.value.trim()) payload = parseProof();
    if (!payload) throw new Error("No eligibility proof is available for this wallet.");
    if (!payload.proof) payload = parseProof();
    if (!state.tosAccepted) await acceptTerms();

    const tx = state.mode === "standard"
      ? await state.airdrop.claimStandard(payload.proof, payload.amount ?? BigInt(payload.totalCuecoinWei), { value: state.fee })
      : await state.airdrop.claimPremium(payload.proof, { value: state.fee });
    setNotice("Claim submitted. Waiting for confirmation…");
    const receipt = await tx.wait();
    const link = `${config.explorerUrl}/tx/${receipt.hash}`;
    setNotice("Claim confirmed on BNB Smart Chain.", "success");
    showToast(`Claim confirmed. Transaction: ${shortAddress(receipt.hash)}`);
    window.open(link, "_blank", "noopener,noreferrer");
    await refreshAccountState();
  } catch (error) {
    setNotice(readableError(error), "error");
  } finally {
    state.busy = false;
    updateClaimButton();
  }
}

function updateClaimButton() {
  if (!configuredAddress(config.airdropAddress)) {
    ui.claimButton.textContent = "Launch configuration pending";
    ui.claimButton.disabled = true;
    return;
  }
  if (!state.account) {
    ui.claimButton.textContent = "Connect wallet to continue";
    ui.claimButton.disabled = true;
    return;
  }
  if (!config.termsUrl) {
    ui.claimButton.textContent = "Terms configuration pending";
    ui.claimButton.disabled = true;
    return;
  }
  if (!state.eligible) {
    ui.claimButton.textContent = "Wallet is not currently eligible";
    ui.claimButton.disabled = true;
    return;
  }
  ui.claimButton.textContent = state.tosAccepted ? `Claim ${state.mode} allocation` : "Accept terms and claim";
  ui.claimButton.disabled = state.busy || !ui.termsCheckbox.checked;
}

async function refreshAccountState() {
  updateClaimButton();
  if (!state.account) return;
  if (!state.airdrop) {
    ui.walletState.innerHTML = `<span class="walletStateIcon">02</span><div><strong>${shortAddress(state.account)}</strong><p>Wallet connected. Contract configuration is pending.</p></div>`;
    setNotice("Claims are disabled until the verified deployment address is published.");
    return;
  }
  const [currentVersion, acceptedVersion, eligibility, fee, unlock] = await Promise.all([
    state.airdrop.currentTosVersion(),
    state.airdrop.tosVersionAccepted(state.account),
    state.mode === "standard" ? state.airdrop.isStandardEligible(state.account) : state.airdrop.isPremiumEligible(state.account),
    state.mode === "standard" ? state.airdrop.standardFeeWei() : state.airdrop.premiumFeeWei(),
    state.airdrop.unlockStatus(state.account)
  ]);
  state.tosAccepted = acceptedVersion === currentVersion;
  state.eligible = eligibility[0] || eligibility[1] === "ToS not accepted";
  state.fee = fee;
  ui.claimFee.textContent = `${ethers.formatEther(fee)} BNB`;
  const eligibilityText = eligibility[1] === "ToS not accepted" ? "Ready after onchain terms acceptance" : eligibility[1];
  ui.walletState.innerHTML = `<span class="walletStateIcon">${state.eligible ? "✓" : "!"}</span><div><strong>${shortAddress(state.account)}</strong><p>${eligibilityText}</p></div>`;
  ui.proofHelp.textContent = config.proofApiUrl
    ? "The official proof service will load your proof automatically when you claim."
    : "Paste proof JSON from the official CueCoin snapshot service when it is published.";
  ui.unlockPercent.textContent = `${unlock.percentUnlocked}%`;
  ui.unlockedAmount.textContent = `${Number(ethers.formatEther(unlock.totalUnlocked)).toLocaleString()} CUE`;
  ui.gamesVerified.textContent = unlock.gamesVerified.toString();
  ui.nextMilestone.textContent = unlock.nextMilestone === 0n ? "Complete" : `${unlock.nextMilestone} games`;
  ui.unlockSummary.textContent = unlock.totalLocked === 0n
    ? "No standard allocation is currently locked for this wallet."
    : `${Number(ethers.formatEther(unlock.remaining)).toLocaleString()} CUE remains locked.`;
  updateClaimButton();
}

async function loadPublicStatus() {
  if (!configuredAddress(config.airdropAddress)) {
    ui.claimStatus.className = "statusPill";
    ui.claimStatus.innerHTML = "<i></i> Not configured";
    ui.contractLink.textContent = "Awaiting deployment configuration";
    return;
  }
  ui.contractLink.href = `${config.explorerUrl}/address/${config.airdropAddress}`;
  ui.contractLink.target = "_blank";
  ui.contractLink.rel = "noopener noreferrer";
  ui.contractLink.textContent = config.airdropAddress;
  const rpc = new ethers.JsonRpcProvider(config.rpcUrls[0], config.chainId);
  const contract = new ethers.Contract(config.airdropAddress, AIRDROP_ABI, rpc);
  const [stats, standardFee] = await Promise.all([contract.airdropStats(), contract.standardFeeWei()]);
  ui.claimStatus.className = `statusPill ${stats.isOpen ? "live" : "closed"}`;
  ui.claimStatus.innerHTML = `<i></i> ${stats.isOpen ? "Claims open" : "Claims closed"}`;
  ui.claimFee.textContent = `${ethers.formatEther(standardFee)} BNB`;
}

function safeTaskUrl(value) {
  try {
    const url = new URL(value);
    return url.protocol === "https:" ? url.href : "";
  } catch {
    return "";
  }
}

async function loadTasks() {
  if (!configuredAddress(config.taskRegistryAddress)) return;
  const rpc = new ethers.JsonRpcProvider(config.rpcUrls[0], config.chainId);
  const registry = new ethers.Contract(config.taskRegistryAddress, TASK_ABI, rpc);
  const tasks = await registry.getActiveTasks();
  if (!tasks.length) return;
  const labels = ["Mandatory", "Engagement", "Bonus"];
  ui.taskIntro.textContent = "These tasks are read from the active onchain registry. Complete them with the same wallet you will use to claim.";
  ui.taskGrid.replaceChildren(...tasks.map((task) => {
    const article = document.createElement("article");
    article.className = "taskItem";
    const index = document.createElement("span");
    index.className = "taskIndex";
    index.textContent = labels[Number(task.tier)] || "Task";
    const body = document.createElement("div");
    const title = document.createElement("h3");
    title.textContent = task.name;
    const description = document.createElement("p");
    description.textContent = task.description;
    body.append(title, description);
    const url = safeTaskUrl(task.ctaUrl);
    if (url) {
      const link = document.createElement("a");
      link.href = url;
      link.target = "_blank";
      link.rel = "noopener noreferrer";
      link.textContent = "Open task";
      body.append(link);
    }
    article.append(index, body);
    return article;
  }));
}

ui.connectButton.addEventListener("click", connectWallet);
ui.heroConnect.addEventListener("click", connectWallet);
ui.standardTab.addEventListener("click", () => updateMode("standard"));
ui.premiumTab.addEventListener("click", () => updateMode("premium"));
ui.termsCheckbox.addEventListener("change", updateClaimButton);
ui.claimButton.addEventListener("click", submitClaim);

if (config.termsUrl) {
  ui.termsLink.href = config.termsUrl;
  ui.termsLink.target = "_blank";
  ui.termsLink.rel = "noopener noreferrer";
} else {
  ui.termsLink.addEventListener("click", (event) => {
    event.preventDefault();
    showToast("The official terms are not published yet.", true);
  });
}

if (window.ethereum) {
  window.ethereum.on("accountsChanged", () => window.location.reload());
  window.ethereum.on("chainChanged", () => window.location.reload());
}

Promise.allSettled([loadPublicStatus(), loadTasks()]).then((results) => {
  const failure = results.find((result) => result.status === "rejected");
  if (failure) showToast(`Live data unavailable: ${readableError(failure.reason)}`, true);
});
updateClaimButton();
