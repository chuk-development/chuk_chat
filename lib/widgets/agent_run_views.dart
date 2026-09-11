/// The pieces a streaming run is made of: collapsible tool lines, a separate
/// reasoning block, and cards for files the agent produced.
///
/// They are public widgets, not private helpers, so each one can be pumped and
/// asserted on its own. Every one of them shows only what the protocol actually
/// carried: a duration is drawn when the host reported one and left out when it
/// did not, and a file that failed to decode becomes an error card rather than a
/// broken image.
library;

import 'package:flutter/material.dart';

import 'package:cowork/ui/expressive/icon_map.dart';

import 'package:cowork/services/cowork/agent_file_saver.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/utils/theme_extensions.dart';

/// One tool call, as a single quiet line that opens on tap.
///
/// Collapsed it reads `name · short argument · short result`; expanded it adds
/// the full output. A failed call is drawn in the error colour with a different
/// icon, so success and failure never look alike.
class AgentToolLine extends StatefulWidget {
  const AgentToolLine({
    super.key,
    required this.call,
    this.initiallyExpanded = false,
  });

  final CoworkRelayTool call;
  final bool initiallyExpanded;

  @override
  State<AgentToolLine> createState() => _AgentToolLineState();
}

class _AgentToolLineState extends State<AgentToolLine> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final call = widget.call;
    final failed = call.failed;
    final accent = failed ? theme.colorScheme.error : theme.m3.onSurfaceVariant;
    final mono = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      color: accent,
    );

    final summary = <String>[
      call.name,
      if (call.arguments != null && call.arguments!.trim().isNotEmpty)
        _oneLine(call.arguments!),
      if (call.status != null) call.status!,
      if (_shortResult(call) != null) _shortResult(call)!,
      if (call.duration != null) _formatDuration(call.duration!),
      if (failed) _failureTag(call),
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppIcon(
                    failed ? Icons.error_outline : Icons.check_circle_outline,
                    size: 14,
                    color: accent,
                    semanticLabel: failed ? 'failed' : 'succeeded',
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      summary,
                      style: mono,
                      maxLines: _expanded ? null : 1,
                      overflow: _expanded ? null : TextOverflow.ellipsis,
                    ),
                  ),
                  AppIcon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: accent,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) _buildDetail(context, call, mono),
        ],
      ),
    );
  }

  Widget _buildDetail(
    BuildContext context,
    CoworkRelayTool call,
    TextStyle? mono,
  ) {
    final theme = Theme.of(context);
    final lines = <String>[
      if (call.arguments != null && call.arguments!.isNotEmpty)
        '\$ ${call.arguments}',
      if (call.detail != null && call.detail!.isNotEmpty) call.detail!,
      if (call.exitCode != null) 'exit ${call.exitCode}',
      if (call.timedOut) 'timed out',
    ];
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(left: 20, top: 2),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: theme.m3.surfaceContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: SelectableText(
        lines.isEmpty ? 'No output.' : lines.join('\n'),
        style: mono,
      ),
    );
  }

  static String? _shortResult(CoworkRelayTool call) {
    final result = call.result;
    if (result == null || result.trim().isEmpty) return null;
    final line = _oneLine(result);
    return line.length <= 60 ? line : '${line.substring(0, 60)}…';
  }

  static String _oneLine(String value) {
    final flat = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 80 ? flat : '${flat.substring(0, 80)}…';
  }

  static String _failureTag(CoworkRelayTool call) {
    if (call.timedOut) return 'timed out';
    if (call.exitCode != null) return 'exit ${call.exitCode}';
    return 'failed';
  }

  static String _formatDuration(Duration d) {
    if (d.inMilliseconds < 1000) return '${d.inMilliseconds}ms';
    if (d.inSeconds < 60)
      return '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';
    return '${d.inMinutes}m ${d.inSeconds % 60}s';
  }
}

/// The model's thinking, kept apart from the answer.
///
/// Reasoning is a separate channel: it is never merged into the reply text, and
/// it stays folded away until the user asks for it.
class AgentReasoningBlock extends StatefulWidget {
  const AgentReasoningBlock({
    super.key,
    required this.text,
    this.initiallyExpanded = false,
  });

  final String text;
  final bool initiallyExpanded;

  @override
  State<AgentReasoningBlock> createState() => _AgentReasoningBlockState();
}

class _AgentReasoningBlockState extends State<AgentReasoningBlock> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.m3.onSurfaceVariant;
    final style = theme.textTheme.bodySmall?.copyWith(
      color: muted,
      fontStyle: FontStyle.italic,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  AppIcon(Icons.psychology_outlined, size: 14, color: muted),
                  const SizedBox(width: 6),
                  Text('Reasoning', style: style),
                  AppIcon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: muted,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(left: 20, bottom: 4),
              child: SelectableText(widget.text, style: style),
            ),
        ],
      ),
    );
  }
}

/// A file the agent produced: a preview for an image, a save action otherwise.
///
/// The bytes arrive already decoded (once, in the transport) and are handed to
/// [Image.memory] as they are — the card never re-encodes or copies them, so a
/// screenshot does not sit in memory twice.
class AgentFileCard extends StatefulWidget {
  const AgentFileCard({super.key, required this.file, required this.saver});

  final CoworkRelayFile file;
  final AgentFileSaver saver;

  @override
  State<AgentFileCard> createState() => _AgentFileCardState();
}

class _AgentFileCardState extends State<AgentFileCard> {
  bool _saving = false;
  String? _savedTo;
  String? _saveError;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final location = await widget.saver.save(widget.file);
      if (mounted) setState(() => _savedTo = location);
    } catch (error) {
      // Never swallow it: the user has to see that the save did not happen.
      if (mounted) setState(() => _saveError = '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final file = widget.file;
    final broken = !file.isValid;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8, right: 40),
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          border: Border.all(
            color: broken ? theme.colorScheme.error : theme.dividerColor,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (broken)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    AppIcon(
                      Icons.broken_image_outlined,
                      size: 16,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        file.error ?? 'The file could not be read.',
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  ],
                ),
              )
            else if (file.isImage)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: Image.memory(
                  file.bytes!,
                  fit: BoxFit.contain,
                  // A body that claims image/* but is not one must not crash the
                  // thread either.
                  errorBuilder: (context, error, stackTrace) => Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'The image could not be decoded.',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  AppIcon(
                    file.isImage
                        ? Icons.image_outlined
                        : Icons.description_outlined,
                    size: 16,
                    color: theme.hintColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(file.name, overflow: TextOverflow.ellipsis),
                        Text(
                          _subtitle(file),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.hintColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!broken)
                    _saving
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : TextButton(
                            onPressed: _save,
                            child: Text(_savedTo == null ? 'Save' : 'Saved'),
                          ),
                ],
              ),
            ),
            if (_savedTo != null)
              Padding(
                padding: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
                child: Text(
                  'Saved to $_savedTo',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (_saveError != null)
              Padding(
                padding: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
                child: Text(
                  _saveError!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _subtitle(CoworkRelayFile file) {
    final size = file.bytes?.length ?? file.declaredSize;
    if (size == null) return file.mimeType;
    return '${file.mimeType} · ${formatBytes(size)}';
  }
}

/// Formats a byte count the way a file manager does.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
