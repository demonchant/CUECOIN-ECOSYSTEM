import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const root = process.cwd();
const output = join(root, "dist");
const game = join(root, "game");

rmSync(output, { recursive: true, force: true });
mkdirSync(join(output, "assets"), { recursive: true });
mkdirSync(join(output, "vendor"), { recursive: true });

for (const file of ["app.js", "contracts.js", "economy.js", "engine.js", "styles.css", "manifest.webmanifest", "service-worker.js"]) {
  copyFileSync(join(game, file), join(output, file));
}
copyFileSync(join(root, "config.js"), join(output, "config.js"));
copyFileSync(join(root, "assets", "logoDark.jpg"), join(output, "assets", "logoDark.jpg"));
copyFileSync(join(root, "assets", "cuestrike-app-icon.png"), join(output, "assets", "cuestrike-app-icon.png"));
copyFileSync(join(root, "node_modules", "ethers", "dist", "ethers.umd.min.js"), join(output, "vendor", "ethers.umd.min.js"));

let html = readFileSync(join(game, "index.html"), "utf8");
html = html
  .replaceAll('href="../"', 'href="./"')
  .replaceAll('../assets/', './assets/')
  .replace('src="https://cdn.jsdelivr.net/npm/ethers@6.17.0/dist/ethers.umd.min.js"', 'src="./vendor/ethers.umd.min.js"')
  .replace('src="../config.js"', 'src="./config.js"');
writeFileSync(join(output, "index.html"), html);

const manifestPath = join(output, "manifest.webmanifest");
const manifest = readFileSync(manifestPath, "utf8").replaceAll("../assets/", "./assets/");
writeFileSync(manifestPath, manifest);

const workerPath = join(output, "service-worker.js");
const worker = readFileSync(workerPath, "utf8")
  .replaceAll('"../config.js"', '"./config.js"')
  .replaceAll('"../assets/', '"./assets/');
writeFileSync(workerPath, worker);

for (const required of ["index.html", "app.js", "engine.js", "vendor/ethers.umd.min.js", "assets/cuestrike-app-icon.png"]) {
  const path = join(output, required);
  if (!existsSync(path)) throw new Error(`Mobile build is missing ${required}`);
}

console.log("CueStrike mobile web bundle built in dist.");
