// Microhm phone page. Plain script, no build step: edit, save, refresh.
// Views by address: "#" the list, "#s=<name>" one session, "#new" the new-session form.
// The phone link carries the secret as "#k=<secret>"; it is traded for a cookie at once.
"use strict";

const $ = (id) => document.getElementById(id);

// Every state a row can show, in Status order; the same dot and word everywhere.
const STATUS = {
  WAITING_FOR_INPUT: { label: "Waiting", rank: 0 },
  WORKING: { label: "Working", rank: 1 },
  IDLE: { label: "Idle", rank: 2 },
  ENDED: { label: "Ended", rank: 3 },
};
const AGENT = {
  "claude-code": "Claude", codex: "Codex", "cursor-agent": "Cursor", grok: "Grok",
  opencode: "OpenCode", pi: "Pi", muse: "Muse", shell: "Shell",
};

let sessions = []; // running, from the server
let ended = []; // saved sessions that are not running
let renderedList = null;
const screens = new Map(); // the last screen seen of each session, shown at once on return
let listTimer = null;
let stream = null;
let current = null; // the session being shown
let retryDelay = 1000; // reconnecting backs off, so a failing server is not hammered
const MAX_RETRY_DELAY = 15000;

// ------------------------------------------------------------------ server calls

class Locked extends Error {}

async function api(path, body) {
  const options = body === undefined ? {} : {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  };
  let response;
  try {
    response = await fetch(path, options);
  } catch (e) {
    // Safari's own words for this are "Load failed"
    throw new Error("Can't reach Microhm. Is it running, and is this phone on your network?");
  }
  if (response.status === 401) throw new Locked();
  const data = await response.json().catch(() => ({}));
  if (!response.ok || data.ok === false) throw new Error(data.error || data.text || response.statusText);
  return data;
}

async function login(token) {
  try {
    await api("/api/login", { token });
  } catch (e) {
    // a stale link: fall through to the locked screen if the cookie does not work either
  }
  history.replaceState(null, "", location.pathname);
}

// ------------------------------------------------------------------ routing

// The list is home, and history holds at most the list and one view above it, so Safari's
// swipe back (and its back button) always lands on the list. Opening a session or the form
// from the list adds that one entry; leaving it by the page's own buttons steps back
// through it rather than adding another; starting a session takes the form's place.
let fromList = false; // the view shown sits one history entry above the list
let navigation = null; // "open" or "replace": how the next address change came about

/** From the list to a view: one history entry above the list. */
function openView(hash) {
  navigation = "open";
  location.hash = hash;
}

/** This view's history entry becomes {@code hash}'s, still above the list if it was. */
function replaceView(hash) {
  navigation = "replace";
  location.replace("#" + hash);
}

/** Back to the list: the entry below when there is one, else this entry becomes the list
 * (a view reached by a link or a reload has no list below it). */
function toList() {
  if (fromList) history.back(); else replaceView("");
}

function route() {
  const hash = decodeURIComponent(location.hash.slice(1));
  if (navigation === "open") fromList = true;
  else if (navigation !== "replace") fromList = false; // swipe back or forward, a link, a reload
  navigation = null;
  stopList();
  stopStream();
  hideSheet();
  current = null;
  if (hash.startsWith("s=")) {
    showSession(hash.slice(2));
  } else if (hash === "new") {
    showNew();
  } else {
    showList();
  }
}

function show(id) {
  for (const view of document.querySelectorAll(".view")) view.hidden = view.id !== id;
}

function locked() {
  stopList();
  stopStream();
  show("locked-view");
}

function problem(id, message) {
  const el = $(id);
  el.textContent = message || "";
  el.hidden = !message;
}

function failed(id, e) {
  if (e instanceof Locked) return locked();
  problem(id, e.message);
}

// ------------------------------------------------------------------ list: sort, filter, group

// Sort and filters, kept on this phone. The same choices as Microhm's sidebar.
const view = loadView();

function loadView() {
  const saved = readJson("view2") || {};
  return {
    // grouped by folder unless chosen otherwise: easiest on the eyes
    sort: ["status", "session", "folder"].includes(saved.sort) ? saved.sort : "folder",
    descending: !!saved.descending,
    hiddenStates: new Set(saved.hiddenStates || []),
    hiddenAgents: new Set(saved.hiddenAgents || []),
  };
}

function saveView() {
  writeJson("view2", {
    sort: view.sort, descending: view.descending,
    hiddenStates: [...view.hiddenStates], hiddenAgents: [...view.hiddenAgents],
  });
  renderedList = null;
  renderList();
}

async function showList() {
  show("list-view");
  renderControls();
  await refreshList();
  listTimer = setInterval(refreshList, 3000);
}

function stopList() {
  clearInterval(listTimer);
  listTimer = null;
}

async function refreshList() {
  try {
    const data = await api("/api/sessions");
    problem("list-problem", "");
    sessions = data.sessions;
    ended = data.ended || [];
    renderList();
  } catch (e) {
    failed("list-problem", e);
  }
}

function label(s) {
  return s.display || s.name;
}

function folder(project) {
  return (project || "").split(/[\\/]/).filter(Boolean).pop() || project || "";
}

function allRows() {
  return [
    ...sessions.map((s) => ({ ...s, ended: false })),
    ...ended.map((s) => ({ ...s, state: "ENDED", ended: true })),
  ];
}

function compareRows(a, b) {
  const byName = label(a).localeCompare(label(b), undefined, { sensitivity: "base" });
  let primary = 0;
  if (view.sort === "status") {
    primary = (STATUS[a.state]?.rank ?? 9) - (STATUS[b.state]?.rank ?? 9);
  } else if (view.sort === "folder") {
    // the full path next, so two folders with the same name never interleave
    primary = folder(a.project).localeCompare(folder(b.project), undefined, { sensitivity: "base" })
      || (a.project || "").localeCompare(b.project || "");
  }
  return (view.descending ? -1 : 1) * (primary || byName);
}

// The sort and filter rows start hidden; the funnel shows them. It turns blue while
// filters hide some sessions, so a short list is never a mystery.
function toggleControls() {
  const open = $("controls").hidden;
  $("controls").hidden = !open;
  $("filters").hidden = !open;
  renderControls();
}

function renderControls() {
  const open = !$("controls").hidden;
  const filtered = view.hiddenStates.size > 0 || view.hiddenAgents.size > 0;
  const funnel = $("view-button");
  funnel.setAttribute("aria-expanded", String(open));
  funnel.classList.toggle("on", open);
  funnel.classList.toggle("filtered", filtered);
  for (const button of $("sort").querySelectorAll("button")) {
    button.setAttribute("aria-pressed", String(button.dataset.sort === view.sort));
  }
  $("direction").textContent = view.descending ? "↑" : "↓";
  const filters = $("filters");
  filters.replaceChildren();
  for (const [state, info] of Object.entries(STATUS)) {
    filters.append(chip(info.label, !view.hiddenStates.has(state), () => toggle(view.hiddenStates, state)));
  }
  const agents = [...new Set(allRows().map((s) => s.harness))].sort();
  if (agents.length > 1) {
    const gap = document.createElement("span");
    gap.className = "chip-gap";
    filters.append(gap);
    for (const agent of agents) {
      filters.append(chip(AGENT[agent] || agent, !view.hiddenAgents.has(agent), () => toggle(view.hiddenAgents, agent)));
    }
  }
}

function chip(text, on, onClick) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "chip";
  button.textContent = text;
  button.setAttribute("aria-pressed", String(on));
  button.onclick = onClick;
  return button;
}

function toggle(set, key) {
  if (set.has(key)) set.delete(key); else set.add(key);
  saveView();
  renderControls();
}

function renderList() {
  const rows = allRows();
  const key = JSON.stringify([rows, view.sort, view.descending, [...view.hiddenStates], [...view.hiddenAgents]]);
  if (key === renderedList) return;
  renderedList = key;
  renderControls();
  const list = $("sessions");
  list.replaceChildren();
  if (rows.length === 0) {
    list.append(empty("No sessions yet. Tap New to start one."));
    return;
  }
  const shown = rows
    .filter((s) => !view.hiddenStates.has(s.state) && !view.hiddenAgents.has(s.harness))
    .sort(compareRows);
  if (shown.length === 0) {
    list.append(empty("Nothing matches the filters."));
    return;
  }
  if (view.sort === "folder") {
    // one group per folder, headed by its name and path, like the sidebar's folder groups
    let group = null;
    let path = null;
    for (const s of shown) {
      if (s.project !== path) {
        path = s.project;
        const head = document.createElement("div");
        head.className = "group-head";
        const name = document.createElement("b");
        name.textContent = folder(path);
        const full = document.createElement("span");
        full.textContent = path;
        head.append(name, full);
        group = document.createElement("div");
        group.className = "group";
        list.append(head, group);
      }
      group.append(row(s));
    }
  } else {
    const group = document.createElement("div");
    group.className = "group";
    for (const s of shown) group.append(row(s));
    list.append(group);
  }
}

function empty(text) {
  const p = document.createElement("p");
  p.className = "empty";
  p.textContent = text;
  return p;
}

// play: a triangle drawn with a thick round-joined stroke, so its corners are soft
const ICON_PLAY = '<svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true"><path d="M8.5 6.8v10.4a1 1 0 0 0 1.5.86l8.6-5.2a1 1 0 0 0 0-1.72L10 5.94a1 1 0 0 0-1.5.86z" fill="currentColor" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/></svg>';
const ICON_STOP = '<svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true"><rect x="6" y="6" width="12" height="12" rx="2.5" fill="currentColor"/></svg>';

// A row: the name and where on the left (tap to open a running session), its status and
// one action on the right: play resumes an ended session, stop closes a running one.
function row(s) {
  const el = document.createElement("div");
  el.className = "row" + (s.ended ? " ended" : "");
  const main = document.createElement(s.ended ? "div" : "a");
  main.className = "row-main";
  if (!s.ended) {
    main.href = "#s=" + encodeURIComponent(s.name);
    main.onclick = () => { navigation = "open"; }; // the link itself goes there
  }
  const name = document.createElement("span");
  name.className = "name";
  name.textContent = label(s);
  const where = document.createElement("span");
  where.className = "where";
  // an ended agent without a saved conversation starts a new one when resumed
  const fresh = s.ended && !s.conversation && s.harness !== "shell" ? " · new conversation" : "";
  where.textContent = (AGENT[s.harness] || s.harness) + (view.sort === "folder" ? "" : " · " + folder(s.project)) + fresh;
  main.append(name, where);
  const side = document.createElement("div");
  side.className = "row-side";
  const action = document.createElement("button");
  action.type = "button";
  if (s.ended) {
    action.className = "btn play";
    action.setAttribute("aria-label", "Resume " + label(s));
    action.innerHTML = ICON_PLAY;
    action.onclick = () => resumeSession(s, action);
    side.append(status("ENDED"), action);
  } else {
    action.className = "btn stop" + (closable(s.state) ? "" : " unavailable");
    action.setAttribute("aria-label", "Close " + label(s));
    action.innerHTML = ICON_STOP;
    // close from the list: open the session, so you see what you close, and ask there
    action.onclick = () => {
      closeOnOpen = s.name;
      openView("s=" + encodeURIComponent(s.name));
    };
    side.append(status(s.state), action);
  }
  el.append(main, side);
  return el;
}

/** Whether Close is on offer: only an idle session (the server checks again). */
function closable(state) {
  return state === "IDLE";
}

function status(state) {
  const el = document.createElement("span");
  setStatus(el, state);
  return el;
}

function setStatus(el, state) {
  el.className = "status " + (state || "");
  el.textContent = state ? (STATUS[state]?.label || state.toLowerCase()) : "";
}

async function resumeSession(s, button) {
  button.disabled = true;
  try {
    const result = await api("/api/resume", { session: s.name });
    openView("s=" + encodeURIComponent(result.name));
  } catch (e) {
    failed("list-problem", e);
    button.disabled = false;
  }
}

// ------------------------------------------------------------------ one session

let lastView = null;
let stickToBottom = true;
let closeOnOpen = null; // a session to offer closing once its view is open (from the list)

function showSession(name) {
  current = name;
  retryDelay = 1000;
  show("session-view");
  problem("session-problem", "");
  const known = screens.get(name) || sessions.find((s) => s.name === name);
  $("session-title").textContent = known ? (known.display || known.name) : name;
  setSessionState(known ? known.state : "");
  drawnStyled = null;
  $("scroller").style.background = "";
  $("scroller").style.color = "";
  $("screen").textContent = known && known.text !== undefined ? known.text : "";
  if (known && known.styled) drawStyled(known.styled);
  // nothing to show yet: say it is on its way rather than leave the area black
  $("connecting").hidden = !!(known && known.text && known.text.trim());
  $("progress").hidden = true;
  $("history").textContent = histories.get(name) || "";
  lastView = known && known.text !== undefined ? known : null;
  stickToBottom = true;
  scrollToBottom();
  openStream();
  if (closeOnOpen === name) {
    closeOnOpen = null;
    closeFlow(name, $("session-title").textContent, true);
  }
}

function setSessionState(state) {
  setStatus($("session-state"), state);
  // like the sidebar, Close looks unavailable unless the session is idle
  $("close-button").classList.toggle("unavailable", !closable(state));
}

function openStream() {
  stopStream();
  const size = phoneSize();
  streamWidth = window.innerWidth;
  const es = new EventSource("/api/stream?session=" + encodeURIComponent(current)
    + "&cols=" + size.cols + "&rows=" + size.rows + "&styled=1");
  stream = es;
  es.onmessage = (event) => {
    problem("session-problem", "");
    retryDelay = 1000;
    renderScreen(JSON.parse(event.data));
  };
  es.addEventListener("history", (event) => appendHistory(JSON.parse(event.data)));
  es.addEventListener("exited", () => {
    setSessionState("ENDED");
    stopStream();
  });
  es.addEventListener("problem", (event) => {
    problem("session-problem", JSON.parse(event.data).error);
  });
  es.onerror = async () => {
    // Reconnect ourselves, waiting longer each time: 1 s, 2 s, 4 s … up to 15 s. EventSource
    // would retry at once and forever, and a server that keeps dropping the stream would
    // make the page flicker. Asking for the screen first tells a 401 or an ended session.
    if (stream !== es) return;
    es.close();
    const delay = retryDelay;
    retryDelay = Math.min(retryDelay * 2, MAX_RETRY_DELAY);
    if (delay >= 4000) problem("session-problem", "The connection keeps dropping. Trying again…");
    setTimeout(async () => {
      if (stream !== es) return; // left the session, or a newer stream took over
      try {
        await api("/api/screen?session=" + encodeURIComponent(current));
        openStream();
      } catch (e) {
        failed("session-problem", e);
        if (!(e instanceof Locked)) {
          // ended, or the Mac is unreachable: show it as such and stop retrying
          setSessionState("ENDED");
          stopStream();
        }
      }
    }, delay);
  };
}

function stopStream() {
  if (stream) stream.close();
  stream = null;
}

function scrollToBottom() {
  const scroller = $("scroller");
  scroller.scrollTop = scroller.scrollHeight;
}

function atBottom() {
  const scroller = $("scroller");
  return scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 40;
}

// Scrollback: the stream sends what the session still holds, then each line as it
// scrolls off the screen. Kept per session, capped so a long session stays light.
const MAX_HISTORY_CHARS = 400000;
const histories = new Map();

function appendHistory(chunk) {
  showProgress(chunk);
  if (!chunk.reset && !chunk.text) return;
  const stick = atBottom();
  const el = $("history");
  let text = (chunk.reset ? "" : el.textContent) + (el.textContent && !chunk.reset && chunk.text ? "\n" : "") + chunk.text;
  text = text.replace(/\n+$/, "");
  if (text.length > MAX_HISTORY_CHARS) text = text.slice(text.indexOf("\n", text.length - MAX_HISTORY_CHARS) + 1);
  el.textContent = text;
  histories.set(current, text);
  if (stick) scrollToBottom();
}

// The first scrollback arrives in pieces that count up to its total: a bar while it does.
function showProgress(chunk) {
  if (chunk.total === undefined || chunk.done) {
    $("progress").hidden = true;
    return;
  }
  $("progress").hidden = false;
  $("progress-fill").style.width = Math.round(100 * chunk.loaded / chunk.total) + "%";
  $("progress-text").textContent = "Loading earlier output · " + size(chunk.loaded) + " of " + size(chunk.total);
}

function size(bytes) {
  if (bytes < 1024) return bytes + " B";
  if (bytes < 1024 * 1024) return Math.round(bytes / 1024) + " KB";
  return (bytes / (1024 * 1024)).toFixed(1) + " MB";
}

function renderScreen(view) {
  if (view.name !== current && view.display !== current) return; // a late event from the last session
  // keep the spinner while the screen is still blank: after the phone resizes a session,
  // its program (Claude Code, say) clears and redraws, which can take a moment
  $("connecting").hidden = view.text.trim().length > 0;
  screens.set(current, view);
  const screen = $("screen");
  const stick = stickToBottom || atBottom();
  stickToBottom = false;
  $("session-title").textContent = view.display || view.name;
  setSessionState(view.state);
  if (view.styled) {
    drawStyled(view.styled);
  } else if (screen.textContent !== view.text) {
    drawnStyled = null;
    screen.textContent = view.text;
  }
  lastView = view;
  if (stick) scrollToBottom();
}

// The screen in colour: rows of runs, each with its colours (absent: the terminal's
// defaults, which also paint the area) and style bits (bold 1, dim 2, italic 4,
// underline 8, strikethrough 16; an underline's kind: double 32, curly 64, dotted 128,
// dashed 256), as the server draws them with the Mac's palette.
let drawnStyled = null;

function drawStyled(styled) {
  const key = JSON.stringify(styled.rows);
  if (key === drawnStyled) return;
  drawnStyled = key;
  const scroller = $("scroller");
  scroller.style.background = styled.bg;
  scroller.style.color = styled.fg;
  $("screen").innerHTML = styled.rows.map((runs) => rowHtml(runs, styled.bg)).join("\n");
}

/**
 * One row as HTML. The row is taken apart into cells and put back together so that every
 * stretch of solid colour becomes one shape: a space on a coloured background is drawn as
 * a full block in that colour, and neighbouring box and block cells of the same colour join
 * into one run (see runSvg), whichever styled run they came from. Separate pieces meeting
 * off a device pixel leave a faint seam; Claude's logo mixes blocks and coloured spaces.
 */
function rowHtml(runs, screenBackground) {
  const cells = [];
  for (const run of runs) {
    // a background the same as the screen's is no background: Claude's logo paints part of
    // its body on an explicit black, and that must still join the cells beside it
    const b = run.b && run.b !== screenBackground ? run.b : null;
    for (const ch of run.t) {
      if (ch === " " && b) {
        cells.push({ ch: "█", f: b, b: null, s: 0, tile: true });
      } else {
        cells.push({ ch, f: run.f || null, b, s: run.s || 0, tile: isTile(ch.codePointAt(0)) });
      }
    }
  }
  let html = "";
  let group = null;
  const flush = () => {
    if (group) html += group.tile ? tileHtml(group) : textHtml(group);
    group = null;
  };
  for (const cell of cells) {
    const key = (cell.tile ? "T" : "X") + "|" + cell.f + "|" + cell.b + "|" + (cell.tile ? cell.s & 2 : cell.s);
    if (!group || group.key !== key) {
      flush();
      group = { key, tile: cell.tile, f: cell.f, b: cell.b, s: cell.s, text: "", count: 0 };
    }
    group.text += cell.ch;
    group.count++;
  }
  flush();
  return html;
}

/** A run of box and block cells: one shape across all of them, in their colour. */
function tileHtml(group) {
  let css = "width:" + group.count + "ch;";
  if (group.f) css += "color:" + group.f + ";";
  if (group.s & 2) css += "opacity:.6;";
  const shape = '<span class="g ' + runClass(group.text) + '" style="' + css + '"></span>';
  return group.b ? '<span style="background:' + group.b + '">' + shape + "</span>" : shape;
}

function textHtml(group) {
  const text = escapeHtml(group.text);
  let css = "";
  if (group.f) css += "color:" + group.f + ";";
  if (group.b) css += "background:" + group.b + ";";
  if (group.s & 1) css += "font-weight:700;";
  if (group.s & 2) css += "opacity:.6;";
  if (group.s & 4) css += "font-style:italic;";
  const lines = (group.s & 8 ? " underline" : "") + (group.s & 16 ? " line-through" : "");
  if (lines) css += "text-decoration:" + lines + underlineStyle(group.s) + ";";
  return css ? '<span style="' + css + '">' + text + "</span>" : text;
}

/** The underline's kind (double 32, curly 64, dotted 128, dashed 256) as a CSS line style. */
function underlineStyle(bits) {
  if (!(bits & 8)) return "";
  if (bits & 32) return " double";
  if (bits & 64) return " wavy";
  if (bits & 128) return " dotted";
  if (bits & 256) return " dashed";
  return "";
}

function escapeHtml(text) {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// ------------------------------------------------------------------ cell glyphs

// Box drawing (U+2500–257F) and block elements (U+2580–259F) are drawn as shapes that fill
// their cell exactly, as the Mac window's BoxDrawing does: a font's glyph box is not the
// cell, so stacked rows of blocks (Claude's logo) and box borders leave gaps and steps.
// Each shape is an 8 × 16 SVG used as a mask over the text colour, one CSS class per
// character, made the first time it appears. Light lines are an eighth of the cell wide,
// heavy twice that, double lines two light strokes a light width apart.

const GW = 8, GH = 16, LIGHT = 1, HEAVY = 2;
// URDL arm weights (0 none, 1 light, 2 heavy, 3 double; "d" dashed), as in BoxDrawing.java
const LINES_1 = ["0101", "0202", "1010", "2020", "d", "d", "d", "d", "d", "d", "d", "d",
  "0110", "0210", "0120", "0220", "0011", "0012", "0021", "0022",
  "1100", "1200", "2100", "2200", "1001", "1002", "2001", "2002",
  "1110", "1210", "2110", "1120", "2120", "2210", "1220", "2220",
  "1011", "1012", "2011", "1021", "2021", "2012", "1022", "2022",
  "0111", "0112", "0211", "0212", "0121", "0122", "0221", "0222",
  "1101", "1102", "1201", "1202", "2101", "2102", "2201", "2202",
  "1111", "1112", "1211", "1212", "2111", "1121", "2121", "2112",
  "2211", "1122", "1221", "2212", "1222", "2122", "2221", "2222"];
const LINES_2 = ["0303", "3030", "0310", "0130", "0330", "0013", "0031", "0033",
  "1300", "3100", "3300", "1003", "3001", "3003", "1310", "3130",
  "3330", "1013", "3031", "3033", "0313", "0131", "0333", "1303",
  "3101", "3303", "1313", "3131", "3333"];
const LINES_3 = ["0001", "1000", "0100", "0010", "0002", "2000", "0200", "0020",
  "0201", "1020", "0102", "2010"];
// U+2596–259F: bit 1 upper left, 2 upper right, 4 lower left, 8 lower right
const QUADRANTS = [4, 8, 1, 1 | 4 | 8, 1 | 8, 1 | 2 | 4, 1 | 2 | 8, 2, 2 | 4, 2 | 4 | 8];

// ⏺ (U+23FA), Claude Code's bullet (it blinks while a tool runs): no monospace font has it,
// so iPhone Safari falls back to Apple Color Emoji, a grey tile wider than the cell that
// ignores the run's colour. Drawn as a dot in the text colour instead.
const RECORD = 0x23fa;

function isTile(cp) {
  return (cp >= 0x2500 && cp <= 0x259f) || cp === RECORD;
}

const runClasses = new Map(); // run text -> class name
let glyphSheet = null;

/** The class that draws the run {@code text} as one shape, its CSS rule added on first use. */
function runClass(text) {
  let name = runClasses.get(text);
  if (!name) {
    name = "g" + runClasses.size.toString(36);
    runClasses.set(text, name);
    if (!glyphSheet) {
      glyphSheet = document.createElement("style");
      document.head.append(glyphSheet);
    }
    const url = "url('data:image/svg+xml;utf8," + encodeURIComponent(runSvg(text)) + "')";
    glyphSheet.append("." + name + "{-webkit-mask-image:" + url + ";mask-image:" + url + "}\n");
  }
  return name;
}

/**
 * The mask for a run of tile characters side by side: one SVG spanning the whole run.
 * Every solid rectangle of every character goes into ONE path. Shapes drawn separately are
 * each antialiased on their own, and where two meet off a device-pixel boundary (a cell is
 * 7.2 px wide, 21.6 device pixels on an iPhone) their half-covered edges leave a faint dark
 * seam, every 4 or 5 cells. Within one path a shared edge is interior: no seam.
 */
function runSvg(text) {
  const out = { solid: "", parts: [] };
  let i = 0;
  for (const ch of text) {
    glyphInto(ch.codePointAt(0), i * GW, out);
    i++;
  }
  if (out.solid) out.parts.unshift('<path d="' + out.solid + '"/>');
  return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' + (GW * i) + " " + GH
    + '" preserveAspectRatio="none">' + out.parts.join("") + "</svg>";
}

function glyphSvg(cp) {
  return runSvg(String.fromCodePoint(cp));
}

/** One character's shapes, {@code dx} units to the right, added to {@code out}. */
function glyphInto(cp, dx, out) {
  const parts = out.parts;
  const rect = (x, y, w, h, opacity) => {
    if (!(w > 0 && h > 0)) return;
    if (opacity) {
      parts.push('<rect x="' + (x + dx) + '" y="' + y + '" width="' + w + '" height="' + h + '" fill-opacity="' + opacity + '"/>');
    } else {
      out.solid += "M" + (x + dx) + " " + y + "h" + w + "v" + h + "h" + (-w) + "z";
    }
  };
  const stroke = (d) => parts.push('<path transform="translate(' + dx + ' 0)" d="' + d
    + '" fill="none" stroke="#000" stroke-width="' + LIGHT + '"/>');
  if (cp === RECORD) {
    // a dot about a lowercase letter wide, centred on the lowercase height
    parts.push('<circle cx="' + (dx + GW / 2) + '" cy="8.5" r="3"/>');
  } else if (cp >= 0x2580) {
    block(cp, rect);
  } else {
    let arms = null;
    if (cp <= 0x254b) arms = LINES_1[cp - 0x2500];
    else if (cp >= 0x2550 && cp <= 0x256c) arms = LINES_2[cp - 0x2550];
    else if (cp >= 0x2574) arms = LINES_3[cp - 0x2574];
    if (arms && arms !== "d") {
      const [u, r, d, l] = [...arms].map(Number);
      if (u === 3 || r === 3 || d === 3 || l === 3) doubleLines(rect, u, r, d, l);
      else lines(rect, u, r, d, l);
    } else if ([0x2504, 0x2505, 0x2508, 0x2509, 0x254c, 0x254d].includes(cp)) {
      dashes(rect, cp >= 0x254c ? 2 : cp >= 0x2508 ? 4 : 3, (cp & 1) === 0 ? LIGHT : HEAVY, true);
    } else if ([0x2506, 0x2507, 0x250a, 0x250b, 0x254e, 0x254f].includes(cp)) {
      dashes(rect, cp >= 0x254c ? 2 : cp >= 0x2508 ? 4 : 3, (cp & 1) === 0 ? LIGHT : HEAVY, false);
    } else if (cp >= 0x256d && cp <= 0x2570) {
      // ╭ ╮ ╯ ╰: straight to the cell edges, rounded through the centre
      const cx = GW / 2, cy = GH / 2, radius = Math.min(GW, GH) / 2;
      const toRight = cp === 0x256d || cp === 0x2570, toBottom = cp === 0x256d || cp === 0x256e;
      const ex = toRight ? GW : 0, ey = toBottom ? GH : 0;
      const sx = toRight ? Math.min(cx + radius, ex) : Math.max(cx - radius, ex);
      const sy = toBottom ? Math.min(cy + radius, ey) : Math.max(cy - radius, ey);
      stroke("M" + cx + " " + ey + "L" + cx + " " + sy + "Q" + cx + " " + cy + " " + sx + " " + cy + "L" + ex + " " + cy);
    } else if (cp >= 0x2571 && cp <= 0x2573) {
      if (cp !== 0x2572) stroke("M" + GW + " 0L0 " + GH);
      if (cp !== 0x2571) stroke("M0 0L" + GW + " " + GH);
    }
  }
}

function thickness(weight) {
  return weight === 2 ? HEAVY : weight === 0 ? 0 : LIGHT;
}

// Light and heavy arms: each reaches past the centre by the perpendicular strokes' half
// width, so corners and junctions are filled.
function lines(rect, u, r, d, l) {
  const tu = thickness(u), tr = thickness(r), td = thickness(d), tl = thickness(l);
  const vertical = Math.max(tu, td), horizontal = Math.max(tl, tr);
  if (tu > 0) {
    const band = horizontal > 0 ? horizontal : tu;
    rect((GW - tu) / 2, 0, tu, (GH - band) / 2 + band);
  }
  if (td > 0) {
    const band = horizontal > 0 ? horizontal : td;
    const start = (GH - band) / 2;
    rect((GW - td) / 2, start, td, GH - start);
  }
  if (tl > 0) {
    const band = vertical > 0 ? vertical : tl;
    rect(0, (GH - tl) / 2, (GW - band) / 2 + band, tl);
  }
  if (tr > 0) {
    const band = vertical > 0 ? vertical : tr;
    const start = (GW - band) / 2;
    rect(start, (GH - tr) / 2, GW - start, tr);
  }
}

// A double arm is two light strokes at ±t from the single stroke; where it meets a
// perpendicular arm its outer stroke runs to that arm's far stroke, its inner to the near.
function doubleLines(rect, u, r, d, l) {
  const t = LIGHT;
  const up = u > 0, right = r > 0, down = d > 0, left = l > 0;
  const vx = (GW - t) / 2, hy = (GH - t) / 2;
  const vDouble = u === 3 || d === 3, hDouble = l === 3 || r === 3;
  const xa = vDouble ? vx - t : vx, xb = vDouble ? vx + t : vx;
  const ya = hDouble ? hy - t : hy, yb = hDouble ? hy + t : hy;
  const v = (x, y0, y1) => rect(x, y0, t, y1 - y0);
  const h = (y, x0, x1) => rect(x0, y, x1 - x0, t);
  if (up) {
    if (u === 3) { v(xa, 0, (left ? ya : yb) + t); v(xb, 0, (right ? ya : yb) + t); }
    else v(vx, 0, left && right ? (down ? yb : ya) + t : yb + t);
  }
  if (down) {
    if (d === 3) { v(xa, left ? yb : ya, GH); v(xb, right ? yb : ya, GH); }
    else v(vx, left && right ? (up ? ya : yb) : ya, GH);
  }
  if (left) {
    if (l === 3) { h(ya, 0, (up ? xa : xb) + t); h(yb, 0, (down ? xa : xb) + t); }
    else h(hy, 0, up && down ? (right ? xb : xa) + t : xb + t);
  }
  if (right) {
    if (r === 3) { h(ya, up ? xb : xa, GW); h(yb, down ? xb : xa, GW); }
    else h(hy, up && down ? (left ? xa : xb) : xa, GW);
  }
}

function dashes(rect, n, t, horizontal) {
  const length = horizontal ? GW : GH;
  const slot = length / n;
  const gap = Math.max(0.5, slot / 3);
  for (let i = 0; i < n; i++) {
    const a = i * slot + gap / 2, b = (i + 1) * slot - gap / 2;
    if (b <= a) continue;
    if (horizontal) rect(a, (GH - t) / 2, b - a, t);
    else rect((GW - t) / 2, a, t, b - a);
  }
}

function block(cp, rect) {
  if (cp === 0x2580) rect(0, 0, GW, GH / 2);
  else if (cp >= 0x2581 && cp <= 0x2588) { const top = GH - GH * (cp - 0x2580) / 8; rect(0, top, GW, GH - top); }
  else if (cp >= 0x2589 && cp <= 0x258f) rect(0, 0, GW * (8 - (cp - 0x2588)) / 8, GH);
  else if (cp === 0x2590) rect(GW / 2, 0, GW / 2, GH);
  else if (cp >= 0x2591 && cp <= 0x2593) rect(0, 0, GW, GH, (cp - 0x2590) * 0.25);
  else if (cp === 0x2594) rect(0, 0, GW, GH / 8);
  else if (cp === 0x2595) rect(GW - GW / 8, 0, GW / 8, GH);
  else {
    const bits = QUADRANTS[cp - 0x2596];
    if (bits & 1) rect(0, 0, GW / 2, GH / 2);
    if (bits & 2) rect(GW / 2, 0, GW / 2, GH / 2);
    if (bits & 4) rect(0, GH / 2, GW / 2, GH / 2);
    if (bits & 8) rect(GW / 2, GH / 2, GW / 2, GH / 2);
  }
}


// The columns and rows that fit the screen area at its font size: the session runs at
// this size while the phone watches it (the server gives the old size back afterwards).
let streamWidth = 0;

function phoneSize() {
  const scroller = $("scroller");
  const box = getComputedStyle(scroller);
  const style = getComputedStyle($("screen"));
  const width = scroller.clientWidth - parseFloat(box.paddingLeft) - parseFloat(box.paddingRight);
  const height = scroller.clientHeight - parseFloat(box.paddingTop) - parseFloat(box.paddingBottom);
  const ctx = phoneSize.ctx || (phoneSize.ctx = document.createElement("canvas").getContext("2d"));
  ctx.font = style.fontSize + " " + style.fontFamily;
  const charWidth = ctx.measureText("M".repeat(20)).width / 20;
  const fontSize = parseFloat(style.fontSize);
  const lineHeight = parseFloat(style.lineHeight) || fontSize * 1.35;
  return {
    cols: Math.max(20, Math.floor(width / charWidth)),
    rows: Math.max(5, Math.floor(height / lineHeight)),
  };
}

async function pressKeys(keys) {
  try {
    await api("/api/keys", { session: current, keys });
  } catch (e) {
    failed("session-problem", e);
  }
}

async function sendMessage(event) {
  event.preventDefault();
  const box = $("message");
  const text = box.value;
  $("send-button").disabled = true;
  try {
    // an empty message just presses Enter
    await api("/api/send", { session: current, text, enter: true });
    box.value = "";
    growMessage();
  } catch (e) {
    failed("session-problem", e);
  } finally {
    $("send-button").disabled = false;
  }
}

function growMessage() {
  const box = $("message");
  // Measuring collapses the box for a moment; the screen above grows, its scroll position
  // is clamped, and the box growing back would leave the screen a line up from where it was,
  // until the next screen update scrolled it back: the screen shook with every keystroke.
  // Keep the screen's distance from its bottom instead (the reader's place, or the bottom).
  const scroller = $("scroller");
  const fromBottom = scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop;
  box.style.height = "auto";
  box.style.height = box.scrollHeight + "px";
  scroller.scrollTop = scroller.scrollHeight - scroller.clientHeight - fromBottom;
}

// Close asks first, the way Microhm's Close does: a session whose agent is working or
// waiting for you, or that has a program running, is not closed. From the session view
// it goes back to the list afterwards; from the list it stays.
let sheetToken = 0; // which question the sheet is showing: a late answer to an old one is ignored

async function closeFlow(name, title, fromSession) {
  const problemId = fromSession ? "session-problem" : "list-problem";
  // the sheet comes up at once; the Mac's answer (a second or two) fills it in
  const token = showSheet({ title: "Close " + title + "?", text: "Checking whether it can close…", busy: true });
  let check;
  try {
    check = await api("/api/close-check?session=" + encodeURIComponent(name));
  } catch (e) {
    if (token !== sheetToken) return;
    hideSheet();
    return failed(problemId, e);
  }
  if (token !== sheetToken) return; // closed, or another question took its place
  if (!check.closable) {
    showSheet({ title: "Can't close " + title + " now", text: check.reason, cancel: "OK" });
    return;
  }
  showSheet({
    title: "Close " + title + "?",
    text: "The agent is asked to quit and its shell exits. You can resume it later from the list.",
    confirm: "Close",
    onConfirm: async (button) => {
      button.disabled = true;
      button.textContent = "Closing…";
      // stop watching first: the session ending is expected, not something to report
      if (fromSession && current === name) {
        stopStream();
        problem("session-problem", "");
      }
      try {
        await api("/api/close", { session: name });
        hideSheet();
        if (fromSession) toList(); else refreshList();
      } catch (e) {
        hideSheet();
        failed(problemId, e);
      }
    },
  });
}

// ------------------------------------------------------------------ sheet

function showSheet({ title, text, confirm, onConfirm, cancel, busy }) {
  sheetToken++;
  $("sheet-title").textContent = title;
  $("sheet-text").textContent = text || "";
  $("sheet-spinner").hidden = !busy;
  const confirmButton = $("sheet-confirm");
  confirmButton.hidden = !confirm;
  confirmButton.disabled = false;
  confirmButton.textContent = confirm || "";
  confirmButton.onclick = onConfirm ? () => onConfirm(confirmButton) : null;
  $("sheet-cancel").textContent = cancel || "Cancel";
  $("sheet").hidden = false;
  return sheetToken;
}

function hideSheet() {
  sheetToken++;
  $("sheet").hidden = true;
}

// ------------------------------------------------------------------ new session

let harnesses = null;

async function showNew() {
  show("new-view");
  problem("new-problem", "");
  try {
    if (!harnesses) harnesses = (await api("/api/harnesses")).harnesses;
    if (sessions.length === 0 && ended.length === 0) {
      const data = await api("/api/sessions");
      sessions = data.sessions;
      ended = data.ended || [];
    }
  } catch (e) {
    failed("new-problem", e);
  }
  const select = $("new-harness");
  if (select.options.length === 0 && harnesses) {
    for (const id of harnesses) select.append(new Option(AGENT[id] || id, id));
    select.value = readPref("harness") || "claude-code";
  }
  const projects = [...new Set(allRows().map((s) => s.project).filter(Boolean))].sort();
  $("projects").replaceChildren(...projects.map((p) => new Option(p)));
  if (!$("new-project").value) $("new-project").value = readPref("project") || "";
}

async function startSession(event) {
  event.preventDefault();
  const body = {
    harness: $("new-harness").value,
    project: $("new-project").value.trim(),
  };
  const name = $("new-name").value.trim();
  const prompt = $("new-prompt").value.trim();
  if (name) body.name = name;
  if (prompt) body.prompt = prompt;
  $("start-button").disabled = true;
  try {
    const result = await api("/api/spawn", body);
    writePref("harness", body.harness);
    writePref("project", body.project);
    $("new-name").value = "";
    $("new-prompt").value = "";
    // the reply reads "<name> started (...)"; the session takes the form's place in history
    const started = result.text.split(" ")[0];
    replaceView("s=" + encodeURIComponent(started));
  } catch (e) {
    failed("new-problem", e);
  } finally {
    $("start-button").disabled = false;
  }
}

// ------------------------------------------------------------------ small things

function readPref(key) {
  try { return localStorage.getItem("mhm." + key); } catch (e) { return null; }
}

function writePref(key, value) {
  try { localStorage.setItem("mhm." + key, value); } catch (e) { /* private mode */ }
}

function readJson(key) {
  try { return JSON.parse(readPref(key)); } catch (e) { return null; }
}

function writeJson(key, value) {
  writePref(key, JSON.stringify(value));
}

// ------------------------------------------------------------------ start

$("new-button").onclick = () => openView("new");
$("view-button").onclick = toggleControls;
$("back-button").onclick = toList;
$("cancel-new").onclick = toList;
$("close-button").onclick = () => closeFlow(current, $("session-title").textContent, true);
$("sheet-cancel").onclick = hideSheet;
$("sheet").addEventListener("click", (event) => { if (event.target === $("sheet")) hideSheet(); });
$("sort").addEventListener("click", (event) => {
  const button = event.target.closest("button[data-sort]");
  if (!button) return;
  view.sort = button.dataset.sort;
  saveView();
});
$("direction").onclick = () => {
  view.descending = !view.descending;
  saveView();
};
// the keypad stays out of the way until asked for; this phone remembers if it was open
function setKeysOpen(open) {
  $("keys").hidden = !open;
  $("keys-button").classList.toggle("on", open);
  $("keys-button").setAttribute("aria-expanded", String(open));
  writePref("keys", open ? "1" : "0");
}
setKeysOpen(readPref("keys") === "1");
$("keys-button").onclick = () => setKeysOpen($("keys").hidden);
$("keys").addEventListener("click", (event) => {
  const button = event.target.closest("button[data-keys]");
  if (button) pressKeys([button.dataset.keys]);
});
$("compose").addEventListener("submit", sendMessage);
$("message").addEventListener("input", growMessage);
$("new-form").addEventListener("submit", startSession);
window.addEventListener("hashchange", route);
// Turning the phone changes the width: ask for the new size. The keyboard only changes
// the height, and must not shrink the session.
window.addEventListener("resize", () => {
  if (current && !$("session-view").hidden && stream && Math.abs(window.innerWidth - streamWidth) > 20) {
    openStream();
  }
});
// Safari drops the stream while the phone sleeps; pick it up again on return
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && current && !$("session-view").hidden
      && (!stream || stream.readyState === EventSource.CLOSED)) {
    openStream();
  }
});

(async () => {
  if (location.hash.startsWith("#k=")) await login(location.hash.slice(3));
  route();
})();
