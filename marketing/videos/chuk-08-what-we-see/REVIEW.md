# REVIEW: chuk-08-what-we-see

Output: `marketing/out/08-what-we-see.mp4`, 62.0 s, 1920x1080, 30 fps, H.264 + AAC 48 kHz
stereo, `--quality high --gpu -w 4` (NVENC). Audio measured: mean -14.1 dB, max -1.4 dB.

## Build

`python3 _work/make_cipher.py` (once) then `python3 _work/build.py`. Edit the script, not
`compositions/`. Shot list and numbers: `SPEC.md`. Fidelity sheets: `python3 _work/fidelity.py
<composer frame> <chat frame>` -> `_work/fidelity/composer.jpg`, `chat.jpg`.

## Decisions where the brief was open or wrong

- Code shot: the brief names lines 809-825. Those lines are the old `encrypt()` (envelope
  `v:'1'`, it uses `_cipher`, no `AesGcm.with256bits()` in them). The video shows lines 52-67
  of `sealChatPayload` instead, verbatim (identical on origin/master): that function writes
  `encrypted_chats.encrypted_payload` in exactly the `{"v":"2",...}` envelope the table shot
  shows, and it holds both `AesGcm.with256bits()` and the 12-byte `nonce`.
- Ciphertext: real AES-256-GCM over the real layers (v3 payload JSON -> 0x00|codec 1|len
  frame -> AES-GCM, random key thrown away, 12-byte nonce). Three neighbour rows are real
  ciphertext of three other chats that are never shown.
- The s06 scramble lands on the first 51 characters of the same ciphertext.
- Model line ("z-ai/... · fireworks/...") and "Answer in German" step left out of the
  Worked block: they sell models and name a provider. Kept the real disclaimer under the
  composer.
- Favicons: the sites' own favicons (Google favicon service, neutral User-Agent).
- Typed text uses the composer's real style (Ubuntu 600, caret coral), from
  `chat_ui_desktop.dart`.
- Fidelity fixes after the side-by-side: field 17 px (not 16), field text 1 px left of the
  padding box, Fast pill padding 11 px, disclaimer 11.5 px, bubble and answer 16.4 px,
  timeline labels and chips 12.7 px, bubble radius 16 on all corners.
- No sound effects: the music is final.
- Claim fixes (2026-10-26, CodeRabbit + coordinator): s05 "This is all our server ever
  sees." -> "This is all our server stores." (inference is not end-to-end). s08a "Never used
  for training." -> "Your key never leaves your device." at 100 px (112 px ran to 30 px of
  the frame edge; 100 px keeps it inside the action-safe box). Timing and look unchanged.
- Reproducible build: `_work/build.py` reads the code shot from the repo relative to the
  script, copies the vendored GSAP (`marketing/videos/_lib/assets/js/gsap.min.js`) into
  `assets/js/` (no CDN at render time), copies the music from
  `marketing/_shared/music/07-chasing-horizons-62s.wav` (gitignored; source in
  `marketing/videos/_lib/README.md`, section Music) and stops with a clear message if it
  is missing. Scene hosts carry `class="clip"`; every timeline registry is initialised.
- Frame 0 shows only the canvas (check: `first_frame_empty`). Left as is: the owner approved
  this look and timing; set a thumbnail on the platform instead.
- End card (owner fix): official lockup only. Mark = `assets/img/logo.svg` (copy of
  repo `assets/logo.svg`), 440 px box, centred. Wordmark = `assets/img/wordmark.svg`
  (copy of repo `assets/wordmark.svg`) inlined as-is at 900 px wide, fills recoloured to
  ink #2A1F17, slogan group keeps its fill-opacity 0.55. No re-typed name or slogan.
  `chuk.chat` in Liberation Mono Regular (embedded), 30 px, ink soft.

## Checks

- `npx hyperframes check`: ok, 0 errors. 4 contrast warnings kept: three are the s02
  first frame while the piece fades in from opacity 0, one is the real bubble colours
  (#E8E4D8 on #B6674D, 3.3:1), which are the app's.
- Info-level overflow on the push-ins (s03, s07) is the intended crop.

## Weakest shot

s07 end state: the code panel shrinks to 0.72 so the serif line fits; the code is then
about 22 px. It was readable at 30 px during the push-in.
