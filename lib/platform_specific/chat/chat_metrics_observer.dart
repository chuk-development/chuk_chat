// lib/platform_specific/chat/chat_metrics_observer.dart
import 'package:flutter/widgets.dart';

/// Calls back on every view-metrics change — the soft keyboard opening or
/// closing, a rotation. Kept as its own observer instead of a mixin on the
/// chat State so the State keeps the mixins it already has.
class ChatMetricsObserver with WidgetsBindingObserver {
  ChatMetricsObserver(this.onMetrics);

  final VoidCallback onMetrics;

  @override
  void didChangeMetrics() => onMetrics();
}
