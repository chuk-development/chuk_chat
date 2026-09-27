#!/usr/bin/env node
// 1) Cut the supplied track (assets/bgm/track.wav) to the video: from TRACK_OFFSET,
//    TOTAL seconds, short fade-in, fade-out over the natural decay.
// 2) Collect every audible keystroke from the tapes (global time) -> tools/keystrokes.json
// 3) Mix assets/sfx/keys.wav with tools/mix_keys.py (bundled media-use key-press.mp3).
// 4) Write audio_meta.json by hand-rules (supplied music, one pre-mixed SFX bed).
import { spawnSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { engine, FRAMES, TRACK_OFFSET, TOTAL, startOf } from "./lib.mjs";
import { TAPES } from "./tapes.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const run = (cmd, args) => {
  const r = spawnSync(cmd, args, { cwd: ROOT, encoding: "utf8" });
  if (r.status !== 0) { console.error(r.stderr); process.exit(1); }
  return r.stdout;
};

const FADE_OUT = 1.4;
run("ffmpeg", [
  "-hide_banner", "-loglevel", "error", "-y",
  "-ss", String(TRACK_OFFSET), "-t", String(TOTAL), "-i", "assets/bgm/track.wav",
  "-af", `afade=t=in:st=0:d=0.3,afade=t=out:st=${(TOTAL - FADE_OUT).toFixed(2)}:d=${FADE_OUT}`,
  "-c:a", "pcm_s16le", "-ar", "44100", "assets/bgm/track-cut.wav",
]);

const E = engine();
const hits = [];
for (const [id, tp] of Object.entries(TAPES)) {
  const g0 = startOf(id);
  const ev = E.hfTape(tp.ops, tp.seed);
  for (let i = 1; i < ev.length; i++) {
    const e = ev[i];
    if (!e.c) continue;
    const prev = ev[i - 1].text;
    const ch = e.k === "key" ? e.text.slice(-1) : "";
    hits.push({ t: +(g0 + e.t).toFixed(4), kind: e.k, space: ch === " ", frame: id });
  }
}
hits.sort((a, b) => a.t - b.t);
writeFileSync(join(ROOT, "tools/keystrokes.json"), JSON.stringify({ total: TOTAL, hits }, null, 1));
console.log(`keystrokes: ${hits.length}`);
run("python3", ["tools/mix_keys.py"]);

const meta = {
  bgm: {
    path: "assets/bgm/track-cut.wav",
    volume: 0.86,
    mode: "supplied",
    duration_s: TOTAL,
    source: "assets/bgm/track.wav (marketing/_shared/music/03-2am.wav)",
    source_offset_s: TRACK_OFFSET,
    note: "Cut from 5.05 s: first piano note on 1.40 s, swell hit (track 38.45 s) on 33.40 s = app reveal. 0.3 s fade-in, 1.4 s fade-out over the natural decay.",
  },
  voices: [],
  sfx: [
    {
      frame: 1,
      file: "assets/sfx/keys.wav",
      offset_s: 0,
      duration_s: TOTAL,
      volume: 0.24,
      note: "Pre-mixed keystrokes at the exact tape times (media-use bundled key-press.mp3).",
    },
  ],
};
writeFileSync(join(ROOT, "audio_meta.json"), JSON.stringify(meta, null, 2) + "\n");
console.log("wrote assets/bgm/track-cut.wav, assets/sfx/keys.wav, audio_meta.json");
