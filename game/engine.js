export const TABLE = Object.freeze({ left: 48, top: 48, right: 952, bottom: 492 });
export const BALL_RADIUS = 11;
const STOP_SPEED = 4;
const MAX_SHOT_SPEED = 1180;
const FRICTION = 0.992;
const RESTITUTION = 0.96;
const POCKET_RADIUS = 24;

export const POCKETS = Object.freeze([
  { x: TABLE.left, y: TABLE.top },
  { x: 500, y: TABLE.top - 3 },
  { x: TABLE.right, y: TABLE.top },
  { x: TABLE.left, y: TABLE.bottom },
  { x: 500, y: TABLE.bottom + 3 },
  { x: TABLE.right, y: TABLE.bottom }
]);

export function groupForBall(id) {
  if (id >= 1 && id <= 7) return "solids";
  if (id >= 9 && id <= 15) return "stripes";
  if (id === 8) return "eight";
  return "cue";
}

export function isValidFirstContact(group, remaining, ballId) {
  if (group === null) return ballId !== 0 && ballId !== 8;
  if (remaining === 0) return ballId === 8;
  return groupForBall(ballId) === group;
}

function rackPosition(row, column) {
  const spacingX = BALL_RADIUS * Math.sqrt(3) + 0.55;
  const spacingY = BALL_RADIUS * 2 + 0.55;
  return { x: 715 + row * spacingX, y: 270 + (column - row / 2) * spacingY };
}

function createRack() {
  const balls = [{ id: 0, x: 270, y: 270, vx: 0, vy: 0, pocketed: false }];
  const rackIds = [1, 9, 2, 10, 8, 3, 11, 4, 12, 5, 13, 6, 14, 7, 15];
  let index = 0;
  for (let row = 0; row < 5; row++) {
    for (let column = 0; column <= row; column++) {
      const position = rackPosition(row, column);
      balls.push({ id: rackIds[index++], ...position, vx: 0, vy: 0, pocketed: false });
    }
  }
  return balls;
}

function distanceSquared(a, b) {
  const dx = a.x - b.x;
  const dy = a.y - b.y;
  return dx * dx + dy * dy;
}

export class CueStrikeEngine {
  constructor(options = {}) {
    this.onEvent = options.onEvent || (() => {});
    this.mode = options.mode || "practice";
    this.reset(this.mode);
  }

  reset(mode = this.mode) {
    this.mode = mode;
    this.balls = createRack();
    this.players = [
      { name: "You", group: null },
      { name: mode === "practice" ? "Practice table" : "CueBot", group: null }
    ];
    this.currentPlayer = 0;
    this.phase = "aiming";
    this.winner = null;
    this.shot = null;
    this.shotNumber = 0;
    this.message = mode === "practice" ? "Practice table ready" : "Break to begin";
    this.onEvent({ type: "reset", message: this.message });
  }

  get cueBall() {
    return this.balls[0];
  }

  ballsRemaining(group) {
    return this.balls.filter((ball) => !ball.pocketed && groupForBall(ball.id) === group).length;
  }

  validTargets(playerIndex = this.currentPlayer) {
    const group = this.players[playerIndex].group;
    const remaining = group ? this.ballsRemaining(group) : null;
    return this.balls.filter((ball) => !ball.pocketed && isValidFirstContact(group, remaining, ball.id));
  }

  shoot(angle, power) {
    if (this.phase !== "aiming" || this.winner !== null) return false;
    const normalizedPower = Math.min(1, Math.max(0.04, power));
    this.cueBall.vx = Math.cos(angle) * MAX_SHOT_SPEED * normalizedPower;
    this.cueBall.vy = Math.sin(angle) * MAX_SHOT_SPEED * normalizedPower;
    this.phase = "moving";
    this.shotNumber++;
    this.shot = {
      player: this.currentPlayer,
      firstContact: null,
      pocketed: [],
      scratch: false,
      railAfterContact: false,
      railBalls: new Set()
    };
    this.message = `${this.players[this.currentPlayer].name} plays shot ${this.shotNumber}`;
    this.onEvent({ type: "shot", player: this.currentPlayer, power: normalizedPower });
    return true;
  }

  step(seconds) {
    if (this.phase !== "moving") return false;
    const safeSeconds = Math.min(0.04, Math.max(0, seconds));
    const substeps = Math.max(1, Math.ceil(safeSeconds / (1 / 240)));
    const dt = safeSeconds / substeps;
    for (let step = 0; step < substeps; step++) this.integrate(dt);
    if (this.balls.every((ball) => ball.pocketed || Math.hypot(ball.vx, ball.vy) < STOP_SPEED)) {
      for (const ball of this.balls) {
        ball.vx = 0;
        ball.vy = 0;
      }
      this.resolveShot();
    }
    return true;
  }

  integrate(dt) {
    for (const ball of this.balls) {
      if (ball.pocketed) continue;
      ball.x += ball.vx * dt;
      ball.y += ball.vy * dt;
      const decay = Math.pow(FRICTION, dt * 240);
      ball.vx *= decay;
      ball.vy *= decay;
      this.resolveRail(ball);
      this.resolvePocket(ball);
    }
    for (let i = 0; i < this.balls.length; i++) {
      const a = this.balls[i];
      if (a.pocketed) continue;
      for (let j = i + 1; j < this.balls.length; j++) {
        const b = this.balls[j];
        if (!b.pocketed) this.resolveCollision(a, b);
      }
    }
  }

  resolveRail(ball) {
    let railHit = false;
    if (ball.x - BALL_RADIUS < TABLE.left) {
      ball.x = TABLE.left + BALL_RADIUS;
      ball.vx = Math.abs(ball.vx) * RESTITUTION;
      railHit = true;
    } else if (ball.x + BALL_RADIUS > TABLE.right) {
      ball.x = TABLE.right - BALL_RADIUS;
      ball.vx = -Math.abs(ball.vx) * RESTITUTION;
      railHit = true;
    }
    if (ball.y - BALL_RADIUS < TABLE.top) {
      ball.y = TABLE.top + BALL_RADIUS;
      ball.vy = Math.abs(ball.vy) * RESTITUTION;
      railHit = true;
    } else if (ball.y + BALL_RADIUS > TABLE.bottom) {
      ball.y = TABLE.bottom - BALL_RADIUS;
      ball.vy = -Math.abs(ball.vy) * RESTITUTION;
      railHit = true;
    }
    if (railHit && this.shot) {
      if (ball.id !== 0) this.shot.railBalls.add(ball.id);
      if (this.shot.firstContact !== null) this.shot.railAfterContact = true;
    }
  }

  resolvePocket(ball) {
    for (const pocket of POCKETS) {
      if (distanceSquared(ball, pocket) <= POCKET_RADIUS * POCKET_RADIUS) {
        ball.pocketed = true;
        ball.vx = 0;
        ball.vy = 0;
        if (!this.shot) return;
        if (ball.id === 0) this.shot.scratch = true;
        else if (!this.shot.pocketed.includes(ball.id)) this.shot.pocketed.push(ball.id);
        this.onEvent({ type: "pocket", ballId: ball.id });
        return;
      }
    }
  }

  resolveCollision(a, b) {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const distance = Math.hypot(dx, dy);
    const minimum = BALL_RADIUS * 2;
    if (distance === 0 || distance >= minimum) return;
    const nx = dx / distance;
    const ny = dy / distance;
    const overlap = minimum - distance;
    a.x -= nx * overlap / 2;
    a.y -= ny * overlap / 2;
    b.x += nx * overlap / 2;
    b.y += ny * overlap / 2;
    const relative = (b.vx - a.vx) * nx + (b.vy - a.vy) * ny;
    if (relative < 0) {
      const impulse = -(1 + RESTITUTION) * relative / 2;
      a.vx -= impulse * nx;
      a.vy -= impulse * ny;
      b.vx += impulse * nx;
      b.vy += impulse * ny;
    }
    if (this.shot && this.shot.firstContact === null) {
      if (a.id === 0 && b.id !== 0) this.shot.firstContact = b.id;
      if (b.id === 0 && a.id !== 0) this.shot.firstContact = a.id;
    }
  }

  resolveShot() {
    if (!this.shot) return;
    if (this.mode === "practice") {
      if (this.shot.scratch) this.restoreCueBall();
      if (this.shot.pocketed.includes(8)) {
        this.message = "Eight ball pocketed. Rack again when ready.";
        this.winner = 0;
        this.phase = "ended";
      } else {
        this.phase = "aiming";
        this.message = this.shot.pocketed.length ? "Clean pocket. Keep practising." : "Line up the next shot.";
      }
      this.onEvent({ type: "turn", message: this.message, player: 0 });
      return;
    }

    const playerIndex = this.shot.player;
    const opponentIndex = 1 - playerIndex;
    const player = this.players[playerIndex];
    const isBreak = this.shotNumber === 1;
    const remainingBefore = player.group ? this.ballsRemaining(player.group) + this.shot.pocketed.filter((id) => groupForBall(id) === player.group).length : null;
    const legalContact = this.shot.firstContact !== null && isValidFirstContact(player.group, remainingBefore, this.shot.firstContact);
    const actionAfterContact = this.shot.pocketed.length > 0 || this.shot.railAfterContact;
    const legalBreak = this.shot.pocketed.length > 0 || this.shot.railBalls.size >= 4;
    let foul = this.shot.scratch || !legalContact || !actionAfterContact || (isBreak && !legalBreak);

    if (isBreak && this.shot.pocketed.includes(8)) {
      this.respotEightBall();
      this.shot.pocketed = this.shot.pocketed.filter((id) => id !== 8);
      this.onEvent({ type: "respot", ballId: 8, reason: "Eight ball on the break" });
    }

    if (player.group === null && !foul) {
      const assignment = this.shot.pocketed.map(groupForBall).find((group) => group === "solids" || group === "stripes");
      if (assignment) {
        player.group = assignment;
        this.players[opponentIndex].group = assignment === "solids" ? "stripes" : "solids";
        this.onEvent({ type: "groups", player: playerIndex, group: assignment });
      }
    }

    if (this.shot.pocketed.includes(8)) {
      const cleared = player.group !== null && this.ballsRemaining(player.group) === 0;
      this.winner = !foul && cleared ? playerIndex : opponentIndex;
      this.phase = "ended";
      this.message = !foul && cleared ? `${player.name} wins on the eight ball` : `${player.name} loses on an illegal eight ball`;
      this.onEvent({ type: "gameOver", winner: this.winner, reason: this.message });
      return;
    }

    const ownPocket = player.group
      ? this.shot.pocketed.some((id) => groupForBall(id) === player.group)
      : this.shot.pocketed.some((id) => groupForBall(id) === "solids" || groupForBall(id) === "stripes");

    if (foul) {
      this.currentPlayer = opponentIndex;
      this.restoreCueBall();
      this.phase = "ballInHand";
      if (this.shot.scratch) this.message = "Scratch. Ball in hand.";
      else if (isBreak && !legalBreak) this.message = "Illegal break. Ball in hand.";
      else if (!legalContact) this.message = "Foul contact. Ball in hand.";
      else this.message = "No rail after contact. Ball in hand.";
    } else if (ownPocket) {
      this.currentPlayer = playerIndex;
      this.phase = "aiming";
      this.message = `${player.name} continues`;
    } else {
      this.currentPlayer = opponentIndex;
      this.phase = "aiming";
      this.message = `${this.players[this.currentPlayer].name} at the table`;
    }
    this.onEvent({ type: "turn", player: this.currentPlayer, foul, message: this.message });
  }

  restoreCueBall() {
    const cue = this.cueBall;
    cue.pocketed = false;
    cue.vx = 0;
    cue.vy = 0;
    cue.x = 255;
    cue.y = 270;
    if (!this.canPlaceCueBall(cue.x, cue.y)) {
      cue.x = 180;
      cue.y = 210;
    }
  }

  respotEightBall() {
    const eight = this.balls.find((ball) => ball.id === 8);
    if (!eight) return;
    const candidates = [
      { x: 715 + BALL_RADIUS * Math.sqrt(3) * 2, y: 270 },
      { x: 715, y: 270 },
      { x: 650, y: 270 }
    ];
    const position = candidates.find(({ x, y }) => this.balls.every((ball) => ball.id === 8 || ball.pocketed || (ball.x - x) ** 2 + (ball.y - y) ** 2 >= (BALL_RADIUS * 2.1) ** 2)) || candidates[2];
    Object.assign(eight, position, { vx: 0, vy: 0, pocketed: false });
  }

  canPlaceCueBall(x, y) {
    if (x < TABLE.left + BALL_RADIUS || x > TABLE.right - BALL_RADIUS) return false;
    if (y < TABLE.top + BALL_RADIUS || y > TABLE.bottom - BALL_RADIUS) return false;
    return this.balls.every((ball) => ball.id === 0 || ball.pocketed || ((ball.x - x) ** 2 + (ball.y - y) ** 2) >= (BALL_RADIUS * 2.15) ** 2);
  }

  placeCueBall(x, y) {
    if (this.phase !== "ballInHand" || !this.canPlaceCueBall(x, y)) return false;
    Object.assign(this.cueBall, { x, y, vx: 0, vy: 0, pocketed: false });
    this.phase = "aiming";
    this.message = `${this.players[this.currentPlayer].name} placed the cue ball`;
    this.onEvent({ type: "placed", player: this.currentPlayer });
    return true;
  }

  cpuDecision() {
    if (this.currentPlayer !== 1 || this.winner !== null) return null;
    if (this.phase === "ballInHand") this.placeCueBall(250, 270);
    if (this.phase !== "aiming") return null;
    const cue = this.cueBall;
    const targets = this.validTargets(1);
    let best = null;
    for (const target of targets) {
      for (const pocket of POCKETS) {
        const tx = pocket.x - target.x;
        const ty = pocket.y - target.y;
        const targetDistance = Math.hypot(tx, ty) || 1;
        const ghost = {
          x: target.x - tx / targetDistance * BALL_RADIUS * 2,
          y: target.y - ty / targetDistance * BALL_RADIUS * 2
        };
        const shotDistance = Math.hypot(ghost.x - cue.x, ghost.y - cue.y);
        const score = shotDistance + targetDistance * 0.7;
        if (!best || score < best.score) best = { ghost, score, shotDistance, targetDistance };
      }
    }
    if (!best && targets[0]) best = { ghost: targets[0], shotDistance: 400, targetDistance: 400, score: 800 };
    if (!best) return null;
    const angle = Math.atan2(best.ghost.y - cue.y, best.ghost.x - cue.x) + (Math.random() - 0.5) * 0.025;
    const power = Math.min(0.92, Math.max(0.28, (best.shotDistance + best.targetDistance * 0.45) / 1050));
    return { angle, power };
  }
}
