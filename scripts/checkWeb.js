import { readFileSync } from "node:fs";

const html = readFileSync("index.html", "utf8");
const app = readFileSync("app.js", "utf8");
const ids = [...html.matchAll(/ id="([^"]+)"/g)].map((match) => match[1]);
const duplicates = ids.filter((id, index) => ids.indexOf(id) !== index);
const references = [...app.matchAll(/byId\("([^"]+)"\)/g)].map((match) => match[1]);
const missing = references.filter((id) => !ids.includes(id));
const localImages = [...html.matchAll(/<img[^>]+src="\.\/([^"]+)"/g)].map((match) => match[1]);
const slideCount = (html.match(/class="storySlide(?: active)?"/g) || []).length;
const dotCount = (html.match(/aria-label="Show image [0-9]+"/g) || []).length;
const missingImages = localImages.filter((path) => {
  try {
    readFileSync(path);
    return false;
  } catch {
    return true;
  }
});

if (duplicates.length || missing.length || missingImages.length || slideCount !== 4 || dotCount !== slideCount) {
  console.error(JSON.stringify({ duplicates, missing, missingImages, slideCount, dotCount }, null, 2));
  process.exitCode = 1;
} else {
  console.log(`Verified ${ids.length} HTML ids, ${references.length} JavaScript references, ${localImages.length} images, and ${slideCount} carousel slides.`);
}
