// The phone page's script, run in a fake browser (see fake-browser.mjs).
// Run: node --test app/src/test/web/
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./fake-browser.mjs";

// Values made inside the page's own realm (its arrays and objects) compare by content here.
const plain = (value) => JSON.parse(JSON.stringify(value));

// ------------------------------------------------------------------ screen drawing

test("text is escaped before it goes into the screen's HTML", () => {
  const { window } = load();
  assert.equal(window.escapeHtml("<b>&</b>"), "&lt;b&gt;&amp;&lt;/b&gt;");
  assert.equal(window.textHtml({ text: "a<b", s: 0, f: null, b: null }), "a&lt;b");
});

test("styles become CSS, and each underline kind its line style", () => {
  const { window } = load();
  const css = (s) => window.textHtml({ text: "x", s, f: "#ff0000", b: "#000080" });
  assert.equal(css(1 | 4), '<span style="color:#ff0000;background:#000080;font-weight:700;font-style:italic;">x</span>');
  assert.match(css(8), /text-decoration: underline;/);
  assert.match(css(8 | 32), /text-decoration: underline double;/);
  assert.match(css(8 | 64), /text-decoration: underline wavy;/);
  assert.match(css(8 | 128), /text-decoration: underline dotted;/);
  assert.match(css(8 | 256), /text-decoration: underline dashed;/);
  assert.match(css(8 | 16 | 64), /text-decoration: underline line-through wavy;/);
  // a kind bit without the underline bit draws nothing
  assert.doesNotMatch(css(64), /text-decoration/);
});

test("a space on a coloured background is drawn as a block in that colour", () => {
  const { window } = load();
  const html = window.rowHtml([{ t: "a" }, { t: "  ", b: "#ff0000" }], "#000000");
  assert.match(html, /^a<span class="g g\w+" style="width:2ch;color:#ff0000;"><\/span>$/);
});

test("a background equal to the screen's is no background, so its cells join their neighbours", () => {
  const { window } = load();
  // Claude's logo: block characters in one colour, then a space on an explicit black
  const html = window.rowHtml([{ t: "██", f: "#d77757" }, { t: " ", b: "#000000" }, { t: "█", f: "#d77757" }], "#000000");
  // the black space is plain text, not a black block; the blocks around it stay one shape each
  assert.equal((html.match(/class="g /g) || []).length, 2);
  assert.match(html, /width:2ch;color:#d77757;/);
  assert.doesNotMatch(html, /#000000/);
});

test("neighbouring box cells of one colour from different runs become one shape", () => {
  const { window } = load();
  const html = window.rowHtml([{ t: "──", f: "#888888" }, { t: "──", f: "#888888", s: 1 }], "#000000");
  // bold does not matter to a shape; only dim does
  assert.equal((html.match(/class="g /g) || []).length, 1);
  assert.match(html, /width:4ch;/);
});

test("a late screen from the previous session is ignored", () => {
  const page = load();
  page.app.current = "now";
  page.window.renderScreen({ name: "before", text: "old", state: "IDLE" });
  assert.equal(page.$("screen").textContent, "");
  page.window.renderScreen({ name: "now", text: "new", state: "IDLE" });
  assert.equal(page.$("screen").textContent, "new");
});

// ------------------------------------------------------------------ links

test("a web link on a row is a link, without the sentence around it", () => {
  const { window } = load();
  const links = plain(window.findLinks(["see (https://a.example/x?q=1&r=2). ok"], 60));
  assert.deepEqual(links, [[{ from: 5, to: 32, url: "https://a.example/x?q=1&r=2" }]]);
  const html = window.rowHtml([{ t: "see (https://a.example/x?q=1&r=2). ok", f: "#aaaaaa" }], "#000000", links[0]);
  assert.match(html, /<a href="https:\/\/a.example\/x\?q=1&amp;r=2" target="_blank" rel="noopener noreferrer"><span style="color:#aaaaaa;">https:\/\/a.example\/x\?q=1&amp;r=2<\/span><\/a>/);
  assert.match(html, /^<span style="color:#aaaaaa;">see \(<\/span><a /);
});

test("a link Claude Code broke at the right edge goes on at the same indent", () => {
  const { window } = load();
  // its /rc at 55 columns, as the phone showed it
  const rows = [
    "  /remote-control is active · Continue here, on your",
    "  phone, or at https://claude.ai/code/session_01VwoQ7kk",
    "  6qR2T3BjAuWd5Hk",
    "  next line",
  ];
  const url = "https://claude.ai/code/session_01VwoQ7kk6qR2T3BjAuWd5Hk";
  assert.deepEqual(plain(window.findLinks(rows, 55)), [[], [{ from: 15, to: 55, url }], [{ from: 2, to: 17, url }], []]);
});

test("a link short of the edge, or a next row at another indent, ends the link", () => {
  const { window } = load();
  assert.deepEqual(plain(window.findLinks(["  - https://a.example/x", "  - next"], 40))[1], []);
  assert.deepEqual(plain(window.findLinks(["  https://a.example/", "    word"], 20))[1], []);
  // a terminal wrap: the row is full and the next starts at the left edge
  assert.deepEqual(plain(window.findLinks(["$ echo https://a.ex", "ample/x", "$"], 19)),
    [[{ from: 7, to: 19, url: "https://a.example/x" }], [{ from: 0, to: 7, url: "https://a.example/x" }], []]);
});

test("a link's pieces keep their own colours", () => {
  const { window } = load();
  const links = [{ from: 0, to: 4, url: "http://x" }];
  const html = window.rowHtml([{ t: "ht", f: "#ff0000" }, { t: "tp", f: "#00ff00" }], "#000000", links);
  assert.equal((html.match(/<a /g) || []).length, 2);
});

// ------------------------------------------------------------------ cell glyphs

/** The solid rectangles of a glyph mask's path, as [x, y, w, h]. */
function solidRects(svg) {
  const d = /<path d="([^"]*)"\/>/.exec(svg);
  if (!d) return [];
  return [...d[1].matchAll(/M([\d.-]+) ([\d.-]+)h([\d.-]+)v([\d.-]+)h[\d.-]+z/g)].map((m) => m.slice(1).map(Number));
}

function covers(rects, x, y) {
  return rects.some(([rx, ry, w, h]) => x >= rx && x < rx + w && y >= ry && y < ry + h);
}

test("Claude's ⏺ bullet is a dot in the text colour, one cell wide, never the emoji", () => {
  const { window } = load();
  assert.match(window.glyphSvg(0x23fa), /<circle cx="4" cy="8.5" r="3"\/>/);
  const html = window.rowHtml([{ t: "⏺", f: "#4eba65" }, { t: " Bash(ls)" }], "#000000");
  assert.match(html, /^<span class="g g\w+" style="width:1ch;color:#4eba65;"><\/span> Bash\(ls\)$/);
  assert.doesNotMatch(html, /⏺/);
});

test("a full block fills its cell, and a run of them is one path", () => {
  const { window } = load();
  const one = window.runSvg("█");
  assert.match(one, /viewBox="0 0 8 16"/);
  assert.deepEqual(solidRects(one), [[0, 0, 8, 16]]);
  const three = window.runSvg("███");
  assert.match(three, /viewBox="0 0 24 16"/);
  assert.equal((three.match(/<path /g) || []).length, 1, "one path: no seams between cells");
  assert.deepEqual(solidRects(three), [[0, 0, 8, 16], [8, 0, 8, 16], [16, 0, 8, 16]]);
});

test("half, eighth and quadrant blocks cover their part of the cell", () => {
  const { window } = load();
  const upperHalf = solidRects(window.glyphSvg(0x2580));
  assert.ok(covers(upperHalf, 4, 2) && !covers(upperHalf, 4, 12));
  const lowerEighth = solidRects(window.glyphSvg(0x2581));
  assert.deepEqual(lowerEighth, [[0, 14, 8, 2]]);
  const upperLeft = solidRects(window.glyphSvg(0x2598)); // ▘
  assert.ok(covers(upperLeft, 1, 1));
  assert.ok(!covers(upperLeft, 6, 1) && !covers(upperLeft, 1, 12) && !covers(upperLeft, 6, 12));
  const threeQuarters = solidRects(window.glyphSvg(0x259b)); // ▛
  assert.ok(covers(threeQuarters, 1, 1) && covers(threeQuarters, 6, 1) && covers(threeQuarters, 1, 12));
  assert.ok(!covers(threeQuarters, 6, 12));
});

test("shades are partly transparent rectangles", () => {
  const { window } = load();
  assert.match(window.glyphSvg(0x2591), /fill-opacity="0.25"/);
  assert.match(window.glyphSvg(0x2593), /fill-opacity="0.75"/);
});

test("box lines reach the cell edges they point to, and no others", () => {
  const { window } = load();
  const horizontal = solidRects(window.glyphSvg(0x2500)); // ─
  assert.ok(covers(horizontal, 0, 8) && covers(horizontal, 7.9, 8));
  assert.ok(!covers(horizontal, 4, 0) && !covers(horizontal, 4, 15.9));
  const cross = solidRects(window.glyphSvg(0x253c)); // ┼
  for (const [x, y] of [[0, 8], [7.9, 8], [4, 0], [4, 15.9], [4, 8]]) assert.ok(covers(cross, x, y), `┼ at ${x},${y}`);
  const corner = solidRects(window.glyphSvg(0x250c)); // ┌
  assert.ok(covers(corner, 7.9, 8) && covers(corner, 4, 15.9));
  assert.ok(!covers(corner, 0, 8) && !covers(corner, 4, 0));
});

test("heavy lines are twice as thick as light ones", () => {
  const { window } = load();
  const [light] = solidRects(window.glyphSvg(0x2502)); // │ (one arm per half)
  const [heavy] = solidRects(window.glyphSvg(0x2503)); // ┃
  assert.equal(heavy[2], 2 * light[2]);
});

test("double lines are two strokes", () => {
  const { window } = load();
  const rects = solidRects(window.glyphSvg(0x2550)); // ═
  const rows = new Set(rects.map(([, y]) => y));
  assert.equal(rows.size, 2);
});

test("each run of glyphs gets one CSS class, made once", () => {
  const page = load();
  const a = page.window.runClass("──");
  assert.equal(page.window.runClass("──"), a);
  assert.notEqual(page.window.runClass("█"), a);
  const sheet = page.window.document.head.children[0];
  assert.equal(sheet.children.length, 2);
  assert.match(sheet.children[0], /mask-image:url\('data:image\/svg\+xml;utf8,/);
});

// ------------------------------------------------------------------ the list

const SESSIONS = [
  { name: "mhm-b", display: "beta", harness: "codex", project: "/home/u/web", state: "WORKING" },
  { name: "mhm-a", display: "alpha", harness: "claude-code", project: "/home/u/api", state: "IDLE" },
  { name: "mhm-c", display: "gamma", harness: "shell", project: "/work/web", state: "WAITING_FOR_INPUT" },
];
const ENDED = [
  { name: "mhm-d", display: "delta", harness: "claude-code", project: "/home/u/api", conversation: "123" },
  { name: "mhm-e", display: "epsilon", harness: "codex", project: "/home/u/api" },
];

function listPage(viewChoices = {}) {
  const page = load();
  Object.assign(page.app.view, viewChoices);
  page.app.sessions = SESSIONS;
  page.app.ended = ENDED;
  page.app.renderedList = null;
  page.window.renderList();
  return page;
}

const names = (page) => page.$("sessions").querySelectorAll("span.name").map((el) => el.textContent);
const groupHeads = (page) => page.$("sessions").querySelectorAll("div.group-head").map((el) => el.children[0].textContent);

test("grouped by folder by default, with two folders of the same name kept apart", () => {
  const page = listPage();
  assert.equal(page.app.view.sort, "folder");
  // /home/u/web and /work/web are both "web": two groups, never interleaved
  assert.deepEqual(groupHeads(page), ["api", "web", "web"]);
  assert.deepEqual(names(page), ["alpha", "delta", "epsilon", "beta", "gamma"]);
});

test("by status: waiting, working, idle, then ended", () => {
  const page = listPage({ sort: "status" });
  assert.deepEqual(names(page), ["gamma", "beta", "alpha", "delta", "epsilon"]);
  assert.deepEqual(groupHeads(page), []);
});

test("by session name, reversed by the direction button", () => {
  assert.deepEqual(names(listPage({ sort: "session" })), ["alpha", "beta", "delta", "epsilon", "gamma"]);
  assert.deepEqual(names(listPage({ sort: "session", descending: true })), ["gamma", "epsilon", "delta", "beta", "alpha"]);
});

test("filters hide states and agents, and say so when nothing is left", () => {
  const page = listPage({ sort: "session" });
  page.app.view.hiddenStates.add("ENDED");
  page.app.view.hiddenAgents.add("codex");
  page.app.renderedList = null;
  page.window.renderList();
  assert.deepEqual(names(page), ["alpha", "gamma"]);
  assert.ok(page.$("view-button").classList.contains("filtered"), "the funnel shows that filters are on");
  for (const state of Object.keys(page.app.STATUS)) page.app.view.hiddenStates.add(state);
  page.app.renderedList = null;
  page.window.renderList();
  assert.equal(page.$("sessions").textContent, "Nothing matches the filters.");
});

test("no sessions at all says how to start one", () => {
  const page = load();
  page.app.renderedList = null;
  page.window.renderList();
  assert.equal(page.$("sessions").textContent, "No sessions yet. Tap New to start one.");
});

test("rows: running ones open and can be stopped when idle; ended ones resume", () => {
  const page = load();
  page.app.view.sort = "session";
  const idle = page.window.row({ ...SESSIONS[1], ended: false });
  assert.equal(idle.children[0].tagName, "A");
  assert.equal(idle.children[0].href, "#s=mhm-a");
  const idleStop = idle.querySelectorAll("button")[0];
  assert.equal(idleStop.className, "btn stop");
  assert.equal(idleStop.getAttribute("aria-label"), "Close alpha");

  const working = page.window.row({ ...SESSIONS[0], ended: false });
  assert.equal(working.querySelectorAll("button")[0].className, "btn stop unavailable");
  assert.equal(working.querySelectorAll("span.status")[0].textContent, "Working");

  const resumable = page.window.row({ ...ENDED[0], state: "ENDED", ended: true });
  assert.equal(resumable.children[0].tagName, "DIV");
  assert.equal(resumable.querySelectorAll("button")[0].getAttribute("aria-label"), "Resume delta");
  assert.equal(resumable.querySelectorAll("span.where")[0].textContent, "Claude · api");

  const fresh = page.window.row({ ...ENDED[1], state: "ENDED", ended: true });
  assert.equal(fresh.querySelectorAll("span.where")[0].textContent, "Codex · api · new conversation");
});

test("a stop tap from the list opens the session to ask there", () => {
  const page = load();
  const row = page.window.row({ ...SESSIONS[1], name: "mhm a/1", ended: false });
  row.querySelectorAll("button")[0].onclick();
  assert.equal(page.location.hash, "s=mhm%20a%2F1");
});

test("folder names come from Mac and Windows paths alike", () => {
  const { window } = load();
  assert.equal(window.folder("/Users/me/Projects/app/"), "app");
  assert.equal(window.folder("C:\\Users\\me\\app"), "app");
  assert.equal(window.folder("/"), "/");
  assert.equal(window.folder(undefined), "");
});

// ------------------------------------------------------------------ server calls

test("a 401 means signed out, and the page shows how to sign in", async () => {
  const page = load({ server: () => ({ status: 401, body: {} }) });
  await page.settle();
  await assert.rejects(page.window.api("/api/sessions"), (e) => e instanceof page.app.Locked);
  assert.equal(page.$("locked-view").hidden, false);
  assert.equal(page.$("list-view").hidden, true);
});

test("an unreachable Mac gets a plain explanation, not Safari's 'Load failed'", async () => {
  const page = load({ server: () => { throw new TypeError("Load failed"); } });
  await page.settle();
  await assert.rejects(page.window.api("/api/sessions"), /Can't reach Microhm/);
  assert.equal(page.$("list-problem").hidden, false);
  assert.match(page.$("list-problem").textContent, /Can't reach Microhm/);
});

test("a refusal shows the server's own words", async () => {
  const page = load({ server: () => ({ status: 200, body: { ok: false, error: "No such session" } }) });
  await assert.rejects(page.window.api("/api/send", { session: "x" }), /No such session/);
  const empty = load({ server: () => ({ status: 500, statusText: "Server Error" }) });
  await assert.rejects(empty.window.api("/api/sessions"), /Server Error/);
});

test("a body makes it a JSON POST", async () => {
  const page = load();
  await page.settle();
  await page.window.api("/api/send", { session: "s", text: "hi", enter: true });
  const call = page.calls.at(-1);
  assert.equal(call.method, "POST");
  assert.deepEqual(plain(call.body), { session: "s", text: "hi", enter: true });
});

test("the phone link's secret is traded for a cookie and leaves the address bar", async () => {
  const page = load({ hash: "#k=s3cret" });
  await page.settle();
  assert.deepEqual(plain(page.calls[0]), { path: "/api/login", method: "POST", body: { token: "s3cret" } });
  assert.deepEqual(page.replaced, ["/"]);
  assert.equal(page.$("list-view").hidden, false);
});

test("a stale link still leaves the address bar", async () => {
  const page = load({ hash: "#k=old", server: (path) => (path === "/api/login" ? { status: 401 } : { status: 401 }) });
  await page.settle();
  assert.deepEqual(page.replaced, ["/"]);
  assert.equal(page.$("locked-view").hidden, false);
});

// ------------------------------------------------------------------ the close sheet

test("Close asks the Mac first, and passes on why it can't", async () => {
  const page = load({
    server: (path) => (path.startsWith("/api/close-check")
      ? { body: { closable: false, reason: "It's still working. Close it once it's done." } }
      : { body: { sessions: [], ended: [] } }),
  });
  await page.settle();
  const flow = page.window.closeFlow("mhm-a", "alpha", false);
  assert.equal(page.$("sheet").hidden, false);
  assert.equal(page.$("sheet-title").textContent, "Close alpha?");
  assert.equal(page.$("sheet-spinner").hidden, false);
  await flow;
  assert.equal(page.$("sheet-title").textContent, "Can't close alpha now");
  assert.equal(page.$("sheet-text").textContent, "It's still working. Close it once it's done.");
  assert.equal(page.$("sheet-confirm").hidden, true);
  assert.equal(page.$("sheet-cancel").textContent, "OK");
});

test("an answer that comes after the sheet was dismissed is ignored", async () => {
  let answer;
  const page = load({
    server: (path) => (path.startsWith("/api/close-check")
      ? new Promise((resolve) => { answer = resolve; })
      : { body: { sessions: [], ended: [] } }),
  });
  await page.settle();
  const flow = page.window.closeFlow("mhm-a", "alpha", false);
  await page.settle();
  page.window.hideSheet();
  answer({ body: { closable: true } });
  await flow;
  assert.equal(page.$("sheet").hidden, true);
});

test("confirming closes, and from the session view goes back to the list", async () => {
  const page = load({
    server: (path) => (path.startsWith("/api/close-check") ? { body: { closable: true } } : { body: { ok: true } }),
  });
  await page.settle();
  page.app.current = "mhm-a";
  page.location.hash = "s=mhm-a";
  await page.window.closeFlow("mhm-a", "alpha", true);
  const confirm = page.$("sheet-confirm");
  assert.equal(confirm.textContent, "Close");
  await confirm.onclick();
  assert.deepEqual(plain(page.calls.at(-1)), { path: "/api/close", method: "POST", body: { session: "mhm-a" } });
  assert.equal(page.$("sheet").hidden, true);
  assert.equal(page.location.hash, "");
});

// ------------------------------------------------------------------ history: swipe back lands on the list

// The fake browser fires no hashchange: route() stands in for it after each address change.

test("a session opened from the list goes back to it through history, as a swipe does", async () => {
  const page = load({ server: (path) => ({ body: path === "/api/sessions" ? { sessions: SESSIONS, ended: [] } : { ok: true } }) });
  page.window.route();
  await page.settle();
  page.$("sessions").querySelectorAll("a.row-main")[0].onclick(); // the link then goes there
  page.location.hash = "s=mhm-a";
  page.window.route();
  page.$("back-button").onclick();
  assert.deepEqual(plain(page.steps), [["back"]]);
});

test("starting a session takes the form's place, so back from it is the list", async () => {
  const page = load({ server: (path) => ({ body: path === "/api/spawn" ? { ok: true, text: "mhm-new started (shell in /tmp)" } : { sessions: [], ended: [], harnesses: ["shell"] } }) });
  page.window.route();
  page.$("new-button").onclick();
  page.window.route();
  await page.settle();
  page.$("new-project").value = "/tmp";
  await page.window.startSession({ preventDefault() {} });
  assert.deepEqual(plain(page.steps), [["replace", "#s=mhm-new"]]);
  page.window.route();
  page.$("back-button").onclick();
  assert.deepEqual(plain(page.steps), [["replace", "#s=mhm-new"], ["back"]]);
});

test("a session reached by a link or a reload has no list below: its entry becomes the list", () => {
  const page = load({ hash: "s=mhm-a" });
  page.window.route();
  page.$("back-button").onclick();
  assert.deepEqual(plain(page.steps), [["replace", "#"]]);
  assert.equal(page.location.hash, "");
});

test("swiping back to the list and forward again: the session no longer sits above the list", () => {
  const page = load();
  page.window.route();
  page.$("new-button").onclick();
  page.window.route();
  page.location.hash = ""; // swipe back
  page.window.route();
  page.location.hash = "new"; // swipe forward
  page.window.route();
  page.$("cancel-new").onclick();
  assert.deepEqual(plain(page.steps), [["replace", "#"]]);
});

// ------------------------------------------------------------------ scrollback

test("scrollback pieces join line by line, and a reset starts over", () => {
  const page = load();
  page.app.current = "s";
  page.window.appendHistory({ reset: true, text: "one\ntwo\n\n" });
  page.window.appendHistory({ text: "three" });
  assert.equal(page.$("history").textContent, "one\ntwo\nthree");
  page.window.appendHistory({ reset: true, text: "again" });
  assert.equal(page.$("history").textContent, "again");
});

test("scrollback is capped at a line boundary", () => {
  const page = load();
  page.app.current = "s";
  const line = "x".repeat(99);
  const lines = Array.from({ length: page.app.MAX_HISTORY_CHARS / 100 + 50 }, (_, i) => i + ":" + line);
  page.window.appendHistory({ reset: true, text: lines.join("\n") });
  const kept = page.$("history").textContent;
  assert.ok(kept.length <= page.app.MAX_HISTORY_CHARS);
  assert.ok(lines.includes(kept.split("\n")[0]), "starts with a whole line");
  assert.ok(kept.endsWith(lines.at(-1)));
});

test("the first scrollback shows its progress until done", () => {
  const page = load();
  page.window.showProgress({ loaded: 65536, total: 3 * 1024 * 1024 });
  assert.equal(page.$("progress").hidden, false);
  assert.equal(page.$("progress-fill").style.width, "2%");
  assert.equal(page.$("progress-text").textContent, "Loading earlier output · 64 KB of 3.0 MB");
  page.window.showProgress({ loaded: 3 * 1024 * 1024, total: 3 * 1024 * 1024, done: true });
  assert.equal(page.$("progress").hidden, true);
  assert.equal(page.window.size(512), "512 B");
});

// ------------------------------------------------------------------ remembered on the phone

test("sort and filters are remembered on this phone", () => {
  const storage = new Map();
  const first = load({ storage });
  first.app.view.sort = "status";
  first.app.view.hiddenAgents.add("shell");
  first.window.saveView();
  const again = load({ storage });
  assert.equal(again.app.view.sort, "status");
  assert.deepEqual([...again.app.view.hiddenAgents], ["shell"]);
});

test("a saved sort the page doesn't know falls back to folders", () => {
  const storage = new Map([["mhm.view2", JSON.stringify({ sort: "colour" })]]);
  assert.equal(load({ storage }).app.view.sort, "folder");
  const broken = new Map([["mhm.view2", "{not json"]]);
  assert.equal(load({ storage: broken }).app.view.sort, "folder");
});

test("private browsing (storage refused) still works, with the defaults", async () => {
  const page = load({ storageFails: true });
  await page.settle();
  assert.equal(page.app.view.sort, "folder");
  assert.equal(page.$("keys").hidden, true);
  page.window.setKeysOpen(true); // does not throw
  assert.equal(page.$("keys").hidden, false);
  assert.equal(page.$("list-view").hidden, false);
});

test("the keypad remembers being open", () => {
  const storage = new Map();
  load({ storage }).window.setKeysOpen(true);
  assert.equal(load({ storage }).$("keys").hidden, false);
});

// ------------------------------------------------------------------ routing

test("the address picks the view", async () => {
  const list = load({ hash: "#whatever" });
  await list.settle();
  assert.equal(list.$("list-view").hidden, false);
  const form = load({ hash: "#new" });
  await form.settle();
  assert.equal(form.$("new-view").hidden, false);
  assert.equal(form.$("list-view").hidden, true);
});

test("the new-session form offers the Mac's agents and the folders in use", async () => {
  const storage = new Map([["mhm.harness", "codex"]]);
  const page = load({
    hash: "#new",
    storage,
    server: (path) => ({
      body: path === "/api/harnesses" ? { harnesses: ["claude-code", "codex", "shell"] }
        : path === "/api/sessions" ? { sessions: SESSIONS, ended: ENDED } : {},
    }),
  });
  await page.settle();
  const select = page.$("new-harness");
  assert.deepEqual(select.options.map((o) => o.textContent), ["Claude", "Codex", "Shell"]);
  assert.equal(select.value, "codex", "the agent picked last time");
  assert.deepEqual(page.$("projects").children.map((o) => o.value), ["/home/u/api", "/home/u/web", "/work/web"]);
});
