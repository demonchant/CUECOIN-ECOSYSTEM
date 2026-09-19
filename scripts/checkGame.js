import { existsSync, readFileSync } from "node:fs";

const html = readFileSync("game/index.html", "utf8");
const app = readFileSync("game/app.js", "utf8");
const ids = [...html.matchAll(/ id="([^"]+)"/g)].map((match) => match[1]);
const duplicates = ids.filter((id, index) => ids.indexOf(id) !== index);
const references = [...app.matchAll(/byId\("([^"]+)"\)/g)].map((match) => match[1]);
const missingIds = [...new Set(references.filter((id) => !ids.includes(id)))];
const imports = [...app.matchAll(/from "(\.\/[^\"]+)"/g)].map((match) => `game/${match[1].slice(2)}`);
const missingImports = imports.filter((path) => !existsSync(path));
const config = readFileSync("config.js", "utf8");
const requiredConfig = ["cueCoinAddress", "escrowAddress", "rewardsPoolAddress", "sitAndGoAddress", "tournamentAddress", "gameApiUrl"];
const missingConfig = requiredConfig.filter((key) => !config.includes(`${key}:`));
const combinedSource = `${html}\n${app}`;
const forbiddenPayments = ["Stripe payment", "Stripe.js", "PayPal", "credit card"].filter((term) => combinedSource.toLowerCase().includes(term.toLowerCase()));

if (duplicates.length || missingIds.length || missingImports.length || missingConfig.length || forbiddenPayments.length) {
  console.error(JSON.stringify({ duplicates, missingIds, missingImports, missingConfig, forbiddenPayments }, null, 2));
  process.exitCode = 1;
} else {
  console.log(`Verified ${ids.length} game elements, ${references.length} DOM references, ${imports.length} modules, contract config keys, and CUE only payment copy.`);
}
