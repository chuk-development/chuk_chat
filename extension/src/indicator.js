// A strip along the top edge while the coworker is driving this tab. The user
// must never have to guess whether something else is holding the mouse.

(() => {
  const ID = "agents-agent-indicator";
  const runtime = (globalThis.browser ?? globalThis.chrome).runtime;

  const LOOK = {
    active: { bar: "linear-gradient(90deg,#7c5cff,#00c2a8)", chip: "#7c5cff", text: "Agents is driving" },
    deliverable: { bar: "linear-gradient(90deg,#00c2a8,#7c5cff)", chip: "#00a48f", text: "Agents has something for you" },
    handoff: { bar: "linear-gradient(90deg,#ff9f43,#ff6b6b)", chip: "#e8722c", text: "Agents needs you here" },
  };

  function show(on, state, label) {
    let bar = document.getElementById(ID);
    if (!on) {
      bar?.remove();
      return;
    }
    if (!bar) {
      bar = document.createElement("div");
      bar.id = ID;
      bar.style.cssText = [
        "position:fixed", "inset:0 0 auto 0", "height:3px", "z-index:2147483647",
        "pointer-events:none", "background:linear-gradient(90deg,#7c5cff,#00c2a8)",
        "box-shadow:0 0 12px rgba(124,92,255,.7)",
      ].join(";");
      const chip = document.createElement("div");
      chip.style.cssText = [
        "position:absolute", "top:6px", "right:10px", "padding:3px 9px",
        "border-radius:999px", "font:600 11px/1.4 system-ui,sans-serif",
        "color:#fff", "background:#7c5cff", "letter-spacing:.02em",
      ].join(";");
      bar.appendChild(chip);
      (document.body || document.documentElement).appendChild(bar);
    }
    const look = LOOK[state] ?? LOOK.active;
    bar.style.background = look.bar;
    bar.firstChild.style.background = look.chip;
    bar.firstChild.textContent = label || look.text;
  }

  runtime.onMessage.addListener((msg) => {
    if (msg && msg.channel === "agents" && msg.op === "driving") show(msg.on, msg.state, msg.label);
  });
})();
