# test/pages · Signaturen

## test/pages/agent_profile_edit_page_test.dart  (77 Z.)
- L11 `void main()`

## test/pages/agents_pairing_page_test.dart  (229 Z.)
- L10 `class _FakeCamera`  — A stand-in camera. It renders a marker instead of a preview and exposes the
  - L11 `ValueChanged<String>? onCode`
  - L12 `ValueChanged<String>? onUnavailable`
  - L13 `int builds = 0`
  - L15 `Widget build( BuildContext context, { required ValueChanged<String> onCode, required ValueChanged<String> onUnavailable, })`
- L30 `void main()`

## test/pages/automations_page_test.dart  (230 Z.)
- L14 `AgentsAutomation _automation( String id, { String session = 'thread-1', String state = 'active', })`
- L28 `void main()`

## test/pages/mcp_connectors_page_test.dart  (106 Z.)
- L17 `class _MemorySecrets implements AgentsSecureKeyValueStore`  — In-memory secure backend so secrets round-trip with no platform channel.
  - L18 `final Map<String, String> map = <String, String>{}`
  - L21 `Future<String?> read(String key)`
  - L24 `Future<void> write(String key, String value)`
  - L27 `Future<void> delete(String key)`
- L30 `void main()`

## test/pages/mobile_agents_settings_page_test.dart  (268 Z.)
- L12 `void main()`

## test/pages/model_selector_design_test.dart  (114 Z.)
- L8 `void main()`

## test/pages/newest_message_time_test.dart  (17 Z.)
- L5 `void main()`

## test/pages/secrets_settings_page_test.dart  (166 Z.)
- L14 `class _Memory implements AgentsSecureKeyValueStore`
  - L15 `final Map<String, String> map = <String, String>{}`
  - L18 `Future<String?> read(String key)`
  - L21 `Future<void> write(String key, String value)`
  - L24 `Future<void> delete(String key)`
- L32 `List<(String, int, String?)> _flat(List<(Map<String, String>, int, String?)> xs)`  — Settings > API Keys: names are listed with a "set" badge, values are never
- L37 `String _j(Map<String, String> m)`
- L39 `void main()`

## test/pages/settings_page_test.dart  (144 Z.)
- L21 `void main()`  — With Agents on, the settings hub is the Agents app's own hub: its entries,

## test/pages/skills_settings_page_test.dart  (357 Z.)
- L22 `Widget _host(Widget child)`
- L29 `_userSkill = Skill( name: 'my-review', description: 'Reviews code. Use when the user asks for a review.', body: '# My re`
- L40 `AgentsSkill _skill(String name, {String source = 'workspace', bool enabled = true})`
- L48 `void main()`

## test/pages/theme_page_test.dart  (172 Z.)
- L16 `class _State`
  - L17 `Brightness themeMode = Brightness.dark`
  - L18 `Color accent = kDefaultAccentColor`
  - L19 `Color iconFg = kDefaultIconFgColor`
  - L20 `Color bg = kDefaultBgColor`
  - L21 `double contrast = kDefaultContrast`
  - L22 `String uiFont = kDefaultUiFontFamily`
  - L23 `String chatFont = kDefaultChatFontFamily`
  - L24 `bool dynamicColor = false`
- L27 `AppShellConfig _config(_State s)`
- L84 `Widget _host(AppShellConfig config)`
- L91 `void main()`
