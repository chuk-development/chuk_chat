import { api, hasDebugger, hasTabGroups } from "./api.js";

const id = api.runtime.id;
// The development build pins its id with the manifest `key`, and the
// installer knows that id, so it needs no argument. Only a build with another
// id (a store build) has to name it.
const PINNED_CHROME_ID = "gchdfokldhdgbjmdcjmkeapcknekogmm";
const flag = hasDebugger && id !== PINNED_CHROME_ID ? ` --chrome-id ${id}` : "";
document.getElementById("install").textContent = `tools/agents-browser-bridge/install_host_manifest.py${flag}`;

document.getElementById("caps").textContent = [
  `extension id   ${id}`,
  `trusted input  ${hasDebugger ? "yes (chrome.debugger)" : "no — synthetic events only"}`,
  `tab groups     ${hasTabGroups ? "yes" : "no"}`,
].join("\n");

async function paint() {
  const snapshot = await api.runtime.sendMessage({ channel: "agents", op: "reconnect" });
  const connected = Boolean(snapshot?.status?.connected);
  document.getElementById("dot").classList.toggle("on", connected);
  document.getElementById("link").textContent = connected
    ? "connected to Agents on this computer"
    : "not connected (Agents is not running here, or the bridge is not registered)";
}

paint();
