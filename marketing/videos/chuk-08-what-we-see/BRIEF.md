---
workflow: general-video (autonomous)
flow: automation
storyboard: no
message: "This is all we see." Your chats are encrypted on your device; our server keeps only ciphertext.
destination: youtube
aspect: 1920x1080
fps: 30
language: en
length: 62s
angle: Anthropic no-people product-ad grammar, privacy is the only subject, real Chuk Chat UI rebuilt 1:1
narration: no
music: supplied (marketing/_shared/music/07-chasing-horizons-62s.wav, 62.0 s)
---

# chuk-08-what-we-see

## Why this exists (owner feedback on 07, 2026-10-26)

1. "It does not look like our UI." Video 07 invented a light UI. **Wrong.**
   The real app is the dark warm-grey UI in `assets/screenshots/*.webp`
   (look at `screenshot_tool_calling_ui.webp`, `screenshot_home_ui.webp`,
   `screenshot_model_selection.webp` at full size). Rebuild exactly that,
   1:1, in HTML. The website already did this well: copy markup, sizes and
   colours from `/home/user/git/chuk.chat/layouts/partials/uc/a-composer.html`,
   `private.html` and `assets/css/usecases.css` (and the other `uc-*.css`).
2. "Every AI chat has these features." Do not sell web search, charts,
   maps, models or connectors. **Privacy is the only subject.**

Keep from 07 what worked: the Anthropic grammar
(`marketing/_review/anthropic-ref/ANALYSIS.md`): brown paper canvas with a
faint grid, one big UI piece per shot, the cursor as actor, real typing,
slow push-ins, serif headlines, one colour-block section, tan title cards,
logo end card. The build tooling of `../chuk-07-launch/_work/build.py` can
be copied and adapted.

## Palette

Canvas and cards (around the UI): `#F4EEE4` with grid `#E6DCCD`, tan
`#DCCBB4`, colour block `#5C4033`, ink `#2A1F17`, ink soft `#6E5D4E`.
**The UI pieces themselves use the real app colours** (dark surface
`#262624`, composer outline, coral user bubble and send button, light text),
measured from the screenshots, not invented.

## Fidelity check (required)

For the composer, the user bubble, the "Worked for Ns" block with source
chips and the answer text: put your render next to a crop of the real
screenshot at the same scale (`_work/fidelity/*.jpg`) and fix every
difference in font, size ratio, radius, colour, icon and spacing. Fonts:
messages and answer text in JetBrains Mono; the small UI labels in the same
sans the screenshot shows (Ubuntu, `/home/user/git/chuk.chat/static/fonts`
or the capture's font files). Icons are SVG, same shapes as the app (Lucide
style), never text glyphs.

## Story (cuts on beats)

1. Tan card, serif: "Some questions you'd never ask out loud."
2. The real composer, big, centered on the canvas ("Ask me anything !",
   plus button, "Fast" chip, mic, coral send). Cursor clicks into it. Types:
   `my blood test says ferritin 9. should i be worried?` Cursor clicks send.
3. Real coral user bubble at top, then the real "Worked for 2s" block with
   source chips (nhs.uk, mayoclinic.org, aerzteblatt.de), then the answer
   streams in mono, 3-4 short lines, e.g. "A ferritin of 9 µg/L is low. It
   usually means your iron stores are empty, even before anaemia shows. It is
   common and treatable. Ask your doctor about an iron panel and the cause."
   Push in on the bubble.
4. Canvas, serif: "Here's what we store."
5. A rebuilt database row (Supabase table editor look, light, clean):
   table `encrypted_chats`, columns `id`, `user_id` (uuid, partly masked),
   `encrypted_payload`, `updated_at`. The `encrypted_payload` cell opens into
   the real envelope format, generated for real with AES-256-GCM in
   `_work/make_cipher.py` (Python `cryptography`, random key, 12-byte nonce):
   `{"v":"2","kv":1,"nonce":"…","ciphertext":"…","mac":"…"}`. Long base64
   that scrolls. Serif line: "This is all our server ever sees."
6. Colour block (dark brown): the bubble text scrambles into the same
   ciphertext. Line: "Encrypted on your device. With a key only you hold."
7. Code shot: a rebuilt GitHub file view (dark), path
   `chuk-development/chuk_chat / lib/services/encryption_service.dart`, the
   real lines 809-825 of that file (copy them verbatim), with
   `AesGcm.with256bits()` and `nonce` highlighted by a slow push-in. Serif
   line: "Don't trust us. Read the code."
8. Three short beats, one per cut, serif on canvas/tan:
   "Never used for training." / "No ads. No tracking." /
   "Run from Germany, under EU law."
9. End card on tan: CC mark (`assets/logo.svg`) + "Chuk Chat" +
   "Private and Secure. Always." (exact wording, readable size, ink soft) +
   `chuk.chat`. Hold until the music ends.

## Claims (legal, do not change)

Only the claims above. Never say "nobody can read it" or "not even the AI":
the model receives the prompt in plain text to answer it. "Our server only
stores ciphertext" is true. "A key only you hold" is true (key derived on
the device).

## Quality bar

Same as 07: everything big and legible at full-size frames, typing about
18 chars/s, holds at least 1.2 s, eased cursor with press scale, no glow,
`npx hyperframes check` passes. Render to
`/home/user/git/chuk_chat/marketing/out/08-what-we-see.mp4`, `--quality high`.
