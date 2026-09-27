# 02 — Nobody's reading

- Length: about 45 s. Music: `02-nobody-reading.wav` (tense minor pulse,
  then a release into warm major). Put the release exactly on the switch to
  Chuk Chat.
- Message: "Your chat is encrypted before it leaves your device."
- Angle: privacy as a visual. Split screen.

## Shape

1. Hook (0–3 s): one message types itself in a plain box:
   "How do I tell my boss I am burned out?" Text: "Everything you type into
   an AI goes somewhere."
2. Tension (3–20 s): the message travels as a card along a line to a server
   rack. On a neutral, unbranded, grey chat (never a real competitor) it
   arrives as readable text and collects stamps: "stored", "logged",
   "may be used for training". Cold, clinical. Ticking pulse.
3. Switch (20–22 s): hard cut / wipe on the music release. "Or…"
4. Chuk Chat (22–38 s): the same message in the real dark Chuk Chat window.
   On send, the text scrambles into ciphertext (base64-like noise) on the
   device, before it leaves. It travels to the server as noise. Server card
   from the site: "What our server stores" → ciphertext only, "AES-256-GCM ·
   the key stays on your device". Back on the device the answer appears
   readable: "Start with facts, not with blame." (from the site mock).
5. Claim (38–41 s): "We keep only ciphertext. Never used for training."
6. End card (41–45 s).

Look for a scramble/decrypt text effect with `npx hyperframes catalog --query "text scramble decrypt"` before you build one.
