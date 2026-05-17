import { createRequire } from "node:module";
import { mkdir } from "node:fs/promises";
import { resolve } from "node:path";

const require = createRequire(import.meta.url);
const { chromium } = require("playwright");
const root = resolve(import.meta.dirname, "../..");
const outDir = resolve(root, "docs/assets");
await mkdir(outDir, { recursive: true });

const html = String.raw;

const baseStyles = `
  * { box-sizing: border-box; }
  body {
    margin: 0;
    width: 1280px;
    height: 900px;
    background:
      linear-gradient(90deg, rgba(22,22,22,.05) 1px, transparent 1px),
      linear-gradient(0deg, rgba(22,22,22,.04) 1px, transparent 1px),
      #f4f0e8;
    background-size: 44px 44px;
    font-family: ui-serif, "Iowan Old Style", Georgia, serif;
    color: #151515;
    letter-spacing: 0;
  }
  .frame {
    position: absolute;
    inset: 70px;
    border: 3px solid #151515;
    background: #fffaf0;
    box-shadow: 18px 18px 0 #151515;
    overflow: hidden;
  }
  .topbar {
    height: 48px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 18px;
    border-bottom: 3px solid #151515;
    background: #e6d8bb;
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: 15px;
    font-weight: 800;
  }
  .lights { display: flex; gap: 8px; }
  .lights span {
    width: 14px;
    height: 14px;
    border: 2px solid #151515;
    border-radius: 50%;
    display: block;
  }
  .red { background:#bc4132; }
  .gold { background:#d79b2b; }
  .green { background:#0f7b56; }
  .mono { font-family: ui-monospace, "SF Mono", Menlo, monospace; }
`;

const hero = html`<!doctype html>
<html><head><meta charset="utf-8"><style>${baseStyles}
  .menubar {
    height: 46px;
    display: flex;
    justify-content: flex-end;
    align-items: center;
    gap: 18px;
    padding: 0 28px;
    border-bottom: 3px solid #151515;
    background: #f8f5ee;
    font: 16px ui-monospace, "SF Mono", Menlo, monospace;
  }
  .pill {
    border: 3px solid #151515;
    background: #d79b2b;
    padding: 8px 14px;
    box-shadow: 5px 5px 0 #151515;
    font-weight: 900;
  }
  .dropdown {
    position: absolute;
    top: 118px;
    right: 92px;
    width: 430px;
    border: 3px solid #151515;
    background: #fffaf0;
    box-shadow: 14px 14px 0 #151515;
  }
  .item {
    display: flex;
    justify-content: space-between;
    gap: 18px;
    padding: 17px 20px;
    border-bottom: 2px solid #151515;
    font-size: 22px;
  }
  .item:last-child { border-bottom: 0; }
  .label { color: #645d52; }
  .value { font-weight: 900; }
  .hero-copy {
    position: absolute;
    left: 82px;
    bottom: 86px;
    width: 520px;
  }
  h1 {
    margin: 0;
    font-size: 82px;
    line-height: .9;
    letter-spacing: 0;
  }
  p {
    margin: 22px 0 0;
    font-size: 24px;
    line-height: 1.35;
    color: #332f28;
  }
</style></head>
<body>
  <div class="frame">
    <div class="menubar">
      <span>Mon 8:41 PM</span>
      <span class="pill">★ 1,284</span>
    </div>
    <div class="dropdown">
      <div class="topbar"><span>GH Menu Stars</span><div class="lights"><span class="red"></span><span class="gold"></span><span class="green"></span></div></div>
      <div class="item"><span class="label">Repository</span><span class="value">jazzyalex/GH-menu-stars</span></div>
      <div class="item"><span class="label">Stars</span><span class="value">1,284  +18</span></div>
      <div class="item"><span class="label">Release downloads</span><span class="value">7,946  +212</span></div>
      <div class="item"><span class="label">Checked</span><span class="value">2 min ago</span></div>
      <div class="item"><span class="label">Updates</span><span class="value">Automatic</span></div>
    </div>
    <div class="hero-copy">
      <h1>Stars where you can see them.</h1>
      <p>A tiny native macOS watcher for repository momentum and release downloads.</p>
    </div>
  </div>
</body></html>`;

const settings = html`<!doctype html>
<html><head><meta charset="utf-8"><style>${baseStyles}
  .content {
    display: grid;
    grid-template-columns: 320px 1fr;
    height: calc(100% - 48px);
  }
  .side {
    border-right: 3px solid #151515;
    background: #efe3ca;
    padding: 28px;
  }
  .side h1 {
    margin: 0 0 18px;
    font-size: 46px;
    line-height: .95;
  }
  .nav {
    display: grid;
    gap: 12px;
    margin-top: 42px;
    font: 15px ui-monospace, "SF Mono", Menlo, monospace;
  }
  .nav div {
    padding: 12px;
    border: 2px solid #151515;
    background: #fffaf0;
  }
  .main {
    padding: 34px;
  }
  .group {
    border: 3px solid #151515;
    background: #fffaf0;
    margin-bottom: 24px;
    box-shadow: 8px 8px 0 #151515;
  }
  .group-title {
    padding: 13px 18px;
    border-bottom: 3px solid #151515;
    background: #d79b2b;
    font: 800 16px ui-monospace, "SF Mono", Menlo, monospace;
  }
  .row {
    display: grid;
    grid-template-columns: 210px 1fr;
    align-items: center;
    gap: 18px;
    padding: 18px;
    border-bottom: 2px solid #151515;
  }
  .row:last-child { border-bottom: 0; }
  .label { font-size: 20px; font-weight: 800; }
  .field {
    padding: 13px 14px;
    border: 2px solid #151515;
    background: #f4f0e8;
    font: 16px ui-monospace, "SF Mono", Menlo, monospace;
  }
  .toggle {
    display: inline-flex;
    align-items: center;
    gap: 12px;
    font: 16px ui-monospace, "SF Mono", Menlo, monospace;
  }
  .box {
    width: 24px;
    height: 24px;
    border: 3px solid #151515;
    background: #0f7b56;
    color: #fff;
    display: grid;
    place-items: center;
    font-weight: 900;
  }
  .button {
    display: inline-block;
    padding: 13px 16px;
    border: 3px solid #151515;
    background: #0f7b56;
    color: white;
    box-shadow: 5px 5px 0 #151515;
    font: 800 15px ui-monospace, "SF Mono", Menlo, monospace;
  }
</style></head>
<body>
  <div class="frame">
    <div class="topbar"><span>Settings</span><div class="lights"><span class="red"></span><span class="gold"></span><span class="green"></span></div></div>
    <div class="content">
      <aside class="side">
        <h1>Track one repo cleanly.</h1>
        <div class="nav">
          <div>Repository</div>
          <div>Refresh</div>
          <div>Updates</div>
        </div>
      </aside>
      <main class="main">
        <section class="group">
          <div class="group-title">Repository</div>
          <div class="row"><div class="label">GitHub URL</div><div class="field">https://github.com/jazzyalex/GH-menu-stars</div></div>
          <div class="row"><div class="label">Refresh</div><div class="field">Every 15 minutes</div></div>
          <div class="row"><div class="label">Notifications</div><div class="toggle"><span class="box">✓</span> Star changes</div></div>
        </section>
        <section class="group">
          <div class="group-title">App</div>
          <div class="row"><div class="label">Dock icon</div><div class="toggle"><span class="box">✓</span> Hidden menu-bar mode</div></div>
          <div class="row"><div class="label">Auto-Update</div><div class="toggle"><span class="box">✓</span> Signed Sparkle updates</div></div>
          <div class="row"><div class="label">Manual check</div><div><span class="button">Check for Updates...</span></div></div>
        </section>
      </main>
    </div>
  </div>
</body></html>`;

async function capture(name, content) {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 }, deviceScaleFactor: 1 });
  await page.setContent(content, { waitUntil: "load" });
  await page.screenshot({ path: resolve(outDir, name), fullPage: false });
  await browser.close();
}

await capture("hero-menu.png", hero);
await capture("settings-panel.png", settings);
