# REVIEW: chuk-12-memory

Outputs: `marketing/out/12-memory.mp4` (1920x1080) and `marketing/out/12-memory-vertical.mp4`
(1080x1920), 45.0 s each, 30 fps, H.264 + AAC, `--quality high --gpu -w 4`.

## Build

```
python3 _work/make_assets.py   # once: real ciphertext -> _work/cipher.json, icons + lock emoji -> _work/gen/
python3 _work/episode.py       # both projects (this folder and ../chuk-12-memory-vertical)
flutter test marketing/videos/chuk-12-memory/_work/fidelity_test/real_widgets_test.dart   # from the repo root
python3 _work/fidelity.py      # fidelity sheets + diff images
```
Edit `_work/episode.py` / `_work/ui12.py`, never `compositions/`.

## Decisions

- Ciphertext is real AES-256-GCM in the app's `encrypt()` envelope
  `{"v":"1","kv":1,"nonce","ciphertext","mac"}` (random key, thrown away).
  encrypted_meta = jsonEncode `{"v":1,"tbl":"projects","row":<id>,"name","description",
  "custom_system_prompt"}` sealed, like `EncryptedMeta.encode` (short strings go through
  `encrypt()`); plain columns `🔒` / NULL / NULL, as `sealedProjectColumns` writes them.
  identity_memory = `encrypt(trimmed memory text)` (71 B -> 188-char envelope, shown whole).
  Neighbour rows are real ciphertext of plausible plaintext.
- Memory lives on the AI Identity & Memory page (account-wide), not inside the workspace; the
  film shows the two pages in sequence and never says the memory belongs to the workspace.
  Lines are written with "- " (typable), not the "•" of the l10n example.
- Fidelity: the reference halves are the REAL widgets rendered in a widget test (Clawed dark,
  contrast .55, JetBrains Mono as chat font like 08/09). Both pages are State-heavy (storage
  service, Supabase), so their build bodies are copied verbatim into the test; every widget
  inside is the real one. Test-only change: family-less TextStyles get Ubuntu (the app uses the
  system font; in a test they render as boxes). Sheets: `_work/fidelity/workspace.jpg`,
  `memory.jpg` (+ `diff-*.png`). Layout matches to about 1 app px.
- Icons: HugeIcons SVGs from `assets/icons/hugeicons` (what AppIcon draws); where icon_map
  has no HugeIcon (rocket_launch_outlined = the workspace's displayIcon, save,
  open_in_full_rounded, download_outlined) the Material glyph outline from Flutter's
  MaterialIcons font, extracted with fontTools.
- Workspace colour #8B5CF6 and rocket icon = `Workspace("Tax helper").displayColor/displayIcon`
  (printed by the test, `_work/fidelity/theme-values.txt`).
- The Settings tab is shown scrolled to the Custom System Prompt card: at scroll 0 the real
  page draws the identity card under the tab bar (see "App bug" below).
- Server views: 16:9 = 08's table editor, type raised to 30 px; 9:16 = Supabase's row editor
  side panel in the same light look, 34 px. The viewer bar names the row by its masked id,
  never by the workspace name (the database has none).
- Own hook "What does your AI remember about you?" and bridge "What reaches our database?";
  no 08/09 lines reused. No sound effects, music only.

## Checks

- `npx hyperframes check`: ok, 0 errors in both. Warnings kept: contrast 2.6:1 on the disabled
  "Save changes" (the app's disabled colours), app-scale UI text under the 28 px craft floor
  (tab badges, info card, subtitles at 2.2x), read-time warnings on ciphertext and typed text.
- Table / list / code text: 30 px+ (16:9), 34 px+ (9:16). App field text 35 px (16:9) /
  40 px (9:16); memory mono 31 / 35 px.
- Full-size frames decoded from both MP4s in `_work/final/` and
  `../chuk-12-memory-vertical/_work/final/`.

## App bug found (not fixed, outside this task)

`workspace_detail_page.dart` `_buildSettingsTab` (and the Files/Chats tabs) pads with
`floatingHeaderInset(context)` without `extra:` for the TabBar, from the State's context above
the Scaffold, so the first card starts under the tab bar (visible in
`_work/fidelity/real-workspace.png`). Fix: `floatingHeaderInset(context, extra: kTextTabBarHeight)`.

## Weakest shot

s05 16:9 table: the encrypted_meta column is cut after 44 characters, so the opened viewer
carries the proof; the table itself mainly shows the 🔒 / NULL column pattern.
