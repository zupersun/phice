// Drives the client through the sequence a real phone goes through, and asserts
// the things whose absence has produced a black screen.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { load } from "./harness.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

const IDS = ["pad", "code", "theme", "why", "haptic", "btn-pair", "btn-start",
             "btn-retry"];
const LAYOUT = {
  t: "layout", version: 1,
  buttons: [
    { id: "left", role: "left", x: 3, y: 2, w: 42, h: 62, label: "" },
    { id: "scroll", role: "scroll", x: 46, y: 2, w: 8, h: 62, label: "" },
    { id: "right", role: "right", x: 55, y: 2, w: 42, h: 62, label: "" },
    { id: "power", role: "power", x: 42, y: 68, w: 16, h: 7, label: "" },
  ],
};

function connect(app) {
  // One control channel and one lossy channel, as the Mac creates them.
  const made = (label) => {
    const ch = {
      label, readyState: "open", sentText: [],
      send(t) { ch.sentText.push(t); },
      close() { ch.readyState = "closed"; },
      listeners: {},
      addEventListener(k, fn) { (ch.listeners[k] ||= []).push(fn); },
      deliver(obj) { (ch.listeners.message || [])
        .forEach((f) => f({ data: JSON.stringify(obj) })); },
    };
    return ch;
  };
  return { ctl: made("phice-ctl"), data: made("phice") };
}

const app = load(IDS);
const failures = [];
const check = (what, fn) => {
  try { fn(); console.log(`  ok    ${what}`); }
  catch (e) { failures.push(what); console.log(`  FAIL  ${what}: ${e.message}`); }
};

console.log("client smoke:");

check("the script loads without throwing", () => {
  assert.equal(app.errors.length, 0, app.errors.join("; "));
});

// The client hides wireChannel inside its IIFE, so reach it the way the page
// does: through the datachannel handler the RTCPeerConnection was given.
const api = app.win.__phice;

check("the client exposes a seam the harness can drive", () => {
  assert.ok(api, "window.__phice missing");
});

check("a layout message puts buttons on the pad", () => {
  api.handleMessage(JSON.stringify(LAYOUT));
  const pad = app.nodes.pad;
  assert.equal(pad.children.length, 4, `pad has ${pad.children.length} children`);
  assert.equal(api.state.buttons.size, 4);
});

check("every button gets a role class and a position", () => {
  const first = app.nodes.pad.children[0];
  assert.match(first.className, /\bbtn\b/);
  assert.match(first.className, /role-left/);
  for (const k of ["left", "top", "width", "height"]) {
    assert.ok(first.style[k], `button has no ${k}`);
  }
});

check("a theme message is applied to the style element", () => {
  api.handleMessage(JSON.stringify({ t: "theme", css: "body{background:#123}" }));
  assert.equal(app.nodes.theme.textContent, "body{background:#123}");
});

check("a state message drives data-state, not the screen flow", () => {
  api.handleMessage(JSON.stringify({ t: "state", phase: "on",
                                     ui: { appearance: "dark", recenter_ms: 650 } }));
  assert.equal(app.doc.body.dataset.state, "on");
  assert.notEqual(app.doc.body.dataset.screen, "on",
                  "the engine phase must not clobber the pairing flow");
});

check("an unknown message is ignored rather than throwing", () => {
  api.handleMessage(JSON.stringify({ t: "something-new" }));
  api.handleMessage("not json at all");
});

check("index.html provides every element the script looks up", () => {
  for (const id of IDS) assert.ok(app.nodes[id], `missing #${id}`);
});

check("the code box accepts only letters and digits", () => {
  const code = app.nodes.code;
  code.value = "ab-3 x!9z";
  code.dispatch("input", {});
  assert.equal(code.value, "AB3X9Z", `got ${code.value}`);
  code.value = "ABCDEFGHIJ";
  code.dispatch("input", {});
  assert.equal(code.value.length, 6, "six characters, no more");
});

check("the page carries a floor under the design", () => {
  const html = readFileSync(resolve(ROOT, "web/app/index.html"), "utf8");
  assert.ok(html.includes('id="fallback"'), "no fallback stylesheet");
  assert.ok(html.indexOf('id="fallback"') < html.indexOf('id="theme"'),
            "the fallback must come first, so the Mac's theme still wins");
  assert.match(html, /\.btn\{[^}]*background:/,
               "the fallback must give buttons a background, or they are invisible");
});

if (failures.length) { console.error(`\n${failures.length} failed`); process.exit(1); }
console.log("all good");
