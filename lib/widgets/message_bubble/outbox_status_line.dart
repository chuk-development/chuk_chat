// lib/widgets/message_bubble/outbox_status_line.dart
//
// The line under a user bubble that says what the offline outbox does with
// the message: waiting, uploading, transcribing, sending, failed or held.
// It reads the outbox row by the message's queue id from
// `OfflineRetryManager.instance.rows`. Only this line listens to the outbox,
// so the bubble above it does not rebuild on every outbox change.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/chat_message.dart' show ChatMessageStatus;
import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/services/offline_retry_manager.dart';
import 'package:chuk_chat/services/offline_send_coordinator.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// Retry or delete one outbox row by its queue id.
typedef OutboxRowAction = Future<void> Function(String queueId);

/// The outbox status of one user message.
///
/// With a row for [queueId], the row's state decides the line. Without a row
/// (an Agents outbox entry, or a row that is already gone), [status] decides
/// it, and Retry calls [onRetryFallback]. When neither applies, the line
/// draws nothing.
class OutboxStatusLine extends StatefulWidget {
  const OutboxStatusLine({
    super.key,
    required this.status,
    this.queueId,
    this.lastError,
    this.onRetryFallback,
    this.retryRow,
    this.discardRow,
  });

  /// The message's local delivery status.
  final ChatMessageStatus? status;

  /// The outbox row of this message, if it has one.
  final String? queueId;

  /// Error text of the message, for the tooltip of a failed line. The row's
  /// own error wins when there is one.
  final String? lastError;

  /// Retry for a message without a row.
  final VoidCallback? onRetryFallback;

  /// Retry (and "Send" of a held transcript). Defaults to
  /// [OfflineSendCoordinator.retryRow]. Tests inject a fake here.
  final OutboxRowAction? retryRow;

  /// Delete. Defaults to [OfflineSendCoordinator.discard].
  final OutboxRowAction? discardRow;

  /// True when a user message with these values can show the line.
  static bool applies(ChatMessageStatus? status, String? queueId) =>
      status == ChatMessageStatus.pending ||
      status == ChatMessageStatus.failed ||
      (queueId != null && queueId.isNotEmpty);

  @override
  State<OutboxStatusLine> createState() => _OutboxStatusLineState();
}

class _OutboxStatusLineState extends State<OutboxStatusLine> {
  /// Rebuilds the line when a queued row passes
  /// [OfflineRetryManager.longPending].
  Timer? _longPendingTimer;
  String? _timerRowId;
  bool _busy = false;

  @override
  void dispose() {
    _longPendingTimer?.cancel();
    super.dispose();
  }

  bool _isLongPending(QueuedMessage row) =>
      DateTime.now().millisecondsSinceEpoch - row.createdAt >=
      OfflineRetryManager.longPending.inMilliseconds;

  /// Arms one timer for the moment a queued row becomes long pending, so the
  /// Retry button comes up without an outbox change.
  void _armLongPendingTimer(QueuedMessage? row) {
    if (row == null || row.state != OutboxState.queued || _isLongPending(row)) {
      _longPendingTimer?.cancel();
      _longPendingTimer = null;
      _timerRowId = null;
      return;
    }
    if (_timerRowId == row.id && _longPendingTimer != null) return;
    _longPendingTimer?.cancel();
    _timerRowId = row.id;
    final int dueMs =
        row.createdAt +
        OfflineRetryManager.longPending.inMilliseconds -
        DateTime.now().millisecondsSinceEpoch;
    _longPendingTimer = Timer(Duration(milliseconds: dueMs + 50), () {
      _longPendingTimer = null;
      _timerRowId = null;
      if (mounted) setState(() {});
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[OutboxStatusLine] action failed: ${e.runtimeType}');
      }
      if (mounted) {
        final loc = AppLocalizations.of(context);
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(loc?.messageFailed ?? 'Failed to send')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _retry(String queueId) => _run(
    () => (widget.retryRow ?? OfflineSendCoordinator.retryRow)(queueId),
  );

  void _discard(String queueId) => _run(
    () => (widget.discardRow ?? OfflineSendCoordinator.discard)(queueId),
  );

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, QueuedMessage>>(
      valueListenable: OfflineRetryManager.instance.rows,
      builder: (context, rows, _) {
        final String? id = widget.queueId;
        final QueuedMessage? row = id == null || id.isEmpty ? null : rows[id];
        _armLongPendingTimer(row);
        return row == null
            ? _buildWithoutRow(context)
            : _buildRow(context, row);
      },
    );
  }

  Widget _buildWithoutRow(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final t = Theme.of(context);
    final ChatMessageStatus? status = widget.status;
    if (status != ChatMessageStatus.pending &&
        status != ChatMessageStatus.failed) {
      return const SizedBox.shrink();
    }
    final bool failed = status == ChatMessageStatus.failed;
    final String label = failed
        ? (loc?.messageFailed ?? 'Failed to send')
        : (loc?.outboxWaitingForNetwork ?? 'Waiting for network');
    final VoidCallback? retry = widget.onRetryFallback;
    final String? queueId = widget.queueId;
    return _line(
      context,
      icon: failed ? Icons.error_outline : Icons.schedule,
      label: label,
      color: failed ? t.colorScheme.error : _muted(t),
      tooltip: failed && widget.lastError != null
          ? '$label: ${widget.lastError}'
          : label,
      actions: [
        if (retry != null)
          _OutboxAction(
            key: const ValueKey<String>('outbox_retry'),
            label: loc?.messageRetry ?? 'Retry',
            onTap: _busy ? null : retry,
          ),
        // A waiting message with a queue id but no chat outbox row is an
        // Agents prompt (or a row already gone): Delete drops it.
        if (queueId != null && queueId.isNotEmpty)
          _OutboxAction(
            key: const ValueKey<String>('outbox_delete'),
            label: loc?.outboxDelete ?? 'Delete',
            onTap: _busy ? null : () => _discard(queueId),
          ),
      ],
    );
  }

  Widget _buildRow(BuildContext context, QueuedMessage row) {
    final loc = AppLocalizations.of(context);
    final t = Theme.of(context);
    final Color muted = _muted(t);
    final String retryLabel = loc?.messageRetry ?? 'Retry';
    final String deleteLabel = loc?.outboxDelete ?? 'Delete';
    _OutboxAction retryAction(String label) => _OutboxAction(
      key: const ValueKey<String>('outbox_retry'),
      label: label,
      onTap: _busy ? null : () => _retry(row.id),
    );
    final _OutboxAction deleteAction = _OutboxAction(
      key: const ValueKey<String>('outbox_delete'),
      label: deleteLabel,
      onTap: _busy ? null : () => _discard(row.id),
    );

    switch (row.state) {
      case OutboxState.queued:
        final String label =
            loc?.outboxWaitingForNetwork ?? 'Waiting for network';
        return _line(
          context,
          icon: Icons.schedule,
          label: label,
          color: muted,
          tooltip: label,
          // A row that waits long gets both ways out: send now, or drop it.
          actions: [
            if (_isLongPending(row)) ...[
              retryAction(retryLabel),
              deleteAction,
            ],
          ],
        );
      case OutboxState.preparing:
        final String label = row.isVoice
            ? (loc?.outboxTranscribing ?? 'Transcribing…')
            : (loc?.outboxUploading ?? 'Uploading…');
        return _line(
          context,
          label: label,
          color: muted,
          tooltip: label,
          busy: true,
        );
      case OutboxState.sending:
        final String label = loc?.outboxSending ?? 'Sending…';
        return _line(
          context,
          label: label,
          color: muted,
          tooltip: label,
          busy: true,
        );
      case OutboxState.failed:
        final String label = loc?.messageFailed ?? 'Failed to send';
        final String? error = row.lastError ?? widget.lastError;
        return _line(
          context,
          icon: Icons.error_outline,
          label: label,
          color: t.colorScheme.error,
          tooltip: error == null ? label : '$label: $error',
          actions: [retryAction(retryLabel), deleteAction],
        );
      case OutboxState.held:
        final String label = loc?.outboxTranscriptReady ?? 'Transcript ready';
        return _line(
          context,
          icon: Icons.mic,
          label: label,
          color: muted,
          tooltip: label,
          actions: [retryAction(loc?.outboxSend ?? 'Send'), deleteAction],
        );
    }
  }

  static Color _muted(ThemeData t) =>
      t.colorScheme.onSurface.withValues(alpha: .6);

  Widget _line(
    BuildContext context, {
    IconData? icon,
    bool busy = false,
    required String label,
    required Color color,
    required String tooltip,
    List<Widget> actions = const <Widget>[],
  }) {
    final Widget glyph = busy
        ? SizedBox(
            key: const ValueKey<String>('outbox_busy'),
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
          )
        : AppIcon(icon, size: 14, color: color);
    return Padding(
      padding: const EdgeInsets.only(top: 4, right: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Flexible(
            child: Tooltip(
              message: tooltip,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: Center(child: glyph),
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: color),
                    ),
                  ),
                ],
              ),
            ),
          ),
          for (final Widget action in actions) ...[
            const SizedBox(width: 4),
            action,
          ],
        ],
      ),
    );
  }
}

/// A text action on the status line, the same look as the old Retry.
class _OutboxAction extends StatelessWidget {
  const _OutboxAction({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final Color color = onTap == null
        ? t.colorScheme.onSurface.withValues(alpha: .38)
        : t.colorScheme.primary;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Text(
            label,
            maxLines: 1,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}
