import { expect } from "chai";
import { BAULK_X, CueStrikeEngine, groupForBall, isValidFirstContact } from "../game/engine.js";
import { airdropUnlock, directMatchPayout, sitAndGoPayout, tournamentPayout } from "../game/economy.js";

describe("CueStrike game rules and economy", function () {
  it("racks a cue ball and fifteen object balls", function () {
    const engine = new CueStrikeEngine();
    expect(engine.balls).to.have.length(16);
    expect(new Set(engine.balls.map((ball) => ball.id)).size).to.equal(16);
    expect(engine.phase).to.equal("aiming");
  });

  it("classifies object balls and legal first contacts", function () {
    expect(groupForBall(1)).to.equal("solids");
    expect(groupForBall(12)).to.equal("stripes");
    expect(groupForBall(8)).to.equal("eight");
    expect(isValidFirstContact(null, null, 8)).to.equal(false);
    expect(isValidFirstContact("solids", 3, 2)).to.equal(true);
    expect(isValidFirstContact("solids", 0, 8)).to.equal(true);
  });

  it("gives ball in hand after a no contact foul", function () {
    const engine = new CueStrikeEngine({ mode: "wager" });
    engine.shotNumber = 2;
    engine.shot = { player: 0, firstContact: null, pocketed: [], scratch: false, railAfterContact: false, railBalls: new Set() };
    engine.resolveShot();
    expect(engine.currentPlayer).to.equal(1);
    expect(engine.phase).to.equal("ballInHand");
  });

  it("requires a rail or pocket after legal contact", function () {
    const engine = new CueStrikeEngine({ mode: "wager" });
    engine.players[0].group = "solids";
    engine.players[1].group = "stripes";
    engine.shotNumber = 2;
    engine.shot = { player: 0, firstContact: 1, pocketed: [], scratch: false, railAfterContact: false, railBalls: new Set() };
    engine.resolveShot();
    expect(engine.phase).to.equal("ballInHand");
    expect(engine.message).to.contain("No rail");
  });

  it("hands free play to CueBot after the player misses", function () {
    const engine = new CueStrikeEngine({ mode: "practice" });
    engine.shotNumber = 2;
    engine.shot = { player: 0, firstContact: 1, pocketed: [], scratch: false, railAfterContact: true, railBalls: new Set([1]) };
    engine.resolveShot();
    expect(engine.currentPlayer).to.equal(1);
    expect(engine.players[1].name).to.equal("CueBot");
    expect(engine.cpuDecision()).to.have.keys("angle", "power");
  });

  it("places a scratched cue ball on the baulk line and blocks backward shots", function () {
    const engine = new CueStrikeEngine({ mode: "practice" });
    engine.shotNumber = 2;
    engine.shot = { player: 0, firstContact: 1, pocketed: [], scratch: true, railAfterContact: true, railBalls: new Set([1]) };
    engine.resolveShot();
    expect(engine.currentPlayer).to.equal(1);
    expect(engine.ballInHandRule).to.equal("baulkForward");
    expect(engine.placeCueBall(700, 210)).to.equal(true);
    expect(engine.cueBall.x).to.equal(BAULK_X);
    expect(engine.shoot(Math.PI, 0.5)).to.equal(false);
    expect(engine.shoot(0, 0.5)).to.equal(true);
  });

  it("respots an eight ball made on the break", function () {
    const engine = new CueStrikeEngine({ mode: "wager" });
    engine.balls.find((ball) => ball.id === 8).pocketed = true;
    engine.shotNumber = 1;
    engine.shot = { player: 0, firstContact: 1, pocketed: [8], scratch: false, railAfterContact: true, railBalls: new Set([1, 2, 3, 4]) };
    engine.resolveShot();
    expect(engine.balls.find((ball) => ball.id === 8).pocketed).to.equal(false);
    expect(engine.winner).to.equal(null);
  });

  it("awards a legal eight ball and rejects an early eight ball", function () {
    const legal = new CueStrikeEngine({ mode: "wager" });
    legal.players[0].group = "solids";
    legal.players[1].group = "stripes";
    legal.balls.filter((ball) => groupForBall(ball.id) === "solids").forEach((ball) => { ball.pocketed = true; });
    legal.balls.find((ball) => ball.id === 8).pocketed = true;
    legal.shotNumber = 2;
    legal.shot = { player: 0, firstContact: 8, pocketed: [8], scratch: false, railAfterContact: true, railBalls: new Set() };
    legal.resolveShot();
    expect(legal.winner).to.equal(0);

    const early = new CueStrikeEngine({ mode: "wager" });
    early.players[0].group = "solids";
    early.players[1].group = "stripes";
    early.balls.find((ball) => ball.id === 8).pocketed = true;
    early.shotNumber = 2;
    early.shot = { player: 0, firstContact: 1, pocketed: [8], scratch: false, railAfterContact: true, railBalls: new Set() };
    early.resolveShot();
    expect(early.winner).to.equal(1);
  });

  it("matches the contract payout percentages", function () {
    expect(directMatchPayout(100)).to.deep.include({ pot: 200, winner: 196, burned: 2, rewardsPool: 2 });
    expect(sitAndGoPayout(100)).to.deep.include({ pot: 1600, first: 1120, second: 320, burned: 128, development: 32 });
    expect(tournamentPayout(100, 16)).to.deep.include({ pot: 1600, first: 960, second: 320, burned: 160, dao: 160 });
  });

  it("unlocks airdrop allocations only at ten game milestones", function () {
    expect(airdropUnlock(1000, 9)).to.equal(0);
    expect(airdropUnlock(1000, 10)).to.equal(100);
    expect(airdropUnlock(1000, 1000)).to.equal(1000);
  });
});
