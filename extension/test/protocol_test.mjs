// Run: node extension/test/protocol_test.mjs
import assert from "node:assert/strict";
import { COMMANDS, isKnown, validate, ok, fail } from "../src/protocol.js";

let passed = 0;
function check(what, fn) {
  fn();
  passed += 1;
  console.log(`ok  ${what}`);
}

check("the vocabulary is closed and frozen", () => {
  assert.equal(Object.isFrozen(COMMANDS), true);
  assert.equal(isKnown("browser_navigate"), true);
  assert.equal(isKnown("eval"), false);
  assert.equal(isKnown("constructor"), false, "a prototype key must not pass as a command");
});

check("a missing argument is named, not swallowed", () => {
  assert.equal(validate("browser_navigate", {}), 'browser_navigate needs "url"');
  assert.equal(validate("browser_type", { ref: "e1" }), 'browser_type needs "text"');
  assert.equal(validate("browser_click", { ref: "e1" }), null);
});

check("an unknown command never reaches a driver", () => {
  assert.equal(validate("browser_run_code", { js: "1" }), "unknown command: browser_run_code");
});

check("commands without arguments validate on an empty object", () => {
  assert.equal(validate("browser_snapshot", {}), null);
  assert.equal(validate("browser_snapshot", undefined), null);
});

check("results carry the command id both ways", () => {
  assert.deepEqual(ok("c1", { a: 1 }), { type: "browser_result", cmd_id: "c1", ok: true, data: { a: 1 } });
  assert.deepEqual(fail("c2", new Error("nope")), {
    type: "browser_result", cmd_id: "c2", ok: false, error: "Error: nope",
  });
});


// -- what the OpenAI extension taught us -------------------------------------

const { cdpRefusal, addressing } = await import("../src/protocol.js");
const { Leases, ORIGIN, STATE } = await import("../src/leases.js");

check("the generic CDP pipe accepts a method name as data", () => {
  assert.equal(validate("browser_cdp", { method: "Input.dispatchMouseEvent" }), null);
  assert.equal(validate("browser_cdp", {}), 'browser_cdp needs "method"');
  assert.equal(cdpRefusal("Page"), 'browser_cdp needs a "Domain.method" name');
});

check("the pipe refuses the methods that would run supplied code", () => {
  assert.match(validate("browser_cdp", { method: "Runtime.evaluate" }), /would run supplied code/);
  assert.match(cdpRefusal("Page.addScriptToEvaluateOnNewDocument"), /supplied code/);
  assert.equal(cdpRefusal("DOM.getDocument"), null);
});

check("a node is addressable four ways", () => {
  assert.deepEqual(addressing({ ref: "e7" }), { kind: "ref", ref: "e7" });
  assert.deepEqual(addressing({ selector: "#go" }), { kind: "selector", selector: "#go" });
  assert.deepEqual(addressing({ point: [10, 20] }), { kind: "point", point: [10, 20] });
  assert.deepEqual(addressing({}), { kind: "focus" });
});

check("a click must say what it clicks, typing may use focus", () => {
  assert.match(validate("browser_click", {}), /needs "ref", "selector" or "point"/);
  assert.equal(validate("browser_click", { point: [4, 5] }), null);
  assert.equal(validate("browser_type", { text: "hi" }), null);
});

check("a lease records where a tab came from and what it is doing", () => {
  const leases = new Leases();
  assert.equal(leases.held(7), false);
  leases.grant(7, ORIGIN.USER);
  assert.equal(leases.get(7).origin, "user");
  assert.equal(leases.get(7).state, STATE.ACTIVE);
  leases.handoff(7);
  assert.equal(leases.get(7).state, "handoff");
  assert.deepEqual(leases.list().map((l) => l.tabId), [7]);
  leases.release(7);
  assert.equal(leases.held(7), false);
});

console.log(`\n${passed} passed`);
