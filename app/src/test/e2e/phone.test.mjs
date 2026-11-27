// End-to-end tests for the phone page. Starts the page on its own (PhoneMain) with a
// scratch home, registry and daemon, drives it in headless Chromium at phone size, and
// runs a real /bin/sh session through it: sign-in, start, type, keys, colours, scrollback,
// the session's size, close (refused and done) and resume. The tests run in order and
// share one page, like a person using it. Run through scripts/phone-e2e.sh, which builds
// the jar; see the README's Tests section.
//
// Env: MHM_JAR      the app jar (PhoneMain, and the daemon it starts)
//      MHM_WEB_DIR  the live page dir (MICROHM_WEB_DIR)
//      MHM_CHROMIUM optional Chromium executable (default: Playwright's own)
//      MHM_KEEP_WORK keep the scratch folder
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { chromium } from "playwright-core";

const TOKEN = "e2e-phone-secret-0123456789";
// os.tmpdir(), not a deeper folder: the daemon's socket path must stay under 104 bytes
const WORK = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "mhm-e2e-")));
const HOME = path.join(WORK, "home");
const MUX = path.join(WORK, "mux");
const PROJECT = path.join(WORK, "alpha");
const NAME = "e2e-shell";
const PHONE = { viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true };

let server, serverOut = "", base, browser, page, session;
const errors = [];

function freePort() {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.once("error", reject);
    s.listen(0, "127.0.0.1", () => { const { port } = s.address(); s.close(() => resolve(port)); });
  });
}

function stopDaemon() {
  try {
    execFileSync("java", ["--enable-native-access=ALL-UNNAMED", "-cp", process.env.MHM_JAR,
      "io.github.ghosthack.microhm.mux.Main", "shutdown", "--home", MUX], { stdio: "ignore" });
  } catch (e) {
    // not running
  }
}

before(async () => {
  assert.ok(process.env.MHM_JAR, "MHM_JAR is not set; run scripts/phone-e2e.sh");
  fs.mkdirSync(HOME);
  fs.mkdirSync(PROJECT);
  const port = await freePort();
  base = `http://127.0.0.1:${port}/`;
  server = spawn("java", ["--enable-native-access=ALL-UNNAMED", "-Djava.awt.headless=true",
    `-Duser.home=${HOME}`, "-cp", process.env.MHM_JAR,
    "io.github.ghosthack.microhm.app.phone.PhoneMain", `--port=${port}`, `--token=${TOKEN}`,
    `--registry=${path.join(HOME, ".micro-harness-manager", "sessions.json")}`, `--mux-home=${MUX}`], {
    // a plain shell with no profile of yours: /bin/sh -l, HOME in the scratch folder
    env: { ...process.env, SHELL: "/bin/sh", HOME, ENV: "", MICROHM_WEB_DIR: process.env.MHM_WEB_DIR ?? "" },
  });
  server.stdout.on("data", (d) => { serverOut += d; });
  server.stderr.on("data", (d) => { serverOut += d; });
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("server did not start:\n" + serverOut)), 60000);
    const poll = setInterval(() => {
      if (serverOut.includes("phone page ready on port")) { clearInterval(poll); clearTimeout(timer); resolve(); }
    }, 100);
    server.once("exit", (code) => {
      clearInterval(poll); clearTimeout(timer);
      reject(new Error(`server exited ${code}:\n${serverOut}`));
    });
  });
  browser = await chromium.launch(process.env.MHM_CHROMIUM ? { executablePath: process.env.MHM_CHROMIUM } : {});
  const context = await browser.newContext(PHONE);
  page = await context.newPage();
  page.on("pageerror", (e) => errors.push("pageerror: " + e.message));
  page.on("console", (m) => { if (m.type() === "error") errors.push("console: " + m.text()); });
});

after(async () => {
  await browser?.close();
  if (server && server.exitCode === null) {
    server.kill();
    await new Promise((resolve) => server.once("exit", resolve));
  }
  stopDaemon();
  if (process.env.MHM_KEEP_WORK) console.log("kept", WORK);
  else fs.rmSync(WORK, { recursive: true, force: true });
});

const visible = (sel) => page.evaluate((s) => {
  const e = document.querySelector(s);
  return !!e && !e.hidden && getComputedStyle(e).display !== "none";
}, sel);
const text = (sel) => page.$eval(sel, (e) => e.textContent);
const waitText = (sel, re, timeout = 15000) => page.waitForFunction(
  ([s, source, flags]) => new RegExp(source, flags).test(document.querySelector(s)?.textContent ?? ""),
  [sel, re.source, re.flags], { timeout });
const waitVisible = (sel, timeout = 15000) => page.waitForSelector(sel, { state: "visible", timeout });
const waitState = (label, timeout = 30000) => waitText("#session-state", new RegExp("^" + label + "$"), timeout);

async function send(line) {
  await page.fill("#message", line);
  await page.click("#send-button");
  await page.waitForFunction(() => document.getElementById("message").value === "");
}

// ------------------------------------------------------------------ signing in

test("a wrong secret is refused, and the page says how to sign in", async () => {
  const stranger = await browser.newContext(PHONE);
  const p = await stranger.newPage();
  await p.goto(base + "#k=not-the-secret");
  await p.waitForSelector("#locked-view", { state: "visible" });
  assert.match(await p.textContent("#locked-view"), /Open the phone link/);
  assert.equal(new URL(p.url()).hash, "", "the wrong secret leaves the address bar too");
  const answer = await p.evaluate(() => fetch("/api/sessions").then((r) => r.status));
  assert.equal(answer, 401);
  await stranger.close();
});

test("the phone link signs in, keeps a cookie, and drops the secret from the address bar", async () => {
  await page.goto(base + "#k=" + TOKEN);
  await waitVisible("#list-view");
  assert.ok(!page.url().includes(TOKEN));
  const cookie = (await page.context().cookies()).find((c) => c.name === "mhm_phone");
  assert.ok(cookie, "the sign-in cookie");
  assert.equal(cookie.httpOnly, true);
  assert.equal(cookie.sameSite, "Strict");
  await waitText("#sessions", /No sessions yet/);
});

test("a request from another site is refused", async () => {
  // the page's own POST is let through (a second tab: its 400 for an empty message is
  // expected, and stays out of the page errors checked at the end)
  const tab = await page.context().newPage();
  await tab.goto(base);
  const status = await tab.evaluate(() => fetch("/api/send", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: "{}",
  }).then((r) => r.status));
  assert.notEqual(status, 403);
  assert.notEqual(status, 401);
  await tab.close();
  const forged = await fetch(base + "api/send", {
    method: "POST",
    headers: { "Content-Type": "application/json", Origin: "http://evil.example", Cookie: "mhm_phone=" + TOKEN },
    body: JSON.stringify({ session: "x", text: "rm -rf ~" }),
  });
  assert.equal(forged.status, 403);
});

// ------------------------------------------------------------------ a session

test("New starts a shell in a folder and opens it", async () => {
  await page.click("#new-button");
  await waitVisible("#new-view");
  await page.selectOption("#new-harness", "shell");
  await page.fill("#new-project", PROJECT);
  await page.fill("#new-name", NAME);
  await page.click("#start-button");
  await waitVisible("#session-view");
  session = decodeURIComponent(new URL(page.url()).hash.slice(3));
  assert.match(session, /^mhm-alpha/);
  assert.equal(await text("#session-title"), NAME);
  // the prompt: /bin/sh's own, whatever it reads ("sh-3.2$", "$ ")
  await waitText("#screen", /\$\s*$/m);
  assert.equal(await visible("#connecting"), false);
});

test("a message runs as a command, and its output shows", async () => {
  await send("echo e2e-$((6 * 7))");
  await waitText("#screen", /^e2e-42$/m);
});

test("an attached file's path goes into the message, and the session can read it", async () => {
  await page.fill("#message", "cat");
  await page.$eval("#message", (e) => e.setSelectionRange(3, 3));
  await page.setInputFiles("#attach-input",
    { name: "Screen Shot.png", mimeType: "image/png", buffer: Buffer.from("e2e-attached-bytes") });
  await page.waitForFunction(() => /^cat \/\S+Screen_Shot\.png $/.test(document.getElementById("message").value));
  const file = (await page.$eval("#message", (e) => e.value)).trim().split(" ")[1];
  // in the session's project, in a folder that keeps itself out of git
  assert.equal(path.dirname(fs.realpathSync(file)), path.join(PROJECT, ".microhm", "uploads"));
  assert.match(fs.readFileSync(path.join(PROJECT, ".microhm", ".gitignore"), "utf8"), /^\*$/m);
  assert.equal(fs.readFileSync(file, "utf8"), "e2e-attached-bytes");
  await page.click("#send-button");
  await page.waitForFunction(() => document.getElementById("message").value === "");
  await waitText("#screen", /^e2e-attached-bytes/m);
});

test("the session runs at the phone's size while the phone watches", async () => {
  await send("stty size");
  await waitText("#screen", /^\d+ \d+$/m);
  const [rows, cols] = (await text("#screen")).match(/^(\d+) (\d+)$/m).slice(1).map(Number);
  // 390 px at 12 px monospace: about fifty columns, not the 120 a session starts with
  assert.ok(cols >= 30 && cols <= 70, `columns ${cols}`);
  assert.ok(rows >= 10, `rows ${rows}`);
});

test("colours and underline kinds reach the page", async () => {
  await send("printf '\\033[31mred-e2e\\033[0m \\033[4:3mcurly-e2e\\033[0m \\033[1mbold-e2e\\033[0m\\n'");
  await waitText("#screen", /red-e2e curly-e2e bold-e2e/);
  const styles = await page.$$eval("#screen span", (spans) => Object.fromEntries(spans
    .filter((s) => /-e2e$/.test(s.textContent))
    .map((s) => [s.textContent, s.getAttribute("style")])));
  assert.match(styles["red-e2e"], /color:#[0-9a-f]{6}/);
  assert.match(styles["curly-e2e"], /text-decoration: underline wavy/);
  assert.match(styles["bold-e2e"], /font-weight:700/);
});

test("a web link on the screen is a link that opens in a new tab", async () => {
  await send("printf 'see (https://e2e.example/%s).\\n' path-42");
  await waitText("#screen", /see \(https:\/\/e2e\.example\/path-42\)\./);
  const links = await page.$$eval("#screen a", (as) => as.map((a) => [a.textContent, a.getAttribute("href"), a.target]));
  assert.ok(links.some(([t, href, target]) => t === "https://e2e.example/path-42"
    && href === "https://e2e.example/path-42" && target === "_blank"), JSON.stringify(links));
});

test("Braille, box edges and text backgrounds line up across styled runs and rows at 3×", async () => {
  await send("printf '\\033[2J\\033[H  \\033[97m┌─────┐\\n  │ abc │\\n  │ \\033[1mxyz\\033[22m │\\n  └─────┘\\n"
    + "  ██\\033[33m██\\n  \\033[97m⣿⣿\\033[96m⣿⣿\\n  \\033[97m⣿⣿⣿⣿\\033[0m\\n"
    + "  \\033[48;2;65;65;65m> \\033[94m[Image #1]\\033[39m       \\033[0m\\n"
    + "  \\033[48;2;65;65;65m> \\033[1msome words\\033[22m here\\033[0m\\n"
    + "tiles-e2e\\n'");
  await waitText("#screen", /^tiles-e2e$/m);
  const layer = page.locator("#screen .tile-layer");
  const png = await layer.screenshot({ scale: "device" });
  const raster = await page.evaluate(async (base64) => {
    const image = new Image();
    image.src = "data:image/png;base64," + base64;
    await image.decode();
    const canvas = document.createElement("canvas");
    canvas.width = image.width;
    canvas.height = image.height;
    const ctx = canvas.getContext("2d");
    ctx.drawImage(image, 0, 0);
    const { data } = ctx.getImageData(0, 0, image.width, image.height);
    const brightness = (x, y) => {
      const i = (y * image.width + x) * 4;
      return Math.max(data[i], data[i + 1], data[i + 2]);
    };
    const bright = (x, y) => brightness(x, y) > 128;
    const firstRun = document.querySelector('.tile-run[data-tiles="┌─────┐"]');
    const { width, height } = firstRun.getBoundingClientRect();
    const cell = width * devicePixelRatio / 7, row = height * devicePixelRatio;
    const columns = [2.5, 8.5].map((column) => {
      const centre = Math.round(column * cell);
      return Array.from({ length: 3 * row - 8 }, (_, i) =>
        Array.from({ length: 9 }, (_, dx) => Number(bright(centre - 4 + dx, Math.round(row / 2) + 4 + i))).join(""));
    });
    const blocks = Array.from({ length: Math.floor(4 * cell) - 2 },
      (_, i) => bright(Math.round(2 * cell) + 1 + i, Math.round(4.5 * row)));
    let backgroundGaps = 0;
    for (let y = 7 * row; y < 9 * row; y++) {
      for (let x = Math.ceil(2.5 * cell); x < Math.floor(14 * cell); x++) {
        if (brightness(x, y) < 56) backgroundGaps++;
      }
    }
    function centres(start, end, lit) {
      const results = [];
      let first = -1;
      for (let i = start; i <= end; i++) {
        if (i < end && lit(i)) {
          if (first === -1) first = i;
        } else if (first !== -1) {
          results.push((first + i - 1) / 2);
          first = -1;
        }
      }
      return results;
    }
    return { columns, blocks, backgroundGaps, cell, row,
      xs: centres(Math.floor(2 * cell), Math.round(6 * cell), (x) => bright(x, Math.round(5.125 * row))),
      ys: centres(5 * row, 7 * row, (y) => bright(Math.round(2.25 * cell), y)) };
  }, png.toString("base64"));
  for (const stroke of raster.columns) {
    assert.match(stroke[0], /111/);
    assert.equal(new Set(stroke).size, 1, "a vertical border keeps the same pixels through each row");
  }
  assert.ok(raster.blocks.every(Boolean), "no dark pixel at the colour boundary");
  assert.equal(raster.backgroundGaps, 0, "the highlighted text and its spaces fill both rows");
  for (const [centres, pitch] of [[raster.xs, raster.cell / 2], [raster.ys, raster.row / 4]]) {
    assert.equal(centres.length, 8);
    for (let i = 1; i < centres.length; i++) {
      assert.ok(Math.abs(centres[i] - centres[i - 1] - pitch) <= 1, `uneven Braille dots: ${centres}`);
    }
  }
});

test("Close is refused while a command runs, and ⌃C from the keypad stops it", async () => {
  await send("sleep 60");
  await waitState("Working");
  await page.click("#close-button");
  await waitVisible("#sheet");
  await waitText("#sheet-title", /^Can't close e2e-shell now$/);
  assert.ok((await text("#sheet-text")).length > 0, "a reason");
  await page.click("#sheet-cancel");
  assert.equal(await visible("#sheet"), false);

  await page.click("#keys-button");
  await waitVisible("#keys");
  await page.click('#keys button[data-keys="C-c"]');
  await send("echo after-interrupt");
  await waitText("#screen", /^after-interrupt$/m, 10000);
  await page.click("#keys-button");
  assert.equal(await visible("#keys"), false);
});

test("lines that scroll off the screen land in the scrollback", async () => {
  await send("i=1; while [ $i -le 150 ]; do echo scroll-$i; i=$((i+1)); done");
  await waitText("#screen", /^scroll-150$/m);
  await waitText("#history", /(^|\n)scroll-1\n/);
  const history = await text("#history");
  assert.ok(history.indexOf("scroll-1\n") < history.indexOf("scroll-2\n"), "in order");
});

test("typing a long message keeps the screen still at its bottom", async () => {
  const gap = () => page.$eval("#scroller", (s) => Math.round(s.scrollHeight - s.clientHeight - s.scrollTop));
  await page.evaluate(() => scrollToBottom());
  assert.equal(await gap(), 0);
  // long enough to wrap, then keystrokes that grow it by another line
  await page.fill("#message", "a message long enough to wrap onto a second line of the box");
  await page.dispatchEvent("#message", "input");
  await page.evaluate(() => scrollToBottom());
  try {
    await page.focus("#message");
    await page.press("#message", "End");
    for (const ch of " and then some more words, enough to make a third line") {
      await page.keyboard.type(ch);
      assert.equal(await gap(), 0, "the screen moved after typing " + JSON.stringify(ch));
    }
  } finally {
    // the tests after this one share the page: leave the box empty
    await page.fill("#message", "");
    await page.dispatchEvent("#message", "input");
  }
});

test("back from a new session, as Safari's swipe does it, is the list, not the form", async () => {
  await page.goBack();
  await waitVisible("#list-view");
  assert.equal(await visible("#new-view"), false);
});

test("the list shows the session in its folder", async () => {
  await waitText("#sessions", new RegExp(NAME));
  const heads = await page.$$eval("#sessions .group-head b", (bs) => bs.map((b) => b.textContent));
  assert.deepEqual(heads, ["alpha"]);
  assert.match(await text("#sessions .row .status"), /^(Idle|Working)$/);
});

test("stop from the list opens the session and asks there; Close ends it", async () => {
  // the list refreshes every few seconds; Close is offered once the shell sits at its prompt
  await waitText("#sessions .row .status", /^Idle$/, 30000);
  await page.click("#sessions .row button.stop");
  await waitVisible("#session-view");
  await waitVisible("#sheet");
  await waitText("#sheet-title", /^Close e2e-shell\?$/, 30000);
  await waitVisible("#sheet-confirm");
  await page.click("#sheet-confirm");
  await waitVisible("#list-view", 30000);
  await waitText("#sessions .row .status", /^Ended$/, 30000);
  assert.equal(await visible("#sessions .row button.play"), true);
});

test("an ended shell resumes in its folder", async () => {
  await page.click("#sessions .row button.play");
  await waitVisible("#session-view", 30000);
  await waitText("#screen", /\$\s*$/m, 30000);
  // the path is wider than the phone's screen: let the shell compare, and answer briefly
  await send(`[ "$(pwd -P)" = "${PROJECT}" ] && echo same-folder || echo "other-folder $(pwd -P)"`);
  await waitText("#screen", /^same-folder$/m);
});

test("no page errors along the way", () => {
  assert.deepEqual(errors, []);
});
