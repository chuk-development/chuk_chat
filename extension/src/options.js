import { api, hasDebugger, hasTabGroups } from "./api.js";

const relay = document.getElementById("relay");
const saved = document.getElementById("saved");

api.storage.local.get("relayUrl").then(({ relayUrl }) => {
  relay.value = relayUrl ?? "";
});

document.getElementById("save").addEventListener("click", async () => {
  await api.storage.local.set({ relayUrl: relay.value.trim() });
  saved.textContent = "saved";
  await api.runtime.sendMessage({ channel: "agents", op: "reconnect" });
  setTimeout(() => (saved.textContent = ""), 2000);
});

document.getElementById("caps").textContent = [
  `extension id   ${api.runtime.id}`,
  `trusted input  ${hasDebugger ? "yes (chrome.debugger)" : "no — synthetic events only"}`,
  `tab groups     ${hasTabGroups ? "yes" : "no"}`,
].join("\n");
