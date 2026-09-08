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

console.log(`\n${passed} passed`);
