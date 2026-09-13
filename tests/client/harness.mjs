// Runs the real phone client against a stub DOM, so its logic is exercised
// without Safari. Every bug the phone has shown -- an invisible Start button, a
// theme that never arrived, a channel that opened early -- lived in a file that
// nothing executed. This executes it.
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "../..");

function element(id = "", tag = "div") {
  const el = {
    id, tagName: tag, children: [], dataset: {}, style: new Map(),
    className: "", textContent: "", innerHTML: "", hidden: false,
    listeners: {},
    appendChild(c) { this.children.push(c); return c; },
    addEventListener(k, fn) { (this.listeners[k] ||= []).push(fn); },
    removeEventListener() {},
    dispatch(k, ev) { (this.listeners[k] || []).forEach((f) => f(ev)); },
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 390, height: 700,
                                    right: 390, bottom: 700 }),
    setPointerCapture() {}, focus() {}, click() {},
    attrs: {},
    setAttribute(k, v) { this.attrs[k] = String(v);
                         if (k.startsWith("data-")) this.dataset[k.slice(5)] = String(v); },
    removeAttribute(k) { delete this.attrs[k];
                         if (k.startsWith("data-")) delete this.dataset[k.slice(5)]; },
    getAttribute(k) { return this.attrs[k] ?? null; },
    querySelectorAll: () => [],
  };
  el.style.setProperty = (k, v) => el.style.set(k, v);
  el.style.removeProperty = (k) => el.style.delete(k);
  Object.defineProperty(el, "firstElementChild",
                        { get: () => el.children[0] || null });
  return el;
}

export function load(ids) {
  const nodes = Object.fromEntries(ids.map((i) => [i, element(i)]));
  const body = element("body");
  const store = new Map();
  const sent = [];
  const errors = [];
  const doc = {
    body,
    documentElement: element("html"),
    getElementById: (i) => nodes[i] || null,
    createElement: (t) => element("", t),
    addEventListener: () => {},
  };
  const win = {
    document: doc,
    location: { host: "phice.vercel.app", search: "", pathname: "/app",
                protocol: "https:" },
    localStorage: {
      getItem: (k) => (store.has(k) ? store.get(k) : null),
      setItem: (k, v) => store.set(k, String(v)),
      removeItem: (k) => store.delete(k),
    },
    navigator: { vibrate: undefined },
    performance: { now: () => 0 },
    addEventListener: (k, fn) => body.addEventListener(k, fn),
    setInterval: () => 1, clearInterval: () => {}, setTimeout: () => 1,
    fetch: async () => { throw new Error("no network in the harness"); },
    console: { warn: (...a) => errors.push(a.join(" ")), log: () => {},
               error: (...a) => errors.push(a.join(" ")) },
    RTCPeerConnection: class { addEventListener() {} },
    WebSocket: class { addEventListener() {} },
  };
  win.window = win;
  const ctx = vm.createContext(win);
  const src = readFileSync(resolve(root, "web/app/app.js"), "utf8");
  vm.runInContext(src, ctx, { filename: "app.js" });
  return { win, doc, nodes, body, sent, errors, store };
}
