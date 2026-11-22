// Just enough of Safari for the phone page's script to load and run under Node, with no
// dependencies: elements that keep their children, text, classes and attributes; a fake
// server behind fetch; storage that can refuse, as in private browsing. Each load() is a
// fresh page.
import { readFileSync } from "node:fs";
import vm from "node:vm";

const APP_JS = readFileSync(new URL("../../main/resources/web/app.js", import.meta.url), "utf8");

// The script's top-level let/const are not properties of its global object; this hands the
// tests what they need to read or set.
const EXPORTS = `
;globalThis.__app = {
  view, STATUS, Locked, MAX_HISTORY_CHARS,
  get sessions() { return sessions; }, set sessions(v) { sessions = v; },
  get ended() { return ended; }, set ended(v) { ended = v; },
  get current() { return current; }, set current(v) { current = v; },
  get renderedList() { return renderedList; }, set renderedList(v) { renderedList = v; },
  get sheetToken() { return sheetToken; },
};`;

export class FakeElement {
  constructor(tag = "div", id = null) {
    this.tagName = tag.toUpperCase();
    this.id = id;
    this.children = [];
    this.parent = null;
    this.ownText = "";
    this.innerHTML = "";
    this.className = "";
    this.attributes = new Map();
    this.dataset = {};
    this.style = {};
    this.hidden = false;
    this.disabled = false;
    this.value = "";
    this.listeners = {};
    this.onclick = null;
    this.scrollTop = 0;
    this.scrollHeight = 0;
    this.clientHeight = 0;
    this.clientWidth = 0;
  }

  get classList() {
    const el = this;
    const names = () => new Set(el.className.split(/\s+/).filter(Boolean));
    return {
      toggle(name, force) {
        const set = names();
        const on = force === undefined ? !set.has(name) : !!force;
        if (on) set.add(name); else set.delete(name);
        el.className = [...set].join(" ");
        return on;
      },
      add(name) { this.toggle(name, true); },
      remove(name) { this.toggle(name, false); },
      contains(name) { return names().has(name); },
    };
  }

  /** A select's options. */
  get options() {
    return this.children.filter((c) => c instanceof FakeElement && c.tagName === "OPTION");
  }

  get textContent() {
    return this.ownText + this.children.map((c) => (typeof c === "string" ? c : c.textContent)).join("");
  }

  set textContent(text) {
    this.ownText = String(text);
    this.children = [];
  }

  append(...nodes) {
    for (const node of nodes) {
      if (node instanceof FakeElement) node.parent = this;
      this.children.push(node);
    }
  }

  replaceChildren(...nodes) {
    this.children = [];
    this.ownText = "";
    this.append(...nodes);
  }

  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  getAttribute(name) { return this.attributes.has(name) ? this.attributes.get(name) : null; }
  addEventListener(type, listener) { (this.listeners[type] ||= []).push(listener); }

  /** "tag", ".class", "tag.class" or "tag[data-x]" */
  matches(selector) {
    const m = /^([a-z]*)(?:\.([\w-]+))?(?:\[data-([\w-]+)\])?$/i.exec(selector);
    if (!m) throw new Error("selector not supported: " + selector);
    const [, tag, cls, data] = m;
    if (tag && this.tagName !== tag.toUpperCase()) return false;
    if (cls && !this.classList.contains(cls)) return false;
    if (data && !(data.replace(/-(\w)/g, (_, c) => c.toUpperCase()) in this.dataset)) return false;
    return true;
  }

  querySelectorAll(selector) {
    const found = [];
    const walk = (el) => {
      for (const child of el.children) {
        if (!(child instanceof FakeElement)) continue;
        if (child.matches(selector)) found.push(child);
        walk(child);
      }
    };
    walk(this);
    return found;
  }

  closest(selector) {
    for (let el = this; el; el = el.parent) if (el.matches(selector)) return el;
    return null;
  }
}

const VIEWS = ["list-view", "session-view", "new-view", "locked-view"];

/**
 * A fresh page. {@code server(path, options)} answers fetch: return {status?, body?}, or
 * throw for a network failure; by default every call succeeds with no sessions.
 */
export function load({ hash = "", storage = new Map(), storageFails = false, server } = {}) {
  const elements = new Map();
  const byId = (id) => {
    if (!elements.has(id)) {
      const el = new FakeElement("div", id);
      if (VIEWS.includes(id)) el.className = "view";
      elements.set(id, el);
    }
    return elements.get(id);
  };
  VIEWS.forEach(byId);

  const calls = [];
  const page = {
    server: server || ((path) => ({ body: path === "/api/sessions" ? { sessions: [], ended: [] } : { ok: true } })),
    calls,
    replaced: [],
    // history steps the page took itself: ["replace", url] and ["back"]
    steps: [],
    streams: [],
  };

  const document = {
    head: new FakeElement("head"),
    visibilityState: "visible",
    getElementById: byId,
    createElement: (tag) => {
      const el = new FakeElement(tag);
      // a canvas measures text as if every character were 7px wide
      if (el.tagName === "CANVAS") el.getContext = () => ({ font: "", measureText: (text) => ({ width: 7 * text.length }) });
      return el;
    },
    querySelectorAll: (selector) => [...elements.values()].filter((el) => el.matches(selector)),
    addEventListener() {},
  };
  const localStorage = {
    getItem(key) {
      if (storageFails) throw new Error("SecurityError");
      return storage.has(key) ? storage.get(key) : null;
    },
    setItem(key, value) {
      if (storageFails) throw new Error("QuotaExceededError");
      storage.set(key, String(value));
    },
  };
  class EventSource {
    static CLOSED = 2;
    constructor(url) { this.url = url; this.readyState = 0; page.streams.push(this); }
    addEventListener() {}
    close() { this.readyState = EventSource.CLOSED; }
  }
  // like a browser's: the hash reads with its "#" (or as "" when empty), set with or without
  let fragment = hash.replace(/^#/, "");
  const location = {
    get hash() { return fragment ? "#" + fragment : ""; },
    set hash(value) { fragment = String(value).replace(/^#/, ""); },
    pathname: "/",
    replace(url) { page.steps.push(["replace", url]); location.hash = url; },
  };
  // new Option(text, value), as a select or datalist holds them
  function Option(text, value) {
    const option = new FakeElement("option");
    option.textContent = text;
    option.value = value === undefined ? text : value;
    return option;
  }

  const context = vm.createContext({
    document,
    window: { addEventListener() {}, innerWidth: 390 },
    localStorage,
    location,
    history: {
      replaceState: (state, title, url) => { page.replaced.push(url); location.hash = ""; },
      back: () => { page.steps.push(["back"]); },
    },
    EventSource,
    Option,
    fetch: async (path, options = {}) => {
      calls.push({ path, method: options.method || "GET", body: options.body ? JSON.parse(options.body) : undefined });
      const answer = await page.server(path, options);
      const status = answer.status || 200;
      return {
        status,
        ok: status >= 200 && status < 300,
        statusText: answer.statusText || "",
        json: async () => {
          if (answer.body === undefined) throw new SyntaxError("no body");
          return answer.body;
        },
      };
    },
    setInterval: () => 1,
    clearInterval() {},
    setTimeout: () => 1,
    clearTimeout() {},
    getComputedStyle: () => ({ paddingLeft: "0", paddingRight: "0", paddingTop: "0", paddingBottom: "0", fontSize: "12px", lineHeight: "15px", fontFamily: "monospace" }),
    console,
  });
  vm.runInContext(APP_JS + EXPORTS, context, { filename: "app.js" });

  page.window = context;
  page.app = context.__app;
  page.$ = byId;
  page.location = location;
  page.storage = storage;
  /** Lets the page's pending promises (fetch answers, awaits) run. */
  page.settle = () => new Promise((resolve) => setImmediate(resolve));
  return page;
}
