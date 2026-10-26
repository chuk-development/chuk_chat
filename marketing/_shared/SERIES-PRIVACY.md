# Chuk Chat privacy series (from 2026-10-26)

Owner decision: video 08 (`marketing/videos/chuk-08-what-we-see`) is the
approved look. Make many more in the same design, one feature per video,
always with a privacy point, and publish them steadily for volume.

## Fixed for every episode

- **Look:** exactly 08. Anthropic no-people grammar
  (`marketing/_review/anthropic-ref/ANALYSIS.md`): brown paper canvas
  `#F4EEE4` with grid `#E6DCCD`, tan `#DCCBB4`, brown colour block `#5C4033`,
  ink `#2A1F17`, Newsreader serif lines, one big UI piece per shot, cursor,
  real typing, push-ins, cuts on beats.
- **UI:** the real app UI rebuilt 1:1 (dark warm grey, coral bubble, mono
  text), from `assets/screenshots/*.webp` and `~/git/chuk.chat` partials.
  Every new UI piece gets a fidelity image (real crop vs render) in `_work/fidelity/`.
  If a screen has no real screenshot, rebuild it from the Flutter widget
  code in `lib/` (colours, radii, sizes from the theme), never invent.
- **End card:** `assets/logo.svg` + `assets/wordmark.svg` as-is (only
  recoloured), `chuk.chat` in Liberation Mono. Never re-type the brand.
- **Claims:** only from `marketing/_shared/PRIVACY_CLAIMS.md` ("may say").
- **Length:** 45 s. **Formats:** 16:9 1920x1080 for YouTube and 9:16
  1080x1920 for Shorts/Reels/TikTok (same story, re-laid out, not cropped).
- **Render:** `--quality high --gpu -w 4`. Never CPU encoding.
- **Output:** `marketing/out/<nn>-<slug>.mp4` and `marketing/out/<nn>-<slug>-vertical.mp4`.
- **Shared code:** `marketing/videos/_lib/` (built from 08's `_work/build.py`).
  An episode is one spec file plus its own scene bits.

## Episodes

| # | Slug | Music | Privacy point (from PRIVACY_CLAIMS.md) | Story beat |
|---|---|---|---|---|
| 09 | your-files | s1-summer-bells-45s | Photos, scans and files are encrypted on your device before they are stored. | Drag a photo of a lab report into the composer, ask "what does this say about my thyroid?". Answer. Cut: the storage bucket listing `images/<uid>/<uuid>.enc`, open one: ciphertext. "Stored as ciphertext. / Only you hold the key." (storage + key only; never that the server or the model does not see the file) |
| 10 | private-images | s2-sky-falling-45s | Generated images are made with zero data retention, kept in server memory at most 15 minutes, then stored encrypted. | Type "a watercolour of our dog Bruno on the beach", the real image block generates. Cut: the request flags `"zdr": true, "data_collection": "deny"` highlighted, then the media manager showing the image as `.enc`. "Zero retention. / Then encrypted." (retention + storage only; never that the server does not see the prompt or image) |
| 11 | local-search | s3-english-garden-45s | Searching your chats happens on your device. | Real sidebar search, type "landlord", results appear instantly. A small counter "Requests while you search" stays at 0: scoped to the sidebar search filter, which filters in memory (desktop) or in an isolate (phone) and sends no request. Not a claim about the whole app or the search_chats tool. "There is no server search." |
| 12 | memory | s4-every-beat-45s | Instructions and memory are encrypted on your device before they are stored. | Workspace "Tax helper" with custom instructions and a memory line ("I'm self-employed since 2024"). Cut: the stored row is ciphertext. "It remembers you. Encrypted." |
| 13 | connectors | s1-summer-bells-45s | Connector sign-in runs between your device and the service; tokens stay in your device's secure storage. (Notion, Linear, Todoist only, never GitHub.) | Connect Notion: browser sign-in, back in the app, "Connected". Cut: "Stored in your device keychain". "Your logins stay with you." |
| 14 | just-an-email | s2-sky-falling-45s | An email and a password. No phone number. No tracking SDK in the app. Delete your account any time. | Real sign-up form, only email + password, typed. "No phone number. No ads, no tracking SDK in the app." Then account deletion dialog. "Leave whenever you want." |
