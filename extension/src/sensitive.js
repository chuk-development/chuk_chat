// Which form fields never leave the page with their value.
//
// A plain script on purpose: the service worker injects it into a tab before
// snapshot.js (a content script cannot import), and node's test imports it the
// same way. It only reads what an element says about itself.
//
// Passwords, card data and one-time codes are blanked in every snapshot. The
// model learns that the field is filled, never what is in it. Cookies and the
// browser's stored passwords are out of reach anyway: the add-on has no
// `cookies` permission and no command that reads either.

(() => {
  const SECRET_TYPES = new Set(["password"]);
  // https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#autofill
  const SECRET_AUTOCOMPLETE = new Set([
    "current-password", "new-password", "one-time-code",
    "cc-number", "cc-csc", "cc-exp", "cc-exp-month", "cc-exp-year", "cc-name",
  ]);
  // Whole words of a field's name or id ("user_password", "otp-code"), not
  // substrings: "passenger" and "compass" are not secrets.
  // Card and bank fields are named in many ways ("cardnumber", "ccNumber",
  // "cc-num", "security_code", "exp", "expiry_date", "iban_number"). The
  // expiry words are anchored on both sides, so "expand" and "export" pass.
  const SECRET_NAME = new RegExp(
    [
      "(^|[^a-z])(pass|password|passwd|passcode|pwd|pin|cvc|cvv|cvv2|csc|otp|totp|secret|token|iban)([^a-z]|$)",
      "(^|[^a-z])exp(iry|iration)?([^a-z]?(date|month|year|mm|yy|yyyy))?([^a-z]|$)",
      "card.?num",
      "(^|[^a-z])cc.?num",
      "security.?code",
    ].join("|"),
    "i",
  );

  function attr(el, name) {
    if (!el) return "";
    if (typeof el.getAttribute === "function") return String(el.getAttribute(name) ?? "");
    return String(el[name] ?? "");
  }

  /** True when the value of `el` must not be read out. */
  function isSensitiveField(el) {
    if (!el) return false;
    const tag = String(el.tagName ?? "").toLowerCase();
    if (tag !== "input" && tag !== "textarea") return false;
    const type = String(el.type ?? attr(el, "type") ?? "").toLowerCase();
    if (SECRET_TYPES.has(type)) return true;
    if (type === "hidden") return true;
    const tokens = attr(el, "autocomplete").toLowerCase().split(/\s+/);
    if (tokens.some((token) => SECRET_AUTOCOMPLETE.has(token))) return true;
    return SECRET_NAME.test(`${attr(el, "name")} ${attr(el, "id")}`);
  }

  globalThis.agentsSensitive = Object.freeze({ isSensitiveField, HIDDEN: "[hidden]" });
})();
