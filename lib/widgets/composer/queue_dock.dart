// lib/widgets/composer/queue_dock.dart
//
// The queue dock: the messages the user sent while a reply runs, drawn above
// the composer field (deepseek-harness idea 67). One row per message, oldest
// first. A row can be edited in place, removed, or (a queued one, in a plain
// chat) sent now as a steer into the running turn.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/composer/follow_up_queue.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

class QueueDock extends StatelessWidget {
  const QueueDock({
    super.key,
    required this.queue,
    required this.onEdit,
    required this.onRemove,
    this.onSteerNow,
    this.trailingInset = 0,
  });

  final FollowUpQueue queue;

  /// The user saved a new text for the message.
  final void Function(String id, String text) onEdit;
  final ValueChanged<String> onRemove;

  /// Sends a queued message now as a steer. Null where steer is not
  /// available (an Agents thread): the action is not shown.
  final ValueChanged<String>? onSteerNow;

  /// Space kept free on the right, for a send button floating over the
  /// composer's top right corner (desktop).
  final double trailingInset;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: queue,
      builder: (BuildContext context, _) {
        final List<QueuedFollowUp> items = queue.items;
        if (items.isEmpty) return const SizedBox.shrink();
        return Padding(
          key: const ValueKey<String>('composer-queue-dock'),
          padding: EdgeInsets.only(bottom: 6, right: trailingInset),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final QueuedFollowUp item in items)
                _QueueRow(
                  key: ValueKey<String>('composer-queue-${item.id}'),
                  item: item,
                  onEdit: (String text) => onEdit(item.id, text),
                  onRemove: () => onRemove(item.id),
                  onSteerNow: switch (onSteerNow) {
                    final ValueChanged<String> steer
                        when item.kind != FollowUpKind.steer =>
                      () => steer(item.id),
                    _ => null,
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

class _QueueRow extends StatefulWidget {
  const _QueueRow({
    super.key,
    required this.item,
    required this.onEdit,
    required this.onRemove,
    this.onSteerNow,
  });

  final QueuedFollowUp item;
  final ValueChanged<String> onEdit;
  final VoidCallback onRemove;
  final VoidCallback? onSteerNow;

  @override
  State<_QueueRow> createState() => _QueueRowState();
}

class _QueueRowState extends State<_QueueRow> {
  TextEditingController? _edit;
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _edit?.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _startEdit() {
    setState(() => _edit = TextEditingController(text: widget.item.text));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _save() {
    final String text = _edit?.text.trim() ?? '';
    if (text.isNotEmpty && text != widget.item.text) widget.onEdit(text);
    _cancel();
  }

  void _cancel() {
    final TextEditingController? c = _edit;
    setState(() => _edit = null);
    WidgetsBinding.instance.addPostFrameCallback((_) => c?.dispose());
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations l =
        AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));
    final bool steer = widget.item.kind == FollowUpKind.steer;
    final Color muted = scheme.onSurfaceVariant;
    final TextStyle labelStyle = TextStyle(
      color: muted,
      fontSize: 12,
      fontWeight: FontWeight.w600,
    );
    final Widget body = _edit == null
        ? Text.rich(
            TextSpan(
              children: <InlineSpan>[
                TextSpan(
                  text: '${steer ? l.composerSteerPending : l.queuedLabel}: ',
                  style: labelStyle,
                ),
                TextSpan(
                  text: widget.item.text.replaceAll('\n', ' '),
                  style: labelStyle.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          )
        : CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              const SingleActivator(LogicalKeyboardKey.enter): _save,
              const SingleActivator(LogicalKeyboardKey.escape): _cancel,
            },
            child: TextField(
              key: const ValueKey<String>('composer-queue-edit-field'),
              controller: _edit,
              focusNode: _focus,
              minLines: 1,
              maxLines: 4,
              style: TextStyle(color: scheme.onSurface, fontSize: 14),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 6),
              ),
            ),
          );

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.only(left: 10, right: 2),
      constraints: const BoxConstraints(minHeight: 36),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(kRadiusMd),
      ),
      child: Row(
        children: <Widget>[
          AppIcon(steer ? Icons.bolt : Icons.schedule, size: 16, color: muted),
          const SizedBox(width: 8),
          Expanded(child: body),
          if (_edit != null)
            _DockAction(
              key: const ValueKey<String>('composer-queue-save'),
              icon: Icons.check,
              tooltip: l.composerQueueSave,
              onTap: _save,
            )
          else ...<Widget>[
            if (widget.onSteerNow case final VoidCallback steerNow)
              _DockAction(
                key: const ValueKey<String>('composer-queue-steer'),
                icon: Icons.bolt,
                tooltip: l.composerQueueSteerNow,
                onTap: steerNow,
              ),
            _DockAction(
              key: const ValueKey<String>('composer-queue-edit'),
              icon: Icons.edit,
              tooltip: l.composerQueueEdit,
              onTap: _startEdit,
            ),
          ],
          _DockAction(
            key: const ValueKey<String>('composer-queue-remove'),
            icon: Icons.close,
            tooltip: l.composerQueueRemove,
            onTap: _edit != null ? _cancel : widget.onRemove,
          ),
        ],
      ),
    );
  }
}

/// A 36 px square target with a 16 px glyph, centred.
class _DockAction extends StatelessWidget {
  const _DockAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(kRadiusMd),
          child: SizedBox(
            width: 36,
            height: 36,
            child: Center(
              child: AppIcon(icon, size: 16, color: scheme.onSurfaceVariant),
            ),
          ),
        ),
      ),
    );
  }
}
