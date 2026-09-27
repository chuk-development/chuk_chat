# lib/services/settings · Signaturen

## lib/services/settings/debug_settings.dart  (41 Z.)
- L12 `abstract final class DebugSettings`  — Reads and writes the developer debug toggles, so the settings page and the
  - L16 `static const String captureContextKey = 'dev_capture_context'`  — "Capture model context": when on, each task rides with `debug: true`, so
  - L21 `static Future<bool> captureContext()`  — The stored "capture model context" value. Defaults to false, including
  - L32 `static Future<void> setCaptureContext(bool value)`  — Persists the "capture model context" value. A storage failure is swallowed:

## lib/services/settings/embedding_model_service.dart  (90 Z.)
- L11 `class EmbeddingModelService`  — The embedding model the host uses for semantic memory (Mem0).
  - L12 `const EmbeddingModelService._()`
  - L14 `static const String _prefsKey = 'embedding_model_v1'`
  - L18 `static const String defaultModelId = 'qwen3-embedding-8b'`  — The embedder the memory stack runs by default (deepinfra → fireworks,
  - L22 `static const List<EmbeddingModelOption> options = <EmbeddingModelOption>[ EmbeddingModelOption( id: 'qwen3-embedding-8b', name: 'Qwen3 Embedding 8B', dimensions: 1024, ), EmbeddingModelOption( id: 'qwen3-embedding-4b', name: 'Qwen3 Embedding 4B', dimensions: 1024, ), EmbeddingModelOption(id: 'bge-m3', name: 'BGE-M3', dimensions: 1024), EmbeddingModelOption( id: 'text-embedding-3-large', name: 'OpenAI text-embedding-3-large', dimensions: 3072, ), ]`  — The options offered in the picker. Static for now; a host capability
  - L43 `static Future<String> load()`  — The stored choice, or [defaultModelId] when nothing is stored or the
  - L57 `static Future<void> save(String modelId)`  — Persist [modelId]. Failures are swallowed.
  - L69 `static String nameFor(String modelId)`  — The human name for [modelId], falling back to the id itself.
- L78 `@immutable class EmbeddingModelOption`  — One embedding-model choice: an id, a display name, and its vector size.
  - L80 `const EmbeddingModelOption({ required this.id, required this.name, required this.dimensions, })`
  - L86 `final String id`
  - L87 `final String name`
  - L88 `final int dimensions`

## lib/services/settings/mobile_chat_preferences.dart  (64 Z.)
- L6 `class MobileChatPreferences extends ChangeNotifier`  — Mobile presentation only. Never changes the model's reasoning effort or
  - L7 `static final instance = MobileChatPreferences()`
  - L8 `static const reasoningKey = 'cowork_mobile_show_thinking'`
  - L9 `static const activityKey = 'cowork_mobile_show_activity'`
  - L10 `static const typographyKey = 'cowork_mobile_messenger_typography'`
  - L12 `bool showThinking = false`
  - L13 `bool showActivity = false`
  - L14 `bool messengerTypography = true`
  - L15 `Future<void>? _loading`
  - L16 `Future<void> _writes = Future<void>.value()`
  - L18 `Future<void> load()`
  - L20 `Future<void> _load()`
  - L32 `Future<void> setThinking(bool value)`
  - L39 `Future<void> setActivity(bool value)`
  - L46 `Future<void> setMessengerTypography(bool value)`
  - L53 `Future<void> _save(String key, bool value)`

## lib/services/settings/theme_controller.dart  (60 Z.)
- L10 `class ThemeController extends ValueNotifier<ThemeMode>`  — The app's theme mode, persisted so the choice survives a restart.
  - L11 `ThemeController([super.initial = ThemeMode.system])`
  - L13 `static const String _prefsKey = 'theme_mode_v1'`
  - L15 `bool _loaded = false`
  - L18 `Future<void> load()`  — Read the stored mode into [value]. Idempotent: the disk read runs once.
  - L31 `Future<void> setMode(ThemeMode mode)`  — Set the mode and persist it. A storage failure still updates the live
  - L41 `static ThemeMode _parse(String? raw)`
  - L49 `static String label(ThemeMode mode)`  — A short human label for a mode, for the settings row and picker.

## lib/services/settings/verbose_service.dart  (82 Z.)
- L21 `class VerboseService extends ChangeNotifier`  — The persisted verbose-view switch, as a [ChangeNotifier] singleton.
  - L22 `VerboseService._()`
  - L25 `static final VerboseService instance = VerboseService._()`  — The one shared instance. All readers use it, so all readers agree.
  - L29 `static const String _prefsKey = 'verbose_view_enabled'`  — The stable key for the stored switch. Do not change it. A change would
  - L33 `static const String _legacyKey = 'dev_verbose_logging'`  — The old developer key for the same idea. [load] adopts its value when the
  - L35 `bool _enabled = false`
  - L36 `bool _loaded = false`
  - L40 `bool get enabled`  — Whether the client shows the full log. Default false. Safe to read before
  - L43 `bool get loaded`  — Whether [load] has run. A page can show a spinner until this is true.
  - L47 `Future<void> load()`  — Read the stored value into [enabled]. Idempotent: the disk read runs once.
  - L65 `Future<void> setEnabled(bool value)`  — Set the switch and persist it. Always updates the live value and notifies
