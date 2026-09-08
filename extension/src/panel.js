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

function paintStatus({ connected, kind }, engine) {
  dot.classList.toggle("on", Boolean(connected));
  state.textContent = connected
    ? `CoWork · ${kind} · ${engine} input`
    : "not connected to CoWork";
}

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
  const reply = await api.runtime.sendMessage({ channel: "cowork", op: "reconnect" });
  paintStatus(reply.status, reply.engine ?? "");
});

document.getElementById("composer").addEventListener("submit", async (event) => {
  event.preventDefault();
  const text = input.value.trim();
  if (!text) return;
  input.value = "";
  append(text, true);
  const reply = await api.runtime.sendMessage({
    channel: "cowork",
    op: "send",
    frame: { type: "page_message", text, context: pageContext },
  });
  if (!reply?.sent) append("No link to CoWork right now — the message was not sent.", false);
});

api.runtime.onMessage.addListener((msg) => {
  if (!msg || msg.channel !== "cowork") return;
  if (msg.op === "status") paintStatus(msg.status, msg.engine ?? "");
  if (msg.op === "page_context") paintContext(msg.context);
  if (msg.op === "reply") append(msg.text, false);
});

(async () => {
  const status = await api.runtime.sendMessage({ channel: "cowork", op: "get_status" });
  paintStatus(status.status, status.engine);
  const { context } = await api.runtime.sendMessage({ channel: "cowork", op: "page_context_request" });
  paintContext(context);
})();
