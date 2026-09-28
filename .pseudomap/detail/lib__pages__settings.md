# lib/pages/settings · Signaturen

## lib/pages/settings/embedding_settings_page.dart  (95 Z.)
- L15 `class EmbeddingSettingsPage extends StatefulWidget`  — Picks the embedding model the host uses for semantic memory.
  - L16 `const EmbeddingSettingsPage({super.key})`
  - L19 `State<EmbeddingSettingsPage> createState()`
- L22 `class _EmbeddingSettingsPageState extends State<EmbeddingSettingsPage>`
  - L23 `String _selected = EmbeddingModelService.defaultModelId`
  - L24 `bool _loading = true`
  - L27 `void initState()`
  - L32 `Future<void> _load()`
  - L41 `Future<void> _pick(String id)`
  - L47 `Widget build(BuildContext context)`

## lib/pages/settings/herenow_settings_page.dart  (153 Z.)
- L19 `class HereNowSettingsPage extends StatefulWidget`  — The here.now publishing connector: let a coworker put a file or a folder on
  - L20 `const HereNowSettingsPage({super.key, HereNowStore? store}) : _injectedStore = store`
  - L23 `final HereNowStore? _injectedStore`
  - L26 `State<HereNowSettingsPage> createState()`
- L29 `class _HereNowSettingsPageState extends State<HereNowSettingsPage>`
  - L30 `late final HereNowStore _store = widget._injectedStore ?? HereNowStore()`
  - L32 `HereNowSettings _settings = const HereNowSettings()`
  - L33 `bool _loading = true`
  - L36 `void initState()`
  - L41 `Future<void> _reload()`
  - L50 `Future<void> _update(HereNowSettings next)`
  - L56 `Widget build(BuildContext context)`
