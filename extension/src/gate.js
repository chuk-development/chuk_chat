// The user's Stop. One flag, one place that refuses.
//
// While it is set, no command from Agents reaches a tab: the add-on answers
// every one with the same refusal, so a coworker that keeps trying learns the
// same thing each time. Only the user lifts it (the panel's "Allow again"), or
// the host does when the user sends a new task (`browser_resume`).

export const STOPPED_MESSAGE =
  "the user pressed Stop in their browser. Do not use the browser again in this task. " +
  "Tell the user where you stopped and what is left.";

export class StopGate {
  constructor() {
    this.stopped = false;
    this.reason = "";
    this.since = 0;
  }

  /** Returns true when this call changed the state. */
  stop(reason = "user") {
    if (this.stopped) return false;
    this.stopped = true;
    this.reason = String(reason);
    this.since = Date.now();
    return true;
  }

  resume() {
    if (!this.stopped) return false;
    this.stopped = false;
    this.reason = "";
    this.since = 0;
    return true;
  }

  /** The refusal for a command, or null when it may run. */
  refusal() {
    return this.stopped ? STOPPED_MESSAGE : null;
  }
}
