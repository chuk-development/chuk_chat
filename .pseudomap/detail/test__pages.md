# test/pages · Signaturen

## test/pages/agent_profile_edit_page_test.dart  (115 Z.)
- L11 `void main()`

## test/pages/agent_profile_page_test.dart  (50 Z.)
- L13 `void main()`

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

## test/pages/mcp_connectors_page_test.dart  (212 Z.)
- L19 `class _MemorySecrets implements AgentsSecureKeyValueStore`  — In-memory secure backend so secrets round-trip with no platform channel.
  - L20 `final Map<String, String> map = <String, String>{}`
  - L23 `Future<String?> read(String key)`
  - L26 `Future<void> write(String key, String value)`
  - L29 `Future<void> delete(String key)`
- L32 `void main()`

## test/pages/mobile_agents_settings_page_test.dart  (267 Z.)
- L14 `void main()`

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

## test/pages/settings_page_test.dart  (162 Z.)
- L22 `void main()`  — One settings page for both builds. With Agents on it is upstream

## test/pages/skills_settings_page_test.dart  (357 Z.)
- L22 `Widget _host(Widget child)`
- L29 `_userSkill = Skill( name: 'my-review', description: 'Reviews code. Use when the user asks for a review.', body: '# My re`
- L40 `AgentsSkill _skill(String name, {String source = 'workspace', bool enabled = true})`
- L48 `void main()`

## test/pages/theme_page_test.dart  (166 Z.)
- L15 `class _State`
  - L16 `Brightness themeMode = Brightness.dark`
  - L17 `Color accent = kDefaultAccentColor`
  - L18 `Color iconFg = kDefaultIconFgColor`
  - L19 `Color bg = kDefaultBgColor`
  - L20 `double contrast = kDefaultContrast`
  - L21 `String uiFont = kDefaultUiFontFamily`
  - L22 `String chatFont = kDefaultChatFontFamily`
  - L23 `bool dynamicColor = false`
- L26 `AppShellConfig _config(_State s)`
- L83 `Widget _host(AppShellConfig config)`
- L90 `void main()`
