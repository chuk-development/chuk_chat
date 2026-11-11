# SPEC: chuk-07-launch

GOAL:    The viewer sees one private chat do everything he asks (search, map, file, numbers,
         models, tools, every device) and remembers "Chuk Chat. Private and Secure. Always."
OUTPUT:  HyperFrames, 1920 x 1080, 30 fps, 62.0 s = 1860 frames.
TIME:    Music `assets/audio/music.wav` (07-chasing-horizons-62s), 122.2 BPM, beat 0.491 s
         (14.7 frames), bar 1.964 s. First beat 1.97 s. Loud section from 17.7 s, break
         26.0-28.4 s, surge 36.0 s, tail fades 60.5-62 s. Every scene cut sits on a beat.
LOOK:    Ground #F4EEE4 with 1 px grid #E6DCCD every 48 px. Tan field #DCCBB4 (title and end
         cards). Brown field #5C4033 once (encryption), text on it #F4EEE4.
         Ink #2A1F17, ink soft #6E5D4E. UI surface #FFFDF9, border 2 px #E2D6C6, user bubble
         #EADFCF, accent #8B5A2B (send button, ticks, star mark, route, the one bar).
         Shadow on floating UI only: 0 8px 30px rgba(42,31,23,.08). No glow, no coloured shadow.
         Headlines: Newsreader Display 600, sentence case, 76-110 px, tracking -1%.
         UI text: JetBrains Mono (the app font) 28-44 px. Nothing below 28 px except the phone.
         Medium: the real Chuk Chat UI, rebuilt light, at 1.2-2x its real size.
OBJECTS: CC mark (assets/img/logo.svg, inlined), composer (text field, send circle top right,
         + button, Fast pill, mic), chips, user bubbles, source rows, map card with water,
         streets, three pins and a route, ciphertext bubble with lock, PDF file message,
         progress list, bar chart card, model pill + list with real model logos, connector
         tiles with real logos, desktop window + phone. Cursor: black arrow with white
         outline, 68 px tall; white hand with ink outline on buttons.
MOTION:  Enter expo.out / power4.out 0.4-0.6 s. Camera power2.inOut 1.2-2.2 s.
         Exit power3.in 0.25-0.35 s. Cursor moves power2.inOut 0.7-1.0 s, click =
         scale 0.86 for 0.08 s and back. Typing 18 chars/s. Text holds >= 1.2 s after it ends.
SHOTS:
  01  0.00- 2.46  tan card "Meet Chuk Chat." words grey -> ink. Hard cut on beat.
  02  2.46- 7.87  greeting (mark + "What's on your mind, Lea?"), composer widens, chips pop.
                  Cursor clicks "Plan a trip", pill drops into composer, camera pushes 1.2x.
  03  7.87-15.73  composer at 1.2x: prompt types, cursor clicks send. Bubble, star +
                  "Searching the web...", three source rows.
  04 15.73-19.59  map card: pins drop, route draws, push-in 1.45x on the route.
  05 19.59-27.52  the prompt bubble; ground floods brown; text scrambles to ciphertext,
                  lock lands; "Encrypted on your device. / Only you can read it."; Made in
                  Germany. Brown panel wipes up off frame.
  06 27.52-33.42  follow-ups type in place, right aligned; cursor drags bank-statement.pdf in.
  07 33.42-39.34  progress list ticks (Read the PDF / Find coffee / Add it up); blur swap to
                  chart card "EUR 42.80 this month" on the 36 s surge.
  08 39.34-45.23  composer + model pill; cursor opens list of six models, picks Kimi K3;
                  "Every open model. One price."
  09 45.23-49.16  six connector tiles pop in, cursor connects Notion; "Connect the tools you
                  already use."
  10 49.16-52.60  desktop window + phone, light theme, same chat. Only full-window shot.
  11 52.60-56.53  tan card "What will you ask next?"
  12 56.53-62.00  tan end card: mark rises in, "Chuk Chat" wipes in, slogan. Hold to end.
BANNED:  dark app windows, painted skies, "01 / 13" counters, glow, coloured box-shadow,
         text-glyph icons, titles that drift after landing, everything fading up at once,
         TTS, voice, generated music.
QA:      2.0, 6.0, 11.5, 14.8, 18.8, 24.5, 32.8, 38.0, 43.5, 48.5, 51.5, 55.0, 60.5
         at 1920x1080: all text readable, nothing clipped, cursor on its target.
