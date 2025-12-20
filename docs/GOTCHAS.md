# Gotchas & Important Fixes

Critical things to remember when working on this codebase.

## Message Fields Preservation
**Problem:** Data loss and message duplication due to realtime sync loops.

**Rule:** When loading messages from storage (`_loadChatFromIndex()` or `_handleRealtimeChatUpdate()`), ALWAYS preserve ALL fields including `images` and `attachments`.

Both desktop and mobile UIs must handle these fields identically.

## Image Sending on Mobile
**Problem:** Images not sent to AI on first message, but work on resend.

**Cause:** `_fileHandler.attachedFiles` cleared in `setState` BEFORE passed to streaming handler.

**Fix:** Capture files BEFORE clearing:
```dart
final List<AttachedFile> attachedFilesForApi = List.from(_fileHandler.attachedFiles);
// ... setState clears _fileHandler.attachedFiles ...
await _streamingHandler.sendMessage(
  attachedFiles: attachedFilesForApi,  // Use captured list!
  ...
);
```

See `chat_ui_mobile.dart:1202-1314`

## Image Persistence in Messages
**Rule:** When sending messages with images, use `MessageCompositionService.prepareMessage()` result:
```dart
final result = await MessageCompositionService.prepareMessage(...);
final displayMessageText = result.displayMessageText!;
final images = result.images;

userMessage['images'] = jsonEncode(images);
```

## Mobile Streaming Focus
**Problem:** Keyboard focus fight when user tries to dismiss while AI is responding.

**Rule:** DO NOT refocus text field on every streaming token.

Only focus when user initiates send (`chat_ui_mobile.dart:884`), NOT during updates.

## Deprecation: withOpacity
**Use:** `color.withValues(alpha: 0.5)` instead of `color.withOpacity(0.5)`

## Platform-Specific Code
When adding UI features, implement BOTH:
- `lib/platform_specific/chat/chat_ui_desktop.dart`
- `lib/platform_specific/chat/chat_ui_mobile.dart`

## Theme/Customization Sync
Changes must update BOTH:
1. `SharedPreferences` (local)
2. Supabase (remote via service)

## Encryption
All chat data is encrypted client-side. Never log or commit unencrypted sensitive data.

## Build with Features
For testing all features:
```bash
flutter build apk \
  --dart-define=PLATFORM_MOBILE=true \
  --dart-define=FEATURE_MEDIA_MANAGER=true \
  --dart-define=FEATURE_IMAGE_GEN=true \
  --dart-define=FEATURE_PROJECTS=true \
  --tree-shake-icons \
  --target-platform android-arm64
```

## Git Ignored Directories
- `releases/`
- `debian/`
- `rpm/`
- `AppDir/`
- `tools/`
