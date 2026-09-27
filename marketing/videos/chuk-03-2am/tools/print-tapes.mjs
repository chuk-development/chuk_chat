// Print the milestones of every tape (for tuning timings).
import { engine } from "./lib.mjs";
import { TAPES } from "./tapes.mjs";
const E = engine();
for (const [id, tp] of Object.entries(TAPES)) {
  const ev = E.hfTape(tp.ops, tp.seed);
  console.log("==", id, "events", ev.length);
  for (let i = 1; i < ev.length; i++) {
    const e = ev[i], p = ev[i - 1], n = ev[i + 1];
    const gap = e.t - p.t;
    const milestone = e.k !== "key" && e.k !== "rep" || gap > 0.35 || !n || (n.k !== "key" && e.k === "key") || (e.k === "rep" && (!n || n.k !== "rep"));
    if (milestone) console.log(e.t.toFixed(2).padStart(6), e.k.padEnd(5), ("gap " + gap.toFixed(2)).padEnd(9), JSON.stringify(e.text));
  }
}
