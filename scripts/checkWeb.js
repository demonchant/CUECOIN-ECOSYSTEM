import { readFileSync } from "node:fs";

const html = readFileSync("index.html", "utf8");
const app = readFileSync("app.js", "utf8");
const ids = [...html.matchAll(/ id="([^"]+)"/g)].map((match) => match[1]);
const duplicates = ids.filter((id, index) => ids.indexOf(id) !== index);
const references = [...app.matchAll(/byId\("([^"]+)"\)/g)].map((match) => match[1]);
const missing = references.filter((id) => !ids.includes(id));

if (duplicates.length || missing.length) {
  console.error(JSON.stringify({ duplicates, missing }, null, 2));
  process.exitCode = 1;
} else {
  console.log(`Verified ${ids.length} HTML ids and ${references.length} JavaScript references.`);
}
