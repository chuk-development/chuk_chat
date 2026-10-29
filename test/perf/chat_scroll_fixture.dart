// Shared fixture for the scroll-up speed tests: a 300-message chat and the
// mobile chat's list reduced to the list (anchored transcript, shared
// selection area, the shared render cache and the real rows). Used by
// `chat_scroll_up_perf_test.dart` (widget test, debug, wall clock) and by
// `integration_test/chat_scroll_perf_test.dart` (profile build on a device,
// real frame build and raster times).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/platform_specific/chat/chat_scroll_mixin.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/platform_specific/chat/widgets/chat_message_list_item.dart';
import 'package:chuk_chat/widgets/selection_copy_area.dart';

const int scrollPerfMessageCount = 300;

String _answer(int i, String mix) {
  final int kind = switch (mix) {
    'prose' => 5,
    'table' => 3,
    'list' => 1,
    'tableonly' => 7,
    'code' => 8,
    _ => i % 6,
  };
  switch (kind) {
    case 1:
      return '## Step $i\n\n'
          'The assistant explains **one** step of the plan, with `inline` '
          'code and a [link](https://example.com/$i).\n\n'
          '- first point of the step\n'
          '- second point, a bit longer than the first one\n'
          '  - a nested point\n'
          '1. ordered one\n'
          '2. ordered two\n\n'
          '${"A longer paragraph that wraps over several lines on a phone. " * 6}\n';
    case 3:
      return '| Column | Value | Note |\n'
          '|---|---|---|\n'
          '| alpha | $i | first row |\n'
          '| beta | ${i * 2} | second row |\n'
          '| gamma | ${i * 3} | third row |\n\n'
          'After the table comes a paragraph that closes the answer.\n\n'
          '```dart\nvoid main() {\n  for (var i = 0; i < $i; i++) {\n'
          '    print("row \$i");\n  }\n}\n```\n';
    case 7:
      return '| Column | Value | Note |\n'
          '|---|---|---|\n'
          '| alpha | $i | first row |\n'
          '| beta | ${i * 2} | second row |\n'
          '| gamma | ${i * 3} | third row |\n\n'
          'After the table comes a paragraph that closes the answer.';
    case 8:
      return 'Here is the code.\n\n'
          '```dart\nvoid main() {\n  for (var i = 0; i < $i; i++) {\n'
          '    print("row \\\$i");\n  }\n}\n```\n';
    case 5:
      return '${"The assistant explains a step in plain prose. " * 20}\n\n'
          '> a quote line\n\n'
          '${"Second paragraph with *emphasis* and `code`. " * 10}';
    default:
      return 'Answer $i. ${"The assistant explains a step. " * 8}';
  }
}

String _toolCalls(int i) => jsonEncode(<Map<String, dynamic>>[
  for (int c = 0; c < 3; c++)
    <String, dynamic>{
      'id': 'call-$i-$c',
      'name': c.isEven ? 'shell' : 'read_file',
      'arguments': <String, dynamic>{
        'command': 'ls -la /home/user/project/$i/$c',
        'path': '/home/user/project/file_$c.dart',
      },
      'result': 'total 42\n${"drwxr-xr-x  2 user user 4096 file\n" * 6}',
      'status': 'completed',
      'startedAt': '2026-09-20T10:00:0$c.000Z',
      'completedAt': '2026-09-20T10:00:0${c + 1}.000Z',
    },
]);

/// [mix] narrows the answers to one kind for attributing cost: `prose`,
/// `table`, `list`, `tools` (prose answers, every one with tool calls). The
/// default is the mix of all of them.
List<Map<String, String>> scrollPerfTranscript({
  String mix = '',
}) => <Map<String, String>>[
  for (int i = 0; i < scrollPerfMessageCount; i++)
    if (i.isEven)
      <String, String>{'sender': 'user', 'text': 'Question $i, please help.'}
    else
      <String, String>{
        'sender': 'ai',
        'text': _answer(i, mix),
        'modelId': 'deepseek/deepseek-v4-flash-0731',
        'provider': 'fireworks',
        'generationMs': '${1200 + i}',
        if (mix == 'tools' || (mix.isEmpty && i % 3 == 0))
          'toolCalls': _toolCalls(i),
      },
];

/// The mobile chat's list, reduced to the list: anchored transcript, shared
/// selection area, the shared render cache and the real rows.
class ScrollPerfHost extends StatefulWidget {
  const ScrollPerfHost({super.key, required this.messages});

  final List<Map<String, String>> messages;

  @override
  State<ScrollPerfHost> createState() => _HostState();
}

class _HostState extends State<ScrollPerfHost>
    with ChatScrollMixin<ScrollPerfHost> {
  final MessageRenderCache _cache = MessageRenderCache(shared: true);
  final Uuid _uuid = const Uuid();

  @override
  bool get anchoredTranscript => true;

  @override
  List<Map<String, String>> get transcriptRows => widget.messages;

  @override
  double get transcriptPxPerChar => 0.6;

  @override
  void initState() {
    super.initState();
    scrollController.addListener(onScrollChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scrollChatToBottom(animate: false, force: true);
    });
  }

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.messages;
    const padding = EdgeInsets.fromLTRB(12, 10, 12, 80);
    transcriptBottomInset = padding.bottom;
    Widget item(BuildContext context, int i) {
      final data = _cache.build(
        messages: messages,
        index: i,
        isStreaming: false,
      );
      return ChatMessageListItem(
        messages: messages,
        index: i,
        data: data,
        uuid: _uuid,
        maxWidth: 388,
        activeChatId: 'perf-chat',
        flyInKey: null,
        showToolCalls: true,
        showReasoningTokens: true,
        showModelInfo: true,
        showTps: false,
        isEditing: false,
        actions: const [],
        userMessageActions: const [],
        onSwitchVariant: (_) {},
        messengerMode: true,
      );
    }

    return SelectionCopyArea(
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (_) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) onScrollChanged();
          });
          return false;
        },
        child: buildAnchoredTranscript(
          split: resolveTranscriptSplit(),
          itemCount: messages.length,
          padding: padding,
          itemBuilder: item,
          scrollCacheExtent: const ScrollCacheExtent.pixels(400.0),
          addAutomaticKeepAlives: false,
        ),
      ),
    );
  }
}
