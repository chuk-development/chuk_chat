// The command vocabulary between the CoWork host and this add-on.
//
// The names are deliberately the ones the agent's browser tools already carry
// (`browser_navigate`, `browser_click`, …) so the host, the wire contract and
// the app keep reading one transcript. A command is data, never code: the list
// below is closed, and nothing here evaluates a string. That is what keeps the
// add-on inside both stores' remote-code rules.

export const COMMANDS = Object.freeze({
  browser_navigate: ["url"],
  browser_navigate_back: [],
  browser_snapshot: [],
  browser_click: ["ref"],
  browser_type: ["ref", "text"],
  browser_press_key: ["key"],
  browser_scroll: [],
  browser_take_screenshot: [],
  browser_tabs: ["action"],
  browser_close: [],
});

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
  return null;
}

export function ok(cmdId, data) {
  return { type: "browser_result", cmd_id: cmdId, ok: true, data: data ?? {} };
}

export function fail(cmdId, error) {
  return { type: "browser_result", cmd_id: cmdId, ok: false, error: String(error) };
}
