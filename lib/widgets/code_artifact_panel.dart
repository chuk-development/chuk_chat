// lib/widgets/code_artifact_panel.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:chuk_chat/models/code_artifact.dart';

class CodeArtifactPanel extends StatefulWidget {
  const CodeArtifactPanel({
    super.key,
    required this.artifact,
    required this.onClose,
  });

  final CodeArtifact artifact;
  final VoidCallback onClose;

  @override
  State<CodeArtifactPanel> createState() => _CodeArtifactPanelState();
}

class _CodeArtifactPanelState extends State<CodeArtifactPanel> {
  late final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color iconFg = Theme.of(context).iconTheme.color!;
    final Color bg = Theme.of(context).cardColor;

    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: iconFg.withValues(alpha: 0.2)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(context, iconFg),
            const Divider(height: 1),
            Expanded(
              child: Scrollbar(
                controller: _scrollController,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    widget.artifact.code,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      height: 1.5,
                      color: iconFg.withValues(alpha: 0.9),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, Color iconFg) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(
            Icons.integration_instructions_outlined,
            color: iconFg.withValues(alpha: 0.8),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.artifact.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: iconFg.withValues(alpha: 0.9),
                  ),
                ),
                Text(
                  widget.artifact.languageLabel,
                  style: TextStyle(
                    fontSize: 12,
                    color: iconFg.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Copy code',
            onPressed: () => _copyToClipboard(context),
            icon: Icon(Icons.copy, color: iconFg.withValues(alpha: 0.7)),
          ),
          IconButton(
            tooltip: 'Close artifact',
            onPressed: widget.onClose,
            icon: Icon(Icons.close, color: iconFg.withValues(alpha: 0.7)),
          ),
        ],
      ),
    );
  }

  Future<void> _copyToClipboard(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: widget.artifact.code));
    messenger.showSnackBar(
      SnackBar(
        content: Text('"${widget.artifact.displayTitle}" copied to clipboard.'),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
