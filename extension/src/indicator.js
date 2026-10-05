// A strip along the top edge while the coworker is driving this tab, with a
// Stop button. The user must never have to guess whether something else is
// holding the mouse, and must be able to take it back with one click.
//
// It lives in a closed shadow root: the page's own styles cannot hide it, and
// the snapshot (which walks the document) never sees it, so the coworker
// cannot click its own Stop by reading it as page content.

(() => {
  if (globalThis.__agentsIndicator) return; // injected once per page
  globalThis.__agentsIndicator = true;

  const runtime = (globalThis.browser ?? globalThis.chrome).runtime;

  const LOOK = {
    active: { color: "#6a4fe0", text: "Agents is using this tab" },
    deliverable: { color: "#00806f", text: "Agents has something for you" },
    handoff: { color: "#c25a17", text: "Agents needs you here" },
    stopped: { color: "#5c5c66", text: "Agents stopped" },
  };

  let host = null;
  let parts = null;

  function build() {
    host = document.createElement("agents-indicator");
    const root = host.attachShadow({ mode: "closed" });
    root.innerHTML = `
      <style>
        :host { all: initial; }
        .bar { position: fixed; inset: 0 0 auto 0; height: 3px; z-index: 2147483647;
               pointer-events: none; }
        .chip { position: fixed; top: 6px; right: 10px; z-index: 2147483647;
                display: flex; align-items: center; gap: 8px; padding: 3px 4px 3px 10px;
                border-radius: 999px; font: 600 12px/1.4 system-ui, sans-serif;
                color: #fff; }
        button { all: unset; cursor: pointer; padding: 2px 10px; border-radius: 999px;
                 background: #fff; color: #1b1b1f; font: 600 12px/1.4 system-ui, sans-serif; }
        button:focus-visible { outline: 2px solid #fff; outline-offset: 2px; }
        button[hidden] { display: none; }
      </style>
      <div class="bar"></div>
      <div class="chip" role="status" aria-live="polite">
        <span class="label"></span>
        <button type="button" class="stop">Stop</button>
      </div>`;
    parts = {
      bar: root.querySelector(".bar"),
      chip: root.querySelector(".chip"),
      label: root.querySelector(".label"),
      stop: root.querySelector(".stop"),
    };
    parts.stop.addEventListener("click", (event) => {
      event.stopPropagation();
      event.preventDefault();
      runtime.sendMessage({ channel: "agents", op: "stop", reason: "page" }).catch?.(() => {});
      show(true, "stopped");
    });
    (document.documentElement || document.body).appendChild(host);
  }

  function show(on, state, label) {
    if (!on) {
      host?.remove();
      host = null;
      parts = null;
      return;
    }
    if (!host || !host.isConnected) build();
    const look = LOOK[state] ?? LOOK.active;
    parts.bar.style.background = look.color;
    parts.chip.style.background = look.color;
    parts.label.textContent = label || look.text;
    // Stop is offered while the coworker could still act here.
    parts.stop.hidden = state === "stopped";
  }

  runtime.onMessage.addListener((msg) => {
    if (msg && msg.channel === "agents" && msg.op === "driving") show(msg.on, msg.state, msg.label);
  });
})();
