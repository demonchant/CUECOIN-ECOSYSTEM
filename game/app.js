import { BALL_RADIUS, BAULK_X, POCKETS, TABLE, CueStrikeEngine, groupForBall } from "./engine.js";
import { GAME_MODES, TOURNAMENT_TIERS, WAGER_TIERS, actionPlan, directMatchPayout, formatCue, sitAndGoPayout, tournamentPayout } from "./economy.js";
import { connectGameWallet, deploymentStatus, enterPaidMode, hashTranscript } from "./contracts.js";

const byId = (id) => document.getElementById(id);
const canvas = byId("gameCanvas");
const context = canvas.getContext("2d");
const isNativeApp = Boolean(window.Capacitor?.isNativePlatform?.());
document.documentElement.classList.toggle("nativeApp", isNativeApp);
const LOGICAL_WIDTH = 1000;
const LOGICAL_HEIGHT = 540;
const FIXED_STEP = 1 / 240;
const state = {
  mode: "practice",
  engine: null,
  wallet: null,
  dragging: false,
  aimAngle: 0,
  power: 0.45,
  cpuTimer: null,
  sequence: 0,
  transcript: [],
  sound: true,
  aimGuide: true,
  motion: true,
  lastFrame: performance.now(),
  accumulator: 0,
  renderScale: 1
};

const colors = {
  1: "#f5cf36", 2: "#1769d2", 3: "#d52d39", 4: "#713ba8", 5: "#ef7b26", 6: "#18835a", 7: "#8f263c", 8: "#111722",
  9: "#f5cf36", 10: "#1769d2", 11: "#d52d39", 12: "#713ba8", 13: "#ef7b26", 14: "#18835a", 15: "#8f263c"
};

function record(event) {
  state.transcript.push({
    sequence: ++state.sequence,
    elapsedMs: Math.round(performance.now()),
    ...event
  });
  if (event.type === "pocket") playTone(event.ballId === 0 ? 135 : 430, 0.08);
  if (event.type === "shot") playTone(210, 0.035);
  if (event.type === "shot") void haptic("LIGHT");
  if (event.type === "pocket") void haptic(event.ballId === 0 ? "HEAVY" : "MEDIUM");
  if (event.type === "gameOver") void showResult(event);
  updateScore();
  updateControls();
}

function newEngine(mode = state.mode) {
  clearTimeout(state.cpuTimer);
  state.transcript = [];
  state.sequence = 0;
  state.engine = new CueStrikeEngine({ mode, onEvent: record });
  state.engine.players[0].name = "You";
  if (mode !== "practice") state.engine.players[1].name = "CueBot";
  byId("gameOverlay").classList.add("hidden");
  state.power = 0.45;
  state.aimAngle = 0;
  state.accumulator = 0;
  byId("powerSlider").value = "45";
  byId("powerValue").value = "45";
  updateScore();
  updateControls();
}

function canvasPoint(event) {
  const rectangle = canvas.getBoundingClientRect();
  return {
    x: (event.clientX - rectangle.left) * LOGICAL_WIDTH / rectangle.width,
    y: (event.clientY - rectangle.top) * LOGICAL_HEIGHT / rectangle.height
  };
}

function canHumanAct() {
  return state.engine && state.engine.currentPlayer === 0 && state.engine.winner === null;
}

canvas.addEventListener("pointerdown", (event) => {
  if (!canHumanAct()) return;
  const point = canvasPoint(event);
  if (state.engine.phase === "ballInHand") {
    if (state.engine.placeCueBall(point.x, point.y)) playTone(310, 0.04);
    return;
  }
  if (state.engine.phase !== "aiming") return;
  state.dragging = true;
  aimAt(point);
  canvas.setPointerCapture(event.pointerId);
});

canvas.addEventListener("pointermove", (event) => {
  if (!state.dragging) return;
  aimAt(canvasPoint(event));
});

function aimAt(point) {
  const cue = state.engine.cueBall;
  const distance = Math.hypot(point.x - cue.x, point.y - cue.y);
  if (distance < 8) return;
  const requestedAngle = Math.atan2(point.y - cue.y, point.x - cue.x);
  state.aimAngle = state.engine.mustShootForward
    ? Math.max(-1.47, Math.min(1.47, requestedAngle))
    : requestedAngle;
}

function releaseAim() {
  if (!state.dragging) return;
  state.dragging = false;
}

function strike() {
  if (!canHumanAct() || state.engine.phase !== "aiming") return;
  if (state.engine.shoot(state.aimAngle, state.power)) {
    state.dragging = false;
    updateControls();
  }
}

canvas.addEventListener("pointerup", releaseAim);
canvas.addEventListener("pointercancel", releaseAim);
canvas.addEventListener("keydown", (event) => {
  if (!canHumanAct() || state.engine.phase !== "aiming") return;
  if (event.key === "ArrowLeft") state.aimAngle -= 0.035;
  if (event.key === "ArrowRight") state.aimAngle += 0.035;
  if (event.key === "ArrowUp") state.power = Math.min(1, state.power + 0.05);
  if (event.key === "ArrowDown") state.power = Math.max(0.05, state.power - 0.05);
  if (event.key === " " || event.key === "Enter") {
    event.preventDefault();
    strike();
  }
  syncPowerControl();
});

byId("powerSlider").addEventListener("input", (event) => {
  state.power = Number(event.target.value) / 100;
  syncPowerControl();
});
byId("strikeButton").addEventListener("click", strike);

function syncPowerControl() {
  const value = Math.round(state.power * 100);
  byId("powerSlider").value = String(value);
  byId("powerValue").value = String(value);
  byId("powerSlider").style.setProperty("--power", `${value}%`);
}

function updateControls() {
  if (!state.engine) return;
  const enabled = canHumanAct() && state.engine.phase === "aiming";
  byId("powerSlider").disabled = !enabled;
  byId("strikeButton").disabled = !enabled;
  canvas.classList.toggle("disabled", !enabled && state.engine.phase !== "ballInHand");
}

function roundedRectangle(x, y, width, height, radius) {
  context.beginPath();
  context.roundRect(x, y, width, height, radius);
}

function drawTable() {
  const gradient = context.createLinearGradient(0, 0, 1000, 540);
  gradient.addColorStop(0, "#142c56");
  gradient.addColorStop(0.5, "#071c3b");
  gradient.addColorStop(1, "#10294f");
  context.fillStyle = gradient;
  context.fillRect(0, 0, 1000, 540);

  context.shadowColor = "rgba(0,0,0,.7)";
  context.shadowBlur = 28;
  roundedRectangle(22, 22, 956, 496, 30);
  context.fillStyle = "#382211";
  context.fill();
  context.shadowBlur = 0;

  const rail = context.createLinearGradient(0, 30, 0, 510);
  rail.addColorStop(0, "#0a87a5");
  rail.addColorStop(0.5, "#06465f");
  rail.addColorStop(1, "#032d48");
  roundedRectangle(33, 33, 934, 474, 24);
  context.fillStyle = rail;
  context.fill();

  const lightShift = state.motion ? Math.sin(performance.now() / 2400) * 22 : 0;
  const cloth = context.createRadialGradient(500 + lightShift, 270, 20, 500, 270, 560);
  cloth.addColorStop(0, "#1596a7");
  cloth.addColorStop(1, "#056070");
  roundedRectangle(TABLE.left, TABLE.top, TABLE.right - TABLE.left, TABLE.bottom - TABLE.top, 13);
  context.fillStyle = cloth;
  context.fill();

  context.save();
  context.setLineDash([6, 8]);
  context.strokeStyle = "rgba(255,255,255,.16)";
  context.lineWidth = 1.5;
  context.beginPath();
  context.moveTo(BAULK_X, TABLE.top + 4);
  context.lineTo(BAULK_X, TABLE.bottom - 4);
  context.stroke();
  context.restore();

  context.fillStyle = "rgba(255,255,255,.4)";
  for (let index = 1; index < 4; index++) {
    for (const side of [TABLE.top - 18, TABLE.bottom + 18]) {
      context.beginPath();
      context.arc(TABLE.left + (TABLE.right - TABLE.left) * index / 4, side, 2.1, 0, Math.PI * 2);
      context.fill();
    }
  }
  for (const pocket of POCKETS) {
    const pocketGradient = context.createRadialGradient(pocket.x - 4, pocket.y - 4, 2, pocket.x, pocket.y, 26);
    pocketGradient.addColorStop(0, "#06101c");
    pocketGradient.addColorStop(1, "#00040a");
    context.fillStyle = pocketGradient;
    context.beginPath();
    context.arc(pocket.x, pocket.y, 24, 0, Math.PI * 2);
    context.fill();
  }
}

function drawBall(ball) {
  if (ball.pocketed) return;
  context.save();
  context.translate(ball.x, ball.y);
  context.shadowColor = "rgba(0,0,0,.42)";
  context.shadowBlur = 8;
  context.shadowOffsetY = 5;
  context.beginPath();
  context.arc(0, 0, BALL_RADIUS, 0, Math.PI * 2);
  context.fillStyle = ball.id === 0 || ball.id > 8 ? "#f8f5e9" : colors[ball.id];
  context.fill();
  context.shadowColor = "transparent";
  if (ball.id > 8) {
    context.save();
    context.clip();
    context.fillStyle = colors[ball.id];
    context.fillRect(-BALL_RADIUS, -5.4, BALL_RADIUS * 2, 10.8);
    context.restore();
  }
  if (ball.id !== 0) {
    context.beginPath();
    context.arc(0, 0, 4.9, 0, Math.PI * 2);
    context.fillStyle = "#fdfcf6";
    context.fill();
    context.fillStyle = "#111722";
    context.font = "bold 6.6px Manrope, sans-serif";
    context.textAlign = "center";
    context.textBaseline = "middle";
    context.fillText(String(ball.id), 0, 0.2);
  }
  const shine = context.createRadialGradient(-4, -5, 0, -4, -5, 7);
  shine.addColorStop(0, "rgba(255,255,255,.8)");
  shine.addColorStop(1, "rgba(255,255,255,0)");
  context.fillStyle = shine;
  context.beginPath();
  context.arc(-3, -4, 7, 0, Math.PI * 2);
  context.fill();
  context.restore();
}

function drawAim() {
  if (!state.aimGuide || !canHumanAct() || state.engine.phase !== "aiming") return;
  const cue = state.engine.cueBall;
  const angle = state.dragging ? state.aimAngle : state.aimAngle || 0;
  context.save();
  context.setLineDash([7, 9]);
  context.lineWidth = 1.4;
  context.strokeStyle = "rgba(255,255,255,.65)";
  const collision = projectedCollision(cue, angle);
  const guideLength = collision ? collision.distance : 560;
  context.beginPath();
  context.moveTo(cue.x + Math.cos(angle) * 18, cue.y + Math.sin(angle) * 18);
  context.lineTo(cue.x + Math.cos(angle) * guideLength, cue.y + Math.sin(angle) * guideLength);
  context.stroke();
  if (collision) {
    context.setLineDash([]);
    context.strokeStyle = "rgba(255,255,255,.32)";
    context.beginPath();
    context.arc(collision.x, collision.y, BALL_RADIUS, 0, Math.PI * 2);
    context.stroke();
  }
  context.setLineDash([]);
  const pull = 28 + state.power * 75;
  const backX = cue.x - Math.cos(angle) * pull;
  const backY = cue.y - Math.sin(angle) * pull;
  context.lineCap = "round";
  context.lineWidth = 8;
  context.strokeStyle = "#12325c";
  context.beginPath();
  context.moveTo(backX, backY);
  context.lineTo(backX - Math.cos(angle) * 185, backY - Math.sin(angle) * 185);
  context.stroke();
  context.lineWidth = 3;
  context.strokeStyle = "#e8c48a";
  context.beginPath();
  context.moveTo(backX, backY);
  context.lineTo(backX - Math.cos(angle) * 120, backY - Math.sin(angle) * 120);
  context.stroke();
  context.restore();
}

function projectedCollision(cue, angle) {
  const directionX = Math.cos(angle);
  const directionY = Math.sin(angle);
  let closest = null;
  for (const ball of state.engine.balls) {
    if (ball.id === 0 || ball.pocketed) continue;
    const offsetX = ball.x - cue.x;
    const offsetY = ball.y - cue.y;
    const projection = offsetX * directionX + offsetY * directionY;
    if (projection <= BALL_RADIUS * 2) continue;
    const perpendicularSquared = offsetX * offsetX + offsetY * offsetY - projection * projection;
    const collisionRadius = BALL_RADIUS * 2;
    if (perpendicularSquared > collisionRadius * collisionRadius) continue;
    const distance = projection - Math.sqrt(collisionRadius * collisionRadius - perpendicularSquared);
    if (!closest || distance < closest.distance) {
      closest = { distance, x: cue.x + directionX * distance, y: cue.y + directionY * distance };
    }
  }
  return closest;
}

function drawBallInHand() {
  if (!canHumanAct() || state.engine.phase !== "ballInHand") return;
  context.save();
  context.fillStyle = "rgba(255,255,255,.9)";
  context.font = "600 16px Manrope, sans-serif";
  context.textAlign = "center";
  const instruction = state.engine.ballInHandRule === "baulkForward"
    ? "SCRATCH · TAP THE BAULK LINE · NEXT SHOT FORWARD ONLY"
    : "BALL IN HAND · TAP A CLEAR POSITION";
  context.fillText(instruction, 500, 28);
  context.restore();
}

function render() {
  drawTable();
  drawAim();
  for (const ball of state.engine.balls) drawBall(ball);
  drawBallInHand();
}

function frame(now) {
  const seconds = Math.min(0.05, (now - state.lastFrame) / 1000);
  state.lastFrame = now;
  const wasMoving = state.engine.phase === "moving";
  state.accumulator += seconds;
  let simulations = 0;
  while (state.accumulator >= FIXED_STEP && simulations < 14) {
    state.engine.step(FIXED_STEP);
    state.accumulator -= FIXED_STEP;
    simulations++;
    if (state.engine.phase !== "moving") {
      state.accumulator = 0;
      break;
    }
  }
  if (wasMoving && state.engine.phase !== "moving") scheduleCpu();
  render();
  requestAnimationFrame(frame);
}

function scheduleCpu() {
  clearTimeout(state.cpuTimer);
  if (state.engine.currentPlayer !== 1 || state.engine.winner !== null) return;
  state.engine.message = "CueBot is reading the table…";
  updateScore();
  updateControls();
  state.cpuTimer = setTimeout(() => {
    const decision = state.engine.cpuDecision();
    if (decision) state.engine.shoot(decision.angle, decision.power);
  }, 560);
}

function groupLabel(group) {
  if (!group) return "Open table";
  return group[0].toUpperCase() + group.slice(1);
}

function updateScore() {
  if (!state.engine) return;
  const [one, two] = state.engine.players;
  byId("playerOneGroup").textContent = groupLabel(one.group);
  byId("playerTwoGroup").textContent = groupLabel(two.group);
  byId("playerOneRemaining").textContent = one.group ? state.engine.ballsRemaining(one.group) : 7;
  byId("playerTwoRemaining").textContent = two.group ? state.engine.ballsRemaining(two.group) : 7;
  byId("playerOne").classList.toggle("active", state.engine.currentPlayer === 0 && state.engine.winner === null);
  byId("playerTwo").classList.toggle("active", state.engine.currentPlayer === 1 && state.engine.winner === null);
  byId("turnMessage").textContent = state.engine.message;
  updateControls();
}

async function showResult(event) {
  const overlay = byId("gameOverlay");
  byId("resultTitle").textContent = event.winner === 0 ? "You own this table" : "CueBot takes the frame";
  const digest = await hashTranscript(state.transcript);
  const settlement = state.mode === "practice" ? "No CUE moved." : "Simulation only. No CUE moved and no result was submitted.";
  byId("resultDetail").textContent = `${event.reason}. ${settlement} Replay proof ${digest.slice(0, 12)}…`;
  overlay.classList.remove("hidden");
}

function selectedTier() {
  const source = state.mode === "tournament" ? TOURNAMENT_TIERS : WAGER_TIERS;
  return source.find((tier) => tier.key === byId("tierSelect").value) || source[0];
}

function economyMarkup() {
  if (state.mode === "practice") return `<div><span>Entry</span><strong>Free</strong></div><div><span>Wallet</span><strong>Not needed</strong></div>`;
  if (state.mode === "ranked") return `<div><span>Entry</span><strong>Free</strong></div><div><span>Verified win</span><strong>0.5 CUE</strong></div><small>Rewards come from CueRewardsPool and never from the player device.</small>`;
  const tier = selectedTier();
  if (state.mode === "wager") {
    const payout = directMatchPayout(tier.cue);
    return `<div><span>Each player</span><strong>${formatCue(tier.cue)}</strong></div><div><span>Winner</span><strong>${formatCue(payout.winner)}</strong></div><div><span>Burn</span><strong>${formatCue(payout.burned)}</strong></div><div><span>Rewards pool</span><strong>${formatCue(payout.rewardsPool)}</strong></div><small>NFT bonus is separate and is paid only where the deployed contract allows it.</small>`;
  }
  if (state.mode === "sitAndGo") {
    const payout = sitAndGoPayout(tier.cue);
    return `<div><span>Entry</span><strong>${formatCue(tier.cue)}</strong></div><div><span>First place</span><strong>${formatCue(payout.first)}</strong></div><div><span>Second place</span><strong>${formatCue(payout.second)}</strong></div><div><span>Burn</span><strong>${formatCue(payout.burned)}</strong></div>`;
  }
  const payout = tournamentPayout(tier.cue, 16);
  return `<div><span>Entry</span><strong>${formatCue(tier.cue)}</strong></div><div><span>Minimum NFT</span><strong>${tier.nft}</strong></div><div><span>First at 16</span><strong>${formatCue(payout.first)}</strong></div><div><span>Second at 16</span><strong>${formatCue(payout.second)}</strong></div><small>Final prizes use the registered player count stored by the contract.</small>`;
}

function renderFlow() {
  const tier = state.mode === "practice" || state.mode === "ranked" ? { cue: 0 } : selectedTier();
  byId("actionFlow").innerHTML = actionPlan(state.mode, tier.cue).map((item, index) => `
    <div class="flowStep"><b>${String(index + 1).padStart(2, "0")}</b><strong>${item.label}</strong><p>${item.detail}</p></div>
  `).join("");
}

function renderMode() {
  const mode = GAME_MODES[state.mode];
  const tierSelect = byId("tierSelect");
  const usesTiers = ["wager", "sitAndGo", "tournament"].includes(state.mode);
  byId("modeLabel").textContent = mode.label;
  byId("modeEyebrow").textContent = mode.eyebrow;
  byId("panelModeTitle").textContent = mode.label;
  byId("modeDescription").textContent = mode.description;
  byId("entryControls").classList.toggle("hidden", !usesTiers);
  byId("tournamentIdLabel").classList.toggle("hidden", state.mode !== "tournament");
  byId("tournamentId").classList.toggle("hidden", state.mode !== "tournament");
  byId("targetLabel").classList.toggle("hidden", state.mode !== "wager");
  byId("targetAddress").classList.toggle("hidden", state.mode !== "wager");
  if (usesTiers) {
    const tiers = state.mode === "tournament" ? TOURNAMENT_TIERS : WAGER_TIERS;
    tierSelect.innerHTML = tiers.map((tier) => `<option value="${tier.key}">${tier.label} · ${formatCue(tier.cue)}</option>`).join("");
  }
  byId("economyPreview").innerHTML = economyMarkup();
  const status = deploymentStatus(state.mode);
  byId("deploymentStatus").textContent = status.label;
  byId("deploymentGate").classList.toggle("ready", status.ready);
  if (state.mode === "practice") {
    byId("deploymentDetail").textContent = "Free play against CueBot never requires a wallet or CUE.";
    byId("startMatch").textContent = "Start free match";
  } else if (status.ready) {
    byId("deploymentDetail").textContent = "Token, mode contract, and game service are configured.";
    byId("startMatch").textContent = state.mode === "ranked" ? "Find ranked match" : "Enter with CUE";
  } else {
    byId("deploymentDetail").textContent = "Live value is locked until token, contract, and authoritative game service addresses are configured.";
    byId("startMatch").textContent = "Run local simulation";
  }
  byId("environmentLabel").textContent = status.ready && state.mode !== "practice" ? "Live services configured" : "Local test arena";
  byId("actionNotice").textContent = "";
  renderFlow();
}

document.querySelectorAll("[data-mode]").forEach((button) => button.addEventListener("click", () => {
  document.querySelectorAll("[data-mode]").forEach((item) => item.classList.toggle("active", item === button));
  state.mode = button.dataset.mode;
  renderMode();
  newEngine(state.mode);
}));

byId("tierSelect").addEventListener("change", () => {
  byId("economyPreview").innerHTML = economyMarkup();
  renderFlow();
});

async function connectWallet() {
  const button = byId("gameWallet");
  if (isNativeApp) {
    const message = "Native wallet connection remains locked until the audited mobile wallet adapter is configured.";
    byId("actionNotice").textContent = message;
    throw new Error(message);
  }
  button.disabled = true;
  try {
    state.wallet = await connectGameWallet();
    button.textContent = `${state.wallet.address.slice(0, 6)}…${state.wallet.address.slice(-4)}`;
    return state.wallet;
  } catch (error) {
    byId("actionNotice").textContent = error.message;
    throw error;
  } finally {
    button.disabled = false;
  }
}

byId("gameWallet").addEventListener("click", () => void connectWallet().catch(() => {}));

byId("startMatch").addEventListener("click", async () => {
  const notice = byId("actionNotice");
  const status = deploymentStatus(state.mode);
  notice.textContent = "";
  if (state.mode !== "practice" && status.ready) {
    if (state.mode === "ranked") {
      notice.textContent = "Ranked matchmaking must be issued by the configured authoritative game service.";
      return;
    }
    const tier = selectedTier();
    try {
      const wallet = state.wallet || await connectWallet();
      notice.textContent = "Waiting for exact CUE approval and contract confirmation…";
      await enterPaidMode({
        mode: state.mode,
        amountCue: tier.cue,
        tier: tier.contractTier,
        targetAddress: byId("targetAddress").value.trim(),
        tournamentId: Number(byId("tournamentId").value)
      }, wallet.signer);
      notice.textContent = "Entry confirmed. Waiting for the authoritative server to assign the match.";
      return;
    } catch (error) {
      notice.textContent = error.shortMessage || error.message;
      return;
    }
  }
  newEngine(state.mode);
  notice.textContent = state.mode === "practice" ? "Fresh free play rack ready. CueBot will take every opposing turn." : "Local simulation only. No CUE was approved, locked, won, or lost.";
  canvas.focus();
});

byId("resetGame").addEventListener("click", () => newEngine(state.mode));
byId("rackAgain").addEventListener("click", () => newEngine(state.mode));

let audioContext;
function playTone(frequency, duration) {
  if (!state.sound) return;
  const AudioEngine = window.AudioContext || window.webkitAudioContext;
  if (!AudioEngine) return;
  audioContext ||= new AudioEngine();
  const oscillator = audioContext.createOscillator();
  const gain = audioContext.createGain();
  oscillator.frequency.value = frequency;
  oscillator.type = "sine";
  gain.gain.setValueAtTime(0.05, audioContext.currentTime);
  gain.gain.exponentialRampToValueAtTime(0.001, audioContext.currentTime + duration);
  oscillator.connect(gain).connect(audioContext.destination);
  oscillator.start();
  oscillator.stop(audioContext.currentTime + duration);
}

async function haptic(style) {
  try {
    await window.Capacitor?.Plugins?.Haptics?.impact({ style });
  } catch {
    // Haptics are an enhancement and must never interrupt a match.
  }
}

function setSound(enabled) {
  state.sound = enabled;
  byId("soundSetting").checked = enabled;
  byId("soundToggle").textContent = enabled ? "Sound on" : "Sound off";
}

byId("soundToggle").addEventListener("click", () => setSound(!state.sound));
byId("soundSetting").addEventListener("change", (event) => setSound(event.target.checked));
byId("aimGuideSetting").addEventListener("change", (event) => { state.aimGuide = event.target.checked; });
byId("motionSetting").addEventListener("change", (event) => { state.motion = event.target.checked; });
byId("openSettings").addEventListener("click", () => byId("settingsDialog").showModal());

async function loadArena() {
  const fill = byId("loaderFill");
  const text = byId("loaderText");
  const stages = [[24, "Checking table geometry"], [52, "Racking the balls"], [78, "Loading fair play rules"], [100, "Arena ready"]];
  for (const [progress, label] of stages) {
    fill.style.width = `${progress}%`;
    text.textContent = label;
    await new Promise((resolve) => setTimeout(resolve, 180));
  }
  byId("loadingScreen").classList.add("done");
}

function resizeRenderer() {
  const scale = Math.min(2, Math.max(1, window.devicePixelRatio || 1));
  if (scale === state.renderScale && canvas.width === LOGICAL_WIDTH * scale) return;
  state.renderScale = scale;
  canvas.width = Math.round(LOGICAL_WIDTH * scale);
  canvas.height = Math.round(LOGICAL_HEIGHT * scale);
  context.setTransform(scale, 0, 0, scale, 0, 0);
}

window.addEventListener("resize", resizeRenderer, { passive: true });
document.addEventListener("visibilitychange", () => {
  state.lastFrame = performance.now();
  state.accumulator = 0;
});

resizeRenderer();
newEngine();
renderMode();
syncPowerControl();
if (isNativeApp) {
  byId("gameWallet").textContent = "Wallet locked";
  byId("gameWallet").title = "Activates with the audited mobile wallet adapter";
}
requestAnimationFrame(frame);
void loadArena();

if ("serviceWorker" in navigator && location.protocol.startsWith("http")) {
  window.addEventListener("load", () => navigator.serviceWorker.register("./service-worker.js").catch(() => {}));
}
