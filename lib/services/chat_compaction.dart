// lib/services/chat_compaction.dart
//
// Chat compaction for long chats (docs/GOTCHAS.md, "Chat compaction").
//
// When the next request would fill most of the model's context window, the
// older turns are summarized by the SAME model, as a continuation of the
// chat's own request: the same system prompt, the same `tools[]`, the
// history byte for byte up to the kept tail, plus one instruction message
// (purpose `compact`). That request is a prefix of the last one, so the
// provider's prompt cache serves it.
//
// The summary is stored on the first kept user message (`compactSummary`,
// JSON [CompactionRecord]), encrypted with the chat payload. From then on
// ChatHistoryBuilder sends [summary message] + [tail], after the chat's
// frozen system prompt. The trigger and the tail follow deepseek-harness
// `compaction-basic`: trigger at `min(W * 0.8, W - O - headroom)`, keep the
// newest `0.16 * (W - O)` tokens verbatim, reject a summary that is not
// smaller than what it replaces.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/prompt_cache/prompt_context.dart';
import 'package:chuk_chat/utils/image_token_estimator.dart';
import 'package:chuk_chat/utils/token_estimator.dart';

/// One stored summary: it replaces every message before the message that
/// carries it.
@immutable
class CompactionRecord {
  const CompactionRecord({
    required this.summary,
    required this.madeAt,
    this.modelId,
  });

  /// The 8-section summary text the model wrote.
  final String summary;

  /// How many messages the chat had when the summary was made (the index
  /// of the user message whose send triggered it). A usage count of an
  /// answer before this index was measured on the uncompacted history.
  final int madeAt;

  /// The model that wrote the summary.
  final String? modelId;

  String encode() => jsonEncode(<String, dynamic>{
    'summary': summary,
    'madeAt': madeAt,
    if (modelId != null) 'model': modelId,
  });

  /// Reads [encode]'s output. Null for null, empty or broken input.
  static CompactionRecord? decode(String? stored) {
    if (stored == null || stored.isEmpty) return null;
    try {
      final Object? raw = jsonDecode(stored);
      if (raw is! Map) return null;
      final Object? summary = raw['summary'];
      if (summary is! String || summary.trim().isEmpty) return null;
      final Object? madeAt = raw['madeAt'];
      return CompactionRecord(
        summary: summary,
        madeAt: madeAt is num ? madeAt.toInt() : 0,
        modelId: raw['model'] as String?,
      );
    } on FormatException {
      return null;
    }
  }
}

/// Trigger and tail size for one model, in tokens.
@immutable
class CompactionBudget {
  const CompactionBudget({required this.threshold, required this.retain});

  /// Compact when the estimated prompt reaches this.
  final int threshold;

  /// Newest tokens kept verbatim.
  final int retain;
}

/// What a compaction did.
enum CompactionStatus {
  /// Below the trigger, or nothing older than the tail to summarize.
  notNeeded,

  /// The summary is stored on the message at [CompactionOutcome.tailStart].
  compacted,

  /// The summary request failed, came back empty or was not smaller.
  failed,
}

@immutable
class CompactionOutcome {
  const CompactionOutcome(
    this.status, {
    this.tailStart,
    this.reason,
    this.record,
    this.messages,
    this.overflow = false,
    this.estimate,
    this.window,
  });

  final CompactionStatus status;
  final int? tailStart;
  final String? reason;

  /// The encoded [CompactionRecord] written onto `messages[tailStart]`.
  final String? record;

  /// The compacted copy of the rows before the message being sent
  /// (`0..end-1`), with [record] on the row at [tailStart]. The send
  /// rebuilds its history from this copy, never from the screen's live
  /// list: that list may hold another chat by now.
  final List<Map<String, String>>? messages;

  /// The request does not fit the model's window and nothing was
  /// compacted: the send must stop with [ChatCompaction.overflowError]
  /// instead of going out blind.
  final bool overflow;

  /// The estimated prompt and the model's window, set with [overflow].
  final int? estimate;
  final int? window;

  /// The error the send shows on [overflow].
  String get overflowMessage =>
      ChatCompaction.overflowError(estimate ?? 0, window ?? 0);

  bool get compacted => status == CompactionStatus.compacted;

  /// The row the summary belongs to (from [messages]), or null.
  Map<String, String>? get target {
    final int? i = tailStart;
    final rows = messages;
    if (!compacted || i == null || rows == null || i >= rows.length) {
      return null;
    }
    return rows[i];
  }

  /// Writes [record] onto [live] at [tailStart] when that row is still the
  /// message it was made for ([ChatCompaction.sameMessage]). False (and
  /// [live] untouched) when the list holds another chat or the row moved.
  bool writeInto<V>(List<Map<String, V>> live) {
    final int? i = tailStart;
    final String? r = record;
    final Map<String, String>? t = target;
    if (i == null || r == null || t == null) return false;
    if (i >= live.length || !ChatCompaction.sameMessage(live[i], t)) {
      return false;
    }
    live[i] = Map<String, V>.from(live[i])..[ChatCompaction.fieldKey] = r as V;
    return true;
  }
}

/// Sends one summary request and yields its stream. The app's sender is
/// `WebSocketChatService.sendStreamingChat` with purpose `compact`.
typedef CompactionSend =
    Stream<ChatStreamEvent> Function({
      required String instruction,
      required List<Map<String, dynamic>> history,
      required String modelId,
      required String providerSlug,
    });

class ChatCompaction {
  const ChatCompaction._();

  /// The message-map key of a stored [CompactionRecord].
  static const String fieldKey = 'compactSummary';

  static const double thresholdRatio = 0.8;
  static const double retainRatio = 0.16;
  static const int headroomTokens = 65536;

  /// The summary request asks for at most this many tokens.
  static const int summaryMaxTokens = 8192;

  /// The instruction sent as the last user message of the summary request.
  static const String instruction =
      'You are now acting as a compaction engine for this conversation. '
      'Condense the conversation ABOVE into a structured checkpoint that '
      'lets the assistant continue with no loss of essential context.\n'
      '\n'
      'Output EXACTLY the Markdown structure below: keep every section, in '
      'order. Use terse bullets, not prose paragraphs. Write "(none)" for an '
      'empty section; never drop a section.\n'
      '\n'
      '## Primary Request and Intent\n'
      "- [the user's original and evolving goals; quote verbatim where the "
      'exact wording matters]\n'
      '\n'
      '## Key Concepts\n'
      '- [topics, facts, technologies and conventions in play]\n'
      '\n'
      '## Files, Data and Code\n'
      '- [documents, links, numbers, code: why they matter, key content]\n'
      '\n'
      '## Errors and Fixes\n'
      '- [problem: how it was resolved, plus related user feedback]\n'
      '\n'
      '## Pending Tasks\n'
      '- [explicitly requested work not yet done]\n'
      '\n'
      '## Current Work\n'
      '- [precisely what was in progress at this checkpoint]\n'
      '\n'
      '## Next Step\n'
      '- [the single next action, in line with the most recent request, '
      'or "(none)"]\n'
      '\n'
      '## Critical Context\n'
      '- [decisions and their reasons, constraints, user preferences, open '
      'questions, data needed to continue]\n'
      '\n'
      'Rules:\n'
      "- Write in the conversation's language. Keep exact names, paths, "
      'commands, error strings, identifiers and numbers.\n'
      '- Capture user feedback and explicit instructions faithfully, '
      'especially corrections.\n'
      '- Write finished actions in the past tense.\n'
      '- Never reproduce a secret, token, password or key; write [REDACTED].\n'
      '- Do NOT mention this summarization request.\n'
      '- Output only the checkpoint text: do not call any tool.\n'
      '- If the conversation already starts with a <compacted-summary> '
      'block, it is a PRIOR checkpoint: keep still-true facts, drop stale '
      'ones and merge newer information into one summary with the same '
      'structure.';

  static const String _preamble =
      'This is an automatically generated checkpoint condensing an earlier '
      'span of the conversation to free up context. Treat the captured '
      'context as established background and build on it without restating '
      'it. Continue directly from the messages that follow, without '
      'acknowledging this checkpoint.';

  /// The error a send shows when the chat does not fit the model's window
  /// and could not be compacted.
  static String overflowError(int estimate, int window) =>
      'Too much context for this model ($estimate vs $window token limit). '
      'Compaction failed. Clear history or shorten your message.';

  /// Whether [a] and [b] are the same chat message: the same `messageId`
  /// when both carry one, else the same sender, text and send time. A
  /// stored [fieldKey] does not count.
  static bool sameMessage(Map<String, Object?> a, Map<String, Object?> b) {
    if (a['sender'] != b['sender']) return false;
    final Object? idA = a['messageId'];
    final Object? idB = b['messageId'];
    if (idA is String && idA.isNotEmpty && idB is String && idB.isNotEmpty) {
      return idA == idB;
    }
    return a['text'] == b['text'] && a['sentAt'] == b['sentAt'];
  }

  /// The history entry that stands for everything a summary replaced.
  static String summaryMessage(String summary) =>
      '$_preamble\n\n<compacted-summary>\n${summary.trim()}\n'
      '</compacted-summary>';

  /// Trigger and tail for a window of [contextWindow] tokens with
  /// [maxOutput] reserved for the answer. The headroom is 65536 tokens, at
  /// most half of `W - O`, so a small window still gets a usable trigger.
  /// Null when the window is unknown or too small.
  static CompactionBudget? budgetFor({
    required int? contextWindow,
    required int maxOutput,
  }) {
    final int? w = contextWindow;
    if (w == null || w <= 0) return null;
    final int usable = w - math.max(0, maxOutput);
    if (usable <= 1024) return null;
    final int headroom = math.min(headroomTokens, usable ~/ 2);
    final int threshold = math.min(w * thresholdRatio, usable - headroom)
        .floor();
    final int retain = (usable * retainRatio).floor();
    if (retain >= threshold) return null;
    return CompactionBudget(threshold: threshold, retain: retain);
  }

  /// The output reservation of a model: its completion cap, else a quarter
  /// of the window (the same rule as the send's token budget).
  static int maxOutputFor(int contextWindow, int? maxCompletionTokens) =>
      maxCompletionTokens != null && maxCompletionTokens > 0
      ? math.min(maxCompletionTokens, contextWindow ~/ 2)
      : math.max(256, contextWindow ~/ 4);

  /// Index of the newest user message carrying a summary, or -1.
  static int latestCompactionIndex(List<Map<String, String>> messages) {
    for (var i = messages.length - 1; i > 0; i--) {
      final m = messages[i];
      if (m['sender'] != 'user') continue;
      final raw = m[fieldKey];
      if (raw != null && CompactionRecord.decode(raw) != null) return i;
    }
    return -1;
  }

  /// Rough tokens of one UI message: text, document bodies, the tool
  /// rounds its turn replays (`modelContext` transcript) and its images
  /// (per-model formula, [kUnknownImageTokens] when the size is unknown).
  /// Reasoning is not sent. Used to size the kept tail.
  static int messageTokens(Map<String, String> m, {String? modelId}) {
    var chars = (m['text'] ?? '').length;
    chars += (m['attachments'] ?? '').length;
    chars += (m['toolCalls'] ?? '').length ~/ 2;
    final String? context = m['modelContext'];
    if (context != null && context.isNotEmpty) {
      final TurnPromptContext? decoded = TurnPromptContext.decode(context);
      if (decoded != null) {
        final rounds = decoded.transcript;
        if (rounds != null && rounds.isNotEmpty) {
          chars += jsonEncode(rounds).length;
        }
        chars += (decoded.sent ?? '').length;
      }
    }
    var tokens = (chars / 4).ceil() + 8;
    final String? images = m['images'];
    if (images != null && images.isNotEmpty) {
      tokens += _imageTokens(images, modelId);
    }
    return tokens;
  }

  static int _imageTokens(String raw, String? modelId) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return kUnknownImageTokens;
    }
    if (decoded is! List) return 0;
    var total = 0;
    for (final Object? image in decoded) {
      if (image is! String || image.isEmpty) continue;
      final size = image.startsWith('data:')
          ? ImageTokenEstimator.dimensionsOfDataUrl(image)
          : null;
      total += size == null
          ? kUnknownImageTokens
          : ImageTokenEstimator.tokensFor(modelId, size.$1, size.$2);
    }
    return total;
  }

  /// The estimated prompt size of the next request: the last real usage
  /// (prompt + completion of the newest measured answer, not older than the
  /// latest compaction) plus the messages after it and [pendingMessage].
  /// Without such an answer: the full estimate over [history].
  static int estimatePrompt({
    required List<Map<String, String>> messages,
    required List<Map<String, dynamic>> history,
    required String pendingMessage,
    String? systemPrompt,
    String? modelId,
  }) {
    final int compactedAt = latestCompactionIndex(messages);
    final record = compactedAt > 0
        ? CompactionRecord.decode(messages[compactedAt][fieldKey])
        : null;
    final anchor = TokenEstimator.usageAnchorOf(
      messages,
      notBefore: record?.madeAt ?? 0,
    );
    return TokenEstimator.anchoredPromptTokens(
      anchor: anchor,
      messagesAfterAnchor: anchor == null
          ? const <Map<String, dynamic>>[]
          : <Map<String, dynamic>>[
              for (final m in messages.skip(anchor.messageIndex + 1))
                <String, dynamic>{
                  'content': '${m['text'] ?? ''}${m['attachments'] ?? ''}',
                },
            ],
      fullHistory: history,
      pendingMessage: pendingMessage,
      systemPrompt: systemPrompt,
      modelId: modelId,
    );
  }

  /// Where the kept tail starts: the earliest user message after the
  /// latest compaction from which the messages up to [end] (exclusive) fit
  /// in [retainTokens]. Always keeps the last user turn. Null when there is
  /// nothing before the tail to summarize.
  static int? chooseTailStart(
    List<Map<String, String>> messages, {
    required int end,
    required int retainTokens,
    String? modelId,
  }) {
    final int from = math.max(1, latestCompactionIndex(messages) + 1);
    int? best;
    var tokens = 0;
    for (var i = math.min(end, messages.length) - 1; i >= from; i--) {
      tokens += messageTokens(messages[i], modelId: modelId);
      if (messages[i]['sender'] != 'user') continue;
      if (best != null && tokens > retainTokens) break;
      best = i;
    }
    return best;
  }

  /// Whether a model switch needs the old model to summarize: the chat's
  /// last answer came from [previousModelId] with a larger window than the
  /// one it switches to.
  static bool summarizeWithPrevious({
    required String currentModelId,
    required String? previousModelId,
    required int? currentWindow,
    required int? previousWindow,
  }) =>
      previousModelId != null &&
      previousModelId.isNotEmpty &&
      previousModelId != currentModelId &&
      previousWindow != null &&
      currentWindow != null &&
      previousWindow > currentWindow;

  /// The model and provider of the chat's last answer before [end].
  static (String, String?)? lastAnswerModel(
    List<Map<String, String>> messages,
    int end,
  ) {
    for (var i = math.min(end, messages.length) - 1; i >= 0; i--) {
      final m = messages[i];
      if (m['sender'] == 'user') continue;
      final id = m['modelId'];
      if (id != null && id.isNotEmpty) return (id, m['provider']);
    }
    return null;
  }

  /// Compacts [messages] when the next request reaches the trigger.
  ///
  /// [messages] is the chat's list without the message being sent now
  /// (indexes `0..end-1`); pass a copy, the record is written into it.
  /// [buildHistory] builds the request history as the send would
  /// (ChatHistoryBuilder.build with its `messageStarts`), so the summary
  /// request reuses its bytes. [summaryWindow] is the summarizing model's
  /// window: a span that does not fit it loses its oldest turns first. On
  /// success the record is written into `messages[tailStart]`.
  static Future<CompactionOutcome> maybeCompact({
    required List<Map<String, String>> messages,
    required int end,
    required int estimatedPromptTokens,
    required CompactionBudget budget,
    required int madeAt,
    required String summaryModelId,
    required String summaryProviderSlug,
    required Future<List<Map<String, dynamic>>> Function(List<int> starts)
    buildHistory,
    required CompactionSend send,
    bool force = false,
    int? summaryWindow,
    String? systemPrompt,
  }) async {
    if (!force && estimatedPromptTokens < budget.threshold) {
      return const CompactionOutcome(CompactionStatus.notNeeded);
    }
    final int? tailStart = chooseTailStart(
      messages,
      end: end,
      retainTokens: budget.retain,
      modelId: summaryModelId,
    );
    if (tailStart == null) {
      return const CompactionOutcome(
        CompactionStatus.notNeeded,
        reason: 'nothing to summarize',
      );
    }
    final starts = <int>[];
    final history = await buildHistory(starts);
    if (tailStart >= starts.length) {
      return const CompactionOutcome(
        CompactionStatus.failed,
        reason: 'history does not match the messages',
      );
    }
    // The summarized span: a byte prefix of the chat's own history.
    var prefix = history.sublist(
      0,
      math.min(math.max(0, starts[tailStart]), history.length),
    );
    if (prefix.isEmpty) {
      return const CompactionOutcome(CompactionStatus.notNeeded);
    }
    if (summaryWindow != null && summaryWindow > 0) {
      prefix = fitPrefix(
        prefix,
        limit:
            summaryWindow -
            math.min<int>(summaryMaxTokens, summaryWindow ~/ 4) -
            TokenEstimator.estimateTokens(instruction) -
            (systemPrompt == null
                ? 0
                : TokenEstimator.estimateTokens(systemPrompt)),
        modelId: summaryModelId,
      );
      if (prefix.isEmpty) {
        return const CompactionOutcome(
          CompactionStatus.failed,
          reason: 'span does not fit the summarizing model',
        );
      }
    }

    final buffer = StringBuffer();
    String? error;
    try {
      await for (final event in send(
        instruction: instruction,
        history: prefix,
        modelId: summaryModelId,
        providerSlug: summaryProviderSlug,
      )) {
        switch (event) {
          case ContentEvent(:final text):
            buffer.write(text);
          case FinalContentEvent(:final text):
            buffer
              ..clear()
              ..write(text);
          case ErrorEvent(:final message):
            error = message;
          default:
            break;
        }
      }
    } catch (e) {
      error = '$e';
    }
    if (error != null) {
      return CompactionOutcome(CompactionStatus.failed, reason: error);
    }
    final summary = cleanSummary(buffer.toString());
    if (summary == null) {
      return const CompactionOutcome(
        CompactionStatus.failed,
        reason: 'empty summary',
      );
    }
    final int replaced = TokenEstimator.estimatePromptTokens(
      history: prefix,
      currentMessage: '',
      modelId: summaryModelId,
    );
    final int framed = TokenEstimator.estimateTokens(summaryMessage(summary));
    if (framed >= replaced) {
      return CompactionOutcome(
        CompactionStatus.failed,
        reason: 'summary is not smaller ($framed >= $replaced)',
      );
    }
    final String record = CompactionRecord(
      summary: summary,
      madeAt: madeAt,
      modelId: summaryModelId,
    ).encode();
    messages[tailStart] = Map<String, String>.from(messages[tailStart])
      ..[fieldKey] = record;
    return CompactionOutcome(
      CompactionStatus.compacted,
      tailStart: tailStart,
      record: record,
      messages: messages,
    );
  }

  /// [prefix] without its oldest turns until it fits [limit] tokens. A
  /// leading prior checkpoint (the summary message) stays; the cut always
  /// lands on a user entry, so no tool result loses its call. Empty when
  /// not even the newest turn fits.
  @visibleForTesting
  static List<Map<String, dynamic>> fitPrefix(
    List<Map<String, dynamic>> prefix, {
    required int limit,
    String? modelId,
  }) {
    final List<int> sizes = <int>[
      for (final entry in prefix)
        TokenEstimator.estimateEntryTokens(entry, modelId: modelId),
    ];
    final int total = sizes.fold(0, (a, b) => a + b);
    if (total <= limit) return prefix;
    if (limit <= 0) return const <Map<String, dynamic>>[];
    final Object? first = prefix.first['content'];
    final bool keepCheckpoint =
        first is String && first.contains('<compacted-summary>');
    final int headCount = keepCheckpoint ? 1 : 0;
    var dropped = 0;
    for (var cut = headCount; cut < prefix.length; cut++) {
      if (cut > headCount && prefix[cut]['role'] == 'user') {
        if (total - dropped <= limit) {
          return <Map<String, dynamic>>[
            ...prefix.take(headCount),
            ...prefix.skip(cut),
          ];
        }
      }
      dropped += sizes[cut];
    }
    return const <Map<String, dynamic>>[];
  }

  /// The summary text without thinking blocks and a wrapping
  /// `<compacted-summary>` the model may have copied. Null when empty.
  @visibleForTesting
  static String? cleanSummary(String raw) {
    var text = raw.replaceAll(
      RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false),
      '',
    );
    text = text
        .replaceAll('<compacted-summary>', '')
        .replaceAll('</compacted-summary>', '')
        .trim();
    return text.isEmpty ? null : text;
  }
}
