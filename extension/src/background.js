// The add-on's one long-lived piece: hold the link to Agents, hand every
// command to the driver, and open the panel when the user asks for it.

import { api, hasDebugger, hasTabGroups } from "./api.js";
import { Driver } from "./driver.js";
import { run } from "./commands.js";
import { fail } from "./protocol.js";
import { StopGate } from "./gate.js";
import { Transport } from "./transport.js";
import { pageMessageFrame, panelNote } from "./strip.js";

const driver = new Driver();
const gate = new StopGate();
let status = { connected: false, kind: null };

const transport = new Transport({
  onCommand: (frame) => {
    // The user's Stop beats everything the host sends.
    const refusal = gate.refusal();
    if (refusal) return fail(frame.cmd_id, refusal);
    return run(driver, frame.cmd_id, frame.op, frame.args ?? {});
  },
  onFrame: (frame) => {
    // The host clears a Stop when the user sends a new task.
    if (frame.type === "browser_resume" && gate.resume()) broadcast();
    // A coworker took the browser: its name goes on the strip.
    if (frame.type === "browser_holder") driver.setCoworker(frame.name).then(broadcast, () => {});
    // The host's word on a panel message, and later the coworker's answer.
    const note = panelNote(frame);
    if (note) api.runtime.sendMessage({ channel: "agents", op: "reply", text: note }).catch(() => {});
  },
  onStatus: (next) => {
    status = next;
    broadcast();
  },
});

function snapshotStatus() {
  return {
    status,
    engine: driver.engineName,
    driving: driver.tabId,
    stopped: gate.stopped,
    coworker: driver.coworker,
  };
}

/** Tell an open panel what changed. */
function broadcast() {
  api.runtime.sendMessage({ channel: "agents", op: "status", ...snapshotStatus() }).catch(() => {});
}

function hello() {
  return {
    type: "browser_attach",
    attached: true,
    browser: hasDebugger ? "chrome" : "firefox",
    engine: driver.engineName,
    features: { trusted_input: hasDebugger, tab_groups: hasTabGroups },
    version: api.runtime.getManifest().version,
    stopped: gate.stopped,
  };
}

/**
 * The user's Stop, from the strip on the page, the panel, or Chrome's own
 * "Cancel" on its debugging bar. Let go of every tab at once, refuse every
 * command until the user allows the browser again, and tell the host, which
 * stops the coworker's run.
 */
async function stopAll(reason) {
  const changed = gate.stop(reason);
  // Stop never waits behind a command that hangs.
  transport.clear();
  await driver.stop();
  if (changed) transport.send({ type: "browser_stop", reason: String(reason) });
  broadcast();
}

function allowAgain() {
  if (gate.resume()) transport.send({ type: "browser_resume" });
  broadcast();
}

async function link() {
  if (transport.connected) return;
  await transport.connect(hello());
}

// -- the user's way in --------------------------------------------------------

async function openPanel(tab) {
  if (api.sidePanel) {
    await api.sidePanel.open({ windowId: tab.windowId });
  } else if (api.sidebarAction) {
    await api.sidebarAction.open();
  }
}

api.runtime.onInstalled.addListener(() => {
  api.contextMenus.removeAll(() => {
    api.contextMenus.create({
      id: "cowork-page",
      title: "Talk to Agents about this page",
      contexts: ["page", "selection", "link", "image"],
    });
  });
  if (api.sidePanel?.setPanelBehavior) {
    api.sidePanel.setPanelBehavior({ openPanelOnActionClick: true }).catch(() => {});
  }
  link();
});

api.runtime.onStartup?.addListener(link);

api.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId !== "cowork-page" || !tab) return;
  await openPanel(tab);
  // A right-click is the user handing this tab over.
  driver.leases.grant(tab.id, "user");
  const context = await pageContext(tab.id, info.selectionText);
  api.runtime.sendMessage({ channel: "agents", op: "page_context", context }).catch(() => {});
});

api.action.onClicked.addListener(openPanel);

api.commands?.onCommand.addListener(async (name) => {
  if (name !== "toggle-panel") return;
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  if (tab) await openPanel(tab);
});

/** What the user's own chat about a page gets: text, not markup. */
async function pageContext(tabId, selection) {
  try {
    await driver.ensureInjected(tabId);
    const page = await api.tabs.sendMessage(tabId, { channel: "agents", op: "readable" });
    const data = page && page.ok ? page.data : { url: "", title: "", text: "" };
    return { ...data, selection: selection || "", tabId };
  } catch {
    const tab = await api.tabs.get(tabId);
    return { url: tab.url, title: tab.title, text: "", selection: selection || "", tabId };
  }
}

// -- the panel talks to us here ----------------------------------------------

api.runtime.onMessage.addListener((msg, sender, reply) => {
  if (!msg || msg.channel !== "agents") return;
  if (msg.op === "stop") {
    // From the strip on a page or from the panel. Stopping is always allowed.
    stopAll(msg.reason || (sender.tab ? "page" : "panel")).then(() => reply(snapshotStatus()));
    return true;
  }
  if (msg.op === "allow_again") {
    // Only the add-on's own pages may lift a Stop, never a page's strip.
    if (sender.tab) return undefined;
    allowAgain();
    reply(snapshotStatus());
    return true;
  }
  if (msg.op === "get_status") {
    reply(snapshotStatus());
    return true;
  }
  if (msg.op === "reconnect") {
    link().then(() => reply(snapshotStatus()));
    return true;
  }
  if (msg.op === "send") {
    // The panel's own message to the coworker rides the same transport. Only
    // the add-on's own pages may send, never a script in a page, and only a
    // page_message: the panel is no way to forge a result or a Stop.
    if (sender.tab) return undefined;
    const frame = pageMessageFrame(msg.frame?.text, msg.frame?.context);
    reply({ sent: Boolean(frame) && msg.frame?.type === "page_message" && transport.send(frame) });
    return true;
  }
  if (msg.op === "page_context_request") {
    api.tabs
      .query({ active: true, currentWindow: true })
      .then(([tab]) => pageContext(tab.id))
      .then((context) => reply({ context }));
    return true;
  }
  return undefined;
});

// The service worker sleeps; a periodic wake keeps the link honest.
// A tab that reloads or goes away loses whatever we put in it.
api.tabs.onUpdated.addListener((tabId, change) => {
  if (change.status === "loading") driver.forget(tabId);
  // The strip comes back on every page the driven tab loads, also when the
  // user navigates it.
  if (change.status === "complete" && tabId === driver.tabId && !gate.stopped) {
    driver.ensureInjected(tabId).catch(() => {});
  }
});

// Chrome's own bar ("... started debugging this browser") has a Cancel
// button. The user pressing it means the same as our Stop.
api.debugger?.onDetach?.addListener((_source, reason) => {
  if (reason === "canceled_by_user") stopAll("debugger_bar");
});
api.tabs.onRemoved.addListener((tabId) => {
  driver.forget(tabId);
  driver.leases.release(tabId);
  if (driver.tabId === tabId) driver.tabId = null;
});

api.alarms.create("agents-link", { periodInMinutes: 0.5 });
api.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === "agents-link") link();
});

link();
