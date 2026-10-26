# SPEC: chuk-10-private-images (privacy series, episode 10)

GOAL:    "Zero retention. Then encrypted." A generated watercolour of Bruno comes out of the real
         image block; the request carried zdr / data_collection deny / allow_fallbacks false, the
         result sat in server RAM until its first download, Storage holds it as `.enc`, and the
         media manager decrypts it on the device.
CLAIM:   PRIVACY_CLAIMS.md, Generated images (may say): made with zero data retention (`zdr`,
         `data_collection: deny`), kept in server RAM at most 15 min, then stored encrypted.
         Evidence: api_server routers/ai/images.py:51-60 (policy), 427-442 (request body),
         75-87 + 876-897 (vault TTL 900 s, dropped on first GET); app
         tool_image_result_service.dart:247,347 -> image_storage_service.dart _encryptAndUpload
         (`<uid>/<uuid>.enc`), listUserImages (only `.enc`), downloadAndDecryptImage.
         Not said: "the server never sees your prompt/image", "end-to-end".
OUTPUT:  16:9 1920x1080 (this folder) and 9:16 1080x1920 (`../chuk-10-private-images-vertical`),
         30 fps, 45.0 s, both from `_work/episode.py` + `marketing/videos/_lib`.
TIME:    `s2-sky-falling-45s.wav`, 122.6 BPM, beat 0.49 s. Cuts on beats: 3.19 9.55 17.41 19.86
         24.75 29.95 33.84 38.24 40.70. Quiet dip 18-19.8 holds the bridge card; the strongest
         hit 27.48 is the moment the image is deleted from RAM; fade 42-45 under the end card.
LOOK:    exactly 08 (canvas + grid, tan, brown block once, ink, Newsreader 600, real dark app UI,
         cursor, typing 18 chars/s, push-ins). Own hook and bridge (not 08's / 09's).
SCALE:   16:9 composer 2.2, chat 2.2 (column 570), media modal 1.7 (panel 1000) then push 1.85;
         9:16 composer 1.9, chat 2.2 (column 440), modal 1.36 (panel 760) then push 2.45.
SHOTS:
  s01  0.00- 3.19  canvas: the watercolour paints in on a paper print. "One picture / of Bruno.
                   / Where does it go?"
  s02  3.19- 9.55  real composer, I-beam, types "a watercolour of our dog Bruno on the beach",
                   hand clicks send.
  s03  9.55-17.41  user bubble; "Generating image for 2..5s", step "Ran generate image <prompt>"
                   (flash badge), loader tile 4:3 (sparkle, spinner, Generating…, 1024 × 768);
                   the image lands with the "Krea 2 Large" pill, header turns "Worked for 9s >",
                   the step folds, answer line streams.
  s04 17.41-19.86  canvas: "Here's how it was made."
  s05 19.86-24.75  light card "Image request · openrouter.ai": the exact request body, the
                   provider block (zdr true, data_collection deny, allow_fallbacks false) marked.
                   "Made with zero data retention."
  s06 24.75-29.95  brown block: ring timer 15:00 counting in "server RAM"; on the 27.48 hit the
                   ring empties -> "deleted". "Kept in server memory: / 15 minutes at most." +
                   "Deleted on the first download."
  s07 29.95-33.84  Supabase Storage list images/<uid masked>: the new `<uuid>.enc` (182 KB, real
                   ciphertext length) selected above older `.enc` objects. "Then stored encrypted."
  s08 33.84-38.24  the real Media Manager modal: tiles decrypt one by one (spinner -> picture),
                   hover on Bruno: actions + "26/10/2026 · 182.5 KB", push-in. "Opened on your device."
  s09 38.24-40.70  tan: "Zero retention. / Then encrypted."
  s10 40.70-45.00  tan end card: logo.svg + wordmark.svg, chuk.chat.
TYPE:    tables/lists/code >= 30 px in 16:9 (Storage 32/30, JSON 32), >= 34 px in 9:16 (36/34, 34).
BANNED:  invented UI, light chat UI, feature selling, "nobody can see it", "the server never sees
         your images", glow, coloured shadows, text-glyph icons, paid image generation, real pets'
         photos.
