# REVIEW: chuk-09-your-files

Outputs: `marketing/out/09-your-files.mp4` (1920x1080) and `marketing/out/09-your-files-vertical.mp4`
(1080x1920), 45.0 s each, 30 fps, H.264 (h264_nvenc) + AAC, `--quality high --gpu -w 4`.

## Build

```
python3 _work/make_assets.py   # once: lab-report.jpg + real ciphertext -> _work/cipher.json
python3 _work/episode.py       # both projects (this folder and ../chuk-09-your-files-vertical)
flutter test marketing/videos/chuk-09-your-files/_work/fidelity_test/real_widgets_test.dart   # from the repo root
python3 _work/fidelity.py _work/final/f-23.6.png ../chuk-08-what-we-see/_work/final/f-22.6.png
```
Edit `_work/episode.py` or `marketing/videos/_lib`, never `compositions/`.

## Decisions

- Ciphertext: the stored photo bytes (1440x1920 JPEG, the 1920 px cap of
  ImageCompressionService) through `encryptBytes` exactly: AES-256-GCM, 12-byte nonce,
  jsonEncode `{"v":"1","kv":1,"nonce","ciphertext","mac"}`. Random key, thrown away. The
  object size in the list (299 KB) is the real length of that JSON. Neighbour objects are
  real ciphertext of random bytes.
- Path: `images/<user_id>/<uuid>.enc` (bucketName `images`, `_encryptAndUpload`); one
  neighbour is a `.file.enc` (uploadEncryptedBytes) because the folder really holds both.
- The lab report is fictional ("Northfield Example Laboratory", "Alex Sample", SAMPLE stamp,
  footer "Fictional sample report ... Not a real patient."), rendered from `_work/lab_report.html`.
- Fidelity: the reference halves are the REAL Flutter widgets rendered in a widget test
  (Clawed dark theme): AttachmentPreviewBar, MessageBubble (user + image) and the drop
  overlay block copied from chat_ui_desktop.dart. Fixes found: the thumbnail shows the whole
  photo squashed (Image.memory cacheWidth+cacheHeight 144), so `object-fit: fill`; the drop
  text has 0.25 letter-spacing (bodyMedium). Pixel samples of chip, badge and frame match.
- Storage has no app widget and no public screenshot without logging in: rebuilt in the
  same card, type scale and colours as 08's approved Supabase table editor (`storage.jpg`).
- Step text "User shares a thyroid panel and asks what it means." only, no search chips: the
  answer reads the image, a web search would be invented.
- Server-view mono has ligatures off so `==` in the MAC stays two characters.
- No new music, no sound effects.

## Claim fix (2026-10-26)

- s07 "Your scans stay yours." -> "Stored as ciphertext. / Only you hold the key." (16:9 two
  lines, 9:16 four lines). The old line could read as "the server never sees the file";
  the file and prompt go to the API and the model in plain text to answer. The new line says
  only storage + key (PRIVACY_CLAIMS.md: Files and images, Key). Other lines checked: "Storage
  only holds ciphertext." and "Encrypted on your device, before it's stored." stay. Timing
  and look unchanged.

## Checks

- `npx hyperframes check`: ok, 0 errors in both. Warnings kept: app-scale UI text under the
  28 px floor (Worked step, disclaimer, pills; same as 08), the bubble colours 3.3:1 (the
  app's), read-time warnings on ciphertext texture and the typed prompt.
- Full-size frames of both MP4s in `_work/final/` and `../chuk-09-your-files-vertical/_work/final/`.

## Weakest shot

s05 in 16:9: file names at 26 px are small next to the serif lines; they are readable at
full size, but on a phone the 9:16 cut is the one to post.
