/// What a coworker's run cost, and what the weekly budget said about it
/// (docs/WIRE_CONTRACT.md, "Cost per run and weekly budget").
///
/// The host prices every run in euro at the price the chuk API really charges
/// and sends it on `done.cost`, live and replayed. The app keeps that block
/// with the answer it belongs to, as ONE synthetic tool call
/// ([kAgentsRunCostTool]) on the answer's tool calls: the same field that
/// already carries the run's tool lines through the live fold, the replay and
/// the local cache, so the figure survives a restart with no new message
/// field. The chat list lifts it off before the bubble sees the calls
/// ([splitRunMeta]) and draws it as the answer's meta line.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';

/// One kind of model use inside a run: `run` (the agent loop), `aux` (the
/// context summary and the memory extraction) or `browser` (the browser
/// fallback).
@immutable
class AgentsRunCostLine {
  const AgentsRunCostLine({
    required this.kind,
    this.model,
    this.provider,
    this.calls,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cachedTokens = 0,
    this.eur,
  });

  final String kind;
  final String? model;
  final String? provider;
  final int? calls;

  /// Includes [cachedTokens].
  final int inputTokens;
  final int outputTokens;
  final int cachedTokens;

  /// Null when the host has no price for this line.
  final double? eur;

  int get totalTokens => inputTokens + outputTokens;

  static AgentsRunCostLine? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? kind = raw['kind'];
    if (kind is! String || kind.isEmpty) return null;
    return AgentsRunCostLine(
      kind: kind,
      model: _text(raw['model']),
      provider: _text(raw['provider']),
      calls: _int(raw['calls']),
      inputTokens: _int(raw['input_tokens']) ?? 0,
      outputTokens: _int(raw['output_tokens']) ?? 0,
      cachedTokens: _int(raw['cached_tokens']) ?? 0,
      eur: _eur(raw['eur']),
    );
  }
}

/// The `cost` block of a `done`. [eur] is the total and is present only when
/// every line is priced; a total that left a line out would be a wrong number.
@immutable
class AgentsRunCost {
  const AgentsRunCost({
    this.currency = 'EUR',
    this.eur,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cachedTokens = 0,
    this.lines = const <AgentsRunCostLine>[],
    this.raw = const <String, dynamic>{},
  });

  final String currency;
  final double? eur;

  /// Includes [cachedTokens].
  final int inputTokens;
  final int outputTokens;
  final int cachedTokens;
  final List<AgentsRunCostLine> lines;

  /// The block as the host sent it, kept so the stored copy is the wire copy.
  final Map<String, dynamic> raw;

  int get totalTokens => inputTokens + outputTokens;

  /// Null for anything that is not a cost block, and for a block that names
  /// no tokens and no price at all (nothing to show).
  static AgentsRunCost? fromJson(Object? source) {
    if (source is! Map) return null;
    final Map<String, dynamic> map = source.map(
      (Object? k, Object? v) => MapEntry('$k', v),
    );
    final List<AgentsRunCostLine> lines = <AgentsRunCostLine>[
      if (map['lines'] is List)
        for (final Object? line in map['lines'] as List)
          ?AgentsRunCostLine.fromJson(line),
    ];
    final cost = AgentsRunCost(
      currency: _text(map['currency']) ?? 'EUR',
      eur: _eur(map['eur']),
      inputTokens: _int(map['input_tokens']) ?? 0,
      outputTokens: _int(map['output_tokens']) ?? 0,
      cachedTokens: _int(map['cached_tokens']) ?? 0,
      lines: List<AgentsRunCostLine>.unmodifiable(lines),
      raw: map,
    );
    if (cost.eur == null && cost.totalTokens == 0 && lines.isEmpty) {
      return null;
    }
    return cost;
  }
}

String? _text(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;

int? _int(Object? value) {
  if (value is bool) return null;
  if (value is int) return value;
  if (value is num && value.isFinite) return value.toInt();
  return null;
}

double? _eur(Object? value) {
  if (value is bool || value is! num) return null;
  final double eur = value.toDouble();
  return eur.isFinite && eur >= 0 ? eur : null;
}

// ── the answer's copy: one synthetic tool call ──────────────────────────────

/// The name of the synthetic call that carries a run's meta on its answer:
/// what it cost and the host's run id (which folds a quiet automation run to
/// one line). Never shown as a tool line: [splitRunMeta] lifts it off first.
const String kAgentsRunMetaTool = 'agents_run_meta';

/// The run's meta as the call the answer keeps. ONE mapping for the live
/// ledger and the replay loader. Null when there is nothing to keep.
ToolCall? runMetaCall({AgentsRunCost? cost, String? runId, DateTime? now}) {
  if (cost == null && (runId == null || runId.isEmpty)) return null;
  final DateTime at = now ?? DateTime.now();
  final Map<String, dynamic> meta = <String, dynamic>{
    'cost': ?cost?.raw,
    if (runId != null && runId.isNotEmpty) 'run_id': runId,
  };
  return ToolCall(
    name: kAgentsRunMetaTool,
    arguments: meta,
    status: ToolCallStatus.completed,
    result: jsonEncode(meta),
    startedAt: at,
  )..completedAt = at;
}

/// Puts [call] on [calls] in place of an earlier meta call, keeping what the
/// earlier one knew and the new one does not (a second `finish` may carry the
/// run id and no cost).
void putRunMeta(List<ToolCall> calls, ToolCall? call) {
  if (call == null) return;
  Map<String, dynamic> merged = <String, dynamic>{};
  calls.removeWhere((ToolCall c) {
    if (c.name != kAgentsRunMetaTool) return false;
    merged = <String, dynamic>{...merged, ...c.arguments};
    return true;
  });
  merged = <String, dynamic>{...merged, ...call.arguments};
  calls.add(
    ToolCall(
      id: call.id,
      name: kAgentsRunMetaTool,
      arguments: merged,
      status: ToolCallStatus.completed,
      result: jsonEncode(merged),
      startedAt: call.startedAt,
    )..completedAt = call.completedAt,
  );
}

/// The answer's tool calls and content blocks without the meta call, and what
/// it carried (the last one wins). The lists come back unchanged (identical)
/// when there is no meta call, so a bubble that compares them sees no change.
({
  List<ToolCall>? toolCalls,
  List<ContentBlock>? contentBlocks,
  AgentsRunCost? cost,
  String? runId,
})
splitRunMeta(List<ToolCall>? toolCalls, List<ContentBlock>? contentBlocks) {
  AgentsRunCost? cost;
  String? runId;
  void read(ToolCall call) {
    cost = AgentsRunCost.fromJson(call.arguments['cost']) ?? cost;
    final Object? id = call.arguments['run_id'];
    if (id is String && id.isNotEmpty) runId = id;
  }

  bool isMeta(ToolCall c) => c.name == kAgentsRunMetaTool;
  List<ToolCall>? calls = toolCalls;
  if (toolCalls != null && toolCalls.any(isMeta)) {
    calls = <ToolCall>[];
    for (final ToolCall call in toolCalls) {
      if (isMeta(call)) {
        read(call);
      } else {
        calls.add(call);
      }
    }
  }
  List<ContentBlock>? blocks = contentBlocks;
  if (contentBlocks != null &&
      contentBlocks.any(
        (ContentBlock b) => b.toolCalls?.any(isMeta) ?? false,
      )) {
    blocks = <ContentBlock>[];
    for (final ContentBlock block in contentBlocks) {
      final List<ToolCall>? inBlock = block.toolCalls;
      if (block.type != ContentBlockType.toolCalls || inBlock == null) {
        blocks.add(block);
        continue;
      }
      final List<ToolCall> kept = <ToolCall>[];
      for (final ToolCall call in inBlock) {
        if (isMeta(call)) {
          read(call);
        } else {
          kept.add(call);
        }
      }
      // A block that held only the meta would draw an empty tool round.
      if (kept.isNotEmpty) blocks.add(ContentBlock.toolCalls(kept));
    }
  }
  return (toolCalls: calls, contentBlocks: blocks, cost: cost, runId: runId);
}

// ── formatting ──────────────────────────────────────────────────────────────

/// The meta line's euro figure: two decimals from €0.01, else "< €0.01".
/// German puts the sign after the number ("0,41 €").
String formatRunCostEur(double eur, {String locale = 'en'}) {
  final NumberFormat format = NumberFormat.currency(
    locale: _numberLocale(locale),
    symbol: '€',
    decimalDigits: 2,
  );
  if (eur < 0.01) return '< ${format.format(0.01)}';
  return format.format(eur);
}

/// A line's euro figure in the detail sheet: four decimals below €0.01, so a
/// summary that cost a fraction of a cent still shows what it cost.
String formatRunCostLineEur(double eur, {String locale = 'en'}) {
  final NumberFormat format = NumberFormat.currency(
    locale: _numberLocale(locale),
    symbol: '€',
    decimalDigits: eur < 0.01 ? 4 : 2,
  );
  return format.format(eur);
}

/// 950 -> "950", 5150 -> "5.2k", 1250000 -> "1.3M" ("5,2k" in German).
String formatTokenCount(int tokens, {String locale = 'en'}) {
  final String separator = _numberLocale(locale) == 'de' ? ',' : '.';
  String scaled(double value, String unit) {
    final String text = value >= 100
        ? value.round().toString()
        : value.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
    return '${text.replaceAll('.', separator)}$unit';
  }

  if (tokens < 1000) return '$tokens';
  if (tokens < 1000000) return scaled(tokens / 1000, 'k');
  return scaled(tokens / 1000000, 'M');
}

/// Only the locales the app ships; everything else formats as English.
String _numberLocale(String locale) {
  final String language = locale.split(RegExp('[-_]')).first.toLowerCase();
  return switch (language) {
    'de' || 'es' || 'fr' || 'pt' => language,
    _ => 'en',
  };
}

// ── the weekly budget ───────────────────────────────────────────────────────

/// A `budget_warning` frame: the coworker's week reached 80 % (`warning`) or
/// 100 % (`exceeded`) of its budget.
@immutable
class AgentsBudgetWarning {
  const AgentsBudgetWarning({
    required this.agentId,
    required this.level,
    this.sessionKey,
    this.currency = 'EUR',
    this.spentEur,
    this.budgetEur,
    this.weekStartsAt,
  });

  static const String levelWarning = 'warning';
  static const String levelExceeded = 'exceeded';

  final String agentId;
  final String? sessionKey;
  final String level;
  final String currency;
  final double? spentEur;
  final double? budgetEur;

  /// The host's Monday 00:00, unix seconds.
  final double? weekStartsAt;

  bool get isExceeded => level == levelExceeded;

  /// What makes two frames the same notice: the coworker, its week, the level.
  String get dedupKey => '$agentId\u0000${weekStartsAt ?? ''}\u0000$level';

  /// Null when the frame names no coworker or no known level.
  static AgentsBudgetWarning? fromPayload(Map<String, dynamic> payload) {
    final String? agentId = _text(payload['agent_id']);
    final String? level = _text(payload['level']);
    if (agentId == null) return null;
    if (level != levelWarning && level != levelExceeded) return null;
    final Object? week = payload['week_starts_at'];
    return AgentsBudgetWarning(
      agentId: agentId,
      sessionKey: _text(payload['session_key']),
      level: level!,
      currency: _text(payload['currency']) ?? 'EUR',
      spentEur: _eur(payload['spent_eur']),
      budgetEur: _eur(payload['budget_eur']),
      weekStartsAt: week is num && week is! bool ? week.toDouble() : null,
    );
  }
}

/// The budget notices the threads show. One per coworker, week and level:
/// the host sends each level once a week, but a host restart can send one
/// again, and a second socket can deliver the same frame twice.
class AgentsBudgetNotices extends ChangeNotifier {
  AgentsBudgetNotices._();

  static final AgentsBudgetNotices instance = AgentsBudgetNotices._();

  final Set<String> _seen = <String>{};
  final Map<String, AgentsBudgetWarning> _byThread =
      <String, AgentsBudgetWarning>{};

  /// Records [warning]. False when this coworker's week already had it.
  bool add(AgentsBudgetWarning warning) {
    if (!_seen.add(warning.dedupKey)) return false;
    // The coworker's own thread is its id, so a frame without a session key
    // still finds its thread.
    _byThread[warning.sessionKey ?? warning.agentId] = warning;
    notifyListeners();
    return true;
  }

  /// The newest notice for [threadKey], or null.
  AgentsBudgetWarning? forThread(String threadKey) => _byThread[threadKey];

  /// The user closed the notice. It does not come back this week.
  void dismiss(String threadKey) {
    if (_byThread.remove(threadKey) != null) notifyListeners();
  }

  @visibleForTesting
  void reset() {
    _seen.clear();
    _byThread.clear();
  }
}

/// "Run anyway": the next task of one thread goes over the weekly budget
/// once (`budget_override: true`). Armed by the budget notice, consumed by
/// the first task frame of that thread, and only within [window], so a stale
/// arm can never let a later, unrelated task through.
class AgentsBudgetOverride {
  AgentsBudgetOverride._();

  static const Duration window = Duration(minutes: 2);

  static final Map<String, DateTime> _armed = <String, DateTime>{};

  static void arm(String sessionKey) {
    if (sessionKey.isEmpty) return;
    _armed[sessionKey] = DateTime.now();
  }

  /// True once for an armed [sessionKey], then false.
  static bool consume(String sessionKey) {
    final DateTime? at = _armed.remove(sessionKey);
    if (at == null) return false;
    return DateTime.now().difference(at) <= window;
  }

  static void disarm(String sessionKey) => _armed.remove(sessionKey);

  @visibleForTesting
  static bool isArmed(String sessionKey) => _armed.containsKey(sessionKey);

  @visibleForTesting
  static void reset() => _armed.clear();
}
