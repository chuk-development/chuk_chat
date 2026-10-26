# SPEC: chuk-08-what-we-see

GOAL:    The viewer remembers one thing: "This is all we see." A private question goes
         into the real Chuk Chat; our server stores only ciphertext.
OUTPUT:  HyperFrames, 1920 x 1080, 30 fps, 62.0 s = 1860 frames.
TIME:    Music `assets/audio/music.wav` (07-chasing-horizons-62s), 122.2 BPM, beat 0.49 s.
         Cuts on beats: 3.42 9.84 17.70 20.04 29.00 35.88 43.77 46.73 49.66 52.60.
LOOK:    Canvas #F4EEE4, grid #E6DCCD every 48 px, tan #DCCBB4, colour block #5C4033 once,
         ink #2A1F17, ink soft #6E5D4E. Serif Newsreader Display 600, 92-132 px.
         App pieces use the real app values (measured, same as the chuk.chat rebuild):
         surface #262624, text #E8E4D8, composer outline 2 px #615F5A radius 30,
         send #D97757, user bubble #B6674D + 1 px rgba(232,228,216,.3), radius 16.
         Messages and answer: JetBrains Mono 16.4 app px. UI labels: Ubuntu 600/500.
         Icons: the app's HugeIcons SVGs. Shadows neutral black only. No glow.
SCALE:   Screenshot = 1.75 px per app px. Composer shot 2.2, chat shot 2.0 px per app px.
SHOTS:
  s01  0.00- 3.42  tan: "Some questions you'd / never ask out loud."
  s02  3.42- 9.84  dark window piece with the real composer. I-beam clicks in, caret,
                   types the ferritin question at 18 chars/s, hand clicks send.
  s03  9.84-17.70  coral bubble, "Worked for 2s", thought + Searched step, chips
                   nhs.uk / mayoclinic.org / aerzteblatt.de (real favicons), answer
                   streams (4 lines). Push-in 1.4x on the bubble.
  s04 17.70-20.04  canvas: "Here's what we store."
  s05 20.04-29.00  Supabase-style table encrypted_chats (id, user_id masked,
                   encrypted_payload, updated_at). Base64 slides through the cell, cursor
                   selects and opens it: the real envelope {"v":"2","kv":1,nonce,
                   ciphertext,mac}. "This is all our server ever sees."
  s06 29.00-35.88  brown block: the bubble text scrambles into the same ciphertext,
                   lock lands. "Encrypted on your device. / With a key only you hold."
  s07 35.88-43.77  GitHub file view (dark), chuk-development / chuk_chat,
                   lib/services/encryption_service.dart lines 52-67 verbatim
                   (sealChatPayload). Push-in on AesGcm.with256bits(), then the nonce.
                   "Don't trust us. Read the code."
  s08 43.77-52.60  "Never used for training." / "No ads. No tracking." (tan) /
                   "Run from Germany, under EU law."
  s09 52.60-62.00  tan end card: CC mark, "Chuk Chat", "Private and Secure. Always.",
                   chuk.chat. Hold to the end.
BANNED:  invented UI, light chat UI, feature selling (search, charts, maps, models,
         connectors), "nobody can read it", "not even the AI", glow, coloured shadows,
         text-glyph icons, TTS, voice, generated music.
