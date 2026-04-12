// lib/widgets/artifact_panel.dart
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:chuk_chat/models/artifact.dart';
import 'package:chuk_chat/services/artifact_storage_service.dart';
import 'package:chuk_chat/utils/io_helper.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/markdown_message.dart';
import 'package:chuk_chat/widgets/technical_drawing_widget.dart';

class ArtifactPanel extends StatefulWidget {
  const ArtifactPanel({
    super.key,
    required this.artifact,
    this.onClose,
    this.showHeader = true,
  });

  final ArtifactDocument artifact;
  final VoidCallback? onClose;
  final bool showHeader;

  @override
  State<ArtifactPanel> createState() => _ArtifactPanelState();
}

class _ArtifactPanelState extends State<ArtifactPanel> {
  bool _loadingVersions = true;
  bool _busy = false;
  List<ArtifactVersionSnapshot> _versions = const [];
  int? _selectedVersion;
  String? _selectedVersionContent;

  @override
  void initState() {
    super.initState();
    _selectedVersion = widget.artifact.version;
    _loadVersions();
  }

  @override
  void didUpdateWidget(covariant ArtifactPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artifact.id != widget.artifact.id ||
        oldWidget.artifact.version != widget.artifact.version) {
      _selectedVersion = widget.artifact.version;
      _selectedVersionContent = null;
      _loadVersions();
    }
  }

  Future<void> _loadVersions() async {
    setState(() => _loadingVersions = true);
    try {
      final versions = await ArtifactStorageService.loadVersionHistory(
        widget.artifact.id,
        forceRefresh: true,
      );
      if (!mounted) return;
      setState(() {
        _versions = versions;
        _loadingVersions = false;
      });
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Failed to load artifact versions: $error\n$stackTrace');
      }
      if (!mounted) return;
      setState(() {
        _versions = const [];
        _loadingVersions = false;
      });
    }
  }

  Future<void> _copyContent() async {
    await Clipboard.setData(ClipboardData(text: _effectiveContent));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Artifact copied to clipboard'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _downloadContent() async {
    if (_busy) return;
    setState(() => _busy = true);

    final artifact = widget.artifact;
    final extension = _fileExtensionForArtifact(artifact);
    final suggestedName =
        '${artifact.id}-v${_selectedVersion ?? artifact.version}.$extension';
    final bytes = Uint8List.fromList(utf8.encode(_effectiveContent));

    try {
      if (kIsWeb) {
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile.fromData(bytes, name: suggestedName)],
            subject: artifact.title,
            text: 'Artifact export',
          ),
        );
        return;
      }

      String? selectedPath;
      selectedPath = await FilePicker.saveFile(
        dialogTitle: 'Save Artifact',
        fileName: suggestedName,
        type: FileType.custom,
        allowedExtensions: [extension],
      );

      if (selectedPath != null && selectedPath.isNotEmpty) {
        final file = File(selectedPath);
        await file.writeAsBytes(bytes, flush: true);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved to $selectedPath'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        // Fallback: share temp file
        final tempDir = await getTemporaryDirectory();
        final tempPath =
            '${tempDir.path}${Platform.pathSeparator}$suggestedName';
        final tempFile = File(tempPath);
        await tempFile.writeAsBytes(bytes, flush: true);

        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(tempPath)],
            subject: artifact.title,
            text: 'Artifact export',
          ),
        );
      }
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Artifact export failed: $error\n$stackTrace');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to export artifact: $error'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  String _fileExtensionForArtifact(ArtifactDocument artifact) {
    if (artifact.type == ArtifactType.code &&
        artifact.language != null &&
        artifact.language!.trim().isNotEmpty) {
      final language = artifact.language!.trim().toLowerCase();
      const languageToExtension = <String, String>{
        'javascript': 'js',
        'typescript': 'ts',
        'python': 'py',
        'dart': 'dart',
        'kotlin': 'kt',
        'java': 'java',
        'csharp': 'cs',
        'cpp': 'cpp',
        'c++': 'cpp',
        'c': 'c',
        'objective-c': 'm',
        'swift': 'swift',
        'ruby': 'rb',
        'php': 'php',
        'go': 'go',
        'rust': 'rs',
        'shell': 'sh',
        'bash': 'sh',
        'json': 'json',
        'yaml': 'yaml',
        'yml': 'yml',
        'html': 'html',
        'css': 'css',
        'scss': 'scss',
        'sql': 'sql',
        'xml': 'xml',
      };
      return languageToExtension[language] ?? language;
    }
    return artifact.type.defaultExtension;
  }

  Future<void> _selectVersion(int? version) async {
    if (version == null) return;

    if (version == widget.artifact.version) {
      setState(() {
        _selectedVersion = version;
        _selectedVersionContent = null;
      });
      return;
    }

    final found = _versions.where((v) => v.version == version).firstOrNull;
    if (found == null) return;

    setState(() {
      _selectedVersion = version;
      _selectedVersionContent = found.content;
    });
  }

  String get _effectiveContent =>
      _selectedVersionContent ?? widget.artifact.content;

  ArtifactType get _effectiveType => widget.artifact.type;

  @override
  Widget build(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;

    return Column(
      children: [
        if (widget.showHeader)
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: iconFg.withValues(alpha: 0.12)),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.article_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.artifact.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _TypeBadge(type: _effectiveType),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.copy_outlined, size: 18),
                  onPressed: _copyContent,
                  tooltip: 'Copy',
                ),
                IconButton(
                  icon: const Icon(Icons.download_outlined, size: 18),
                  onPressed: _busy ? null : _downloadContent,
                  tooltip: 'Download',
                ),
                if (widget.onClose != null)
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: widget.onClose,
                    tooltip: 'Close',
                  ),
              ],
            ),
          ),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            child: _ArtifactRenderer(
              type: _effectiveType,
              language: widget.artifact.language,
              content: _effectiveContent,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: iconFg.withValues(alpha: 0.12)),
            ),
          ),
          child: Row(
            children: [
              const Text(
                'Version',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _loadingVersions
                    ? const LinearProgressIndicator(minHeight: 2)
                    : Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: iconFg.withValues(alpha: 0.2),
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: DropdownButton<int>(
                          value:
                              _versions.any(
                                (v) => v.version == _selectedVersion,
                              )
                              ? _selectedVersion
                              : null,
                          isDense: true,
                          isExpanded: true,
                          underline: const SizedBox.shrink(),
                          items: _versions
                              .map(
                                (v) => DropdownMenuItem<int>(
                                  value: v.version,
                                  child: Text('v${v.version}'),
                                ),
                              )
                              .toList(),
                          onChanged: _selectVersion,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class ArtifactBottomSheet extends StatelessWidget {
  const ArtifactBottomSheet({super.key, required this.artifact});

  final ArtifactDocument artifact;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.96,
      expand: false,
      builder: (context, scrollController) {
        return PrimaryScrollController(
          controller: scrollController,
          child: Material(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: Column(
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ArtifactPanel(
                    artifact: artifact,
                    onClose: () => Navigator.of(context).pop(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TypeBadge extends StatelessWidget {
  const _TypeBadge({required this.type});

  final ArtifactType type;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        type.displayLabel,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _ArtifactRenderer extends StatelessWidget {
  const _ArtifactRenderer({
    required this.type,
    required this.content,
    this.language,
  });

  final ArtifactType type;
  final String content;
  final String? language;

  @override
  Widget build(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final scrollController = PrimaryScrollController.maybeOf(context);
    final usePrimary = scrollController == null;

    switch (type) {
      case ArtifactType.code:
        final lang = language?.trim() ?? '';
        final fenced = '```$lang\n$content\n```';
        return SingleChildScrollView(
          controller: scrollController,
          primary: usePrimary,
          child: MarkdownMessage(
            text: fenced,
            textColor: iconFg,
            backgroundColor: bg,
          ),
        );
      case ArtifactType.markdown:
        return SingleChildScrollView(
          controller: scrollController,
          primary: usePrimary,
          child: MarkdownMessage(
            text: content,
            textColor: iconFg,
            backgroundColor: bg,
          ),
        );
      case ArtifactType.svg:
        return _ZoomableVisual(
          child: SvgPicture.string(
            content,
            fit: BoxFit.contain,
            placeholderBuilder: (context) => const Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            ),
          ),
        );
      case ArtifactType.html:
      case ArtifactType.mermaid:
        return SingleChildScrollView(
          controller: scrollController,
          primary: usePrimary,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              border: Border.all(color: iconFg.withValues(alpha: 0.15)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              content,
              style: TextStyle(
                color: iconFg,
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
        );
      case ArtifactType.technicalDrawing:
        return _ZoomableVisual(
          child: TechnicalDrawingWidget(jsonString: content),
        );
    }
  }
}

/// Zoomable wrapper with +/- buttons for visual artifacts (SVG, drawings).
class _ZoomableVisual extends StatefulWidget {
  const _ZoomableVisual({required this.child});

  final Widget child;

  @override
  State<_ZoomableVisual> createState() => _ZoomableVisualState();
}

class _ZoomableVisualState extends State<_ZoomableVisual> {
  final TransformationController _ctrl = TransformationController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _zoom(double factor) {
    final size = context.size;
    if (size == null) return;
    final current = _ctrl.value.clone();
    final center = Offset(size.width / 2, size.height / 2);
    // Scale around center of viewport.
    current
      ..translateByDouble(center.dx, center.dy, 0, 1.0)
      ..scaleByDouble(factor, factor, 1.0, 1.0)
      ..translateByDouble(-center.dx, -center.dy, 0, 1.0);
    _ctrl.value = current;
  }

  void _resetZoom() {
    _ctrl.value = Matrix4.identity();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: InteractiveViewer(
            transformationController: _ctrl,
            minScale: 0.3,
            maxScale: 5.0,
            boundaryMargin: const EdgeInsets.all(100),
            child: Center(child: widget.child),
          ),
        ),
        Positioned(
          right: 8,
          bottom: 8,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ZoomButton(icon: Icons.add, onTap: () => _zoom(1.25)),
              const SizedBox(height: 4),
              _ZoomButton(icon: Icons.remove, onTap: () => _zoom(0.8)),
              const SizedBox(height: 4),
              _ZoomButton(icon: Icons.fit_screen, onTap: _resetZoom),
            ],
          ),
        ),
      ],
    );
  }
}

class _ZoomButton extends StatelessWidget {
  const _ZoomButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 18),
        ),
      ),
    );
  }
}
