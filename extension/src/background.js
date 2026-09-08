// The add-on's one long-lived piece: hold the link to CoWork, hand every
// command to the driver, and open the panel when the user asks for it.

import { api, hasDebugger, hasTabGroups } from "./api.js";
import { Driver } from "./driver.js";
import { run } from "./commands.js";
import { Transport } from "./transport.js";

const driver = new Driver();
let status = { connected: false, kind: null };

const transport = new Transport({
  onCommand: (frame) => run(driver, frame.cmd_id, frame.op, frame.args ?? {}),
  onStatus: (next) => {
    status = next;
    api.runtime.sendMessage({ channel: "cowork", op: "status", status }).catch(() => {});
  },
});

function hello() {
  return {
    type: "browser_attach",
    attached: true,
    browser: hasDebugger ? "chrome" : "firefox",
    engine: driver.engineName,
    features: { trusted_input: hasDebugger, tab_groups: hasTabGroups },
    version: api.runtime.getManifest().version,
  };
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
      title: "Talk to CoWork about this page",
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
  api.runtime.sendMessage({ channel: "cowork", op: "page_context", context }).catch(() => {});
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
    const page = await api.tabs.sendMessage(tabId, { channel: "cowork", op: "readable" });
    const data = page && page.ok ? page.data : { url: "", title: "", text: "" };
    return { ...data, selection: selection || "", tabId };
  } catch {
    const tab = await api.tabs.get(tabId);
    return { url: tab.url, title: tab.title, text: "", selection: selection || "", tabId };
  }
}

// -- the panel talks to us here ----------------------------------------------

api.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (!msg || msg.channel !== "cowork") return;
  if (msg.op === "get_status") {
    reply({ status, engine: driver.engineName, driving: driver.tabId });
    return true;
  }
  if (msg.op === "reconnect") {
    link().then(() => reply({ status }));
    return true;
  }
  if (msg.op === "send") {
    // The panel's own message to the coworker rides the same transport.
    transport.send(msg.frame);
    reply({ sent: transport.connected });
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
});
api.tabs.onRemoved.addListener((tabId) => {
  driver.forget(tabId);
  driver.leases.release(tabId);
  if (driver.tabId === tabId) driver.tabId = null;
});

api.alarms.create("cowork-link", { periodInMinutes: 1 });
api.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === "cowork-link") link();
});

link();
