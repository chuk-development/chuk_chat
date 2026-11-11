---
workflow: product-launch-video
flow: automation
storyboard: no
message: "One private chat for everything you ask."
destination: youtube
aspect: 1920x1080
fps: 30
language: en
length: 62s
angle: copy the principle of Anthropic's no-people product ads (Cowork, Memory) for Chuk Chat, in a brown palette
narration: no
music: supplied (marketing/_shared/music/07-chasing-horizons-62s.wav, 62.0 s, cut to length, do not re-cut)
---

# chuk-07-launch

The owner rejected videos 01-06: wrong music, wrong look, "does not fit the
brand". He asked for one thing: watch Anthropic's product ads without people
and make that, for Chuk Chat. **Read `marketing/_review/anthropic-ref/ANALYSIS.md`
first, then look at `sheets/UAmKyyZ-b9E.jpg`, `sheets/PupmfSttxlc.jpg` and the
full frames in `frames/`.** That grammar is the spec. Do not reuse the
look of 01-06 (no dark app windows, no painted skies, no "01 / 13" counters).

## Palette (brown, owner rule)

| Role | Hex |
|---|---|
| Canvas (with faint 48 px grid lines `#E6DCCD`) | `#F4EEE4` |
| Tan title field | `#DCCBB4` |
| Colour-block field (one section only) | `#5C4033` |
| Text on dark brown | `#F4EEE4` |
| Ink (headlines, UI text) | `#2A1F17` |
| Ink soft | `#6E5D4E` |
| UI surface (cards, composer) | `#FFFDF9`, border `#E2D6C6` |
| User bubble | `#EADFCF` |
| Accent (send button, ticks, star mark) | `#8B5A2B` |

No glow, no coloured `box-shadow`. One soft neutral shadow on floating UI is ok
(`0 8px 30px rgba(42,31,23,.08)`).

## Type

- Headlines: Newsreader (`~/.local/share/fonts/Newsreader-Disp600.ttf`, copy
  into `assets/fonts/`), sentence case, 64-96 px.
- UI text: JetBrains Mono (`../chuk-01-introducing/assets/fonts/jetbrains-mono-latin-wght.woff2`),
  the app's own font. 28-40 px when an element is shown big.
- Embed every font. No system fonts.

## Story (62 s, cuts on the beat of the music)

1. Tan field, serif: "Meet Chuk Chat." (2.5 s)
2. Greeting, very big: CC mark (`/home/user/git/chuk_chat/assets/logo.svg`) +
   "What's on your mind, Lea?" + light composer. Chips below: Research,
   Make a chart, Plan a trip, Read a file. Cursor hovers, clicks "Plan a trip".
3. Prompt types: "find three cafés near kiel harbour and a walk between them".
   Send click. Star mark pulses, "Searching the web..." Three source rows
   appear (cite real-looking domains). Then a map card with three pins and a
   route draws. Push-in on the route.
4. **Colour-block section (dark brown)**: the same chat bubble scrambles
   into ciphertext, then a line: "Encrypted on your device. Only you can read
   it." Small German flag dot + "Made in Germany" is ok.
5. Back on canvas. Stacked follow-up bubbles like Cowork:
   "actually one more thing" / "what did i spend on coffee this month?"
   A PDF chip `bank-statement.pdf` attaches. Progress list ticks:
   Read the PDF, Find coffee, Add it up. Result: a small bar chart card,
   "€42.80 this month".
6. Model picker, big: cursor opens the list (DeepSeek V4 Pro, Kimi K3,
   GLM 5.3, Qwen3.8, MiniMax M3, Mistral Small 4), picks one. Serif line:
   "Every open model. One price."
7. Connectors: a grid of real logos pops in (Notion, GitHub, Google
   Calendar, Gmail, Slack, Todoist). Use real logo files, not glyphs.
8. Everywhere: the same chat on a phone and a desktop window, side by side,
   light theme, 2-3 s. This is the only full-window shot.
9. Tan field, serif: "What will you ask next?"
10. End: CC mark + "Chuk Chat" + "Private and Secure. Always." (exact wording)
    on tan, hold 3 s, music ends.

UI is light (not the dark app theme). Rebuild it in HTML from the real app
(`lib/` theme and widgets, the website capture in
`marketing/_shared/capture/`). The composer, chips and bubbles of
`../chuk-01-introducing/compositions/` can be a starting point, restyled.

## Quality bar

- Every UI element is shown big. Check legibility on full-size single
  frames, not on contact sheets.
- Icons are SVG in flex boxes, never text glyphs.
- Typing speed readable (about 18 chars/s), every text hold at least 1.2 s
  after it finishes.
- Cursor: real arrow + hand SVG, eased movement, click = small press scale.
- Render: `marketing/out/07-launch.mp4`, `--quality high`.
