// Words for the strip on the page and for the panel. Pure functions, no
// browser API, so the node tests can check them.
//
// The host sends `browser_holder` with the coworker's name when a coworker
// takes the browser. The strip then says "Ada is using this tab" instead of
// "Agents is using this tab". Without a name it falls back to "Agents".

export const MAX_NAME = 40;
export const FALLBACK_NAME = "Agents";

/** One line, no control characters, at most MAX_NAME characters. */
export function coworkerName(raw) {
  if (typeof raw !== "string") return "";
  // eslint-disable-next-line no-control-regex
  const text = raw.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, " ").replace(/\s+/g, " ").trim();
  if (text.length <= MAX_NAME) return text;
  return `${text.slice(0, MAX_NAME - 1).trimEnd()}…`;
}

const WORDS = Object.freeze({
  active: "is using this tab",
  deliverable: "has something for you",
  handoff: "needs you here",
  stopped: "stopped",
});

/** The strip's text for a lease state and a coworker name. */
export function stripLabel(state, name) {
  const who = coworkerName(name) || FALLBACK_NAME;
  return `${who} ${WORDS[state] ?? WORDS.active}`;
}

/** The panel's line about who drives the browser. */
export function panelControlText({ stopped, coworker } = {}) {
  if (stopped) return "Stopped. Agents cannot use this browser.";
  const who = coworkerName(coworker) || FALLBACK_NAME;
  return `${who} is using a tab in this browser.`;
}

/**
 * What the panel shows for a frame the host sent about a panel message, or
 * null when the frame is not one of those.
 *   page_message_ack  the host took the message (or says why not)
 *   page_reply        the coworker's answer
 */
export function panelNote(frame) {
  if (!frame || typeof frame !== "object") return null;
  const who = coworkerName(frame.coworker) || FALLBACK_NAME;
  if (frame.type === "page_message_ack") {
    if (frame.ok === true) return `Sent to ${who}. The answer comes here and in the Agents app.`;
    const why = typeof frame.error === "string" && frame.error ? frame.error : "the host did not take it.";
    return `Not sent: ${why}`;
  }
  if (frame.type === "page_reply") {
    return typeof frame.text === "string" && frame.text ? `${who}: ${frame.text}` : null;
  }
  return null;
}

/** The longest page text the panel sends with a message. The host cuts again. */
export const MAX_CONTEXT_TEXT = 20000;

/**
 * The one frame the panel may send: the user's words and the page they are
 * about. Anything else from the panel is refused. Returns null for an empty
 * message.
 */
export function pageMessageFrame(text, context) {
  const words = typeof text === "string" ? text.trim() : "";
  if (!words) return null;
  const given = context && typeof context === "object" ? context : {};
  const str = (value, limit) => (typeof value === "string" ? value.slice(0, limit) : "");
  return {
    type: "page_message",
    text: words.slice(0, 8000),
    context: {
      url: str(given.url, 2000),
      title: str(given.title, 500),
      selection: str(given.selection, 4000),
      text: str(given.text, MAX_CONTEXT_TEXT),
    },
  };
}
