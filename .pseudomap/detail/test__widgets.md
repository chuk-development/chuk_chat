# test/widgets · Signatures

## test/widgets/agent_activity_timeline_test.dart  (679 Z.)

- L15 `_t0 = DateTime.utc(2026, 8, 13, 10, 0, 0)`
- L17 `ToolCall _call( String name, { Map<String, dynamic> arguments = const {}, ToolCallStatus status = ToolCallStatus.completed, int startSecond = 0, int? endSecond, String? roundThinking, })`
- L37 `Future<void> _pumpTimeline( WidgetTester tester, { required List<ToolCall> calls, bool isRunning = false, DateTime? now, bool? initiallyExpanded, void Function(ToolCall)? onStepTap, void Function(AgentActivitySource)? onSourceTap, StreamPhase? phase, DateTime? startedAt, Duration? finalDuration, })`
- L68 `void main()`

## test/widgets/anchored_menu_test.dart  (181 Z.)

- L9 `_screen = Size(400, 800)`
- L11 `Future<void> _pumpAnchor( WidgetTester tester, { required double keyboardInset, required Alignment anchorAt, int itemCount = 3, bool preferAbove = false, })`
- L63 `void main()`

## test/widgets/app_notification_test.dart  (87 Z.)

- L8 `void main()`

## test/widgets/chat_mode_selector_test.dart  (400 Z.)

- L20 `_fireworksLevels = <String>['none', 'low', 'high']`
- L22 `Future<void> _pump( WidgetTester tester, { ChatMode mode = ChatMode.thinking, ValueChanged<ChatMode>? onModeChanged, ValueChanged<String>? onModelSelected, String reasoningEffort = 'none', List<String> reasoningLevels = _fireworksLevels, ValueChanged<String>? onReasoningEffortChanged, VoidCallback? onOpenModelScreen, String? selectedModelId, String? modelLabel, List<ChatModelChoice> pickedModels = const <ChatModelChoice>[], })`
- L57 `void main()`

## test/widgets/chuk_table_test.dart  (71 Z.)

- L5 `void main()`

## test/widgets/composer_recording_row_test.dart  (96 Z.)

- L15 `void main()`

## test/widgets/diff_widget_test.dart  (62 Z.)

- L6 `void main()`

## test/widgets/excalidraw_svg_export_test.dart  (62 Z.)

- L5 `_sampleScene = ''' { "type": "excalidraw", "version": 2, "source": "https://excalidraw.com", "elements": [ {"type":"rect`
- L29 `void main()`

## test/widgets/floating_app_bar_test.dart  (66 Z.)

- L7 `void main()`

## test/widgets/html_artifact_view_test.dart  (113 Z.)

- L7 `_sampleHtml = ''' <!doctype html> <html><head><meta charset="utf-8"><title>Demo</title></head> <body><h1>Hello</h1><p>Pa`
- L13 `void main()`

## test/widgets/map_block_dedupe_test.dart  (72 Z.)

- L5 `void main()`

## test/widgets/markdown_message_test.dart  (60 Z.)

- L7 `void main()`

## test/widgets/measure_size_test.dart  (57 Z.)

- L5 `void main()`

## test/widgets/message_bubble_consecutive_tool_groups_test.dart  (96 Z.)

- L9 `void main()`

## test/widgets/message_bubble_dangling_lt_test.dart  (44 Z.)

- L7 `void main()`

## test/widgets/message_bubble_image_block_test.dart  (35 Z.)

- L5 `void main()`

## test/widgets/message_bubble_live_timer_gap_test.dart  (85 Z.)

- L7 `void main()`

## test/widgets/message_bubble_merge_junk_separated_test.dart  (94 Z.)

- L8 `void main()`

## test/widgets/message_bubble_no_tool_status_test.dart  (62 Z.)

- L6 `void main()`

## test/widgets/message_bubble_pending_image_test.dart  (129 Z.)

- L7 `void main()`

## test/widgets/message_bubble_post_tool_reasoning_test.dart  (97 Z.)

- L7 `void main()`

## test/widgets/message_bubble_sources_test.dart  (88 Z.)

- L7 `void main()`

## test/widgets/message_bubble_variant_pager_test.dart  (89 Z.)

- L7 `void main()`

## test/widgets/selection_copy_area_test.dart  (284 Z.)

- L9 `void main()`

## test/widgets/settings_kit_test.dart  (106 Z.)

- L7 `Widget _host(Widget child)`
- L11 `void main()`

## test/widgets/web_search_sources_test.dart  (40 Z.)

- L4 `void main()`
