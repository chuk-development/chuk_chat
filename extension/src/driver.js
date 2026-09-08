// Turning one command into browser work.
//
// Two engines sit behind the same commands:
//
//   "cdp"      — chrome.debugger. Input.dispatch* produces real, trusted input
//                at browser level, exactly like a mouse and a keyboard. Chrome
//                only; the tab shows Chrome's "being debugged" bar while attached.
//   "synthetic" — DOM events from the content script. Firefox has no debugger
//                API, so this is all Firefox can do. Some pages reject it.
//
// Both talk to the same content script for the page snapshot and for finding an
// element by ref, so a transcript reads the same whichever engine ran it.

import { api, hasDebugger, hasTabGroups } from "./api.js";

const PROTOCOL_VERSION = "1.3";
const GROUP_TITLE = "CoWork";

export class Driver {
  constructor() {
    /** The tab this coworker drives. Never a tab the user opened. */
    this.tabId = null;
    this.attached = false;
    this.engine = hasDebugger ? "cdp" : "synthetic";
  }

  get engineName() {
    return this.engine;
  }

  // -- the agent's own tab ----------------------------------------------------

  async ownTab() {
    if (this.tabId !== null) {
      try {
        await api.tabs.get(this.tabId);
        return this.tabId;
      } catch {
        this.tabId = null;
        this.attached = false;
      }
    }
    const tab = await api.tabs.create({ url: "about:blank", active: false });
    this.tabId = tab.id;
    if (hasTabGroups) {
      try {
        const groupId = await api.tabs.group({ tabIds: [tab.id] });
        await api.tabGroups.update(groupId, { title: GROUP_TITLE, color: "purple" });
      } catch {
        // Grouping is cosmetic; never fail a command over it.
      }
    }
    return this.tabId;
  }

  /** Point the driver at a tab the user already has open (his usual case). */
  async adopt(tabId) {
    if (this.tabId === tabId) return tabId;
    await this.detach();
    const tab = await api.tabs.get(tabId);
    this.tabId = tab.id;
    return this.tabId;
  }

  async attach() {
    if (this.engine !== "cdp" || this.attached) return;
    const tabId = await this.ownTab();
    await api.debugger.attach({ tabId }, PROTOCOL_VERSION);
    this.attached = true;
    await this.send("Page.enable");
    await this.send("Runtime.enable");
  }

  async detach() {
    if (!this.attached) return;
    try {
      await api.debugger.detach({ tabId: this.tabId });
    } catch {
      // Already gone.
    }
    this.attached = false;
  }

  send(method, params = {}) {
    return api.debugger.sendCommand({ tabId: this.tabId }, method, params);
  }

  // -- talking to the page ----------------------------------------------------

  async ask(op, extra = {}) {
    const tabId = await this.ownTab();
    const reply = await api.tabs.sendMessage(tabId, { channel: "cowork", op, ...extra });
    if (!reply) throw new Error(`no answer from the page for "${op}"`);
    if (!reply.ok) throw new Error(reply.error);
    return reply.data;
  }

  async settle(timeoutMs = 15000) {
    // Wait for the tab to stop loading. Cheap poll; a Page.loadEventFired race
    // would need an attached session we may not have in synthetic mode.
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const tab = await api.tabs.get(this.tabId);
      if (tab.status === "complete") return;
      if (Date.now() > deadline) return;
      await new Promise((r) => setTimeout(r, 150));
    }
  }

  // -- input ------------------------------------------------------------------

  async clickAt(x, y) {
    if (this.engine === "cdp") {
      await this.attach();
      const base = { x: Math.round(x), y: Math.round(y), button: "left", clickCount: 1 };
      await this.send("Input.dispatchMouseEvent", { type: "mousePressed", ...base });
      await this.send("Input.dispatchMouseEvent", { type: "mouseReleased", ...base });
      return;
    }
    await api.scripting.executeScript({
      target: { tabId: this.tabId },
      args: [x, y],
      func: (px, py) => {
        const el = document.elementFromPoint(px, py);
        if (!el) throw new Error("nothing at that point");
        el.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, clientX: px, clientY: py }));
      },
    });
  }

  async typeText(text) {
    if (this.engine === "cdp") {
      await this.attach();
      await this.send("Input.insertText", { text });
      return;
    }
    await api.scripting.executeScript({
      target: { tabId: this.tabId },
      args: [text],
      func: (value) => {
        const el = document.activeElement;
        if (!el) throw new Error("nothing focused");
        if ("value" in el) {
          const setter = Object.getOwnPropertyDescriptor(el.constructor.prototype, "value")?.set;
          if (setter) setter.call(el, value);
          else el.value = value;
        } else {
          el.textContent = value;
        }
        el.dispatchEvent(new Event("input", { bubbles: true }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
      },
    });
  }

  async pressKey(key) {
    if (this.engine === "cdp") {
      await this.attach();
      const params = { key, code: key, windowsVirtualKeyCode: keyCode(key), text: printable(key) };
      await this.send("Input.dispatchKeyEvent", { type: "keyDown", ...params });
      await this.send("Input.dispatchKeyEvent", { type: "keyUp", ...params });
      return;
    }
    await api.scripting.executeScript({
      target: { tabId: this.tabId },
      args: [key],
      func: (k) => {
        const el = document.activeElement || document.body;
        for (const type of ["keydown", "keypress", "keyup"]) {
          el.dispatchEvent(new KeyboardEvent(type, { key: k, bubbles: true, cancelable: true }));
        }
      },
    });
  }

  async screenshot() {
    if (this.engine === "cdp") {
      await this.attach();
      const shot = await this.send("Page.captureScreenshot", { format: "png" });
      return shot.data;
    }
    const dataUrl = await api.tabs.captureVisibleTab({ format: "png" });
    return dataUrl.replace(/^data:image\/png;base64,/, "");
  }
}

function printable(key) {
  return key.length === 1 ? key : "";
}

function keyCode(key) {
  const named = { Enter: 13, Tab: 9, Escape: 27, Backspace: 8, ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39 };
  if (named[key]) return named[key];
  return key.length === 1 ? key.toUpperCase().charCodeAt(0) : 0;
}
