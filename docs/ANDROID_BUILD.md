# Android build: AGP 9 toolchain

Flutter 3.50 refuses Gradle below 9.3.1 and AGP below 9.1.1, and its Gradle
plugin calls AGP 9 APIs, so AGP 8 does not work even with the check skipped.
Since 2026-11-20 the build uses the Flutter 3.50 template versions:

| Part | Version | Where |
|------|---------|-------|
| Gradle | 9.5.0 | `android/gradle/wrapper/gradle-wrapper.properties` |
| AGP | 9.3.1 | `android/settings.gradle.kts` |
| Kotlin Gradle plugin | 2.4.20 | `android/settings.gradle.kts` |

`android.newDsl=false` and `android.builtInKotlin=false` stay in
`android/gradle.properties`. Several plugins still apply KGP or use the old
variant API, and Flutter prints a warning for them (desktop_drop,
flutter_callkit_incoming, flutter_webrtc, livekit_client, pdfx,
unifiedpush_android). The warning does not stop the build.

`compileSdk` stays 37. AGP 9 reports it as `android-37.0`, because the SDK
platform folder has a minor version now.

## Three workarounds

All three have a comment with the upstream link. Remove each one when a
stable plugin release has the fix.

1. **flutter_inappwebview_android 1.1.3** calls
   `getDefaultProguardFile('proguard-android.txt')`. AGP 9 stops with an
   error when it evaluates that call. The newest stable release has no fix
   (pichillilorenzo/flutter_inappwebview#2852, PR #2897). Fix in
   `android/build.gradle.kts`: a closure with the same name on each build type
   of that one module returns `proguard-android-optimize.txt`.
2. **CargoKit** (the Rust build glue in irondash_engine_context 0.5.5 and
   super_native_extensions 0.9.1, which come in through markdraw and
   super_clipboard) reads `android-37.0` as an int and calls `Project.exec`.
   Gradle 9 removed `Project.exec`. Upstream: superlistapp/super_native_extensions#565,
   PR #585. Fix in `android/build.gradle.kts`: a `gradle.afterProject`
   listener creates the CargoKit task first, with the same name and the same
   environment, but it uses `ExecOperations`. CargoKit then sees the task and
   does not create its own. super_native_extensions 0.10 drops CargoKit, but
   it is `-dev` only and builds Rust from source.
3. **tink duplicate classes.** unifiedpush_android's connector pulls the JVM
   artifact `com.google.crypto.tink:tink`, and flutter_secure_storage pulls
   `tink-android`. `android/app/build.gradle.kts` substitutes the JVM artifact
   with `tink-android`.

## Check

`scripts/build_apk.sh --no-install` (arm64) and
`scripts/build_apk.sh --emulator --no-install` (x86_64) must both build.
