// One name for both browsers. Chrome ships `chrome.*` and, from 148, `browser.*`;
// Firefox has only `browser.*`. Everything else in this add-on imports `api`
// from here and never touches a vendor global.
export const api = globalThis.browser ?? globalThis.chrome;

/** True where `chrome.debugger` exists — Chrome only. Firefox never implemented it. */
export const hasDebugger = typeof api.debugger !== "undefined";

/** True where tabs can be grouped — Chrome only. */
export const hasTabGroups = typeof api.tabGroups !== "undefined";

/** Chrome's callback APIs return promises from MV3 on; Firefox always did. */
export function lastError() {
  const err = api.runtime.lastError;
  return err ? new Error(err.message) : null;
}
