// lib/widgets/code_artifact_preview_list.dart

import 'package:flutter/material.dart';
import 'package:chuk_chat/models/code_artifact.dart';

class CodeArtifactPreviewList extends StatelessWidget {
  const CodeArtifactPreviewList({
    super.key,
    required this.artifacts,
    required this.onArtifactPressed,
    this.activeSelection,
    this.alignRight = false,
  });

  final List<CodeArtifact> artifacts;
  final ValueChanged<CodeArtifact> onArtifactPressed;
  final CodeArtifactRef? activeSelection;
  final bool alignRight;

  @override
  Widget build(BuildContext context) {
    if (artifacts.isEmpty) {
      return const SizedBox.shrink();
    }

    final WrapAlignment wrapAlignment = alignRight
        ? WrapAlignment.end
        : WrapAlignment.start;

    return Wrap(
      alignment: wrapAlignment,
      spacing: 12,
      runSpacing: 12,
      children: artifacts.map((artifact) {
        final bool isActive =
            activeSelection != null &&
            activeSelection!.messageIndex == artifact.messageIndex &&
            activeSelection!.blockIndex == artifact.blockIndex;
        return _CodeArtifactPreviewCard(
          artifact: artifact,
          isActive: isActive,
          onPressed: () => onArtifactPressed(artifact),
        );
      }).toList(),
    );
  }
}

class _CodeArtifactPreviewCard extends StatelessWidget {
  const _CodeArtifactPreviewCard({
    required this.artifact,
    required this.isActive,
    required this.onPressed,
  });

  final CodeArtifact artifact;
  final bool isActive;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final Color iconFg = Theme.of(context).iconTheme.color!;
    final Color bg = Theme.of(context).cardColor;
    final Color borderColor = isActive
        ? Theme.of(context).colorScheme.primary
        : iconFg.withValues(alpha: 0.25);

    final String previewText = artifact.preview();

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 280),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: borderColor, width: isActive ? 2 : 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.description_outlined,
                      size: 18,
                      color: iconFg.withValues(alpha: 0.8),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        artifact.displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: iconFg.withValues(alpha: 0.9),
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.open_in_new,
                      size: 16,
                      color: iconFg.withValues(alpha: 0.6),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: iconFg.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: iconFg.withValues(alpha: 0.15)),
                  ),
                  child: Text(
                    previewText.isEmpty ? '(empty)' : previewText,
                    maxLines: 7,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.4,
                      color: iconFg.withValues(alpha: 0.85),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
