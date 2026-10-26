# REVIEW: chuk-10-private-images

Outputs: `marketing/out/10-private-images.mp4` (1920x1080) and
`marketing/out/10-private-images-vertical.mp4` (1080x1920), 45.0 s each, 30 fps, H.264 + AAC,
`--quality high --gpu -w 4`.

## Build

```
python3 _work/make_assets.py   # once: gen/bruno.jpg (+ other1-4), request body, real ciphertext -> _work/cipher.json
python3 _work/episode.py       # both projects (this folder and ../chuk-10-private-images-vertical)
flutter test marketing/videos/chuk-10-private-images/_work/fidelity_test/real_widgets_test.dart   # from the repo root
python3 _work/fidelity.py      # sheets in _work/fidelity/
```
Edit `_work/episode.py`, never `compositions/`.

## Decisions

- Hook (own): the finished watercolour paints itself in on a paper print, "One picture of
  Bruno. / Where does it go?". Bridge (own): "Here's how it was made." No 08/09 lines reused.
- The picture: `_work/bruno.html`, an SVG watercolour (seeded turbulence washes, dried rims,
  paper grain), no paid generation. 1536x1152 = the server default landscape_4_3, saved as
  JPEG q85 like ImageCompressionService. The four older library tiles are graded crops of it.
- Request card: the exact body of `build_openrouter_image_request()` (model krea/krea-2-large,
  the default; n 1; provider policy; aspect_ratio 4:3), key order kept. Titled "Image request ·
  openrouter.ai" as a server view in the light card look of 08/09; the server code itself is not
  shown (it is not public).
- RAM shot on the brown block: the vault TTL is 900 s, shown as a 15:00 ring counting down;
  the entry is popped on the first GET, timed to the 27.48 hit, then "deleted".
- Storage: `images/<uid>/<uuid>.enc`; the object size (182 KB) is the real length of the
  encryptBytes JSON of the JPEG. The media manager shows the same object as "182.5 KB"
  (`_formatFileSize` of Storage metadata.size) and the date `26/10/2026` (`_formatDate`).
- The media manager never prints file names, so `.enc` is shown in Storage (s07) and the
  manager shows what the app does with it: tiles decrypt one by one, hover gives date · size.
  9:16 keeps the desktop modal (a phone-width window would switch the page to the mobile
  grid); 760 app px panel = window >= 800, so the desktop grid is the honest one.
- Fidelity (`_work/fidelity/*.jpg`, real above, rebuild below, both 2 px per app px):
  generating.jpg and done.jpg = the REAL MessageBubble with a running / finished
  generate_image call (content blocks, Clawed theme); modal.jpg = the REAL DesktopMediaModal
  (its body shows the no-session error, only the chrome is compared); grid.jpg = toolbar,
  _MediaFilterBar and _ImageTile copied verbatim from media_manager_page.dart (private classes)
  with the public FloatingHeaderButton / FloatingChromeSurface. Findings used: header reads
  "Generating image for Ns ⌄" while running and "Worked for 9s >" (collapsed, step hidden)
  when done; loader #4A4A49; tile #41413E radius 18; track #31312F.
- Type: Storage 32/30 px and JSON 32 px in 16:9, 36/34 and 34 px in 9:16. App chrome text in
  the chat (step row, loader labels, model pill) stays app-scale, like 08/09; the media manager
  date · size line is read only after the push-in (38 px in 16:9, 36 px in 9:16).
- No sound effects, no new music.

## Claim fix (2026-10-26)

- s09 "Made privately. / Kept privately." -> "Zero retention. / Then encrypted." The old
  line could read as "the server never sees the prompt or image". The new one says only
  retention + storage (PRIVACY_CLAIMS.md: Generated images). Other lines checked: "Made with
  zero data retention.", "Kept in server memory: 15 minutes at most.", "Deleted on the first
  download.", "Then stored encrypted.", "Opened on your device." stay. Timing and look
  unchanged.
- `_work/cipher.json` no longer holds the unused vault token and envelope (secret-scanner
  noise, never read by episode.py); `make_assets.py` writes only what the film uses.

## Checks

- `npx hyperframes check`: ok, 0 errors in both. Warnings kept: app-scale UI text under the
  28 px floor (step row, loader, pill, disclaimer; same as 08/09), read-time on the typed prompt,
  loader label contrast 3.65:1 (the app's own colours).
- A GPU snapshot once showed a canvas-coloured hole in the media modal at 38.1 s; SwiftShader and
  the final MP4 frame (`_work/final/f-37.9.png`) are clean.
- Full-size frames decoded from both MP4s in `_work/final/` and `../chuk-10-private-images-vertical/_work/final/`.

## Weakest shot

s03 in 16:9: the 4:3 image at 2.2x is taller than the frame, so the view pans after the image
lands and the "Worked for 9s" header leaves the top edge.
