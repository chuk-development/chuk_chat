# Screenshot gallery

The gallery renders many app screens headlessly, so a reviewer can scan the
PNGs of a change and see which screens it touched. It uses the same harness
as the store screenshots (`test_screenshots/src/harness.dart`: real fonts,
`RepaintBoundary.toImage`). It does not write to `fastlane/`.

## Run it

```bash
flutter test test_screenshots/gallery_test.dart
```

It runs on Linux. It needs no display, no `.env` and no network. No CI
workflow runs it yet.

Optional variables:

| Variable | Default | Effect |
|---|---|---|
| `GALLERY_VARIANTS` | all four | Comma list of `mobile-light`, `mobile-dark`, `desktop-light`, `desktop-dark`. |
| `GALLERY_DPR` | `1` | Pixel density. `2` gives 824x1830 mobile and 2880x1800 desktop PNGs. |

Note: `flutter test test_screenshots` (the fastlane `screenshots` lane) runs
every test file in the folder, so it renders the gallery too. Only the store
shots go to `fastlane/`.

## Output

```
build/gallery/
  mobile-light/01-chat-empty.png
  mobile-dark/...
  desktop-light/...
  desktop-dark/...
  index.json        one entry per PNG
  manifest.sha256   one "<sha256>  <file>" line per PNG, sorted by path
```

Sizes: mobile is a 412x915 logical window, desktop is 1440x900. The desktop
variant renders with `TargetPlatform.linux`, the mobile variant with
`TargetPlatform.android`.

The run deletes `build/gallery/` first, so the folder shows only this run.

`index.json` has, for each PNG: `name`, `file` (relative to
`build/gallery/`), `size`, `theme`, `width`, `height`, `sha256`, and `errors`
when the screen reported a framework error (an overflow, a throw in build).
It also lists `cannotMount`: the screens the gallery leaves out, with the
reason.

## Find the changed screens

`manifest.sha256` is in `sha256sum` format. To list the screens that changed
against a base run:

```bash
diff <(cat base/manifest.sha256) build/gallery/manifest.sha256
# or, inside build/gallery of the base run:
sha256sum -c --quiet /path/to/new/manifest.sha256
```

A screen that shows the current time or a relative date ("2 hours ago") can
change its hash without a code change. The scenes use fixed dates where the
widget takes a `now` callback.

## Add a screen

Add one `GalleryScene` to `gallerySceneList()` in
`test_screenshots/src/gallery_scenes.dart`. The position gives the `NN`
prefix of the file name, so add new scenes at the end of their group to keep
the other file names stable. Scene names must be lower case, digits and `-`.

A screen must mount with no backend. The fixtures follow
`test/layout/every_screen_layout_test.dart`, which proves which screens
mount. A screen that cannot mount goes into `kGalleryCannotMount` with the
reason; do not drop it silently.

## Not a gate

A layout error does not fail the gallery. It goes into `index.json` and shows
in the PNG. The layout sweep (`test/layout/every_screen_layout_test.dart`) is
the gate for overflow, bleed and small targets. The gallery test fails only
when a screen throws outside the framework error handler, or when a PNG
comes out empty.
