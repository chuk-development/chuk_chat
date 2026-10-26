# chukvid: the shared generator for the privacy series

The look of `chuk-08-what-we-see` (approved), as a Python package. An episode is one
spec file (`<episode>/_work/episode.py`) plus its own scene code. The package writes a
normal HyperFrames project per format. Series rules: `marketing/_shared/SERIES-PRIVACY.md`.
Claims: `marketing/_shared/PRIVACY_CLAIMS.md` ("may say" only).

## Layout

| File | What it holds |
|---|---|
| `chukvid/core.py` | `Format` (`LANDSCAPE` 1920x1080, `VERTICAL` 1080x1920 with safe zones top 220 / bottom 380), colour tokens (`@CANVAS@`, `@INK@`, `@BG@` ...), HugeIcons `hi()`, brand `logo()` / `wordmark()` (read from repo `assets/`), cursor (arrow, hand, I-beam), shared CSS and JS helpers (`hfType`, `hfClick`, `hfShape`, `hfReveal`, `hfStream`, `hfHash`), `Episode` (scenes, assets, `index.html`, `hyperframes.json`, `package.json`, `meta.json`, `.gitignore`). |
| `chukvid/ui.py` | The real app, 1:1: `appz()` zoom box, `composer()` (with attachment row), `disclaimer()`, `attach_card()`, `drop_overlay()`, `user_message()` (image above the coral bubble), `worked()` + `worked_js()`, `answer()`. Server side: `db_table()` (Supabase table editor), `envelope_viewer()` (opened cell / object), `storage_list()` (Supabase Storage). Every value names its source widget. |
| `chukvid/scenes.py` | `card()` (serif line card on canvas, tan or brown) and `end_card()` (official lockup only). |
| `chukvid/cipher.py` | Real AES-256-GCM: `encrypt_bytes()` = `EncryptionService.encryptBytes` envelope `{"v":"1",...}` (images, files), `seal_chat()` = `sealChatPayload` envelope `{"v":"2",...}` (chats). Key random, thrown away. Also `human_bytes()` = `formatBytes`. |
| `chukvid/beats.py` | `ensure()` runs `npx hyperframes beats` once, `cuts()` snaps rough cut targets to the beat grid. |
| `chukvid/fidelity.py` | `harness()` renders a library piece alone with the project fonts; `sheet()` puts the real app above the render. |
| `assets/` | Fonts (Newsreader 600, JetBrains Mono, Ubuntu, Liberation Mono) and the app icon sprite. |

## Make a new episode

1. Copy `chuk-09-your-files/_work/` as the pattern: `make_assets.py` (real ciphertext,
   episode images), `episode.py` (the spec), `fidelity.py` (+ `fidelity_test/` if the
   episode shows an app piece the library does not have yet).
2. In `episode.py`: set `MUSIC`, the prompt/answer, `TARGETS` (rough cut times; they snap
   to the beat grid), and write one function per scene. Each scene gets `fmt.vertical`
   and lays itself out for that format: in 9:16 stack the pieces, use a larger UI zoom,
   split serif lines to about 3 words, and keep text between y 220 and y 1540.
   Never crop the 16:9 frame.
3. `build(fmt, folder)` makes the project: `Episode(...)`, `ep.asset(...)`, `ep.write()`,
   `beats.ensure()`, scenes, `ep.write()`. Run `python3 _work/episode.py`: it writes
   `chuk-NN-slug/` and `chuk-NN-slug-vertical/`.
4. A new app piece goes into `ui.py`, rebuilt from the widget in `lib/` (colours, radii,
   sizes, the theme). Render the real widget in a widget test (`fidelity_test/`, run from the
   repo root with `flutter test <path>`; its own `flutter_test_config.dart` keeps `.env`
   unread) and make a sheet with `fidelity.harness()` + `fidelity.sheet()`.
5. Gate and render, one at a time, in each project folder:
   `npx hyperframes@0.8.202 check --json`, `snapshot --at ...` (look at full-size frames),
   then `npx hyperframes@0.8.202 render --quality high --gpu -w 4 --output ../../out/NN-slug.mp4`.
   Decode check frames with `ffmpeg -hwaccel cuda -ss T -i out.mp4 -frames:v 1 f.png`.

Edit the spec, never `compositions/` by hand: every run of `episode.py` rewrites them.

## Fixed rules the code enforces

- Brand: `assets/logo.svg` + `assets/wordmark.svg` from the repo, only recoloured;
  `chuk.chat` in Liberation Mono. Never re-typed.
- No glow, shadows neutral black only, icons SVG (HugeIcons / Material path / Lucide shapes).
- Typing 18 chars/s, cursor moves eased with a press scale.
- Mono text in server views has ligatures off (`==` stays `==`); app text keeps them, like Flutter.
