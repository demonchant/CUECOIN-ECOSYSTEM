import { createReadStream } from "node:fs";
import { createServer } from "node:http";
import { extname, join } from "node:path";

const port = Number(process.env.PORT || 4173);
const root = process.cwd();
const routes = new Map([
  ["/", "index.html"],
  ["/index.html", "index.html"],
  ["/styles.css", "styles.css"],
  ["/app.js", "app.js"],
  ["/config.js", "config.js"],
  ["/assets/logoDark.jpg", "assets/logoDark.jpg"],
  ["/assets/slides/precision.jpg", "assets/slides/precision.jpg"],
  ["/assets/slides/tournament.jpg", "assets/slides/tournament.jpg"],
  ["/assets/slides/cuestrikeMobile.jpg", "assets/slides/cuestrikeMobile.jpg"],
  ["/assets/slides/rewards.jpg", "assets/slides/rewards.jpg"]
]);
const contentTypes = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".jpg": "image/jpeg"
};

createServer((request, response) => {
  const pathname = new URL(request.url, `http://${request.headers.host || "localhost"}`).pathname;
  const file = routes.get(pathname);
  if (!file) {
    response.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
    response.end("Not found");
    return;
  }

  response.writeHead(200, {
    "Content-Type": contentTypes[extname(file)],
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "strict-origin-when-cross-origin"
  });
  createReadStream(join(root, file)).pipe(response);
}).listen(port, "127.0.0.1", () => {
  console.log(`CueCoin airdrop portal: http://127.0.0.1:${port}`);
});
