# test/services · Signatures

## test/services/app_theme_contrast_uifont_test.dart  (94 Z.)

- L12 `void main()`

## test/services/app_theme_service_dynamic_color_test.dart  (155 Z.)

- L10 `ColorScheme _schemeWithPrimary(Color primary, Brightness brightness)`
- L15 `void main()`

## test/services/artifact_diff_engine_test.dart  (102 Z.)

- L6 `void main()`

## test/services/artifact_repair_version_chain_test.dart  (33 Z.)

- L5 `void main()`

## test/services/artifact_rollback_test.dart  (560 Z.)

- L5 `void main()`

## test/services/artifact_storage_pending_flushers_test.dart  (112 Z.)

- L5 `void main()`

## test/services/bash_sandbox_folder_test.dart  (105 Z.)

- L8 `void main()`

## test/services/chat_history_builder_test.dart  (273 Z.)

- L8 `void main()`  — The outgoing payload is `{message: <current turn>, history: [...]}` and the

## test/services/chat_mode_config_test.dart  (413 Z.)

- L11 `void main()`

## test/services/chat_runtime_test.dart  (182 Z.)

- L5 `void main()`

## test/services/encryption_service_test.dart  (702 Z.)

- L15 `void main()`  — Tests for the core AES-GCM encryption logic used by EncryptionService.
- L690 `int? _extractKeyVersion(String encrypted)`  — Mirror of EncryptionService.extractKeyVersion for testing

## test/services/file_conversion_page_images_test.dart  (103 Z.)

- L8 `void main()`  — A scanned PDF has no text layer, so the API returns its pages as image

## test/services/image_compression_service_test.dart  (228 Z.)

- L6 `void main()`

## test/services/message_composition_service_test.dart  (69 Z.)

- L4 `void main()`

## test/services/network_status_service_test.dart  (124 Z.)

- L4 `void main()`

## test/services/oauth_loopback_server_test.dart  (118 Z.)

- L7 `_theme = OAuthResultPageTheme( successColor: '#28a745', errorColor: '#dc3545', background: '#0d1117', card: '#161b22', b`
- L18 `OAuthLoopbackServer _server(int port)`  — Ports in the dynamic range, one per test, so a lingering socket from one
- L25 `typedef _Response = ({int status, String body})`  — Status code and body of one callback request.
- L27 `Future<_Response> _get(Uri uri)`
- L41 `void main()`

## test/services/offline_queue_service_test.dart  (140 Z.)

- L11 `void main()`

## test/services/offline_retry_manager_test.dart  (145 Z.)

- L14 `void main()`

## test/services/onboarding_tour_controller_test.dart  (44 Z.)

- L17 `void main()`

## test/services/per_model_system_prompt_merge_test.dart  (175 Z.)

- L5 `void main()`

## test/services/prefs_to_kv_migration_test.dart  (58 Z.)

- L21 `void main()`

## test/services/reasoning_supported_efforts_test.dart  (198 Z.)

- L19 `Future<void> _seedCatalog(List<Map<String, dynamic>> models)`  — Seed the on-disk catalog cache with [models] and hydrate the capability
- L25 `void main()`

## test/services/round_content_block_service_test.dart  (519 Z.)

- L8 `void main()`

## test/services/sandbox_infra_breaker_test.dart  (123 Z.)

- L4 `void main()`

## test/services/streaming_manager_test.dart  (585 Z.)

- L12 `void main()`
- L568 `class _TestStreamContext`  — Helper class to hold test stream state
  - L569 `final StreamController<ChatStreamEvent> controller`
  - L570 `final String Function() getContent`
  - L571 `final String Function() getReasoning`
  - L572 `final double? Function() getTps`
  - L573 `final bool Function() isCompleted`
  - L574 `final String? Function() getError`
  - L576 `_TestStreamContext({ required this.controller, required this.getContent, required this.getReasoning, required this.getTps, required this.isCompleted, required this.getError, })`

## test/services/tool_call_handler_deferred_action_test.dart  (281 Z.)

- L6 `void main()`

## test/services/tool_call_handler_fact_check_test.dart  (193 Z.)

- L6 `void main()`

## test/services/tool_call_handler_safety_limit_test.dart  (150 Z.)

- L6 `void main()`

## test/services/tool_call_reasoning_lift_test.dart  (65 Z.)

- L5 `void main()`

## test/services/tool_enforcer_test.dart  (137 Z.)

- L5 `Map<String, dynamic> _def(String name)`
- L11 `Map<String, dynamic> _call(String name, [Map<String, dynamic>? args])`
- L16 `void main()`

## test/services/tool_failure_detection_test.dart  (129 Z.)

- L9 `void main()`  — A tool result's failure flag drives the icon the user sees AND whether the

## test/services/tool_image_result_service_test.dart  (178 Z.)

- L8 `void main()`

## test/services/tool_prompt_builder_test.dart  (439 Z.)

- L8 `_skillToolDef = { 'name': 'skill', 'description': 'Load a skill.', 'parameters': <String, dynamic>{'name': 'string'}, }`
- L14 `_tools = [ { 'name': 'find_tools', 'description': 'Discovery', 'parameters': <String, dynamic>{}, }, { 'name': 'web_sear`
- L37 `_testSkill = Skill( name: 'weather-cards', description: 'Renders weather. Use when the user asks about weather.', body:`
- L44 `void main()`

## test/services/tool_result_cache_registry_test.dart  (124 Z.)

- L4 `void main()`

## test/services/tool_turn_signals_test.dart  (47 Z.)

- L4 `void main()`

## test/services/tour_key_registry_test.dart  (62 Z.)

- L7 `void main()`

## test/services/user_scoped_cache_invalidation_test.dart  (301 Z.)

- L16 `void main()`  — Guards the cross-user leak fix: the static caches in these services are

## test/services/user_scoped_cache_race_test.dart  (309 Z.)

- L21 `void main()`  — The sign-out-mid-flight race: an operation starts as user A, A signs out and
