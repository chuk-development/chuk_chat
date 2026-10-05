// Run: node extension/test/strip_test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  FALLBACK_NAME,
  MAX_NAME,
  coworkerName,
  pageMessageFrame,
  panelControlText,
  panelNote,
  stripLabel,
} from "../src/strip.js";

let passed = 0;
async function check(what, fn) {
  await fn();
  passed += 1;
  console.log(`ok  ${what}`);
}

// -- the strip names the coworker ------------------------------------------------

await check("the strip says who is acting", () => {
  assert.equal(stripLabel("active", "Ada"), "Ada is using this tab");
  assert.equal(stripLabel("handoff", "Ada"), "Ada needs you here");
  assert.equal(stripLabel("deliverable", "Ada"), "Ada has something for you");
  assert.equal(stripLabel("stopped", "Ada"), "Ada stopped");
});

await check("without a name the strip falls back to Agents", () => {
  assert.equal(stripLabel("active", ""), `${FALLBACK_NAME} is using this tab`);
  assert.equal(stripLabel("active", undefined), "Agents is using this tab");
  assert.equal(stripLabel("no-such-state", "Ada"), "Ada is using this tab");
});

await check("a name is one short line", () => {
  assert.equal(coworkerName("  Crypto\n\tDesk\u0007 "), "Crypto Desk");
  assert.equal(coworkerName("a\u2028b"), "a b");
  const long = coworkerName("x".repeat(100));
  assert.equal(long.length, MAX_NAME);
  assert.ok(long.endsWith("\u2026"));
  assert.equal(coworkerName(42), "");
});

await check("the panel names who drives", () => {
  assert.equal(panelControlText({ coworker: "Ada" }), "Ada is using a tab in this browser.");
  assert.equal(panelControlText({}), "Agents is using a tab in this browser.");
  assert.match(panelControlText({ stopped: true, coworker: "Ada" }), /^Stopped/);
});

await check("the strip stays in a closed shadow root and has no glow", () => {
  const indicator = readFileSync(new URL("../src/indicator.js", import.meta.url), "utf8");
  assert.match(indicator, /attachShadow\(\{ mode: "closed" \}\)/);
  assert.doesNotMatch(indicator, /box-shadow|text-shadow|filter:\s*drop-shadow/);
  // The name is set as text, never as markup.
  assert.match(indicator, /label\.textContent = label/);
});

// -- the panel's message -------------------------------------------------------------

await check("the panel sends the user's words and the page, cut to size", () => {
  const frame = pageMessageFrame("  what is this?  ", {
    url: "https://example.org/a",
    title: "A page",
    selection: "picked",
    text: "y".repeat(50000),
    tabId: 7,
  });
  assert.equal(frame.type, "page_message");
  assert.equal(frame.text, "what is this?");
  assert.equal(frame.context.url, "https://example.org/a");
  assert.equal(frame.context.text.length, 20000);
  assert.equal(frame.context.tabId, undefined);
  assert.equal(pageMessageFrame("   ", {}), null);
  assert.equal(pageMessageFrame("hi", null).context.url, "");
});

await check("the host's ack and answer read as panel lines", () => {
  assert.equal(
    panelNote({ type: "page_message_ack", ok: true, coworker: "Ada" }),
    "Sent to Ada. The answer comes here and in the Agents app.",
  );
  assert.match(panelNote({ type: "page_message_ack", ok: false, error: "not ready" }), /^Not sent: not ready/);
  assert.equal(panelNote({ type: "page_reply", coworker: "Ada", text: "It is a shop." }), "Ada: It is a shop.");
  assert.equal(panelNote({ type: "browser_resume" }), null);
  assert.equal(panelNote(null), null);
});

await check("only the add-on's own pages may send, and only a page_message", () => {
  const background = readFileSync(new URL("../src/background.js", import.meta.url), "utf8");
  const send = background.slice(background.indexOf('msg.op === "send"'));
  assert.match(send.slice(0, 600), /if \(sender\.tab\) return undefined;/);
  assert.match(send.slice(0, 600), /pageMessageFrame/);
});

// -- the coworker's name arrives in order with the commands --------------------------

await check("browser_holder waits for the commands before it", async () => {
  globalThis.chrome = { runtime: {} };
  const { Transport } = await import("../src/transport.js");
  const seen = [];
  let release;
  const slow = new Promise((resolve) => {
    release = resolve;
  });
  const transport = new Transport({
    onCommand: async (frame) => {
      if (frame.cmd_id === "old") await slow;
      seen.push(`cmd:${frame.cmd_id}`);
      return null;
    },
    onFrame: (frame) => seen.push(`${frame.type}:${frame.name ?? ""}`),
  });
  transport.handle({ type: "browser_cmd", cmd_id: "old", op: "browser_close" });
  transport.handle({ type: "browser_holder", name: "Ada" });
  transport.handle({ type: "browser_cmd", cmd_id: "new", op: "browser_snapshot" });
  transport.handle({ type: "page_reply", text: "hi" }); // not about a command: at once
  assert.deepEqual(seen, ["page_reply:"]);
  release();
  await transport.queue;
  assert.deepEqual(seen, ["page_reply:", "cmd:old", "browser_holder:Ada", "cmd:new"]);
});

await check("a command that never settles is answered with an error and frees the queue", async () => {
  const { Transport, TIMEOUT_ERROR } = await import("../src/transport.js");
  const sent = [];
  const transport = new Transport({
    commandTimeoutMs: 30,
    onCommand: (frame) =>
      frame.cmd_id === "hang" ? new Promise(() => {}) : { type: "browser_result", cmd_id: frame.cmd_id, ok: true },
  });
  transport.kind = "native";
  transport.port = { postMessage: (frame) => sent.push(frame) };
  transport.handle({ type: "browser_cmd", cmd_id: "hang", op: "browser_snapshot" });
  transport.handle({ type: "browser_cmd", cmd_id: "next", op: "browser_snapshot" });
  await transport.queue;
  assert.deepEqual(sent.map((f) => [f.cmd_id, f.ok]), [["hang", false], ["next", true]]);
  assert.equal(sent[0].error, TIMEOUT_ERROR);
});

await check("Stop clears the queue, so nothing waits behind a hung command", async () => {
  const { Transport } = await import("../src/transport.js");
  const sent = [];
  const transport = new Transport({
    commandTimeoutMs: 300,
    onCommand: (frame) =>
      frame.cmd_id === "hang" ? new Promise(() => {}) : { type: "browser_result", cmd_id: frame.cmd_id, ok: true },
  });
  transport.kind = "native";
  transport.port = { postMessage: (frame) => sent.push(frame) };
  transport.handle({ type: "browser_cmd", cmd_id: "hang", op: "browser_click" });
  transport.clear();
  transport.handle({ type: "browser_cmd", cmd_id: "after", op: "browser_snapshot" });
  await transport.queue;
  assert.deepEqual(sent.map((f) => f.cmd_id), ["after"]);
  const background = readFileSync(new URL("../src/background.js", import.meta.url), "utf8");
  assert.match(background, /gate\.stop\(reason\);\s*\/\/[^\n]*\n\s*transport\.clear\(\);/);
});

console.log(`\n${passed} passed`);
