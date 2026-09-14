# Fastlane

## What Fastlane is, and what it is not

Fastlane is a Ruby task runner for app-store chores. It **does not compile
anything itself**. Every lane in this repo shells out to the tool that does the
real work:

| Lane calls | Which runs |
|---|---|
| `flutter build apk` / `appbundle` | Gradle → the Android toolchain |
| `flutter build macos` | `xcodebuild` |
| `flutter build linux` | CMake + ninja |
| `flutter test test_screenshots` | the Flutter test engine |
| `flatpak-builder`, `appimagetool` | the Linux packagers |

What Fastlane adds on top is the part that is tedious by hand: uploading a
bundle to the Play Console, pushing listing text and screenshots for every
locale, writing a changelog file per version code, managing iOS certificates,
and doing all of it the same way on a workstation and in CI.

## Where does the build happen? Do I need a server?

**No.** A lane runs in the shell you start it in. There are exactly three
places a build can happen, and two of them already exist:

1. **This machine** — `cd android && bundle exec fastlane build_aab`. Fine for
   Android and Linux. This is the fastest loop.
2. **GitHub Actions** — two workflows:
   - `.github/workflows/build-cross-platform.yml` builds and publishes the
     cross-platform release. This is the one a normal release uses.
   - `.github/workflows/play-store.yml` is triggered by hand
     (`workflow_dispatch`) and runs the upload lanes. This is where a release
     should come from: the runner is clean and the secrets live in the repo
     settings.
3. **A Mac** — only for macOS and iOS. `xcodebuild` does not exist on Linux, so
   nothing can change that. Either the local Mac build machine or a
   `macos-latest` GitHub runner.

A dedicated build box buys nothing here. It would only start to pay off if
builds were queueing on the free runner minutes, or if a self-hosted runner
were needed to hold a signing key that must not leave the network. Neither is
the case today.

## Install

Fastlane is a gem, so it needs Ruby with headers (a native extension in the
dependency chain does not ship a prebuilt binary):

```bash
sudo apt install -y ruby-dev build-essential   # a native extension needs them
gem install --user-install bundler             # no sudo, no system gem dir
export PATH="$(ruby -e 'print Gem.user_dir')/bin:$PATH"
bundle install                                 # from the repository root
```

Both of the first two lines earn their flags. Without `ruby-dev` the native
extension in fastlane's dependency chain cannot compile. Without
`--user-install`, `gem install` fails with `Gem::FilePermissionError` on
`/var/lib/gems`, which needs root. RubyGems does not put the user gem
directory on `PATH` by itself, so the export has to come before `bundle`
is called for the first time — put it in your shell profile.

There is **one** `Gemfile`, at the repository root. Bundler walks up from the
working directory, so `bundle exec fastlane` finds it from `android/`, `linux/`
and `macos/` alike. `Gemfile.lock` is committed and CI runs with
`BUNDLE_FROZEN`, so a local run and a CI run use the same fastlane.

### `.env`, not JSON

`--dart-define-from-file` accepts both a JSON object and a dotenv file. Every
lane passes the repository's `.env` directly — verified on Flutter 3.47 — which
is also what the repository rules require. Do not "fix" it into a JSON
conversion step.

Check it:

```bash
cd android && bundle exec fastlane lanes
```

## Android lanes

Run from `android/`.

| Lane | What it does |
|---|---|
| `screenshots` | Regenerates the store screenshots and the feature graphic |
| `frame_screenshots` | Wraps the raw PNGs in device frames (needs ImageMagick) |
| `changelog` | Writes `changelogs/<versionCode>.txt` from the git log |
| `build_apk` | Release APK for direct distribution — Stripe payments **on** |
| `build_aab` | Release bundle for Play — Stripe payments **compiled out** |
| `validate` | Builds and dry-runs the upload. Changes nothing on Play |
| `upload_metadata` | Pushes listing text, images and screenshots, no binary |
| `deploy track:<t>` | Builds and uploads to `internal`/`alpha`/`beta`/`production` |
| `release track:<t>` | Screenshots, changelog, both artefacts, upload |

Options: `fastlane deploy track:beta`, `fastlane screenshots locales:en-US,de-DE
devices:phone,tenInch`, `fastlane changelog from:v1.0.108 to:HEAD`.

### The version code

`pubspec.yaml` carries `version: 1.0.109` with no `+build` suffix, so Gradle
would receive a constant `versionCode = 1` and Play would reject every upload
after the first. The lanes derive one instead:

```
major * 100_000 + minor * 1_000 + patch     # 1.0.109 -> 100109
```

It is passed as `--build-number`, so nothing in `pubspec.yaml` has to change.

**The same formula lives in three places** — `android/fastlane/Fastfile`,
`build.sh` and `.github/workflows/build-cross-platform.yml`. They must agree,
or an APK from one path cannot upgrade an APK from another
(`INSTALL_FAILED_VERSION_DOWNGRADE`). The two build scripts used to take the
patch component alone, which also went backwards on a minor bump: 1.1.0 would
have been version code 0.

The headroom is smaller than it looks. `--split-per-abi` multiplies the build
number by 1000 and adds a per-ABI offset, and Android caps `versionCode` at
2 100 000 000 — so the derived number has to stay below 2 100 000. Hence
`major <= 20`, `minor <= 99`, `patch <= 999`; the lanes refuse a version that
breaks those bounds.

### Payments: the one flag that matters

Google requires in-app purchases to go through Play Billing. Shipping the
direct Stripe flow in a Play build risks the listing, not just the payment.
`build_aab` and the macOS App Store lane therefore hardcode
`FEATURE_PAYMENTS_DIRECT=false`; `build_apk`, which feeds the direct downloads,
leaves it on. Do not "simplify" that by sharing one flag set between them.

## Screenshots

Two paths. Both write into
`fastlane/metadata/android/<locale>/images/phoneScreenshots/`, which is
the tree `supply` uploads from.

### Real device (default)

The store screenshots are captured on a real device or the emulator with
`scripts/device_screenshots.sh`, and committed by hand. They show the real
status bar, the real font stack and real chat content — which is what the
listing is supposed to promise.

There is **no workflow that regenerates them.** The old `screenshots.yml`
rendered widgets headlessly and committed the result on every push to
`master`, which overwrote every hand-made capture. It is gone. Recapture the
screenshots when the UI changes, before cutting a release.

Rules for a capture, so nothing private ends up in a store listing:

- Sign in with a throwaway account, or clear the chat list first.
- Put the status bar in demo mode, so the clock, the battery and the
  notification icons are fixed and say nothing about the device:
  ```bash
  adb shell settings put global sysui_demo_allowed 1
  adb shell am broadcast -a com.android.systemui.demo -e command enter
  adb shell am broadcast -a com.android.systemui.demo -e command clock -e hhmm 1200
  adb shell am broadcast -a com.android.systemui.demo -e command battery -e level 100 -e plugged false
  adb shell am broadcast -a com.android.systemui.demo -e command notifications -e visible false
  adb shell am broadcast -a com.android.systemui.demo -e command network -e wifi show -e level 4 -e mobile false
  # when done: adb shell am broadcast -a com.android.systemui.demo -e command exit
  ```
- No real names, no e-mail address, no account menu, no API key, no file path
  that carries a user name.
- **Never capture the sidebar.** It lists real chat titles. On the phone the
  app starts with it closed; on the desktop keep it collapsed.

The full loop, from a booted emulator to the committed listing images:

```bash
./scripts/device_screenshots.sh --demo on      # freeze the status bar
# Drive the app to the screen you want (by hand, or with `adb shell input
# tap/text`), then capture it once per locale:
./scripts/device_screenshots.sh 01_chat en-US  # -> fastlane/screenshots_raw/en-US/
./scripts/device_screenshots.sh 01_chat de-DE  # the German listing needs its own
./scripts/frame_screenshots.sh                 # raw -> framed 1080x1920
./scripts/feature_graphic.sh                   # rebuild the 1024x500 banner
flutter test test/fastlane_metadata_test.dart  # sizes and counts Play accepts
```

`feature_graphic.sh` reads `01_chat.png` from every locale it builds, so
capture that one for each locale before running it.

`fastlane/screenshots_raw/<locale>/` holds the untouched captures, outside the
metadata tree, so re-framing always starts from the original and neither
`supply` nor F-Droid sees two copies of every image.
`scripts/frame_screenshots.sh` puts each capture in a rounded body with the
accent hairline on the brand gradient; `scripts/feature_graphic.sh` builds the
feature graphic out of the wordmark, the slogan and the first capture.

The README screenshots of the desktop app come from
`scripts/desktop_screenshots.sh`, which launches the prebuilt Linux release
bundle on an Xvfb display. An X11 capture of the real desktop returns black while the monitor is
asleep, and it would also catch the user's own windows.

### Generated (fallback, no hardware)

The headless harness still exists for when there is no device at hand:

```bash
flutter test test_screenshots          # or: fastlane screenshots
```

`test_screenshots/` renders the app's own widgets — `MessageBubble`, the real
`ThemePage`, the real theme builder — at 1080x1920 and rasterises them. It runs
headless in about three seconds, is deterministic, and covers every locale in
one pass. It lives outside `test/` on purpose, so `flutter test` with no path
does not pick it up.

Two things the harness has to fix up, because a test binding is not a phone:

- **Fonts.** The test engine ships a placeholder font that draws every glyph as
  a box. `loadAppFonts()` registers everything in `FontManifest.json`, plus
  Roboto from the Flutter SDK (what Android resolves a null `fontFamily` to)
  and the bundled JetBrains Mono under the name `monospace` (what a dozen
  widgets ask for, and what only a real platform can resolve).
- **Preferences.** Several widgets read `SharedPreferences` in `initState` and
  throw `MissingPluginException` without a mock store.

Add a scene in `test_screenshots/src/scenes.dart` and register it in the
`_scenes` list in `screenshots_test.dart`.

### From a real device

```bash
./scripts/device_screenshots.sh 01_chat de-DE
```

`adb exec-out screencap` against whatever the phone currently shows. Use this
when the listing should show the real status bar and real content.

### Framing

`fastlane frame_screenshots` runs `frameit`, which puts a device frame and a
title around each PNG. It needs ImageMagick and downloads the frame images on
first run. Optional — Play accepts bare screenshots.

## One tree, two stores (and the README)

`fastlane/metadata/android/` sits at the repository root rather than under
`android/`, because that is the path **F-Droid reads straight out of the git
repository** — no upload, no console, no account. `supply` is pointed at the
same tree with `metadata_path`, and the README embeds the same PNGs. One
generator feeds all three.

F-Droid's layout is identical to Play's, with two differences worth knowing:
its title limit is 50 characters rather than 30 (we keep to 30, the stricter
one), and it has no feature-graphic requirement, though it will show one.

### Getting into F-Droid itself

The metadata tree is only half of it. F-Droid builds from source on its own
servers, so a recipe has to go into the `fdroiddata` repo, and two things about
this app need an answer first:

- **Build-time credentials.** The app takes `SUPABASE_URL` and
  `SUPABASE_ANON_KEY` from `--dart-define-from-file=.env`, and the F-Droid
  builder has no `.env`. The anon key is a publishable key, so the recipe can
  write one in a `prebuild:` step — but that decision should be deliberate, not
  discovered during a build.
- **Antifeatures.** The app talks to a paid API and to Supabase, so the recipe
  will carry `NonFreeNet`. That is a label, not a rejection.

## The Play Store is not available yet

A new personal Play developer account has to run a closed test with at least
12 testers for 14 continuous days before production access is granted. Until
that is done, `deploy track:production` will not work no matter what this
repo does. What is worth running today:

- `screenshots` — the GitHub workflow already does this on every UI change
- `validate` — needs the Play account, but proves the pipeline end to end
  without publishing anything
- the F-Droid tree, which needs no account at all

## Listing metadata

```
fastlane/metadata/android/
├── en-US/
│   ├── title.txt                (<= 30 chars)
│   ├── short_description.txt    (<= 80)
│   ├── full_description.txt     (<= 4000)
│   ├── changelogs/
│   │   ├── default.txt          fallback for any version code
│   │   └── 100109.txt           written by `fastlane changelog`
│   └── images/
│       ├── icon.png             512x512, copied from web/icons/
│       ├── featureGraphic.png   1024x500, generated
│       └── phoneScreenshots/    generated
└── de-DE/  …
```

Edit the text files in git; `fastlane upload_metadata` pushes them. That keeps
the listing under review like everything else, instead of living only in a web
form.

## Credentials

| What | Where |
|---|---|
| Supabase | `.env` at the repository root, read via `--dart-define-from-file` |
| Upload keystore | `ANDROID_KEYSTORE_PATH` env, else `android/key.properties` |
| Play service account | `SUPPLY_JSON_KEY` env, else `android/play-store-key.json` |

None of the three is committed. In CI they come from repository secrets and are
deleted from the workspace in an `always()` step.

To create the Play service account: Play Console → Setup → API access → create
a Google Cloud service account → grant it "Release apps to testing tracks" and
"Manage store presence" → download the JSON key.

## Desktop

Fastlane's real desktop support ends at the Mac App Store (`deliver`,
`notarize`). `linux/fastlane/Fastfile` uses it as a plain task runner over
`flatpak-builder`, `appimagetool` and `scripts/package-linux.sh`; that works,
but Fastlane adds nothing there that a Makefile would not. Windows and the
Microsoft Store have no Fastlane support at all.

The screenshot pipeline is the part that pays off across platforms anyway: the
same PNGs feed the Play listing, the Flathub `metainfo.xml`, and the website.

## Order of a real release

```bash
# 1. bump the version, commit
# 2. regenerate the listing assets
cd android
bundle exec fastlane screenshots
bundle exec fastlane changelog          # from the last v* tag to HEAD
# 3. dry run — builds, uploads nothing
bundle exec fastlane validate
# 4. ship to a closed track first
bundle exec fastlane deploy track:internal
```

`deploy` uploads to `internal`, `alpha` and `beta` as a **draft**; only
`production` is marked complete. Promote from the Play Console when the build
has been on a device.
