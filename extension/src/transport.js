// Two ways to reach the CoWork host, one interface.
//
//   native — chrome.runtime.connectNative to a small local process. Auth is the
//            host manifest's `allowed_origins`, which names this extension id
//            and nothing else; only the local user can write that file. No port,
//            no token, no origin check. Used when the host runs on this machine.
//   relay  — a WebSocket to the CoWork relay, for a host on another machine.
//
// Both carry the same frames: `browser_cmd` in, `browser_result` out, plus a
// `browser_attach` hello so the host knows what this browser can do.

import { api } from "./api.js";

export const NATIVE_HOST = "dev.chuk.cowork";

export class Transport {
  constructor({ onCommand, onStatus }) {
    this.onCommand = onCommand;
    this.onStatus = onStatus ?? (() => {});
    this.kind = null; // "native" | "relay" | null
    this.port = null;
    this.socket = null;
    this.backoffMs = 1000;
  }

  get connected() {
    return this.kind !== null;
  }

  send(frame) {
    if (this.kind === "native") this.port.postMessage(frame);
    else if (this.kind === "relay") this.socket.send(JSON.stringify(frame));
  }

  /** Try the local process first, fall back to the relay if one is configured. */
  async connect(hello) {
    if (await this.connectNative(hello)) return "native";
    const { relayUrl } = await api.storage.local.get("relayUrl");
    if (relayUrl) return (await this.connectRelay(relayUrl, hello)) ? "relay" : null;
    return null;
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
        port.onMessage.addListener(() => done(true));
        port.postMessage(hello);
        setTimeout(() => done(Boolean(api.runtime.lastError) === false), 800);
      });
      if (!alive) return false;
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

  async connectRelay(url, hello) {
    return new Promise((resolve) => {
      let socket;
      try {
        socket = new WebSocket(url);
      } catch {
        resolve(false);
        return;
      }
      const timer = setTimeout(() => {
        try {
          socket.close();
        } catch {
          // already closing
        }
        resolve(false);
      }, 5000);
      socket.onopen = () => {
        clearTimeout(timer);
        this.kind = "relay";
        this.socket = socket;
        socket.send(JSON.stringify(hello));
        this.onStatus({ connected: true, kind: "relay" });
        resolve(true);
      };
      socket.onmessage = (event) => {
        try {
          this.handle(JSON.parse(event.data));
        } catch {
          // A frame we cannot parse is not ours to act on.
        }
      };
      socket.onclose = () => this.dropped();
      socket.onerror = () => {
        clearTimeout(timer);
        resolve(false);
      };
    });
  }

  async handle(frame) {
    if (!frame || frame.type !== "browser_cmd") return;
    const result = await this.onCommand(frame);
    if (result) this.send(result);
  }

  dropped() {
    this.kind = null;
    this.port = null;
    this.socket = null;
    this.onStatus({ connected: false, kind: null });
  }
}
