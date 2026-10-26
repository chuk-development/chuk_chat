# REVIEW: chuk-14-just-an-email

Outputs: `marketing/out/14-just-an-email.mp4` (1920x1080) and `marketing/out/14-just-an-email-vertical.mp4`
(1080x1920), 45.0 s each, 30 fps, H.264 (h264_nvenc) + AAC, `--quality high --gpu -w 4`.

## Build

```
flutter test --dart-define=SUPABASE_URL=https://example.supabase.co --dart-define=SUPABASE_ANON_KEY=example \
  marketing/videos/chuk-14-just-an-email/_work/fidelity_test/real_widgets_test.dart   # from the repo root
python3 _work/make_assets.py   # layout probe -> _work/layout.json (after any pieces.py change)
python3 _work/episode.py       # both projects (this folder and ../chuk-14-just-an-email-vertical)
python3 _work/fidelity.py      # sheets in _work/fidelity/*.jpg
python3 _work/check.py .       # hyperframes check, one line per finding
```
Edit `_work/episode.py` / `_work/pieces.py`, never `compositions/`.

## Decisions

- Hook: an unbranded light "other apps" form (Full name, Phone number +1, Date of birth,
  "Step 1 of 3") plus a contacts permission sheet. Line "Some apps want all of this." (not
  "most apps"). Bridge lines are new: "We ask for two things.", "And when you want to leave?".
- "Two things" = email and password. The real form also shows the optional Display name, the
  Confirm password repeat and the Terms / 16+ boxes; all are shown as they are, the display
  name stays empty. The 16+ box is a checkbox, not a date of birth (true to login_page.dart).
- Every app piece is rebuilt from the widget code (`_work/pieces.py`) and checked against the
  REAL widgets rendered in a widget test: LoginPage (sign-up mode, empty / typing / filled),
  OtpVerificationPage, the Danger zone and the three AlertDialogs of `_deleteAccount`.
  The test passes fake SUPABASE_* dart-defines only to hide the "not configured" notice;
  `.env` is never read (flutter_test_config.dart). The app's button text style names no font
  (system font = Ubuntu on the owner's desktop); the test sets Ubuntu explicitly.
- Fixes found by the sheets: field text and floated label sit at x 20 (also over a prefix
  icon), the meter label and requirement rows are 17 px tall, TextButtons take 48 px (tap
  target), dialog body text is full fg colour, the code field is 64 px tall.
- The live strength meter walks every prefix of "Tide-Lantern-48!" through
  `InputValidator.validatePasswordStrength` (Weak/Fair/Good with the requirement list, then
  Strong); the card re-centres like the real `Center(SingleChildScrollView)`. Positions for
  the cursor and camera come from a layout probe in headless Chrome (`layout.json`).
- Deletion shows the full real flow: step 1 (erase list incl. "Any active subscriptions"),
  step 2, step 3 with the password, Verify & Delete -> spinner. The Danger zone note says
  "will cancel all subscriptions" (matches routers/billing/user.py).
- Legibility: lists at full size: 16:9 requirement list 12 x 2.6 = 31 px, dialog list
  14 x 2.25 = 31.5 px; 9:16 34.8 px and 34.3 px. In 9:16 the app view is clipped to the
  safe band y 220-1540. Email sam@example.com, code 482915 (fictional).
- No new music, no sound effects.

## Checks

- `npx hyperframes check`: ok, 0 errors in both. Warnings kept: app-scale floated labels
  (10.5 app px) under the 28 px floor, app colours below AA (floated labels, link text,
  disabled button), read-time warnings on the dialog bodies, s03 file length.
- Full-size frames of both MP4s in `_work/final/` and `../chuk-14-just-an-email-vertical/_work/final/`.

## Weakest shot

s07 step 2 ("This is permanent") is on screen ~1.3 s, only long enough to show that a second
warning exists; its body is not meant to be read. s01's generic form is deliberately plain.
