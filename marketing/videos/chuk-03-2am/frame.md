---
version: alpha
name: Chuk Chat — Night (frame layer for video 03 "2 a.m.")
description: >
  Frame-scale design system for the "2 a.m." launch video. Seeded from the code-editorial
  preset (build-frame.mjs, exit 0), then corrected by hand because the automatic remix
  inverted the palette and mapped every display face to "-apple-system", which has no
  font file. The world is the chuk.chat moon-night scene (usecases.css `.uc-scene--night`,
  `.sc-moon`, `.sc-stars`) with the real app window (`.app`, `.a-composer`, `.a-bubble`).
unit: the frame — 1920×1080, 30 fps
principle: the site's night world is copied, not re-invented · one idea per beat · calm

colors:
  ink: "#F6F3EC"          # text on the night sky (site .tone-dark --uc-ink)
  canvas: "#0A0F1F"       # night sky top — the video ground
  night-mid: "#131A33"
  night-low: "#1D2444"
  horizon: "#5A6EBE"      # rgba(90,110,190,.35) radial at the bottom of the sky
  moon: "#FFF7E4"         # moon highlight; body #EDE1C4, rim #D2C6A8
  ink-soft: "#C9CEDF"     # rgba(246,243,236,.76) on night
  ink-faint: "#8E97B5"    # quiet labels on night (clock, notes)
  gold: "#F2C56B"         # site eyebrow on dark worlds (.tone-dark --uc-accent), small only
  coral: "#D97757"        # app accent: send button, caret
  bubble: "#B6674D"       # user message bubble
  app-bg: "#262624"       # app window surface
  app-line: "#615F5A"     # composer border
  app-text: "#E8E4D8"     # text in the app window
  vault-text: "#DDE4FF"   # "What our server stores" badge text
  paper: "#FDFBF7"        # site paper (not used as ground in this video)

borders: { hairline-night: "1px solid rgba(246,243,236,0.16)", composer: "2px solid #615F5A", field-night: "2px solid rgba(232,228,216,0.22)" }
shadows: { app-window: "0 50px 110px -30px rgba(12,10,6,0.6), 0 0 0 1px rgba(255,255,255,0.07)", none: "none" }

typography:
  display:   { fontFamily: "Chuk Sans", px: 96, weight: 300, lineHeight: 1.06, tracking: "-0.03em" }
  headline:  { fontFamily: "Chuk Sans", px: 76, weight: 300, lineHeight: 1.1, tracking: "-0.028em" }
  typed:     { fontFamily: "Chuk Chat Mono", px: 60, weight: 400, lineHeight: 1.32 }
  clock:     { fontFamily: "Chuk Chat Mono", px: 64, weight: 300, tracking: "0.02em" }
  kicker:    { fontFamily: "Chuk Chat Mono", px: 30, weight: 500, tracking: "0.01em" }
  body:      { fontFamily: "Chuk Sans", px: 40, weight: 400, lineHeight: 1.4 }
  app-chat:  { fontFamily: "Chuk Chat Mono", px: 16, weight: 400, lineHeight: 1.45, note: "logical px inside the app window; the window is scaled so it reads ≥ 22 px" }
  app-ui:    { fontFamily: "Ubuntu", px: 16, weight: 600, note: "composer placeholder, pills, 'Thought for 4s' (12 px, 500)" }

spacing:
  slide-pad: "96px"
  gap-md: "32px"
  radius-app: "18px"
  radius-composer: "30px"
  radius-pill: "9999px"

components:
  night-sky:
    background: "radial-gradient(ellipse at 50% 120%, rgba(90,110,190,0.35), transparent 60%), linear-gradient(180deg, #0A0F1F 0%, #131A33 55%, #1D2444 100%)"
    description: "Full-bleed ground of every frame, painted on a class=clip layer. Stars are tiny white dots from a seeded list; they twinkle as a pure function of GLOBAL time so the seam between frames is invisible."
  moon:
    background: "radial-gradient(circle at 36% 34%, #FFF7E4, #EDE1C4 58%, #D2C6A8)"
    description: "Same position and size in every night frame (left 1418px, top 128px, 124px). No halo, no glow."
  night-field:
    description: "An unbranded input field on the sky: 1440px wide, radius 40px, 2px border rgba(232,228,216,0.22), fill rgba(10,15,31,0.45). Typed text in Chuk Chat Mono 60px #F6F3EC. Caret coral #D97757, 5px wide. A dim round send button (grey) that is never pressed."
  app-window:
    description: "The real Chuk Chat desktop window from the site (1000×720 logical, radius 18, #262624, composer radius 30 with 2px #615F5A border, coral send pill, bubble #B6674D, Chuk Chat Mono 16px chat text, Ubuntu UI). Scaled ≥1.4× so chat text reads ≥ 22px."
  vault-badge:
    description: "The site's 'What our server stores' pill (rgba(14,17,30,0.9), 1px rgba(160,180,255,0.32) border, #DDE4FF text, lock icon) with the mono note 'AES-256-GCM · the key stays on your device'."
  end-card:
    description: "Night sky, centered: the Chuk Chat logo mark (assets/brand/logo-light.svg, the repo logo recoloured, never redrawn), 'Chuk Chat' in Chuk Chat Mono, the slogan 'Private and Secure. Always.' and 'chuk.chat'."
---

# Chuk Chat — Night

## Overview

The whole film lives in one place: the moon-night world from chuk.chat. A deep blue sky,
a pale moon, a few small stars. It is 2 a.m., quiet, a little lonely. The only warm colour
is the coral of the caret and, later, of the Chuk Chat send button and the user bubble.

Three voices:

- **Chuk Chat Mono** (JetBrains Mono variable, `assets/fonts/jetbrains-mono-latin-wght.woff2`)
  — the person typing, the clock, the app chat text, the eyebrows. This is the brand voice.
- **Chuk Sans** (Inter variable, `assets/fonts/InterVariable.ttf`, weight 300) — the few
  headline lines ("The questions you would not ask anyone else."). Light, calm, editorial,
  like the site's light sans headlines.
- **Ubuntu** (`assets/fonts/Ubuntu-wght.ttf`) — only inside the rebuilt app UI, as on the site.

## Rules

- One idea per beat. At most about 8 words of headline on screen.
- Headlines ≥ 64 px. Typed text 60 px. App chat text ≥ 22 px effective (scale the window).
- No neon, no glow, no coloured box-shadow. The moon has no halo.
- Coral appears only as the caret, the send button, and the user bubble.
- Gold (`#F2C56B`) only for a small eyebrow, as the site does on dark worlds.
- Keep content above y ≈ 900 (bottom 17% keep-out).
- Motion is slow and soft: `power2.out` / `sine.inOut`, 0.6–1.2 s for entrances. The typing
  is the only fast motion. No bounce, no spin.

## Fonts

```html
<style>
@font-face { font-family: "Chuk Chat Mono"; src: url("assets/fonts/jetbrains-mono-latin-wght.woff2") format("woff2"); font-weight: 100 800; font-display: block; }
@font-face { font-family: "Chuk Sans"; src: url("assets/fonts/InterVariable.ttf") format("truetype"); font-weight: 100 900; font-display: block; }
@font-face { font-family: "Ubuntu"; src: url("assets/fonts/Ubuntu-wght.ttf") format("truetype"); font-weight: 300 700; font-display: block; }
</style>
```
