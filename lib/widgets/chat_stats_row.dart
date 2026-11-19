// lib/widgets/chat_stats_row.dart
//
// A quiet row under the composer: how fast the last reply came, how much of
// its prompt the provider's cache served, how long that cache stays warm,
// and how full the model's context is. One fixed height, so the composer
// never jumps when a number arrives.
//
// The cache countdown shows only in plain chats, and only for a provider
// whose cache lifetime is documented or measured
// (`lib/services/prompt_cache_lifetime.dart`). It counts from the end of the
// last reply this app session saw; after a restart it is gone.
//
// The numbers come from `ChatTurnStats` (written by the streaming manager).
// A count the reply did not report is "—", never 0 (docs/GOTCHAS.md, Usage).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/turn_usage.dart';
import 'package:chuk_chat/services/chat_turn_stats.dart';
import 'package:chuk_chat/services/prompt_cache_lifetime.dart';
import 'package:chuk_chat/services/provider_cache_affinity.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';

/// Height of the row. Fixed: the slot never grows or shrinks with content.
const double kChatStatsRowHeight = 20;

/// Narrower than this, the row is not drawn at all: the three values would
/// crowd the composer on a small phone.
const double kChatStatsRowMinWidth = 360;

class ChatStatsRow extends StatefulWidget {
  const ChatStatsRow({
    super.key,
    required this.chatId,
    required this.modelId,
    this.providerSlug,
    this.stats,
    this.contextLimitOverride,
    this.affinity,
  });

  /// The open chat. Null on a new chat: nothing to show yet.
  final String? chatId;

  /// The selected model, for the context limit.
  final String modelId;

  /// The selected provider, when one is pinned.
  final String? providerSlug;

  /// The source of the numbers. Tests pass their own; null is the app's.
  final ChatTurnStats? stats;

  /// A context limit to use instead of the catalogue's. Tests only.
  final int? contextLimitOverride;

  /// Which provider served the chat last, and when. Tests pass their own;
  /// null is the app's.
  final ProviderCacheAffinity? affinity;

  @override
  State<ChatStatsRow> createState() => _ChatStatsRowState();
}

class _ChatStatsRowState extends State<ChatStatsRow> {
  ChatTurnStats get _stats => widget.stats ?? ChatTurnStats.instance;

  ProviderCacheAffinity get _affinity =>
      widget.affinity ?? ProviderCacheAffinity.instance;

  /// Redraws the countdown once a second, only when its text changed.
  Timer? _ticker;
  String? _lastCountdown;

  @override
  void initState() {
    super.initState();
    _loadLimit();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final String? text = _cacheCountdown(null)?.label;
      if (text != _lastCountdown && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(ChatStatsRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.modelId != widget.modelId ||
        oldWidget.providerSlug != widget.providerSlug) {
      _loadLimit();
    }
  }

  void _loadLimit() {
    if (widget.contextLimitOverride != null) return;
    // The stats notify when the limit arrives; the builder reads it then.
    _stats.contextLengthFor(widget.modelId, widget.providerSlug);
  }

  int? get _limit =>
      widget.contextLimitOverride ??
      _stats.cachedContextLength(widget.modelId, widget.providerSlug);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth < kChatStatsRowMinWidth) {
          return const SizedBox.shrink();
        }
        return SizedBox(
          height: kChatStatsRowHeight,
          child: ListenableBuilder(
            listenable: _stats,
            builder: (BuildContext context, _) {
              final ChatTurnStatsEntry? entry = _stats.displayOf(widget.chatId);
              if (entry == null || entry.isEmpty) {
                return const SizedBox.shrink();
              }
              return _buildRow(context, entry);
            },
          ),
        );
      },
    );
  }

  Widget _buildRow(BuildContext context, ChatTurnStatsEntry entry) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations? l10n = AppLocalizations.of(context);
    final String unknown = l10n?.chatStatsUnknown ?? '—';
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.55);
    final TextStyle style =
        (theme.textTheme.labelSmall ?? const TextStyle(fontSize: 11)).copyWith(
          color: muted,
          fontSize: 11,
          height: 1,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        );

    final TurnUsage? usage = entry.usage;
    final double? tps = entry.tps;
    final double? hit = usage?.cacheHitRatio;
    final String tpsText = tps == null ? unknown : tps.toStringAsFixed(1);
    final String hitText = hit == null ? unknown : '${(hit * 100).round()}%';

    final int? used = _usedTokens(usage);
    final int? limit = _limit;
    final double? fill = used == null || limit == null || limit <= 0
        ? null
        : (used / limit).clamp(0.0, 1.0);

    final String usedText = used == null ? unknown : formatTokenCount(used);
    final String limitText = limit == null ? unknown : formatTokenCount(limit);
    final List<String> tip = <String>[
      l10n?.chatStatsContext(usedText, limitText) ??
          'Context $usedText of $limitText',
      l10n?.chatStatsPrompt(_count(usage?.promptTokens, unknown)) ??
          'Prompt: ${_count(usage?.promptTokens, unknown)}',
      l10n?.chatStatsCached(_count(usage?.cachedTokens, unknown)) ??
          'Cached: ${_count(usage?.cachedTokens, unknown)}',
      l10n?.chatStatsCompletion(_count(usage?.completionTokens, unknown)) ??
          'Completion: ${_count(usage?.completionTokens, unknown)}',
    ];

    final _CacheCountdown? countdown = _cacheCountdown(l10n);
    _lastCountdown = countdown?.label;

    Widget dot() => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text('·', style: style),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Text(
            l10n?.chatStatsTokPerSec(tpsText) ?? '$tpsText tok/s',
            key: const ValueKey<String>('chat-stats-tps'),
            style: style,
          ),
          dot(),
          Text(
            l10n?.chatStatsCacheHit(hitText) ?? 'Cache hit $hitText',
            key: const ValueKey<String>('chat-stats-cache'),
            style: style,
          ),
          if (countdown != null) ...<Widget>[
            dot(),
            Tooltip(
              key: const ValueKey<String>('chat-stats-cache-ttl'),
              message: countdown.tip,
              child: Text(countdown.label, style: style),
            ),
          ],
          dot(),
          Tooltip(
            key: const ValueKey<String>('chat-stats-context'),
            message: tip.join('\n'),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                SizedBox.square(
                  dimension: 12,
                  child: CustomPaint(
                    painter: ContextRingPainter(
                      fill: fill,
                      track: theme.colorScheme.onSurface.withValues(
                        alpha: 0.14,
                      ),
                      arc: fill != null && fill >= 0.9
                          ? theme.colorScheme.error
                          : muted,
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  fill == null ? unknown : '${(fill * 100).round()}%',
                  style: style,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The cache countdown of the open chat, or null when there is nothing
  /// true to show: an Agents thread, no reply seen in this session, another
  /// model or a pinned other provider, or a provider without a known
  /// cache lifetime.
  _CacheCountdown? _cacheCountdown(AppLocalizations? l10n) {
    final String? chatId = widget.chatId;
    if (chatId == null || ChatOrigin.isAgentsThread(chatId)) return null;
    final ProviderAffinity? served = _affinity.lastServedFor(chatId);
    if (served == null || served.modelId != widget.modelId) return null;
    final String? pinned = widget.providerSlug;
    if (pinned != null &&
        pinned.isNotEmpty &&
        _family(pinned) != _family(served.providerSlug)) {
      return null;
    }
    final PromptCacheLifetime? lifetime = promptCacheLifetimeFor(
      served.modelId,
      served.providerSlug,
    );
    if (lifetime == null) return null;
    final Duration remaining = served.servedAt
        .add(lifetime.duration)
        .difference(_affinity.now());
    final String provider = _providerName(served.providerSlug);
    final String ttl = formatCacheTtl(lifetime.duration);
    final String label;
    if (remaining <= Duration.zero) {
      label = lifetime.isExact
          ? (l10n?.chatStatsCacheExpired ?? 'Cache expired')
          : (l10n?.chatStatsCacheLikelyExpired ?? 'Cache likely expired');
    } else if (lifetime.isExact) {
      final String time = formatCacheRemaining(remaining);
      label = l10n?.chatStatsCacheLeft(time) ?? 'Cache $time left';
    } else {
      final String time = formatCacheTtl(remaining, roundUp: true);
      label = l10n?.chatStatsCacheLeftApprox(time) ?? 'Cache ~$time left';
    }
    final String tip = lifetime.isExact
        ? (l10n?.chatStatsCacheTip(provider, ttl) ??
              '$provider keeps the prompt cached for $ttl after the last '
                  'reply. A message after that pays for the full prompt again.')
        : (l10n?.chatStatsCacheTipApprox(provider, ttl) ??
              '$provider usually keeps the prompt cached for about $ttl after '
                  'the last reply, with no guarantee. A message after that '
                  'may pay for the full prompt again.');
    return _CacheCountdown(label, tip);
  }

  static String _family(String slug) => slug.split('/').first.toLowerCase();

  /// `fireworks/fp8` -> `Fireworks`.
  static String _providerName(String slug) {
    final String family = slug.split('/').first;
    if (family.isEmpty) return slug;
    return family[0].toUpperCase() + family.substring(1);
  }

  static int? _usedTokens(TurnUsage? usage) {
    if (usage == null) return null;
    final int? prompt = usage.promptTokens;
    final int? completion = usage.completionTokens;
    if (prompt == null && completion == null) return usage.totalTokens;
    return (prompt ?? 0) + (completion ?? 0);
  }

  static String _count(int? value, String unknown) =>
      value == null ? unknown : formatTokenCount(value);
}

/// The countdown text and its tooltip.
class _CacheCountdown {
  const _CacheCountdown(this.label, this.tip);

  final String label;
  final String tip;
}

/// `950`, `12.3k`, `128k`, `1.0M`.
String formatTokenCount(int value) {
  if (value < 1000) return '$value';
  if (value < 1000000) {
    final double k = value / 1000;
    return k >= 100 ? '${k.round()}k' : '${k.toStringAsFixed(1)}k';
  }
  return '${(value / 1000000).toStringAsFixed(1)}M';
}

/// A thin ring: the neutral track, and the used part as an arc from 12 o'clock.
class ContextRingPainter extends CustomPainter {
  const ContextRingPainter({
    required this.fill,
    required this.track,
    required this.arc,
  });

  /// 0..1, or null when the limit or the use is unknown (track only).
  final double? fill;
  final Color track;
  final Color arc;

  @override
  void paint(Canvas canvas, Size size) {
    const double stroke = 2;
    final Rect rect = (Offset.zero & size).deflate(stroke / 2);
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawOval(rect, paint);
    final double? value = fill;
    if (value == null || value <= 0) return;
    paint
      ..color = arc
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, -math.pi / 2, 2 * math.pi * value, false, paint);
  }

  @override
  bool shouldRepaint(ContextRingPainter old) =>
      old.fill != fill || old.track != track || old.arc != arc;
}
