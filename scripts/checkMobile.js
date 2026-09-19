import { existsSync, readFileSync } from "node:fs";

const config = JSON.parse(readFileSync("capacitor.config.json", "utf8"));
const required = [
  "dist/index.html",
  "dist/app.js",
  "dist/engine.js",
  "dist/vendor/ethers.umd.min.js",
  "dist/assets/cuestrike-app-icon.png",
  "android/app/src/main/AndroidManifest.xml",
  "android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png",
  "ios/App/App/Info.plist",
  "ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png"
];
const missing = required.filter((path) => !existsSync(path));
const androidManifest = readFileSync("android/app/src/main/AndroidManifest.xml", "utf8");
const iosPlist = readFileSync("ios/App/App/Info.plist", "utf8");
const mobileHtml = readFileSync("dist/index.html", "utf8");
const failures = [];

if (config.appId !== "com.cuecoin.cuestrike" || config.webDir !== "dist") failures.push("Capacitor identity or webDir is invalid");
if (!androidManifest.includes('android:screenOrientation="sensorLandscape"')) failures.push("Android landscape mode is missing");
if (iosPlist.includes("UIInterfaceOrientationPortrait")) failures.push("iOS portrait mode is still enabled");
if (mobileHtml.includes("https://cdn.jsdelivr.net/npm/ethers")) failures.push("Native bundle still depends on the ethers CDN");
if (!mobileHtml.includes('./vendor/ethers.umd.min.js')) failures.push("Native ethers bundle is missing");

if (missing.length || failures.length) {
  console.error(JSON.stringify({ missing, failures }, null, 2));
  process.exitCode = 1;
} else {
  console.log(`Verified ${required.length} mobile artifacts, native orientation, offline dependencies, and Capacitor identity.`);
}
