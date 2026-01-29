# Common Tasks

## Adding a New Service
1. Create in `lib/services/`
2. Use const constructor or static methods
3. Add initialization to `main.dart` if needed at startup
4. Update both platform UIs if affects UI state

## Adding a New Page
1. Create in `lib/pages/`
2. Add navigation in sidebar (desktop and/or mobile)
3. Use `Theme.of(context)` for consistent colors
4. Test on both platforms

## Adding a Feature Flag
1. Add to `lib/platform_config.dart`:
```dart
const bool kFeatureMyFeature = bool.fromEnvironment(
  'FEATURE_MY_FEATURE',
  defaultValue: false
);
```
2. Use in code: `if (kFeatureMyFeature) { ... }`
3. Enable: `--dart-define=FEATURE_MY_FEATURE=true`

## Modifying Theme System
1. Update `lib/constants.dart` for new defaults
2. Add state in `_ChukChatAppState` in `main.dart`
3. Update `ThemeSettings` model in `ThemeSettingsService`
4. Update Supabase `theme_settings` table
5. Pass callbacks to both root wrappers
6. Update `ThemePage` UI

## Modifying Customization Settings
1. Add state in `_ChukChatAppState` in `main.dart`
2. Update `CustomizationPreferences` model
3. Update Supabase `customization_preferences` table
4. Pass callbacks to both root wrappers
5. Update `CustomizationPage` UI
6. Implement behavior in relevant components

## Adding Database Column
1. Add migration in `migrations/`
2. Update corresponding service model
3. Run migration in Supabase SQL Editor

## Building Release APK
```bash
# Fast (single arch, ~30s):
flutter build apk --dart-define=PLATFORM_MOBILE=true --tree-shake-icons --target-platform android-arm64

# All features:
flutter build apk \
  --dart-define=PLATFORM_MOBILE=true \
  --dart-define=FEATURE_IMAGE_GEN=true \
  --dart-define=FEATURE_PROJECTS=true \
  --tree-shake-icons \
  --target-platform android-arm64
```

## Building Linux
```bash
./build.sh linux  # All formats
./build.sh deb    # DEB only
./build.sh rpm    # RPM only
./build.sh appimage  # AppImage only
```

## Update Version
1. Edit `pubspec.yaml` version field
2. Update `BUILD.md` if needed
3. Modify `build.sh` if needed
