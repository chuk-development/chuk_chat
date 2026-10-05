// The one way to reach the Agents host: Chrome's native messaging.
//
// `chrome.runtime.connectNative` starts a small local process
// (tools/agents-browser-bridge) that passes frames to the host over a unix
// socket. The access rule is the host manifest's `allowed_origins`, which
// names this extension id and nothing else; only the local user can write that
// file. No port is open anywhere, so no web page and nothing on the network can
// reach this add-on's commands.
//
// (An earlier build also had a "relay" WebSocket to a configurable address.
// It took commands from whatever answered at that address, with no pairing at
// all, so it is gone.)
//
// Frames: `browser_cmd` in, `browser_result` out, a `browser_attach` hello so
// the host knows what this browser can do, `browser_stop` / `browser_resume`
// both ways, `browser_holder` in (the coworker's name for the strip),
// `page_message` out (the panel) with `page_message_ack` / `page_reply` in. Commands run one after another, never interleaved: two commands
// on one tab at once would race on the same page.

import { api } from "./api.js";
import { fail } from "./protocol.js";

export const NATIVE_HOST = "dev.chuk.cowork";

// Host frames that belong between two commands. `browser_holder` names the
// coworker of the NEXT command; run before the queue drains, it would put the
// new name on the old coworker's tab for a moment.
const IN_ORDER = new Set(["browser_holder"]);

// A command that never settles (a page that never answers, a debugger call
// that hangs) must not hold the queue for good. The host gives up on a command
// after 45 s; the add-on answers a little before that, with an error.
export const COMMAND_TIMEOUT_MS = 40000;
export const TIMEOUT_ERROR = "the browser did not finish this step in time. Take a snapshot and try again.";

function withTimeout(work, ms, onTimeout) {
  let timer = null;
  const late = new Promise((resolve) => {
    timer = setTimeout(() => resolve(onTimeout()), ms);
  });
  return Promise.race([Promise.resolve(work), late]).finally(() => clearTimeout(timer));
}

export class Transport {
  constructor({ onCommand, onFrame, onStatus, commandTimeoutMs = COMMAND_TIMEOUT_MS }) {
    this.onCommand = onCommand;
    this.commandTimeoutMs = commandTimeoutMs;
    this.onFrame = onFrame ?? (() => {});
    this.onStatus = onStatus ?? (() => {});
    this.kind = null; // "native" | null
    this.port = null;
    this.queue = Promise.resolve();
  }

  get connected() {
    return this.kind !== null;
  }

  send(frame) {
    if (this.kind !== "native") return false;
    try {
      this.port.postMessage(frame);
      return true;
    } catch {
      return false;
    }
  }

  async connect(hello) {
    return (await this.connectNative(hello)) ? "native" : null;
  }

  async connectNative(hello) {
    if (typeof api.runtime.connectNative !== "function") return false;
    try {
      const port = api.runtime.connectNative(NATIVE_HOST);
      const alive = await new Promise((resolve) => {
        let settled = false;
        const done = (value) => {
          if (settled) return;
          settled = true;
          resolve(value);
        };
        port.onDisconnect.addListener(() => done(false));
        // The bridge answers `bridge_ready` when the host is there, and
        // `browser_attach_error` (then exits) when it is not.
        port.onMessage.addListener((frame) => done(Boolean(frame) && frame.type !== "browser_attach_error"));
        port.postMessage(hello);
        setTimeout(() => done(false), 1500);
      });
      if (!alive) {
        try {
          port.disconnect();
        } catch {
          // already gone
        }
        return false;
      }
      this.kind = "native";
      this.port = port;
      port.onMessage.addListener((frame) => this.handle(frame));
      port.onDisconnect.addListener(() => this.dropped());
      this.onStatus({ connected: true, kind: "native" });
      return true;
    } catch {
      return false;
    }
  }

  handle(frame) {
    if (!frame || typeof frame !== "object") return;
    if (IN_ORDER.has(frame.type)) {
      // Says something about the next command: wait for the ones before it.
      this.queue = this.queue.then(() => this.onFrame(frame)).catch(() => {});
      return;
    }
    if (frame.type !== "browser_cmd") {
      this.onFrame(frame);
      return;
    }
    this.queue = this.queue
      .then(async () => {
        const result = await withTimeout(
          (async () => this.onCommand(frame))(),
          this.commandTimeoutMs,
          () => fail(frame.cmd_id, TIMEOUT_ERROR),
        );
        if (result) this.send(result);
      })
      .catch(() => {});
  }

  /**
   * The user's Stop: start a fresh queue, so nothing waits behind a command
   * that hangs. Commands already queued still run, and the Stop gate refuses
   * each of them.
   */
  clear() {
    this.queue = Promise.resolve();
  }

  dropped() {
    this.kind = null;
    this.port = null;
    this.onStatus({ connected: false, kind: null });
  }
}
