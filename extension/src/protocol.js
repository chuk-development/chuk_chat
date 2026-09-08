// The command vocabulary between the CoWork host and this add-on.
//
// The names are deliberately the ones the agent's browser tools already carry
// (`browser_navigate`, `browser_click`, …) so the host, the wire contract and
// the app keep reading one transcript.
//
// Two layers, on purpose:
//
//   * The named commands below. They are what a transcript shows, what a tool
//     card renders, and what the host's presence logic reads.
//   * `browser_cdp`, one generic pipe that forwards a DevTools protocol method
//     to the attached tab. OpenAI's extension is built almost entirely this way
//     — `chrome.debugger.sendCommand(target, e.method, e.commandParams)`, with
//     only five CDP names anywhere in its bundle. The point is that a new
//     ability then ships in our Python host, not through a store review.
//
// Neither layer evaluates a string it was sent. A DevTools method name is data
// the browser itself dispatches, the same as any other parameter; `Runtime.
// evaluate` is refused here for exactly that reason, since that one *would* be
// remotely supplied code.

export const COMMANDS = Object.freeze({
  browser_navigate: ["url"],
  browser_navigate_back: [],
  browser_snapshot: [],
  browser_click: [],
  browser_type: ["text"],
  browser_press_key: ["key"],
  browser_scroll: [],
  browser_take_screenshot: [],
  browser_tabs: ["action"],
  browser_close: [],
  browser_cdp: ["method"],
  browser_handoff: [],
  browser_request_credentials: ["fields"],
  browser_report_wall: ["kind"],
});

// `Runtime.evaluate` and friends would let the host ship JavaScript through the
// add-on. That is the one thing both stores actually forbid, so the pipe says
// no rather than relying on the host to behave.
const CDP_REFUSED = Object.freeze([
  "Runtime.evaluate",
  "Runtime.callFunctionOn",
  "Runtime.compileScript",
  "Runtime.runScript",
  "Page.addScriptToEvaluateOnNewDocument",
  "Debugger.setBreakpointByUrl",
]);

export function cdpRefusal(method) {
  if (typeof method !== "string" || !method.includes(".")) {
    return `browser_cdp needs a "Domain.method" name`;
  }
  if (CDP_REFUSED.includes(method)) {
    return `${method} is not available through this add-on: it would run supplied code`;
  }
  return null;
}

// A node can be addressed four ways, like OpenAI's: by the ref a snapshot gave
// it, by a CSS selector, by a viewport point, or by nothing at all when the
// command works on whatever has focus.
export function addressing(args) {
  const given = args && typeof args === "object" ? args : {};
  if (given.ref !== undefined) return { kind: "ref", ref: String(given.ref) };
  if (given.selector !== undefined) return { kind: "selector", selector: String(given.selector) };
  if (Array.isArray(given.point) && given.point.length === 2) {
    return { kind: "point", point: [Number(given.point[0]), Number(given.point[1])] };
  }
  return { kind: "focus" };
}

export function isKnown(op) {
  return Object.prototype.hasOwnProperty.call(COMMANDS, op);
}

/** Returns an error string, or null when `args` satisfies the command. */
export function validate(op, args) {
  if (!isKnown(op)) return `unknown command: ${op}`;
  const required = COMMANDS[op];
  const given = args && typeof args === "object" ? args : {};
  for (const key of required) {
    if (given[key] === undefined || given[key] === null) {
      return `${op} needs "${key}"`;
    }
  }
  if (op === "browser_cdp") return cdpRefusal(given.method);
  if (op === "browser_click" && addressing(given).kind === "focus") {
    return 'browser_click needs "ref", "selector" or "point"';
  }
  return null;
}

export function ok(cmdId, data) {
  return { type: "browser_result", cmd_id: cmdId, ok: true, data: data ?? {} };
}

export function fail(cmdId, error) {
  return { type: "browser_result", cmd_id: cmdId, ok: false, error: String(error) };
}
