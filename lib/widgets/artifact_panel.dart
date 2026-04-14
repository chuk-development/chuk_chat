// lib/widgets/artifact_panel.dart
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:chuk_chat/models/artifact.dart';
import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/artifact_storage_service.dart';
import 'package:chuk_chat/services/pdf_attachment_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/tool_handlers/typst_tools.dart' as typst_tools;
import 'package:chuk_chat/utils/io_helper.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/markdown_message.dart';
import 'package:chuk_chat/widgets/technical_drawing_svg_export.dart';
import 'package:chuk_chat/widgets/technical_drawing_widget.dart';
import 'package:pdfrx/pdfrx.dart';

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

enum _ArtifactViewMode { preview, code }

class _ArtifactPanelState extends State<ArtifactPanel> {
  bool _loadingVersions = true;
  bool _busy = false;
  List<ArtifactVersionSnapshot> _versions = const [];
  int? _selectedVersion;
  String? _selectedVersionContent;
  _ArtifactViewMode _viewMode = _ArtifactViewMode.preview;

  /// Captures the visual rendering (SVG / technical drawing) for PNG export.
  final GlobalKey _visualCaptureKey = GlobalKey();

  /// Artifact types that have both a rendered preview and a source-code view.
  static const Set<ArtifactType> _dualViewTypes = {
    ArtifactType.svg,
    ArtifactType.technicalDrawing,
    ArtifactType.typst,
  };

  bool get _hasDualView => _dualViewTypes.contains(widget.artifact.type);

  String get _codeLanguageHint => switch (widget.artifact.type) {
    ArtifactType.svg => 'xml',
    ArtifactType.technicalDrawing => 'json',
    ArtifactType.typst => 'typst',
    _ => '',
  };

  @override
  void initState() {
    super.initState();
    _selectedVersion = widget.artifact.version;
    _loadVersions();
    ArtifactStorageService.pendingInitialOpen
        .addListener(_onPendingVersionChanged);
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

  @override
  void dispose() {
    ArtifactStorageService.pendingInitialOpen
        .removeListener(_onPendingVersionChanged);
    super.dispose();
  }

  void _onPendingVersionChanged() {
    if (!mounted) return;
    // Apply immediately if versions are already loaded; otherwise
    // _loadVersions() will pick the pending value up after its fetch.
    if (!_loadingVersions && _versions.isNotEmpty) {
      _applyPendingInitialVersion();
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
      _applyPendingInitialVersion();
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

  void _applyPendingInitialVersion() {
    final pending = ArtifactStorageService.pendingInitialOpen.value;
    if (pending == null) return;
    // Do NOT consume a request targeting a different artifact — it belongs
    // to the panel state that will be built once the active artifact swaps
    // to `pending.artifactId`.
    if (pending.artifactId != widget.artifact.id) return;
    ArtifactStorageService.pendingInitialOpen.value = null;
    final target = pending.version;
    if (target == null || target == widget.artifact.version) {
      if (_selectedVersion != widget.artifact.version ||
          _selectedVersionContent != null) {
        setState(() {
          _selectedVersion = widget.artifact.version;
          _selectedVersionContent = null;
        });
      }
      return;
    }
    final found = _versions.where((v) => v.version == target).firstOrNull;
    if (found == null) return;
    setState(() {
      _selectedVersion = target;
      _selectedVersionContent = found.content;
    });
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

  /// Formats offered for download based on artifact type.
  List<_DownloadFormat> _availableFormats() {
    switch (widget.artifact.type) {
      case ArtifactType.technicalDrawing:
        return const [
          _DownloadFormat('PNG image', 'png'),
          _DownloadFormat('SVG vector', 'svg'),
          _DownloadFormat('JSON source', 'json'),
        ];
      case ArtifactType.svg:
        return const [
          _DownloadFormat('PNG image', 'png'),
          _DownloadFormat('SVG source', 'svg'),
        ];
      case ArtifactType.typst:
        return const [
          _DownloadFormat('PDF document', 'pdf'),
          _DownloadFormat('Typst source', 'typ'),
        ];
      case ArtifactType.code:
      case ArtifactType.markdown:
      case ArtifactType.html:
      case ArtifactType.mermaid:
        return [
          _DownloadFormat(
            '${widget.artifact.type.defaultExtension.toUpperCase()} file',
            _fileExtensionForArtifact(widget.artifact),
          ),
        ];
    }
  }

  Future<Uint8List?> _bytesForFormat(String ext) async {
    switch (ext) {
      case 'png':
        return _captureVisualAsPng();
      case 'svg':
        // Technical drawing → generate SVG from JSON
        if (widget.artifact.type == ArtifactType.technicalDrawing) {
          final svg = technicalDrawingToSvg(_effectiveContent);
          if (svg == null) return null;
          return Uint8List.fromList(utf8.encode(svg));
        }
        // SVG artifact → raw content
        return Uint8List.fromList(utf8.encode(_effectiveContent));
      case 'pdf':
        if (widget.artifact.type == ArtifactType.typst) {
          final baseUrl = ApiConfigService.apiBaseUrl;
          final token = SupabaseService.auth.currentSession?.accessToken;
          if (baseUrl.isEmpty) {
            return null;
          }
          return typst_tools.compileTypstToPdf(
            serverHttpUrl: baseUrl,
            accessToken: token,
            source: _effectiveContent,
          );
        }
        return null;
      default:
        return Uint8List.fromList(utf8.encode(_effectiveContent));
    }
  }

  Future<Uint8List?> _captureVisualAsPng() async {
    final ctx = _visualCaptureKey.currentContext;
    if (ctx == null) return null;
    final boundary = ctx.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return null;
    final image = await boundary.toImage(pixelRatio: 3.0);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }

  Future<void> _showDownloadMenu() async {
    final formats = _availableFormats();
    // If only one option, skip the menu.
    if (formats.length == 1) {
      await _downloadAs(formats.first.ext);
      return;
    }
    final selected = await showMenu<String>(
      context: context,
      position: _downloadMenuPosition(),
      items: [
        for (final f in formats)
          PopupMenuItem<String>(value: f.ext, child: Text(f.label)),
      ],
    );
    if (selected != null) {
      await _downloadAs(selected);
    }
  }

  RelativeRect _downloadMenuPosition() {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) {
      return const RelativeRect.fromLTRB(100, 100, 0, 0);
    }
    return RelativeRect.fromLTRB(
      overlay.size.width - 200,
      80,
      0,
      overlay.size.height - 200,
    );
  }

  Future<void> _downloadAs(String ext) async {
    if (_busy) return;
    setState(() => _busy = true);

    final artifact = widget.artifact;
    final suggestedName =
        '${artifact.id}-v${_selectedVersion ?? artifact.version}.$ext';

    try {
      final bytes = await _bytesForFormat(ext);
      if (bytes == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Export failed: could not generate $ext'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }

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
        allowedExtensions: [ext],
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

  String? get _effectiveAttachmentPath {
    final selected = _selectedVersion;
    if (selected != null && selected != widget.artifact.version) {
      final snapshot =
          _versions.where((v) => v.version == selected).firstOrNull;
      return snapshot?.attachmentPath;
    }
    return widget.artifact.attachmentPath;
  }

  @override
  Widget build(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;
    final isNarrow = MediaQuery.of(context).size.width < 520;

    final versionDropdown = _loadingVersions
        ? const SizedBox(
            width: 70,
            child: LinearProgressIndicator(minHeight: 2),
          )
        : (_versions.length <= 1
            ? const SizedBox.shrink()
            : Container(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  border: Border.all(color: iconFg.withValues(alpha: 0.2)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: DropdownButton<int>(
                  value: _versions.any((v) => v.version == _selectedVersion)
                      ? _selectedVersion
                      : null,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  style: TextStyle(fontSize: 12, color: iconFg),
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
              ));

    final actionMenu = PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 20),
      tooltip: 'More',
      onSelected: (v) {
        switch (v) {
          case 'copy':
            _copyContent();
          case 'download':
            if (!_busy) _showDownloadMenu();
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'copy',
          child: Row(
            children: [
              Icon(Icons.copy_outlined, size: 18),
              SizedBox(width: 10),
              Text('Copy source'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'download',
          child: Row(
            children: [
              Icon(Icons.download_outlined, size: 18),
              SizedBox(width: 10),
              Text('Download'),
            ],
          ),
        ),
      ],
    );

    Widget header;
    if (isNarrow) {
      // Two-row header so everything fits on a phone.
      header = Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: iconFg.withValues(alpha: 0.12)),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.article_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.artifact.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                actionMenu,
                if (widget.onClose != null)
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: widget.onClose,
                    tooltip: 'Close',
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                _TypeBadge(type: _effectiveType),
                const SizedBox(width: 8),
                if (_hasDualView)
                  Flexible(
                    child: _ViewModeToggle(
                      mode: _viewMode,
                      onChanged: (mode) => setState(() => _viewMode = mode),
                    ),
                  ),
                const Spacer(),
                versionDropdown,
              ],
            ),
          ],
        ),
      );
    } else {
      header = Container(
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
            if (_hasDualView)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _ViewModeToggle(
                  mode: _viewMode,
                  onChanged: (mode) => setState(() => _viewMode = mode),
                ),
              ),
            IconButton(
              icon: const Icon(Icons.copy_outlined, size: 18),
              onPressed: _copyContent,
              tooltip: 'Copy source',
            ),
            IconButton(
              icon: const Icon(Icons.download_outlined, size: 18),
              onPressed: _busy ? null : _showDownloadMenu,
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
      );
    }

    return Column(
      children: [
        if (widget.showHeader) header,
        Expanded(
          child: Container(
            width: double.infinity,
            padding: EdgeInsets.all(isNarrow ? 8 : 12),
            child: _ArtifactRenderer(
              type: _effectiveType,
              language: widget.artifact.language,
              content: _effectiveContent,
              attachmentPath: _effectiveAttachmentPath,
              captureKey: _visualCaptureKey,
              forceCodeView: _hasDualView && _viewMode == _ArtifactViewMode.code,
              codeLanguageHint: _codeLanguageHint,
            ),
          ),
        ),
        if (!isNarrow)
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
  const ArtifactBottomSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 1.0,
      minChildSize: 0.6,
      maxChildSize: 1.0,
      expand: false,
      snap: true,
      snapSizes: const [0.6, 1.0],
      builder: (context, scrollController) {
        return PrimaryScrollController(
          controller: scrollController,
          child: Material(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                // Drag handle — tap/drag to dismiss.
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragEnd: (details) {
                    if ((details.primaryVelocity ?? 0) > 250) {
                      Navigator.of(context).maybePop();
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Container(
                      width: 44,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: ValueListenableBuilder<ArtifactDocument?>(
                    valueListenable:
                        ArtifactStorageService.activeArtifactNotifier,
                    builder: (context, artifact, _) {
                      if (artifact == null) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('No artifact selected.'),
                          ),
                        );
                      }
                      return ArtifactPanel(
                        artifact: artifact,
                        onClose: () => Navigator.of(context).maybePop(),
                      );
                    },
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
    this.attachmentPath,
    this.captureKey,
    this.forceCodeView = false,
    this.codeLanguageHint = '',
  });

  final ArtifactType type;
  final String content;
  final String? language;
  final String? attachmentPath;
  final bool forceCodeView;
  final String codeLanguageHint;

  /// Attached to visual artifacts (SVG, technical drawings) so parent can
  /// capture a PNG via RenderRepaintBoundary.toImage().
  final GlobalKey? captureKey;

  Widget _buildVisualView(BuildContext context, Color iconFg) {
    switch (type) {
      case ArtifactType.svg:
        return _ZoomableVisual(
          child: RepaintBoundary(
            key: captureKey,
            child: Container(
              color: Colors.white,
              child: SvgPicture.string(
                content,
                fit: BoxFit.contain,
                placeholderBuilder: (context) => const Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              ),
            ),
          ),
        );
      case ArtifactType.technicalDrawing:
        return _ZoomableVisual(
          child: RepaintBoundary(
            key: captureKey,
            child: TechnicalDrawingWidget(jsonString: content),
          ),
        );
      case ArtifactType.typst:
        return _TypstPdfRenderer(
          source: content,
          attachmentPath: attachmentPath,
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildCodeView(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final scrollController = PrimaryScrollController.maybeOf(context);
    final usePrimary = scrollController == null;
    final fenced = '```$codeLanguageHint\n$content\n```';
    return SingleChildScrollView(
      controller: scrollController,
      primary: usePrimary,
      child: MarkdownMessage(
        text: fenced,
        textColor: iconFg,
        backgroundColor: bg,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final scrollController = PrimaryScrollController.maybeOf(context);
    final usePrimary = scrollController == null;

    // Dual-view types (typst / svg / technical drawing) keep BOTH children
    // mounted so toggling Preview ⇄ Code doesn't tear down the preview
    // renderer (and, for typst, re-download / re-render the PDF every
    // flip).
    final bool supportsDualView = type == ArtifactType.typst ||
        type == ArtifactType.svg ||
        type == ArtifactType.technicalDrawing;
    if (supportsDualView) {
      return IndexedStack(
        index: forceCodeView ? 1 : 0,
        sizing: StackFit.expand,
        children: [
          _buildVisualView(context, iconFg),
          _buildCodeView(context),
        ],
      );
    }

    if (forceCodeView) {
      return _buildCodeView(context);
    }

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
          child: RepaintBoundary(
            key: captureKey,
            child: Container(
              color: Colors.white,
              child: SvgPicture.string(
                content,
                fit: BoxFit.contain,
                placeholderBuilder: (context) => const Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              ),
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
          child: RepaintBoundary(
            key: captureKey,
            child: TechnicalDrawingWidget(jsonString: content),
          ),
        );
      case ArtifactType.typst:
        return _TypstPdfRenderer(
          source: content,
          attachmentPath: attachmentPath,
        );
    }
  }
}

/// Renders a Typst artifact's PDF. Prefers the persisted encrypted
/// attachment (downloaded & decrypted client-side); falls back to a
/// live backend compile if no attachment exists or it can't be read.
class _TypstPdfRenderer extends StatefulWidget {
  const _TypstPdfRenderer({
    required this.source,
    this.attachmentPath,
  });

  final String source;
  final String? attachmentPath;

  @override
  State<_TypstPdfRenderer> createState() => _TypstPdfRendererState();
}

class _TypstPdfRendererState extends State<_TypstPdfRenderer> {
  String? _error;
  bool _loading = true;
  Uint8List? _pdfBytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _TypstPdfRenderer old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source ||
        old.attachmentPath != widget.attachmentPath) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final path = widget.attachmentPath;
    if (path != null && path.isNotEmpty) {
      try {
        final bytes = await PdfAttachmentService.download(path);
        if (!mounted) return;
        setState(() {
          _pdfBytes = bytes;
          _loading = false;
        });
        return;
      } catch (e) {
        if (kDebugMode) {
          debugPrint('PDF attachment fetch failed ($path): $e — falling '
              'back to live compile');
        }
      }
    }

    await _compile();
  }

  Future<void> _compile() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    final baseUrl = ApiConfigService.apiBaseUrl;
    final token = SupabaseService.auth.currentSession?.accessToken;

    if (baseUrl.isEmpty) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Not connected to server.';
      });
      return;
    }

    try {
      final bytes = await typst_tools.compileTypstToPdf(
        serverHttpUrl: baseUrl,
        accessToken: token,
        source: widget.source,
      );
      if (!mounted) return;
      setState(() {
        _pdfBytes = bytes;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('Compiling Typst…'),
          ],
        ),
      );
    }

    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 36, color: Colors.redAccent),
            const SizedBox(height: 12),
            const Text(
              'Typst compile failed',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            SelectableText(
              _error!,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _compile,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    final bytes = _pdfBytes;
    if (bytes == null) {
      return const SizedBox.shrink();
    }
    return PdfViewer.data(
      bytes,
      sourceName: 'typst.pdf',
      params: const PdfViewerParams(
        margin: 12,
        backgroundColor: Color(0xFF202020),
      ),
    );
  }
}

/// Preview / Code toggle shown in the artifact header for types that support
/// both a rendered preview and a plaintext source view.
class _ViewModeToggle extends StatelessWidget {
  const _ViewModeToggle({required this.mode, required this.onChanged});

  final _ArtifactViewMode mode;
  final ValueChanged<_ArtifactViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<_ArtifactViewMode>(
      showSelectedIcon: false,
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: WidgetStateProperty.all(
          const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        ),
        textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12)),
      ),
      segments: const [
        ButtonSegment(
          value: _ArtifactViewMode.preview,
          icon: Icon(Icons.visibility_outlined, size: 14),
          label: Text('Preview'),
        ),
        ButtonSegment(
          value: _ArtifactViewMode.code,
          icon: Icon(Icons.code, size: 14),
          label: Text('Code'),
        ),
      ],
      selected: {mode},
      onSelectionChanged: (set) {
        if (set.isNotEmpty) onChanged(set.first);
      },
    );
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

class _DownloadFormat {
  const _DownloadFormat(this.label, this.ext);
  final String label;
  final String ext;
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
