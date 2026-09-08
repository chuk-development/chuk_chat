// Who holds a tab.
//
// Taken from how OpenAI's extension models it: every tab the coworker touches
// carries a lease saying where it came from (`agent` — it opened the tab
// itself; `user` — the user handed one over) and what it is doing (`active`,
// `deliverable` when there is something to look at, `handoff` when it wants the
// user to take the wheel). Nothing is injected into a tab without a lease, so
// the lease is the single place that decides who may touch what.

export const ORIGIN = Object.freeze({ AGENT: "agent", USER: "user" });
export const STATE = Object.freeze({
  ACTIVE: "active",
  DELIVERABLE: "deliverable",
  HANDOFF: "handoff",
});

export class Leases {
  constructor() {
    this.byTab = new Map(); // tabId -> { origin, state, since }
  }

  grant(tabId, origin) {
    const lease = { origin, state: STATE.ACTIVE, since: Date.now() };
    this.byTab.set(tabId, lease);
    return lease;
  }

  get(tabId) {
    return this.byTab.get(tabId) ?? null;
  }

  held(tabId) {
    return this.byTab.has(tabId);
  }

  setState(tabId, state) {
    const lease = this.byTab.get(tabId);
    if (!lease) return null;
    lease.state = state;
    return lease;
  }

  /** The user takes the wheel back: the lease stays, but the coworker stops. */
  handoff(tabId) {
    return this.setState(tabId, STATE.HANDOFF);
  }

  release(tabId) {
    return this.byTab.delete(tabId);
  }

  list() {
    return [...this.byTab.entries()].map(([tabId, lease]) => ({ tabId, ...lease }));
  }
}
