// The panel is a thin view: it shows the link state, the page it is talking
// about, and the conversation. Everything else lives in the service worker.

import { api } from "./api.js";

const dot = document.getElementById("dot");
const state = document.getElementById("state");
const log = document.getElementById("log");
const ctx = document.getElementById("context");
const ctxTitle = document.getElementById("ctx-title");
const ctxUrl = document.getElementById("ctx-url");
const input = document.getElementById("input");

let pageContext = null;

const control = document.getElementById("control");
const controlText = document.getElementById("control-text");
const stopButton = document.getElementById("stop");
const allowButton = document.getElementById("allow");

function paintStatus({ connected, kind } = {}, engine) {
  dot.classList.toggle("on", Boolean(connected));
  state.textContent = connected
    ? `Agents · ${kind} · ${engine} input`
    : "not connected to Agents";
}

/** Who holds the browser, and the one button that matters right now. */
function paintControl({ driving, stopped } = {}) {
  const isDriving = driving !== null && driving !== undefined;
  control.hidden = !isDriving && !stopped;
  control.classList.toggle("driving", isDriving && !stopped);
  control.classList.toggle("stopped", Boolean(stopped));
  controlText.textContent = stopped
    ? "Stopped. Agents cannot use this browser."
    : "Agents is using a tab in this browser.";
  stopButton.hidden = Boolean(stopped);
  allowButton.hidden = !stopped;
}

function paintAll(snapshot) {
  if (!snapshot) return;
  paintStatus(snapshot.status, snapshot.engine ?? "");
  paintControl(snapshot);
}

stopButton.addEventListener("click", async () => {
  paintAll(await api.runtime.sendMessage({ channel: "agents", op: "stop", reason: "panel" }));
});

allowButton.addEventListener("click", async () => {
  paintAll(await api.runtime.sendMessage({ channel: "agents", op: "allow_again" }));
});

function paintContext(context) {
  pageContext = context;
  if (!context || !context.url) {
    ctx.hidden = true;
    return;
  }
  ctx.hidden = false;
  ctxTitle.textContent = context.title || context.url;
  ctxUrl.textContent = context.url;
}

function append(text, mine) {
  const el = document.createElement("div");
  el.className = mine ? "msg me" : "msg";
  el.textContent = text;
  log.appendChild(el);
  log.scrollTop = log.scrollHeight;
}

document.getElementById("reconnect").addEventListener("click", async () => {
  state.textContent = "connecting…";
  paintAll(await api.runtime.sendMessage({ channel: "agents", op: "reconnect" }));
});

document.getElementById("composer").addEventListener("submit", async (event) => {
  event.preventDefault();
  const text = input.value.trim();
  if (!text) return;
  input.value = "";
  append(text, true);
  const reply = await api.runtime.sendMessage({
    channel: "agents",
    op: "send",
    frame: { type: "page_message", text, context: pageContext },
  });
  if (!reply?.sent) append("No link to Agents right now — the message was not sent.", false);
});

api.runtime.onMessage.addListener((msg) => {
  if (!msg || msg.channel !== "agents") return;
  if (msg.op === "status") paintAll(msg);
  if (msg.op === "page_context") paintContext(msg.context);
  if (msg.op === "reply") append(msg.text, false);
});

(async () => {
  paintAll(await api.runtime.sendMessage({ channel: "agents", op: "get_status" }));
  const { context } = await api.runtime.sendMessage({ channel: "agents", op: "page_context_request" });
  paintContext(context);
})();
