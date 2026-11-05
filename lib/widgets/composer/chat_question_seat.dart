// lib/widgets/composer/chat_question_seat.dart
//
// The ask_user question of a plain chat, in the composer's seat
// (deepseek-harness idea 66). Agents threads already have this card
// (AgentsQuestionCard, fed by the host); a plain chat's ask_user is a client
// tool, so the question comes from the last answer's completed ask_user call.
//
// The card is the Agents card, fed with a request built here: the
// "(Recommended)" option is preselected and tagged, Enter confirms, and the
// answer goes out as the user's next message. Skip puts the composer back.
import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/agents/agents_thread_modes.dart';
import 'package:chuk_chat/utils/ask_user_args.dart';
import 'package:chuk_chat/widgets/agents_question_card.dart';

/// The last completed ask_user call of one message (contentBlocks first,
/// then the flat list, as the bubble reads it).
ToolCall? lastCompletedAskUser(
  List<ToolCall>? toolCalls,
  List<ContentBlock>? contentBlocks,
) {
  ToolCall? found;
  for (final ContentBlock block in contentBlocks ?? const <ContentBlock>[]) {
    if (block.type != ContentBlockType.toolCalls) continue;
    for (final ToolCall tc in block.toolCalls ?? const <ToolCall>[]) {
      if (tc.name == 'ask_user' && tc.status == ToolCallStatus.completed) {
        found = tc;
      }
    }
  }
  for (final ToolCall tc in toolCalls ?? const <ToolCall>[]) {
    if (tc.name == 'ask_user' && tc.status == ToolCallStatus.completed) {
      found = tc;
    }
  }
  return found;
}

/// The options of an ask_user call: a list, or a list encoded as a string.
List<String> askUserOptions(Object? raw) {
  Object? value = raw;
  if (value is String) {
    try {
      value = jsonDecode(value);
    } catch (_) {
      return const <String>[];
    }
  }
  if (value is! List) return const <String>[];
  return <String>[
    for (final Object? o in value)
      if (o != null && o.toString().trim().isNotEmpty) o.toString().trim(),
  ];
}

/// The card's request for [call], or null when the call has no question or
/// fewer than two options (the bubble then shows nothing either).
AgentsQuestionRequest? askUserRequestFor(ToolCall call) {
  final String question = (call.arguments['question'] ?? '').toString().trim();
  final List<String> options = askUserOptions(call.arguments['options']);
  if (question.isEmpty || options.length < 2) return null;
  return AgentsQuestionRequest(
    questionId: call.id,
    sessionKey: 'chat',
    status: AgentsQuestionRequest.statusOpen,
    questions: <AgentsQuestion>[
      AgentsQuestion(
        id: call.id,
        question: question,
        multiSelect: askUserIsMultiple(call.arguments['multiple']),
        options: <AgentsQuestionOption>[
          for (final String o in options) AgentsQuestionOption(label: o),
        ],
      ),
    ],
  );
}

/// The user message an answer sends: the picked labels (without the
/// "(Recommended)" tag) joined with ", ", then an own answer. Null for a
/// skip.
String? askUserAnswerText(
  AgentsQuestionRequest request,
  List<AgentsQuestionAnswer> answers,
) {
  final List<String> parts = <String>[];
  for (final AgentsQuestionAnswer a in answers) {
    if (a.isSkip) continue;
    final AgentsQuestion? q = request.questions
        .where((AgentsQuestion q) => q.id == a.id)
        .firstOrNull;
    final List<String> picked = <String>[
      for (final String label in a.selected)
        q?.options
                .where((AgentsQuestionOption o) => o.label == label)
                .firstOrNull
                ?.displayLabel ??
            label,
    ];
    final String custom = a.custom?.trim() ?? '';
    final String text = <String>[
      if (picked.isNotEmpty) picked.join(', '),
      if (custom.isNotEmpty) custom,
    ].join('. ');
    if (text.isNotEmpty) parts.add(text);
  }
  if (parts.isEmpty) return null;
  return parts.join('\n');
}

/// The card in the composer seat. [onAnswer] sends the text as the user
/// message; [onSkip] gives the seat back to the composer.
class ChatQuestionSeat extends StatelessWidget {
  const ChatQuestionSeat({
    super.key,
    required this.request,
    required this.onAnswer,
    required this.onSkip,
    this.dense = false,
  });

  final AgentsQuestionRequest request;
  final ValueChanged<String> onAnswer;
  final VoidCallback onSkip;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return AgentsQuestionCard(
      key: ValueKey<String>('chat-question-${request.questionId}'),
      request: request,
      dense: dense,
      keyboardShortcuts: true,
      onSubmit: (List<AgentsQuestionAnswer> answers) async {
        final String? text = askUserAnswerText(request, answers);
        if (text == null) {
          onSkip();
        } else {
          onAnswer(text);
        }
        return true;
      },
    );
  }
}
