# Screenshots

How the seven README images and the ten store images are made. Follow this and
the set comes out the same every time.

Both sets sit on the same painting, `scripts/backdrops/debat-ponsan.jpg`. That
is what makes the README, the Play listing and the F-Droid page look like one
product rather than three.

## Desktop gallery (`assets/screenshots/*.webp`)

One tool does all of it: `scripts/desktop_screenshots.sh`. It runs the release
bundle on a private Xvfb display, so no window of yours reaches the image and a
sleeping monitor cannot turn the capture black.

```bash
flutter build linux --release --dart-define-from-file=.env   # if the bundle is stale
export SCREENSHOT_WIDTH=3840 SCREENSHOT_HEIGHT=2160
./scripts/desktop_screenshots.sh start
```

**Stop `flutter-hot` first.** Two instances of the app share one login, and the
rotating Supabase token then signs the other one out.

### The three settings that decide how it looks

| Variable | Default | Why |
|---|---|---|
| `SCREENSHOT_UI_SCALE` | `2` | GTK scale factor. At 1 a 4K capture draws one device pixel per logical pixel and every control is too small to read. 2 gives a 1920x1080 logical window at full 4K sharpness. |
| `SCREENSHOT_BACKDROP` | the painting | `none` falls back to the brand gradient. |
| `SCREENSHOT_WEBP_QUALITY` | `lossless` | A lossy webp bands the flat dark panels and muddies the painted grass. Lossless is about a third smaller than PNG. |

### The seven captures

Take them in this order. `click` takes coordinates inside the window, so read
them off a capture, never off your own screen.

| Name | What must be on screen |
|---|---|
| `home_ui` | Empty chat. Model dropdown **closed**. |
| `model_selection` | Model dropdown open (click the model chip in the composer). |
| `weather_ui` | A weather card, and nothing above it. |
| `bitcoin_chart` | A chart block. |
| `tool_calling_ui` | A web search with the tool block **expanded** — click "Worked for Ns". |
| `customization` | Settings → Customization, over an empty chat. |
| `theme_settings` | Settings → Theme Settings, over an empty chat. |

```bash
./scripts/desktop_screenshots.sh shot home_ui
./scripts/desktop_screenshots.sh click <x> <y>
./scripts/desktop_screenshots.sh type "..."
./scripts/desktop_screenshots.sh key Return
./scripts/desktop_screenshots.sh webp     # writes assets/screenshots/
./scripts/desktop_screenshots.sh stop
```

### Two traps

**Close the sidebar before every capture.** It lists real chat titles and shows
the account name and the credit balance. This repository is public.

**Start a new chat for each content shot and ask a fresh question.** Do not open
an existing chat: the set then carries private conversations, and a second
answer above the card makes the image look untidy. The three questions that
produced the current set:

- `Show the weather forecast for Kiel as a weather card`
- `Chart the Bitcoin price over the last 7 days`
- `Search the web for the newest Flutter release and summarise what is new`

A plain "what is the weather in Kiel" gives a text answer, not a card. Ask for
the card.

## Store images (`fastlane/metadata/android/<locale>/images/phoneScreenshots/`)

Captured on a real phone, then framed:

```bash
./scripts/device_screenshots.sh --demo on      # clock 12:00, full battery, no notifications
./scripts/device_screenshots.sh 01_chat        # the phone must already show the screen
./scripts/device_screenshots.sh 01_chat de-DE
./scripts/frame_screenshots.sh                 # writes every locale
./scripts/device_screenshots.sh --demo off
```

The raw captures stay in `fastlane/screenshots_raw/<locale>/`, outside the
metadata tree, so re-framing always starts from the original.

`frame_screenshots.sh` puts the capture on the painting **as it is**: square, no
drawn device body. The phone already rounds its own corners, and a second drawn
outline never lines up with the first.

Use an account with no private content, and keep the sidebar and the account
pages out of frame.

## Marketing shots (`docs/screenshots/ads/`)

`scripts/make-app-ad.sh <name>` grabs the live app window on your own desktop
and puts it on the same painting at 3840x2160. This is the only one of the three
that captures the real session, so what is on screen must be demo content.
