// Run: node extension/test/stop_and_secrets_test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { StopGate, STOPPED_MESSAGE } from "../src/gate.js";
await import("../src/sensitive.js"); // a plain script: it sets globalThis.agentsSensitive

let passed = 0;
function check(what, fn) {
  fn();
  passed += 1;
  console.log(`ok  ${what}`);
}

// -- Stop -----------------------------------------------------------------------

check("a fresh gate lets commands through", () => {
  assert.equal(new StopGate().refusal(), null);
});

check("after Stop every command is refused with the same words", () => {
  const gate = new StopGate();
  assert.equal(gate.stop("page"), true);
  assert.equal(gate.refusal(), STOPPED_MESSAGE);
  assert.equal(gate.refusal(), STOPPED_MESSAGE);
  assert.match(STOPPED_MESSAGE, /Do not use the browser again/);
});

check("a second Stop changes nothing, so the host hears it once", () => {
  const gate = new StopGate();
  gate.stop("page");
  assert.equal(gate.stop("panel"), false);
  assert.equal(gate.reason, "page");
});

check("Allow again lifts it, once", () => {
  const gate = new StopGate();
  gate.stop("debugger_bar");
  assert.equal(gate.resume(), true);
  assert.equal(gate.refusal(), null);
  assert.equal(gate.resume(), false);
});

// -- what never leaves the page --------------------------------------------------

const { isSensitiveField, HIDDEN } = globalThis.agentsSensitive;
const input = (props, attrs = {}) => ({
  tagName: "INPUT",
  ...props,
  getAttribute: (name) => attrs[name] ?? null,
});

check("password fields are blanked", () => {
  assert.equal(isSensitiveField(input({ type: "password" })), true);
  assert.equal(HIDDEN, "[hidden]");
});

check("card data and one-time codes are blanked by their autocomplete", () => {
  for (const token of ["cc-number", "cc-csc", "one-time-code", "current-password", "section-pay cc-exp"]) {
    assert.equal(isSensitiveField(input({ type: "text" }, { autocomplete: token })), true, token);
  }
});

check("a field named like a secret is blanked, a passenger is not", () => {
  assert.equal(isSensitiveField(input({ type: "text" }, { name: "user_password" })), true);
  assert.equal(isSensitiveField(input({ type: "text" }, { id: "otp-code" })), true);
  assert.equal(isSensitiveField(input({ type: "tel" }, { name: "pin" })), true);
  assert.equal(isSensitiveField(input({ type: "text" }, { name: "passenger_name" })), false);
  assert.equal(isSensitiveField(input({ type: "text" }, { name: "compass" })), false);
});

for (const name of [
  "cardnumber", "cardNumber", "card_number", "ccnumber", "ccNumber", "cc-num", "billing_cc_number",
  "securitycode", "security_code", "securityCode", "cvv2",
  "exp", "expiry", "expiration", "exp_month", "exp-year", "expdate", "expiryDate", "card_expiry", "exp_mm",
  "iban", "iban_number", "IBAN",
]) {
  check(`a card or bank field named "${name}" is blanked`, () => {
    assert.equal(isSensitiveField(input({ type: "text" }, { name })), true, name);
  });
}

check("words that only look like card fields keep their value", () => {
  for (const name of ["expand", "export", "experience", "expires_in_days", "express_shipping", "Libanon", "accent"]) {
    assert.equal(isSensitiveField(input({ type: "text" }, { name })), false, name);
  }
});

check("ordinary fields keep their value, and only inputs are judged", () => {
  assert.equal(isSensitiveField(input({ type: "email" }, { name: "email" })), false);
  assert.equal(isSensitiveField(input({ type: "search" }, { name: "q" })), false);
  assert.equal(isSensitiveField({ tagName: "BUTTON", getAttribute: () => null }), false);
  assert.equal(isSensitiveField(null), false);
});

// -- what the add-on may and may not do -------------------------------------------

const chrome = JSON.parse(readFileSync(new URL("../manifest.chrome.json", import.meta.url)));
const firefox = JSON.parse(readFileSync(new URL("../manifest.firefox.json", import.meta.url)));

check("no permission that could read cookies or saved passwords", () => {
  for (const manifest of [chrome, firefox]) {
    for (const forbidden of ["cookies", "webRequest", "webRequestBlocking", "privacy", "history"]) {
      assert.equal(manifest.permissions.includes(forbidden), false, forbidden);
    }
  }
});

check("no page can load the add-on's scripts and no socket is opened to the network", () => {
  for (const manifest of [chrome, firefox]) {
    assert.equal(manifest.web_accessible_resources, undefined);
    assert.doesNotMatch(manifest.content_security_policy.extension_pages, /connect-src|wss:|https:\/\/\*/);
    assert.equal(manifest.externally_connectable, undefined);
  }
});

check("the Chrome build pins its id, so pairing needs no copied id", () => {
  assert.equal(typeof chrome.key, "string");
  assert.ok(chrome.key.length > 300);
  const installer = readFileSync(
    new URL("../../tools/agents-browser-bridge/install_host_manifest.py", import.meta.url),
    "utf8",
  );
  assert.match(installer, /DEV_CHROME_ID = "[a-p]{32}"/);
});

check("the options page shows the installer the way the installer takes it", () => {
  const options = readFileSync(new URL("../src/options.js", import.meta.url), "utf8");
  const installer = readFileSync(
    new URL("../../tools/agents-browser-bridge/install_host_manifest.py", import.meta.url),
    "utf8",
  );
  const pinned = installer.match(/DEV_CHROME_ID = "([a-p]{32})"/)[1];
  assert.match(options, new RegExp(`PINNED_CHROME_ID = "${pinned}"`));
  assert.match(options, /id !== PINNED_CHROME_ID \? ` --chrome-id/);
});

check("no private key is in the add-on tree, and the ignore rule keeps it out", () => {
  const ignore = readFileSync(new URL("../.gitignore", import.meta.url), "utf8");
  assert.match(ignore, /^\*\.pem$/m);
});

check("the only way out is native messaging", () => {
  const transport = readFileSync(new URL("../src/transport.js", import.meta.url), "utf8");
  assert.doesNotMatch(transport, /new WebSocket/);
  assert.match(transport, /connectNative/);
});

console.log(`\n${passed} passed`);
