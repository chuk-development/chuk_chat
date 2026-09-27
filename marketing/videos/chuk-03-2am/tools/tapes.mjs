// Keystroke tapes (frame-local seconds). One tape per typed surface.
// Ops: {at} jump to time · {type, speed, first} type chars · {pause} ·
// {bs:n} backspace n · {hold, delay, rate} hold backspace until empty ·
// {words} ctrl+backspace until empty · {select, hl} select all + delete · {send}.

export const TAPES = {
  // Frame 1 — the hook. First key on the first piano note (1.40 s).
  "01-hook": {
    seed: 1957,
    ops: [
      { at: 1.4, type: "is this mole", first: 0, speed: 1.3 },
      { pause: 0.6 },
      { type: " something to worry about", speed: 1.5 },
      { pause: 0.65 },
      { hold: true, delay: 0.34, rate: 0.022 },
    ],
  },

  // Frame 2 — three more questions (clock 02:09, 02:23, 02:38).
  "02-questions": {
    seed: 209,
    ops: [
      // Q2: tired -> burned out, then select-all delete
      { at: 0.4, type: "how do I tell my boss I am tired", first: 0, speed: 1.55 },
      { pause: 0.6 },
      { bs: 5 },
      { pause: 0.25 },
      { type: "burned out", speed: 1.3 },
      { pause: 0.45 },
      { select: true, hl: 0.4 },
      // Q3: the long pause before "I lose my job" sits in the piano silence
      { at: 7.7, type: "can we still afford the flat if", first: 0, speed: 1.6 },
      { pause: 1.45 },
      { type: " I lose my job", speed: 1.1 },
      { pause: 0.55 },
      { words: true, wmin: 0.09, wmax: 0.14 },
      // Q4: slower, the longest hold, then one decisive select-all
      { at: 15.9, type: "how do I say sorry", first: 0, speed: 1.65 },
      { pause: 0.55 },
      { type: " to my sister", speed: 1.55 },
      { pause: 1.0 },
      { select: true, hl: 0.45 },
    ],
  },

  // Frame 4 — this time it is sent: a 1.4 s hesitation, then Enter on the 38.65 s hit (local 5.25).
  "04-sent": {
    seed: 3740,
    ops: [
      { at: 0.7, type: "How do I tell my boss that I am burned out?", first: 0, speed: 1.75 },
      { at: 5.25, send: true },
    ],
  },
};

// Clock values per frame: [local time of the roll, value]
export const CLOCKS = {
  "01-hook": [
    [0, "01:56"],
    [0.45, "01:57"],
  ],
  "02-questions": [
    [0, "01:57"],
    [0.05, "02:09"],
    [7.45, "02:23"],
    [15.65, "02:38"],
  ],
  "03-who-reads": [[0, "02:38"]],
};
