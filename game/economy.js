export const WAGER_TIERS = Object.freeze([
  { key: "micro", label: "Micro", cue: 10, contractTier: 0 },
  { key: "small", label: "Small", cue: 50, contractTier: 1 },
  { key: "medium", label: "Medium", cue: 100, contractTier: 2 },
  { key: "large", label: "Large", cue: 500, contractTier: 3 },
  { key: "xlarge", label: "XLarge", cue: 1000, contractTier: 4 },
  { key: "whale", label: "Whale", cue: 5000, contractTier: 5 }
]);

export const TOURNAMENT_TIERS = Object.freeze([
  { key: "weekly", label: "Weekly", cue: 50, nft: "None", contractTier: 0 },
  { key: "monthly", label: "Monthly", cue: 200, nft: "Common", contractTier: 1 },
  { key: "regional", label: "Regional", cue: 500, nft: "Rare", contractTier: 2 },
  { key: "world", label: "World", cue: 5000, nft: "Legendary", contractTier: 3 }
]);

export const GAME_MODES = Object.freeze({
  practice: {
    label: "Free play",
    eyebrow: "No CUE at risk",
    description: "Play a full rules match against CueBot without a wallet or entry.",
    contract: "None"
  },
  ranked: {
    label: "Ranked",
    eyebrow: "Skill rating",
    description: "Competitive result verification with the standard winner reward.",
    contract: "CueRewardsPool"
  },
  wager: {
    label: "Direct match",
    eyebrow: "One against one",
    description: "Equal CUE stakes lock before play and settle after an oracle verified result.",
    contract: "CueEscrow"
  },
  sitAndGo: {
    label: "Sixteen player",
    eyebrow: "Quick tournament",
    description: "A fixed sixteen player queue with first and second place payouts.",
    contract: "CueSitAndGo"
  },
  tournament: {
    label: "Championship",
    eyebrow: "Bracket play",
    description: "Eight to one hundred twenty eight player brackets with tier based access.",
    contract: "CueTournament"
  }
});

export function directMatchPayout(wager, nftBonusBps = 0) {
  const pot = wager * 2;
  const burned = pot * 0.01;
  const rewardsPool = pot * 0.01;
  const winner = pot - burned - rewardsPool;
  const nftBonus = wager * nftBonusBps / 10000;
  return { pot, winner, burned, rewardsPool, nftBonus };
}

export function sitAndGoPayout(entry) {
  const pot = entry * 16;
  return {
    pot,
    first: pot * 0.7,
    second: pot * 0.2,
    burned: pot * 0.08,
    development: pot * 0.02
  };
}

export function tournamentPayout(entry, players = 16) {
  const pot = entry * players;
  return {
    pot,
    first: pot * 0.6,
    second: pot * 0.2,
    burned: pot * 0.1,
    dao: pot * 0.1
  };
}

export function airdropUnlock(totalAllocation, verifiedGames) {
  const milestones = Math.min(10, Math.floor(Math.max(0, verifiedGames) / 10));
  return totalAllocation * milestones / 10;
}

export function formatCue(value) {
  return `${new Intl.NumberFormat("en", { maximumFractionDigits: 3 }).format(value)} CUE`;
}

export function actionPlan(mode, amount = 0) {
  const commonFinish = [
    { label: "Play", detail: "Authoritative physics records every shot" },
    { label: "Verify", detail: "Independent game oracles sign the final result" },
    { label: "Settle", detail: "The matching contract applies its fixed distribution" }
  ];

  if (mode === "practice") {
    return [
      { label: "Rack", detail: "No wallet and no CUE approval" },
      { label: "Compete", detail: "Full local match against CueBot" },
      { label: "Finish", detail: "No economic result or token movement" }
    ];
  }
  if (mode === "ranked") {
    return [
      { label: "Match", detail: "Skill rating selects a comparable opponent" },
      ...commonFinish,
      { label: "Reward", detail: "Authorized rewards pool pays the verified winner" }
    ];
  }
  return [
    { label: "Approve", detail: `Player authorizes exactly ${formatCue(amount)}` },
    { label: "Lock", detail: `${GAME_MODES[mode].contract} holds the entry before play` },
    ...commonFinish
  ];
}
