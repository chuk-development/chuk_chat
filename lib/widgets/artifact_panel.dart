// lib/widgets/artifact_panel.dart
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:markdraw/markdraw.dart' as markdraw;

import 'package:chuk_chat/models/artifact.dart';
import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/artifact_storage_service.dart';
import 'package:chuk_chat/services/file_save_service.dart';
import 'package:chuk_chat/services/pdf_attachment_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/tool_handlers/typst_tools.dart' as typst_tools;
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/markdown_message.dart';
import 'package:chuk_chat/widgets/excalidraw_svg_export.dart';
import 'package:chuk_chat/widgets/html_artifact_view.dart';
import 'package:chuk_chat/widgets/technical_drawing_svg_export.dart';
import 'package:chuk_chat/widgets/technical_drawing_widget.dart';
import 'package:pdfrx/pdfrx.dart';

class ArtifactPanel extends StatefulWidget {
  const ArtifactPanel({
    super.key,
    required this.artifact,
    this.onClose,
    this.onOpenSourceChat,
    this.showHeader = true,
  });

  final ArtifactDocument artifact;
  final VoidCallback? onClose;
  /// Optional jump to the chat this artifact was generated in. When set,
  /// the panel shows a header button that lets the user open the source
  /// conversation in the main chat area.
  final void Function(String chatId)? onOpenSourceChat;
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

  /// True when the user has picked a snapshot older than the live row.
  /// Disables editing so saving from a historical view doesn't silently
  /// fork off the latest version.
  bool get _isViewingHistory =>
      _selectedVersion != null &&
      _selectedVersion != widget.artifact.version;

  /// All artifacts currently available in this chat. Used for the
  /// switcher button in the header. Refreshed on mount + on every
  /// `ArtifactStorageService.changes` event.
  List<ArtifactDocument> _chatArtifacts = const [];
  StreamSubscription<void>? _artifactsChangesSub;

  /// Captures the visual rendering (SVG / technical drawing) for PNG export.
  final GlobalKey _visualCaptureKey = GlobalKey();

  /// Artifact types that have both a rendered preview and a source-code view.
  static const Set<ArtifactType> _dualViewTypes = {
    ArtifactType.svg,
    ArtifactType.technicalDrawing,
    ArtifactType.typst,
    ArtifactType.excalidraw,
    ArtifactType.html,
  };

  bool get _hasDualView => _dualViewTypes.contains(widget.artifact.type);

  String get _codeLanguageHint => switch (widget.artifact.type) {
    ArtifactType.svg => 'xml',
    ArtifactType.technicalDrawing => 'json',
    ArtifactType.typst => 'typst',
    ArtifactType.excalidraw => 'json',
    ArtifactType.html => 'html',
    _ => '',
  };

  @override
  void initState() {
    super.initState();
    _selectedVersion = widget.artifact.version;
    _loadVersions();
    _loadChatArtifacts();
    _artifactsChangesSub = ArtifactStorageService.changes.listen(
      (_) => _loadChatArtifacts(),
    );
    ArtifactStorageService.pendingInitialOpen.addListener(
      _onPendingVersionChanged,
    );
  }

  Future<void> _loadChatArtifacts() async {
    final chatId = widget.artifact.chatId;
    try {
      final all = await ArtifactStorageService.loadArtifactsForChat(chatId);
      if (!mounted) return;
      setState(() => _chatArtifacts = all);
    } catch (_) {
      // Non-fatal: the switcher just won't populate on error.
    }
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
    ArtifactStorageService.pendingInitialOpen.removeListener(
      _onPendingVersionChanged,
    );
    _artifactsChangesSub?.cancel();
    super.dispose();
  }

  void _switchActiveArtifact(ArtifactDocument target) {
    if (target.id == widget.artifact.id) return;
    ArtifactStorageService.activeArtifactNotifier.value = target;
    ArtifactStorageService.requestOpen(artifactId: target.id);
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
          _DownloadFormat('Word document (.docx)', 'docx'),
          _DownloadFormat('Typst source', 'typ'),
        ];
      case ArtifactType.excalidraw:
        return const [
          _DownloadFormat('Excalidraw file', 'excalidraw'),
          _DownloadFormat('SVG vector', 'svg'),
        ];
      case ArtifactType.html:
        return const [
          _DownloadFormat('HTML source', 'html'),
          _DownloadFormat('PNG screenshot', 'png'),
        ];
      case ArtifactType.code:
      case ArtifactType.markdown:
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
        // Excalidraw → generate SVG from scene JSON
        if (widget.artifact.type == ArtifactType.excalidraw) {
          final svg = excalidrawToSvg(_effectiveContent);
          if (svg == null) return null;
          return Uint8List.fromList(utf8.encode(svg));
        }
        // SVG artifact → raw content
        return Uint8List.fromList(utf8.encode(_effectiveContent));
      case 'excalidraw':
        return Uint8List.fromList(utf8.encode(_effectiveContent));
      case 'pdf':
      case 'docx':
        if (widget.artifact.type == ArtifactType.typst) {
          final baseUrl = ApiConfigService.apiBaseUrl;
          final token = SupabaseService.auth.currentSession?.accessToken;
          if (baseUrl.isEmpty) {
            return null;
          }
          final result = await typst_tools.compileTypstToPdf(
            serverHttpUrl: baseUrl,
            accessToken: token,
            source: _effectiveContent,
            format: ext,
          );
          return result.bytes;
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

      final result = await FileSaveService.save(
        bytes: bytes,
        suggestedName: suggestedName,
        dialogTitle: 'Save Artifact',
        allowedExtensions: [ext],
      );
      if (!mounted) return;
      switch (result.outcome) {
        case SaveOutcome.savedToFolder:
        case SaveOutcome.savedViaPicker:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Saved to ${result.path}'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        case SaveOutcome.savedViaShare:
        case SaveOutcome.cancelled:
          break;
        case SaveOutcome.failed:
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to save artifact'),
              behavior: SnackBarBehavior.floating,
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
      final snapshot = _versions
          .where((v) => v.version == selected)
          .firstOrNull;
      return snapshot?.attachmentPath;
    }
    return widget.artifact.attachmentPath;
  }

  @override
  Widget build(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;
    final isNarrow = MediaQuery.of(context).size.width < 520;

    final double dropdownFontSize = isNarrow ? 14 : 12;
    final double dropdownIconSize = isNarrow ? 22 : 18;
    final double dropdownHorizPad = isNarrow ? 12 : 8;
    final double dropdownHeight = isNarrow ? 36 : 32;
    final versionDropdown = _loadingVersions
        ? SizedBox(
            width: 70,
            height: isNarrow ? dropdownHeight : 16,
            child: const Center(
              child: SizedBox(
                width: 60,
                child: LinearProgressIndicator(minHeight: 2),
              ),
            ),
          )
        : (_versions.length <= 1
              ? const SizedBox.shrink()
              : Container(
                  height: dropdownHeight,
                  padding: EdgeInsets.symmetric(horizontal: dropdownHorizPad),
                  decoration: BoxDecoration(
                    border: Border.all(color: iconFg.withValues(alpha: 0.2)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: DropdownButton<int>(
                    focusColor: Colors.transparent,
                    value: _versions.any((v) => v.version == _selectedVersion)
                        ? _selectedVersion
                        : null,
                    isDense: true,
                    underline: const SizedBox.shrink(),
                    iconSize: dropdownIconSize,
                    style: TextStyle(fontSize: dropdownFontSize, color: iconFg),
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
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: 'copy',
          child: Row(
            children: [
              Icon(Icons.copy_outlined, size: 18),
              SizedBox(width: 10),
              Text('Copy source'),
            ],
          ),
        ),
        const PopupMenuItem(
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
      // Mobile header: bigger touch targets, no awkward wrapping.
      // Row 1: icon + title + action menu + close.
      // Row 2 (only when dual view): full-width Preview|Code toggle + version chip.
      // Row 2 alt (no dual view, only when versions > 1): version chip aligned right.
      final bool showVersion = _loadingVersions || _versions.length > 1;
      header = Container(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: iconFg.withValues(alpha: 0.12)),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 48,
              child: Row(
                children: [
                  Icon(_iconForType(_effectiveType), size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _ArtifactSwitcher(
                      current: widget.artifact,
                      all: _chatArtifacts,
                      onSelect: _switchActiveArtifact,
                      fontSize: 16,
                    ),
                  ),
                  if (widget.onOpenSourceChat != null)
                    IconButton(
                      icon: const Icon(Icons.forum_outlined, size: 22),
                      onPressed: () =>
                          widget.onOpenSourceChat!(widget.artifact.chatId),
                      tooltip: 'Open source chat',
                    ),
                  actionMenu,
                  if (widget.onClose != null)
                    IconButton(
                      icon: const Icon(Icons.close, size: 22),
                      onPressed: widget.onClose,
                      tooltip: 'Close',
                    ),
                ],
              ),
            ),
            if (_hasDualView)
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: _ViewModeToggle(
                        mode: _viewMode,
                        compact: false,
                        onChanged: (mode) => setState(() => _viewMode = mode),
                      ),
                    ),
                    if (showVersion) ...[
                      const SizedBox(width: 8),
                      versionDropdown,
                    ],
                  ],
                ),
              )
            else if (showVersion)
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 8),
                child: Row(children: [const Spacer(), versionDropdown]),
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
              child: _ArtifactSwitcher(
                current: widget.artifact,
                all: _chatArtifacts,
                onSelect: _switchActiveArtifact,
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
            if (widget.onOpenSourceChat != null)
              IconButton(
                icon: const Icon(Icons.forum_outlined, size: 18),
                onPressed: () =>
                    widget.onOpenSourceChat!(widget.artifact.chatId),
                tooltip: 'Open source chat',
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
        if (_isViewingHistory)
          _HistoryReadOnlyBanner(
            selectedVersion: _selectedVersion ?? widget.artifact.version,
            latestVersion: widget.artifact.version,
            onSwitchToLatest: () =>
                _selectVersion(widget.artifact.version),
          ),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: EdgeInsets.all(isNarrow ? 8 : 12),
            child: _ArtifactRenderer(
              type: _effectiveType,
              language: widget.artifact.language,
              content: _effectiveContent,
              attachmentPath: _effectiveAttachmentPath,
              artifactId: widget.artifact.id,
              title: widget.artifact.title,
              captureKey: _visualCaptureKey,
              forceCodeView:
                  _hasDualView && _viewMode == _ArtifactViewMode.code,
              codeLanguageHint: _codeLanguageHint,
              readOnly: _isViewingHistory,
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
                            focusColor: Colors.transparent,
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
  const ArtifactBottomSheet({super.key, this.onOpenSourceChat});

  /// Mobile equivalent of the desktop side panel's source-chat button:
  /// dismisses the sheet and switches the underlying chat UI to the
  /// conversation that produced this artifact.
  final void Function(String chatId)? onOpenSourceChat;

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
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.25),
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
                        onOpenSourceChat: onOpenSourceChat == null
                            ? null
                            : (chatId) {
                                Navigator.of(context).maybePop();
                                onOpenSourceChat!(chatId);
                              },
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
    this.artifactId,
    this.title,
    this.captureKey,
    this.forceCodeView = false,
    this.codeLanguageHint = '',
    this.readOnly = false,
  });

  final ArtifactType type;
  final String content;
  final String? language;
  final String? attachmentPath;
  final String? artifactId;
  final String? title;
  final bool forceCodeView;
  final String codeLanguageHint;

  /// True when the user has selected a non-current snapshot. Forces
  /// editor widgets (e.g. markdraw) into a non-mutating mode so saves
  /// can't accidentally fork a new version off a historical body.
  final bool readOnly;

  /// Attached to visual artifacts (SVG, technical drawings) so parent can
  /// capture a PNG via RenderRepaintBoundary.toImage().
  final GlobalKey? captureKey;

  Widget _buildVisualView(BuildContext context, Color iconFg) {
    switch (type) {
      case ArtifactType.svg:
        return _ZoomableVisual(
          key: ValueKey('zoom_svg_${artifactId ?? ""}'),
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
          key: ValueKey('zoom_td_${artifactId ?? ""}'),
          child: RepaintBoundary(
            key: captureKey,
            child: TechnicalDrawingWidget(jsonString: content),
          ),
        );
      case ArtifactType.excalidraw:
        return RepaintBoundary(
          key: captureKey,
          child: _ExcalidrawMarkdrawEditor(
            // Key changes when readOnly flips so didUpdateWidget can't
            // be tricked into keeping a previously-registered flusher
            // alive on a historical view.
            key: ValueKey('mkdr_${artifactId ?? ""}_${readOnly ? "ro" : "rw"}'),
            artifactId: artifactId,
            title: title,
            jsonString: content,
            readOnly: readOnly,
          ),
        );
      case ArtifactType.html:
        return HtmlArtifactView(
          key: ValueKey('html_${artifactId ?? ""}'),
          html: content,
          captureKey: captureKey,
        );
      case ArtifactType.typst:
        return _TypstPdfRenderer(
          key: ValueKey('typst_${artifactId ?? ""}'),
          source: content,
          attachmentPath: attachmentPath,
          artifactId: artifactId,
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

    // Dual-view types (typst / svg / technical drawing / excalidraw / html)
    // keep BOTH children mounted so toggling Preview ⇄ Code doesn't tear
    // down the preview renderer (and, for typst, re-download / re-render
    // the PDF every flip).
    final bool supportsDualView =
        type == ArtifactType.typst ||
        type == ArtifactType.svg ||
        type == ArtifactType.technicalDrawing ||
        type == ArtifactType.excalidraw ||
        type == ArtifactType.html;
    if (supportsDualView) {
      return IndexedStack(
        index: forceCodeView ? 1 : 0,
        sizing: StackFit.expand,
        children: [_buildVisualView(context, iconFg), _buildCodeView(context)],
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
          key: ValueKey('zoom_svg_${artifactId ?? ""}'),
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
          key: ValueKey('zoom_td_${artifactId ?? ""}'),
          child: RepaintBoundary(
            key: captureKey,
            child: TechnicalDrawingWidget(jsonString: content),
          ),
        );
      case ArtifactType.excalidraw:
        // Unreachable — excalidraw is handled by the IndexedStack dual-view
        // branch above. This case exists only so the switch stays exhaustive.
        return const SizedBox.shrink();
      case ArtifactType.html:
        // Unreachable — html is handled by the IndexedStack dual-view branch.
        return const SizedBox.shrink();
      case ArtifactType.typst:
        return _TypstPdfRenderer(
          key: ValueKey('typst_${artifactId ?? ""}'),
          source: content,
          attachmentPath: attachmentPath,
          artifactId: artifactId,
        );
    }
  }
}

/// Native cross-platform Excalidraw editor backed by the `markdraw`
/// package. Loads the scene JSON into a controller and lets the user
/// edit live — but **never** mutates existing artifact versions. Every
/// persisted change is a fresh version via
/// [ArtifactStorageService.rewriteArtifact]; user edits are held in
/// memory until the chat-send pipeline flushes them (or the editor is
/// disposed). That way "Version 1" stays exactly what the AI authored
/// and the user's scribbles land in "Version 2", "Version 3", ….
///
/// A flush callback is registered with
/// [ArtifactStorageService.registerPendingFlusher] so
/// `ArtifactContextService.buildArtifactsSystemMessage` can force any
/// pending edits to a new version before the AI's next request reads
/// the artifact body.
class _ExcalidrawMarkdrawEditor extends StatefulWidget {
  const _ExcalidrawMarkdrawEditor({
    super.key,
    required this.jsonString,
    this.artifactId,
    this.title,
    this.readOnly = false,
  });

  final String jsonString;
  final String? artifactId;

  /// Forwarded to the markdraw controller via `renameDocument` so the
  /// `appState.name` field in the serialized `.excalidraw` JSON carries
  /// the artifact title. Without this the export shows up nameless when
  /// the user downloads the scene file.
  final String? title;

  /// When true, the editor renders the scene but rejects all edits and
  /// never registers a pending-flusher. Used when the artifact panel is
  /// showing a historical snapshot — saving from there would create a
  /// new version off the OLD body, which is almost never what the user
  /// wants. The official "latest" body remains the only editable surface.
  final bool readOnly;

  @override
  State<_ExcalidrawMarkdrawEditor> createState() =>
      _ExcalidrawMarkdrawEditorState();
}

class _ExcalidrawMarkdrawEditorState extends State<_ExcalidrawMarkdrawEditor> {
  late final markdraw.MarkdrawController _controller;
  String _lastPersisted = '';
  bool _savingSelfTriggered = false;
  bool _busy = false;
  bool _hasUnsavedChanges = false;
  String? _saveError;

  /// The flush callback we registered with [ArtifactStorageService]. Held
  /// so `dispose` can unregister exactly the closure we installed (not a
  /// later one that replaced ours, e.g. after a chat switch).
  Future<void> Function()? _registeredFlush;

  @override
  void initState() {
    super.initState();
    _controller = markdraw.MarkdrawController();
    _loadIntoController(widget.jsonString);
    _applyTitleToController(widget.title);
    // Read-only views never register a flusher — that callback is what
    // would silently push the historical snapshot's body as a NEW
    // version on the next chat send. Skipping it keeps the historical
    // view truly read-only.
    if (!widget.readOnly) {
      _registerFlusher();
    }
    _scheduleAutoCenter();
  }

  /// Auto-fit the scene to the viewport on first paint. Has to wait
  /// for LayoutBuilder to deliver a non-zero size, otherwise zoomToFit
  /// has nothing to fit against. We retry a couple of frames in case
  /// the panel is still animating in.
  void _scheduleAutoCenter() {
    var attempts = 0;
    void tryCenter() {
      if (!mounted) return;
      if (_lastKnownCanvasSize.width > 0 &&
          _lastKnownCanvasSize.height > 0) {
        try {
          _controller.zoomToFit(_lastKnownCanvasSize);
        } catch (error) {
          if (kDebugMode) debugPrint('auto-center zoomToFit failed: $error');
        }
        return;
      }
      attempts++;
      if (attempts > 10) return;
      WidgetsBinding.instance.addPostFrameCallback((_) => tryCenter());
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => tryCenter());
  }

  void _loadIntoController(String json) {
    if (json.trim().isEmpty) {
      _lastPersisted = json;
      return;
    }
    try {
      _controller.loadFromContent(json, 'scene.excalidraw');
      // markdraw's parser normalises the scene (fills defaults, drops
      // unknown excalidraw fields) — so the very next `serializeScene`
      // returns a string that differs from the raw AI-authored JSON even
      // though nothing was edited. Baseline the dedupe key off the
      // post-parse serialization so the first `onSceneChanged` doesn't
      // immediately overwrite the original artifact content with the
      // lossy round-trip.
      _lastPersisted = _controller.serializeScene(
        format: markdraw.DocumentFormat.excalidraw,
      );
    } catch (error, stack) {
      _lastPersisted = json;
      if (kDebugMode) {
        debugPrint('Markdraw load failed: $error\n$stack');
      }
    }
  }

  void _applyTitleToController(String? title) {
    // Empty string clears the name (matches markdraw's contract). Trim
    // so trailing whitespace from a paste doesn't leak into the export.
    final next = (title ?? '').trim();
    try {
      _controller.renameDocument(next);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Markdraw renameDocument failed: $error');
      }
    }
  }

  void _registerFlusher() {
    final id = widget.artifactId;
    if (id == null || id.isEmpty) return;
    Future<void> flush() async {
      await _persistAsNewVersion();
    }

    _registeredFlush = flush;
    ArtifactStorageService.registerPendingFlusher(id, flush);
  }

  @override
  void didUpdateWidget(covariant _ExcalidrawMarkdrawEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Skip the rebuild that our OWN save triggered — otherwise we'd
    // re-load the just-serialized content back into the controller
    // and clobber the user's in-flight selection / undo history.
    if (_savingSelfTriggered) {
      _savingSelfTriggered = false;
      // The widget's `jsonString` is now whatever we serialized — but
      // since we just persisted it, our in-memory controller is already
      // canonical. Rebase the dedupe key off the current controller
      // state so we don't get tricked into re-saving a no-op.
      _lastPersisted = _safeSerialize();
      if (oldWidget.title != widget.title) {
        _applyTitleToController(widget.title);
      }
      return;
    }
    if (oldWidget.jsonString != widget.jsonString) {
      _loadIntoController(widget.jsonString);
      // Fresh content (artifact switched, or AI generated a new version
      // externally) — recentre so the user actually sees the new scene
      // instead of staring at the pan/zoom from the previous artifact.
      _scheduleAutoCenter();
    }
    if (oldWidget.title != widget.title) {
      _applyTitleToController(widget.title);
    }
    if (oldWidget.artifactId != widget.artifactId) {
      // Artifact identity changed (panel reused for a different artifact).
      // Drop the old flusher, register a fresh one keyed to the new id.
      final oldId = oldWidget.artifactId;
      if (oldId != null && oldId.isNotEmpty && _registeredFlush != null) {
        ArtifactStorageService.unregisterPendingFlusher(
          oldId,
          _registeredFlush,
        );
      }
      _registeredFlush = null;
      _registerFlusher();
    }
  }

  @override
  void dispose() {
    final id = widget.artifactId;
    if (id != null && id.isNotEmpty && _registeredFlush != null) {
      ArtifactStorageService.unregisterPendingFlusher(id, _registeredFlush);
    }
    _registeredFlush = null;
    // Read-only views never accepted edits, so there is nothing legitimate
    // to flush. Skip the dispose-time save so leaving a historical view
    // can't fork a new version off the OLD body.
    if (!widget.readOnly) {
      // Flush a final save if there are unsaved edits in the buffer. We
      // don't await — the framework's dispose can't be async — but kicking
      // it off ensures the request reaches the network. This is also a
      // safety net for the "user closes panel without sending a message"
      // path: the next AI turn still sees the latest scene.
      unawaited(_persistAsNewVersion());
    }
    _controller.dispose();
    super.dispose();
  }

  void _onSceneChanged(markdraw.Scene _) {
    // Hard ignore in read-only mode — the IgnorePointer should prevent
    // user input, but markdraw may still fire programmatic scene
    // updates (auto-fit, internal normalisation) which must not count
    // as "unsaved changes" or trigger flushes.
    if (widget.readOnly) return;
    // Live edits stay in memory only. We do NOT auto-save mid-drag —
    // every persisted change must be a fresh artifact version so the
    // existing snapshots stay immutable. The actual flush happens when
    // the user sends a chat message (via the pending-flusher registry)
    // or when the editor is disposed.
    final hasChanges = _safeSerialize() != _lastPersisted;
    if (hasChanges != _hasUnsavedChanges && mounted) {
      setState(() => _hasUnsavedChanges = hasChanges);
    }
  }

  String _safeSerialize() {
    try {
      return _controller.serializeScene(
        format: markdraw.DocumentFormat.excalidraw,
      );
    } catch (error) {
      if (kDebugMode) debugPrint('Markdraw serialize failed: $error');
      return _lastPersisted;
    }
  }

  /// Commits the current scene as a NEW artifact version. Called only
  /// by `flushPendingEdits` (chat send) and `dispose`. Never overwrites
  /// an existing version — `rewriteArtifact` always bumps. If the scene
  /// hasn't changed since the last flush, this is a no-op.
  Future<void> _persistAsNewVersion() async {
    final id = widget.artifactId;
    if (id == null || id.isEmpty) return;
    final serialized = _safeSerialize();
    if (serialized == _lastPersisted) return;
    _lastPersisted = serialized;
    _savingSelfTriggered = true;
    if (mounted) setState(() => _busy = true);
    try {
      final updated = await ArtifactStorageService.rewriteArtifact(
        artifactId: id,
        content: serialized,
        preserveMetadata: true,
      );
      ArtifactStorageService.activeArtifactNotifier.value = updated;
      if (mounted) {
        setState(() {
          _busy = false;
          _saveError = null;
          _hasUnsavedChanges = false;
        });
      }
    } catch (error, stack) {
      if (kDebugMode) {
        debugPrint('Excalidraw artifact save failed: $error\n$stack');
      }
      _lastPersisted = '';
      if (mounted) {
        setState(() {
          _busy = false;
          _saveError = 'Save failed: $error';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not save edits: $error'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Size _lastKnownCanvasSize = const Size(800, 600);

  void _centerCanvas() {
    try {
      _controller.zoomToFit(_lastKnownCanvasSize);
    } catch (error) {
      if (kDebugMode) debugPrint('zoomToFit failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _lastKnownCanvasSize = Size(constraints.maxWidth, constraints.maxHeight);
        return _buildStack(context);
      },
    );
  }

  Widget _buildStack(BuildContext context) {
    return Stack(
      children: [
        // ClipRect contains markdraw's floating PropertyPanel /
        // toolbar / overlays — they're built with `Positioned` inside
        // an internal Stack and will happily render outside our bounds
        // (into the chat area on the left) if we don't clip.
        Positioned.fill(
          child: ClipRect(
            // IgnorePointer (instead of AbsorbPointer) so a tap on the
            // historical view goes THROUGH to the banner's "Switch to
            // latest" button when overlaid. Markdraw has no native
            // read-only flag, so this is the cleanest way to suppress
            // all editing input without forking the package.
            child: IgnorePointer(
              ignoring: widget.readOnly,
              child: markdraw.MarkdrawEditor(
                controller: _controller,
                onSceneChanged: _onSceneChanged,
                config: const markdraw.MarkdrawEditorConfig(
                  // Hide menu/library buttons that would otherwise expose
                  // file-system Save/Open dialogs — persistence is driven
                  // by the artifact panel itself, not the editor chrome.
                  // Hide the markdown-panel toggle too: it opens the split
                  // pane showing the `.markdraw` source format, which would
                  // confuse the user (we only store `.excalidraw` JSON).
                  showMenu: false,
                  showLibraryPanel: false,
                  showMarkdownButton: false,
                ),
              ),
            ),
          ),
        ),
        // Fit-to-view button. markdraw ships its own bottom-left zoom
        // controls, but they're easy to miss and don't have an obvious
        // "centre the whole scene" affordance — when the user has
        // panned far away from the content this is the rescue button.
        Positioned(
          top: 8,
          left: 8,
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
            elevation: 1,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _centerCanvas,
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(Icons.center_focus_strong, size: 18),
              ),
            ),
          ),
        ),
        if (_busy)
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('Saving…', style: TextStyle(fontSize: 11)),
                ],
              ),
            ),
          )
        else if (_hasUnsavedChanges)
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                'Unsaved — sent on next chat message',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onTertiaryContainer,
                ),
              ),
            ),
          ),
        if (_saveError != null && !_busy)
          Positioned(
            bottom: 8,
            left: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _saveError!,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Renders a Typst artifact's PDF. Prefers the persisted encrypted
/// attachment (downloaded & decrypted client-side); falls back to a
/// live backend compile if no attachment exists or it can't be read.
class _TypstPdfRenderer extends StatefulWidget {
  const _TypstPdfRenderer({
    super.key,
    required this.source,
    this.attachmentPath,
    this.artifactId,
  });

  final String source;
  final String? attachmentPath;

  /// When non-null and [attachmentPath] is null, a successful live compile
  /// will upload the PDF and backfill the artifact row so subsequent opens
  /// skip the compile step.
  final String? artifactId;

  @override
  State<_TypstPdfRenderer> createState() => _TypstPdfRendererState();
}

class _TypstPdfRendererState extends State<_TypstPdfRenderer> {
  String? _error;
  bool _loading = true;
  Uint8List? _pdfBytes;
  // PdfViewerController extends ValueListenable and has no dispose() — it is
  // attached/detached via the widget lifecycle, so no explicit teardown.
  final PdfViewerController _pdfController = PdfViewerController();
  bool _ctrlHeld = false;

  @override
  void initState() {
    super.initState();
    _load();
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    super.dispose();
  }

  bool _onHardwareKey(KeyEvent event) {
    final isCtrl = HardwareKeyboard.instance.isControlPressed;
    if (isCtrl != _ctrlHeld && mounted) {
      setState(() => _ctrlHeld = isCtrl);
    }
    return false;
  }

  void _zoomUp() => _pdfController.zoomUp();
  void _zoomDown() => _pdfController.zoomDown();
  void _zoomReset() {
    if (!_pdfController.isReady) return;
    final matrices = _pdfController.calcFitZoomMatrices();
    if (matrices.isEmpty) return;
    _pdfController.goTo(matrices.first.matrix);
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
    if (kDebugMode) {
      debugPrint(
        '📄 [Typst] _load() — attachmentPath=${path ?? "NULL"}, '
        'artifactId=${widget.artifactId ?? "NULL"}, '
        'source=${widget.source.length} chars',
      );
    }
    if (path != null && path.isNotEmpty) {
      try {
        if (kDebugMode) {
          debugPrint('📄 [Typst] Downloading from Supabase Storage: $path');
        }
        final bytes = await PdfAttachmentService.download(path);
        if (!mounted) return;
        if (kDebugMode) {
          debugPrint(
            '📄 [Typst] ✅ Downloaded ${bytes.length} bytes — '
            'skipping compile',
          );
        }
        setState(() {
          _pdfBytes = bytes;
          _loading = false;
        });
        return;
      } catch (e) {
        if (kDebugMode) {
          debugPrint(
            '📄 [Typst] ❌ Download failed ($path): $e — '
            'falling back to compile',
          );
        }
      }
    }

    if (kDebugMode) {
      debugPrint('📄 [Typst] No attachment — compiling live');
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

    if (kDebugMode) {
      debugPrint('📄 [Typst] Compiling via $baseUrl ...');
    }
    try {
      final result = await typst_tools.compileTypstToPdf(
        serverHttpUrl: baseUrl,
        accessToken: token,
        source: widget.source,
      );
      if (!mounted) return;
      if (kDebugMode) {
        debugPrint('📄 [Typst] ✅ Compiled ${result.bytes.length} bytes');
      }
      setState(() {
        _pdfBytes = result.bytes;
        _loading = false;
      });
      // Backfill: if this artifact had no stored PDF, persist the
      // compiled bytes so future opens skip the compile round-trip.
      if (widget.attachmentPath == null && widget.artifactId != null) {
        if (kDebugMode) {
          debugPrint(
            '📄 [Typst] Starting backfill for '
            '${widget.artifactId}...',
          );
        }
        _backfillAttachment(result.bytes, widget.artifactId!);
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('📄 [Typst] ❌ Compile failed: $e');
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// Upload compiled PDF and update the artifact row in the background.
  /// Best-effort — failures are silent; the next open just compiles again.
  static void _backfillAttachment(Uint8List bytes, String artifactId) {
    () async {
      try {
        final path = await PdfAttachmentService.upload(bytes);
        await ArtifactStorageService.setAttachmentPath(
          artifactId: artifactId,
          attachmentPath: path,
        );
        if (kDebugMode) {
          debugPrint(
            '[TypstPdfRenderer] Backfilled attachment for '
            '$artifactId → $path',
          );
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[TypstPdfRenderer] Backfill failed for $artifactId: $e');
        }
      }
    }();
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
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
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
    return Stack(
      children: [
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerSignal: (event) {
              if (event is PointerScrollEvent &&
                  HardwareKeyboard.instance.isControlPressed) {
                if (event.scrollDelta.dy < 0) {
                  _zoomUp();
                } else if (event.scrollDelta.dy > 0) {
                  _zoomDown();
                }
              }
            },
            child: PdfViewer.data(
              bytes,
              sourceName: 'typst.pdf',
              controller: _pdfController,
              // While Ctrl is held, zero out wheel scroll so Ctrl+Wheel only
              // zooms (via the outer Listener) instead of zooming AND
              // scrolling simultaneously.
              params: PdfViewerParams(
                margin: 12,
                backgroundColor: const Color(0xFF202020),
                // Match the standard Flutter ListView wheel scroll feel
                // used in the chat UI — anything less than 1.0 makes the PDF
                // viewer feel sluggish relative to the rest of the app.
                scrollByMouseWheel: _ctrlHeld ? 0.0 : 1.0,
                enableKeyboardNavigation: true,
                textSelectionParams: const PdfTextSelectionParams(),
              ),
            ),
          ),
        ),
        Positioned(
          right: 8,
          bottom: 8,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ZoomButton(icon: Icons.add, onTap: _zoomUp),
              const SizedBox(height: 4),
              _ZoomButton(icon: Icons.remove, onTap: _zoomDown),
              const SizedBox(height: 4),
              _ZoomButton(icon: Icons.fit_screen, onTap: _zoomReset),
            ],
          ),
        ),
      ],
    );
  }
}

/// Preview / Code toggle shown in the artifact header for types that support
/// both a rendered preview and a plaintext source view.
class _ViewModeToggle extends StatelessWidget {
  const _ViewModeToggle({
    required this.mode,
    required this.onChanged,
    this.compact = true,
  });

  final _ArtifactViewMode mode;
  final ValueChanged<_ArtifactViewMode> onChanged;

  /// Compact = desktop header (small font, shrink-wrap).
  /// Non-compact = mobile (larger touch targets, fills available width).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<_ArtifactViewMode>(
      showSelectedIcon: false,
      style: ButtonStyle(
        visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
        tapTargetSize: compact
            ? MaterialTapTargetSize.shrinkWrap
            : MaterialTapTargetSize.padded,
        padding: WidgetStateProperty.all(
          compact
              ? const EdgeInsets.symmetric(horizontal: 10, vertical: 4)
              : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
        textStyle: WidgetStateProperty.all(
          TextStyle(fontSize: compact ? 12 : 13),
        ),
      ),
      segments: [
        ButtonSegment(
          value: _ArtifactViewMode.preview,
          icon: Icon(Icons.visibility_outlined, size: compact ? 14 : 16),
          label: const Text('Preview'),
        ),
        ButtonSegment(
          value: _ArtifactViewMode.code,
          icon: Icon(Icons.code, size: compact ? 14 : 16),
          label: const Text('Code'),
        ),
      ],
      selected: {mode},
      onSelectionChanged: (set) {
        if (set.isNotEmpty) onChanged(set.first);
      },
    );
  }
}

IconData _iconForType(ArtifactType type) {
  switch (type) {
    case ArtifactType.code:
      return Icons.code;
    case ArtifactType.markdown:
      return Icons.article_outlined;
    case ArtifactType.html:
      return Icons.html;
    case ArtifactType.mermaid:
      return Icons.account_tree_outlined;
    case ArtifactType.svg:
      return Icons.image_outlined;
    case ArtifactType.technicalDrawing:
      return Icons.architecture;
    case ArtifactType.typst:
      return Icons.picture_as_pdf;
    case ArtifactType.excalidraw:
      return Icons.brush_outlined;
  }
}

/// Zoomable wrapper with +/- buttons for visual artifacts (SVG, drawings).
class _ZoomableVisual extends StatefulWidget {
  const _ZoomableVisual({super.key, required this.child});

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

  void _zoom(double factor, {Offset? focal}) {
    final size = context.size;
    if (size == null) return;
    final current = _ctrl.value.clone();
    final center = focal ?? Offset(size.width / 2, size.height / 2);
    // Scale around given focal point (or viewport center).
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
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerSignal: (event) {
              if (event is! PointerScrollEvent) return;
              final box = context.findRenderObject() as RenderBox?;
              final focal = box?.globalToLocal(event.position);
              final factor = event.scrollDelta.dy < 0 ? 1.15 : 1 / 1.15;
              _zoom(factor, focal: focal);
            },
            child: InteractiveViewer(
              transformationController: _ctrl,
              minScale: 0.05,
              maxScale: 1000.0,
              boundaryMargin: const EdgeInsets.all(double.infinity),
              child: Center(child: widget.child),
            ),
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

/// Thin banner shown above the renderer when the user has selected a
/// historical snapshot in the version dropdown. Makes "this is read-only,
/// switch back to the latest version to edit" loudly visible — the editor
/// surface itself can look identical to the live one, so without this
/// banner the user would silently lose every edit they make.
class _HistoryReadOnlyBanner extends StatelessWidget {
  const _HistoryReadOnlyBanner({
    required this.selectedVersion,
    required this.latestVersion,
    required this.onSwitchToLatest,
  });

  final int selectedVersion;
  final int latestVersion;
  final VoidCallback onSwitchToLatest;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(
              Icons.history,
              size: 18,
              color: scheme.onTertiaryContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Viewing v$selectedVersion (read-only). Switch to latest '
                '(v$latestVersion) to edit.',
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onTertiaryContainer,
                ),
              ),
            ),
            const SizedBox(width: 10),
            TextButton(
              onPressed: onSwitchToLatest,
              style: TextButton.styleFrom(
                foregroundColor: scheme.onTertiaryContainer,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                minimumSize: const Size(0, 0),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text('Switch to v$latestVersion'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Header title + switcher. When the current chat has more than one artifact,
/// the title becomes a popup button that lists all of them so the user can
/// jump between "Quantum Doc", "Test Doc", etc. without going back to the
/// chat. For a single-artifact chat it renders as plain text.
class _ArtifactSwitcher extends StatelessWidget {
  const _ArtifactSwitcher({
    required this.current,
    required this.all,
    required this.onSelect,
    this.fontSize = 14,
  });

  final ArtifactDocument current;
  final List<ArtifactDocument> all;
  final ValueChanged<ArtifactDocument> onSelect;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final titleStyle = TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
    );

    if (all.length <= 1) {
      return Text(
        current.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: titleStyle,
      );
    }

    return PopupMenuButton<String>(
      tooltip: 'Switch artifact',
      position: PopupMenuPosition.under,
      onSelected: (id) {
        final target = all.firstWhere((a) => a.id == id, orElse: () => current);
        onSelect(target);
      },
      itemBuilder: (_) => all
          .map(
            (a) => PopupMenuItem<String>(
              value: a.id,
              child: Row(
                children: [
                  Icon(_iconForType(a.type), size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      a.title.isEmpty ? a.id : a.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: a.id == current.id
                            ? FontWeight.w700
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'v${a.version}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ],
              ),
            ),
          )
          .toList(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              current.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: titleStyle,
            ),
          ),
          const SizedBox(width: 4),
          Icon(Icons.arrow_drop_down, size: fontSize + 6),
        ],
      ),
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
