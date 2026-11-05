// lib/widgets/message_feedback.dart
//
// The thumbs in an answer's action bar and the sheet behind them: seven
// reasons as chips, an optional note, Submit. Stored on the device by
// [MessageFeedbackStore] (lib/services/message_feedback_store.dart).

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/message_feedback_store.dart';
import 'package:chuk_chat/services/prompt_cache/prompt_context.dart'
    show chatIdHash;
import 'package:chuk_chat/ui/components/components.dart';
import 'package:chuk_chat/ui/expressive/motion.dart' show ExpressiveButton;
import 'package:chuk_chat/widgets/icons/huge_icon.dart';

/// The localised label of a feedback reason.
String feedbackCategoryLabel(FeedbackCategory c, AppLocalizations? l10n) {
  switch (c) {
    case FeedbackCategory.taskResult:
      return l10n?.feedbackTaskResult ?? 'Task result';
    case FeedbackCategory.instructionFollowing:
      return l10n?.feedbackInstructionFollowing ?? 'Instruction following';
    case FeedbackCategory.productInteraction:
      return l10n?.feedbackProductInteraction ?? 'Product interaction';
    case FeedbackCategory.serviceStability:
      return l10n?.feedbackServiceStability ?? 'Service stability';
    case FeedbackCategory.resourceCost:
      return l10n?.feedbackCost ?? 'Cost';
    case FeedbackCategory.securityPrivacy:
      return l10n?.feedbackSecurityPrivacy ?? 'Security and privacy';
    case FeedbackCategory.other:
      return l10n?.feedbackOther ?? 'Other';
  }
}

/// Thumbs up and down, drawn in the action bar's own button style. The
/// chosen one sits on a filled capsule. Hidden when the answer has no id
/// (nothing to key the verdict on).
class MessageFeedbackButtons extends StatefulWidget {
  const MessageFeedbackButtons({
    super.key,
    required this.messageId,
    required this.iconColor,
    this.modelId,
    this.provider,
    this.chatId,
    this.compact = false,
  });

  final String? messageId;
  final Color iconColor;
  final String? modelId;

  /// The provider that answered, sent with the verdict.
  final String? provider;

  /// The chat the answer is in. Only its hash leaves the device.
  final String? chatId;

  /// The phone sizes of the action bar (smaller padding).
  final bool compact;

  @override
  State<MessageFeedbackButtons> createState() => _MessageFeedbackButtonsState();
}

class _MessageFeedbackButtonsState extends State<MessageFeedbackButtons> {
  final MessageFeedbackStore _store = MessageFeedbackStore.instance;

  @override
  void initState() {
    super.initState();
    _store.addListener(_changed);
    if (!_store.isLoaded) unawaited(_store.ensureLoaded());
  }

  @override
  void dispose() {
    _store.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _open(FeedbackRating rating) async {
    final String? id = widget.messageId;
    if (id == null) return;
    await showMessageFeedbackSheet(
      context,
      messageId: id,
      rating: rating,
      modelId: widget.modelId,
      provider: widget.provider,
      chatHash: _hashOf(widget.chatId),
      existing: _store.peek(id),
    );
  }

  static String? _hashOf(String? chatId) =>
      chatId == null || chatId.isEmpty ? null : chatIdHash(chatId);

  @override
  Widget build(BuildContext context) {
    final String? id = widget.messageId;
    if (id == null || id.isEmpty) return const SizedBox.shrink();
    final AppLocalizations? l10n = AppLocalizations.of(context);
    final FeedbackRating? current = _store.peek(id)?.rating;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _thumb(
          key: const ValueKey<String>('feedback-up'),
          icon: HugeIcons.thumbsUp,
          tooltip: l10n?.feedbackGood ?? 'Good answer',
          selected: current == FeedbackRating.up,
          onTap: () => _open(FeedbackRating.up),
        ),
        _thumb(
          key: const ValueKey<String>('feedback-down'),
          icon: HugeIcons.thumbsDown,
          tooltip: l10n?.feedbackBad ?? 'Bad answer',
          selected: current == FeedbackRating.down,
          onTap: () => _open(FeedbackRating.down),
        ),
      ],
    );
  }

  Widget _thumb({
    required Key key,
    required HugeIconData icon,
    required String tooltip,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double box = widget.compact ? 28 : 30;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        selected: selected,
        label: tooltip,
        child: InkWell(
          key: key,
          onTap: onTap,
          customBorder: const StadiumBorder(),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Container(
              width: box,
              height: box,
              alignment: Alignment.center,
              decoration: selected
                  ? BoxDecoration(color: scheme.primary, shape: BoxShape.circle)
                  : null,
              child: HugeIcon(
                icon,
                size: 18,
                color: selected ? scheme.onPrimary : widget.iconColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The reasons sheet. Returns the saved verdict, or null when dismissed.
Future<MessageFeedback?> showMessageFeedbackSheet(
  BuildContext context, {
  required String messageId,
  required FeedbackRating rating,
  String? modelId,
  String? provider,
  String? chatHash,
  MessageFeedback? existing,
  MessageFeedbackStore? store,
}) {
  return showModalBottomSheet<MessageFeedback>(
    context: context,
    isScrollControlled: true,
    showDragHandle: false,
    builder: (BuildContext sheetContext) => MessageFeedbackSheet(
      messageId: messageId,
      rating: rating,
      modelId: modelId,
      provider: provider,
      chatHash: chatHash,
      existing: existing != null && existing.rating == rating ? existing : null,
      store: store ?? MessageFeedbackStore.instance,
    ),
  );
}

class MessageFeedbackSheet extends StatefulWidget {
  const MessageFeedbackSheet({
    super.key,
    required this.messageId,
    required this.rating,
    required this.store,
    this.modelId,
    this.provider,
    this.chatHash,
    this.existing,
  });

  final String messageId;
  final FeedbackRating rating;
  final MessageFeedbackStore store;
  final String? modelId;
  final String? provider;
  final String? chatHash;
  final MessageFeedback? existing;

  @override
  State<MessageFeedbackSheet> createState() => _MessageFeedbackSheetState();
}

class _MessageFeedbackSheetState extends State<MessageFeedbackSheet> {
  late final Set<FeedbackCategory> _picked = <FeedbackCategory>{
    ...?widget.existing?.categories,
  };
  late final TextEditingController _note = TextEditingController(
    text: widget.existing?.note ?? '',
  );
  bool _saving = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    setState(() => _saving = true);
    final MessageFeedback fb = MessageFeedback(
      messageId: widget.messageId,
      rating: widget.rating,
      categories: <FeedbackCategory>[
        for (final FeedbackCategory c in FeedbackCategory.values)
          if (_picked.contains(c)) c,
      ],
      note: _note.text.trim().isEmpty ? null : _note.text.trim(),
      modelId: widget.modelId ?? widget.existing?.modelId,
      provider: widget.provider ?? widget.existing?.provider,
      chatHash: widget.chatHash ?? widget.existing?.chatHash,
      createdAt: DateTime.now(),
    );
    await widget.store.save(fb);
    if (mounted) Navigator.of(context).pop(fb);
  }

  /// Takes the stored verdict back (here and on the server).
  Future<void> _removeRating() async {
    if (_saving) return;
    setState(() => _saving = true);
    await widget.store.remove(widget.messageId);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations? l10n = AppLocalizations.of(context);
    final bool up = widget.rating == FeedbackRating.up;
    final String title = up
        ? (l10n?.feedbackTitleUp ?? 'What went well?')
        : (l10n?.feedbackTitleDown ?? 'What went wrong?');
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  HugeIcon(
                    up ? HugeIcons.thumbsUp : HugeIcons.thumbsDown,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  FloatingHeaderButton(
                    key: const ValueKey<String>('feedback-close'),
                    icon: Icons.close,
                    tooltip: l10n?.feedbackClose ?? 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final FeedbackCategory c in FeedbackCategory.values)
                      FilterChip(
                        key: ValueKey<String>('feedback-chip-${c.id}'),
                        label: Text(feedbackCategoryLabel(c, l10n)),
                        selected: _picked.contains(c),
                        showCheckmark: false,
                        shape: const StadiumBorder(),
                        selectedColor: scheme.primary,
                        labelStyle: TextStyle(
                          color: _picked.contains(c)
                              ? scheme.onPrimary
                              : scheme.onSurface,
                        ),
                        onSelected: (bool on) => setState(() {
                          if (on) {
                            _picked.add(c);
                          } else {
                            _picked.remove(c);
                          }
                        }),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: TextField(
                  key: const ValueKey<String>('feedback-note'),
                  controller: _note,
                  minLines: 2,
                  maxLines: 5,
                  maxLength: 1000,
                  style: const TextStyle(fontSize: 16),
                  decoration: InputDecoration(
                    hintText: l10n?.feedbackNoteHint ?? 'Add a note (optional)',
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ExpressiveButton(
                  key: const ValueKey<String>('feedback-submit'),
                  label: l10n?.feedbackSubmit ?? 'Submit',
                  onTap: _submit,
                ),
              ),
              if (widget.existing != null) ...<Widget>[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ExpressiveButton(
                    key: const ValueKey<String>('feedback-remove'),
                    label: l10n?.feedbackRemoveRating ?? 'Remove rating',
                    tonal: true,
                    onTap: _removeRating,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
