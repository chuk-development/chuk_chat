// lib/pages/media_manager_page.dart

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/widgets/floating_chrome_surface.dart';

import 'package:chuk_chat/widgets/app_notification.dart';
import 'package:chuk_chat/models/artifact.dart';
import 'package:chuk_chat/services/artifact_storage_service.dart';
import 'package:chuk_chat/services/file_save_service.dart';
import 'package:chuk_chat/services/image_disk_cache.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/services/media_provenance_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/artifact_panel.dart';
import 'package:chuk_chat/widgets/image_viewer.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

enum _MediaFilter { images, artifacts }

/// Height of the floating Images / Pages track, so the library below it
/// can start exactly where the track ends.
const double kMediaFilterBarHeight = 52;

class MediaManagerPage extends StatefulWidget {
  final bool embedded;

  const MediaManagerPage({super.key, this.embedded = false});

  @override
  State<MediaManagerPage> createState() => _MediaManagerPageState();
}

class _MediaManagerPageState extends State<MediaManagerPage> {
  List<StoredImage> _images = [];

  /// Files in the image bucket that turned out to be PDFs (old uploads used
  /// the image ending). Shown under Pages, never in the picture grid.
  List<StoredImage> _pdfs = [];
  bool _isLoading = true;
  String? _error;
  final Set<String> _selectedImages = {};
  bool _isSelectionMode = false;

  // Artifacts tab — minimal viable extension: SVG / HTML / Mermaid /
  // technical drawing / Typst PDF / Excalidraw all surface here.
  List<ArtifactDocument> _artifacts = const <ArtifactDocument>[];
  bool _isLoadingArtifacts = true;
  _MediaFilter _filter = _MediaFilter.images;

  /// The page shown in full inside the library (desktop). Null = the list.
  ArtifactDocument? _previewArtifact;

  // One notifier per image path, holding that thumbnail's whole state:
  // loading, the decoded bytes, or the reason it failed. The tile listens to
  // its own notifier, so a slow image repaints itself instead of the grid,
  // and a failed one can say why and be retried on its own.
  final Map<String, ValueNotifier<_ThumbState>> _thumbs = {};

  // Downloading every visible thumbnail at once is what killed the grid on
  // the phone: each image spawns a utf8-decode isolate and a decrypt isolate,
  // so a library of 99 put ~200 isolates in flight and the spinners never
  // came back. Four at a time keeps the pictures arriving steadily and the
  // phone responsive.
  final _ThumbGate _thumbGate = _ThumbGate(maxInFlight: 6);

  @override
  void initState() {
    super.initState();
    _loadImages();
    _loadArtifacts();
  }

  @override
  void dispose() {
    for (final notifier in _thumbs.values) {
      notifier.dispose();
    }
    _thumbs.clear();
    super.dispose();
  }

  Future<void> _loadArtifacts() async {
    if (!mounted) return;
    setState(() => _isLoadingArtifacts = true);
    try {
      final list = await ArtifactStorageService.listAllUserArtifacts();
      if (!mounted) return;
      setState(() {
        _artifacts = list;
        _isLoadingArtifacts = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _artifacts = const <ArtifactDocument>[];
        _isLoadingArtifacts = false;
      });
    }
  }

  Future<void> _loadImages() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final images = await ImageStorageService.listUserImages();
      // Sort by creation date, newest first
      images.sort((a, b) {
        return switch ((a.createdAt, b.createdAt)) {
          (final DateTime ta, final DateTime tb) => tb.compareTo(ta),
          (null, null) => 0,
          (null, _) => 1,
          (_, null) => -1,
        };
      });

      // Sort out the files already known to be PDFs before the grid draws,
      // so they never flash up as broken pictures.
      final pdfFlags = await Future.wait(
        images.map((image) => ImageDiskCache.isPdf(image.path)),
      );
      final pictures = <StoredImage>[];
      final pdfs = <StoredImage>[];
      for (int i = 0; i < images.length; i++) {
        (pdfFlags[i] ? pdfs : pictures).add(images[i]);
      }

      if (mounted) {
        setState(() {
          _images = pictures;
          _pdfs = pdfs;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  /// The notifier for [path], starting the download the first time it is
  /// asked for. Never started twice for one path: the notifier itself is the
  /// record that work is under way.
  ValueNotifier<_ThumbState> _thumb(String path) {
    final existing = _thumbs[path];
    if (existing != null) return existing;
    final notifier = ValueNotifier<_ThumbState>(const _ThumbState.loading());
    _thumbs[path] = notifier;
    unawaited(_downloadThumbnail(path, notifier));
    return notifier;
  }

  Future<void> _downloadThumbnail(
    String path,
    ValueNotifier<_ThumbState> notifier,
  ) async {
    try {
      final bytes = await _thumbGate
          .run(() {
            // The page may be gone, or this thumbnail replaced, while the
            // request sat in the queue. Do not start work nobody waits for.
            if (!mounted || _thumbs[path] != notifier) {
              throw StateError('thumbnail cancelled');
            }
            return _loadTileBytes(path);
          })
          // Outside the gate on purpose: a slow download keeps its slot
          // until it really ends, so repeated timeouts cannot push the
          // number of downloads in flight past the bound.
          .timeout(const Duration(seconds: 45));
      if (_thumbs[path] != notifier) return;
      if (bytes.error == _pdfLabel) {
        _moveToPdfs(path);
        return;
      }
      notifier.value = bytes;
    } on StateError {
      return;
    } catch (error) {
      if (_thumbs[path] != notifier) return;
      // Say what went wrong. An image that silently turns into a broken-image
      // glyph looks like data loss; "the key is not available" or "not found"
      // tells the reader whether to worry and whether retrying can help.
      notifier.value = _ThumbState.failed(_thumbErrorLabel(error));
    }
  }

  /// The tile's state for [path]: the small thumbnail kept on disk when there
  /// is one (no network, no decrypt, no full-size decode), otherwise the full
  /// picture, shrunk once and the thumbnail stored for every later open.
  static Future<_ThumbState> _loadTileBytes(String path) async {
    final Uint8List? cached = await ImageDiskCache.readThumb(path);
    if (cached != null) return _ThumbState.ready(cached);

    final Uint8List full = await ImageStorageService.downloadAndDecryptImage(
      path,
    );
    // Flutter's decoder handles PNG/JPEG/GIF/WebP/BMP and nothing else. A
    // HEIC or AVIF file downloads and decrypts perfectly and then renders
    // as a broken glyph, which reads as data loss. Name the format instead.
    final String? unsupported = _unsupportedImageLabel(full);
    if (unsupported == _pdfLabel) {
      await ImageDiskCache.markPdf(path);
    }
    if (unsupported != null) return _ThumbState.failed(unsupported);

    Uint8List? thumb;
    try {
      thumb = await ImageDiskCache.makeThumbnail(full);
    } catch (_) {
      thumb = null;
    }
    // The `image` package cannot read every file Flutter can (some WebP
    // variants); then the tile shows the full picture and nothing is stored.
    if (thumb == null) return _ThumbState.ready(full);
    unawaited(ImageDiskCache.writeThumb(path, thumb));
    return _ThumbState.ready(thumb);
  }

  static const String _pdfLabel = 'PDF - not a picture';

  /// Takes the file at [path] out of the picture grid and lists it as a PDF.
  void _moveToPdfs(String path) {
    if (!mounted) return;
    final int index = _images.indexWhere((image) => image.path == path);
    if (index < 0) return;
    setState(() {
      final StoredImage file = _images.removeAt(index);
      _pdfs = [..._pdfs, file];
      _selectedImages.remove(path);
    });
  }

  Future<void> _openPdf(StoredImage file) async {
    try {
      final bytes = await ImageStorageService.downloadAndDecryptImage(
        file.path,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) =>
            _PdfPreviewDialog(name: _pdfName(file), bytes: bytes),
      );
    } catch (error) {
      if (!mounted) return;
      AppNotifications.error(context, _thumbErrorLabel(error));
    }
  }

  static String _pdfName(StoredImage file) {
    final DateTime? created = file.createdAt?.toLocal();
    if (created == null) return 'PDF';
    String two(int v) => v.toString().padLeft(2, '0');
    return 'PDF ${created.year}-${two(created.month)}-${two(created.day)} '
        '${two(created.hour)}:${two(created.minute)}';
  }

  /// Retries one failed thumbnail, bypassing the service's own cache.
  void _retryThumbnail(String path) {
    final notifier = _thumbs[path];
    if (notifier == null) return;
    notifier.value = const _ThumbState.loading();
    unawaited(_downloadThumbnail(path, notifier));
  }

  /// The format name when [bytes] hold a picture Flutter cannot decode, and
  /// null when the file is one of the supported formats.
  static String? _unsupportedImageLabel(Uint8List bytes) {
    if (bytes.length < 16) return 'Empty file';
    String ascii(int start, int end) =>
        String.fromCharCodes(bytes.sublist(start, end)).toLowerCase();

    // ISO base media container: the brand at offset 8 says which one.
    if (ascii(4, 8) == 'ftyp') {
      final String brand = ascii(8, 12);
      if (brand.startsWith('avif') || brand.startsWith('avis')) {
        return 'AVIF - not supported';
      }
      if (brand.startsWith('heic') ||
          brand.startsWith('heix') ||
          brand.startsWith('hevc') ||
          brand.startsWith('mif1') ||
          brand.startsWith('msf1')) {
        return 'HEIC - not supported';
      }
      if (brand.startsWith('jxl')) return 'JPEG XL - not supported';
    }
    if (ascii(0, 4) == '%pdf') return _pdfLabel;
    final String head = ascii(0, 5);
    if (head.startsWith('<?xml') || head.startsWith('<svg')) {
      return 'SVG - not supported';
    }
    return null;
  }

  /// A short reason for a failed download, in the reader's terms.
  static String _thumbErrorLabel(Object error) {
    final String text = error.toString().toLowerCase();
    if (text.contains('encryption key')) return 'Locked - key missing';
    if (text.contains('not found') || text.contains('404')) return 'Not found';
    if (text.contains('authenticated')) return 'Signed out';
    if (error is TimeoutException || text.contains('timeoutexception')) {
      return 'Timed out';
    }
    if (text.contains('socket') ||
        text.contains('network') ||
        text.contains('timeout') ||
        text.contains('connection')) {
      return 'No connection';
    }
    if (text.contains('decrypt')) return 'Cannot decrypt';
    return 'Failed to load';
  }

  Future<void> _deleteImage(StoredImage image) async {
    // First check if this image is used in any chats
    final chatsUsingImage = await ImageStorageService.findChatsUsingImage(
      image.path,
    );

    if (!mounted) return;

    bool shouldDelete = false;

    final l = AppLocalizations.of(context)!;

    if (chatsUsingImage.isNotEmpty) {
      // Show warning dialog with chat names
      shouldDelete =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(l.imageUsedInChats),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.imageUsedInChatsBody,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 150),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: chatsUsingImage
                            .map(
                              (chat) => Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 4,
                                ),
                                child: Row(
                                  children: [
                                    const AppIcon(
                                      Icons.chat_bubble_outline,
                                      size: 16,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        chat.chatName,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l.deleteImageShowDeleted,
                    style: const TextStyle(
                      color: Colors.orange,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(l.deleteImageConfirm),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(l.cancel),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  child: Text(l.deleteAnyway),
                ),
              ],
            ),
          ) ??
          false;
    } else {
      // Simple confirmation dialog
      shouldDelete =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(l.deleteImageTitle),
              content: Text(l.deleteImageBody),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(l.cancel),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  child: Text(l.delete),
                ),
              ],
            ),
          ) ??
          false;
    }

    if (!shouldDelete || !mounted) return;

    try {
      await ImageStorageService.deleteEncryptedImage(image.path);
      _thumbs.remove(image.path)?.dispose();
      setState(() {
        _images.removeWhere((i) => i.path == image.path);
        _selectedImages.remove(image.path);
      });

      if (mounted) {
        AppNotifications.show(context, l.imageDeleted);
      }
    } catch (e) {
      if (mounted) {
        AppNotifications.show(context, l.failedToDeleteImage(e.toString()));
      }
    }
  }

  Future<void> _deleteSelectedImages() async {
    if (_selectedImages.isEmpty) return;

    // Check which selected images are used in chats
    final Map<String, List<ChatUsingImage>> usageMap = {};
    for (final path in _selectedImages) {
      final chats = await ImageStorageService.findChatsUsingImage(path);
      if (chats.isNotEmpty) {
        usageMap[path] = chats;
      }
    }

    if (!mounted) return;

    bool shouldDelete = false;

    final l = AppLocalizations.of(context)!;

    if (usageMap.isNotEmpty) {
      // Show warning about images used in chats
      shouldDelete =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(l.someImagesUsedInChats),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${usageMap.length} of ${_selectedImages.length} selected images are used in chats.',
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l.deletedImagesWarning,
                    style: const TextStyle(
                      color: Colors.orange,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(l.deleteAllCount(_selectedImages.length)),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(l.cancel),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  child: Text(l.deleteAll),
                ),
              ],
            ),
          ) ??
          false;
    } else {
      shouldDelete =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(l.deleteSelectedImages),
              content: Text(l.deleteSelectedCount(_selectedImages.length)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(l.cancel),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  child: Text(l.delete),
                ),
              ],
            ),
          ) ??
          false;
    }

    if (!shouldDelete || !mounted) return;

    int deletedCount = 0;
    int failedCount = 0;

    for (final path in _selectedImages.toList()) {
      try {
        await ImageStorageService.deleteEncryptedImage(path);
        _thumbs.remove(path)?.dispose();
        _images.removeWhere((i) => i.path == path);
        deletedCount++;
      } catch (e) {
        failedCount++;
      }
    }

    setState(() {
      _selectedImages.clear();
      _isSelectionMode = false;
    });

    if (mounted) {
      if (failedCount > 0) {
        AppNotifications.show(
          context,
          l.deletedImagesResult(deletedCount, failedCount),
        );
      } else {
        AppNotifications.show(context, l.deletedImagesSuccess(deletedCount));
      }
    }
  }

  void _toggleSelection(String path) {
    setState(() {
      if (_selectedImages.contains(path)) {
        _selectedImages.remove(path);
        if (_selectedImages.isEmpty) {
          _isSelectionMode = false;
        }
      } else {
        _selectedImages.add(path);
      }
    });
  }

  void _enterSelectionMode(String path) {
    setState(() {
      _isSelectionMode = true;
      _selectedImages.add(path);
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _isSelectionMode = false;
      _selectedImages.clear();
    });
  }

  Future<void> _downloadImage(StoredImage image) async {
    try {
      final bytes = await ImageStorageService.downloadAndDecryptImage(
        image.path,
      );
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final result = await FileSaveService.save(
        bytes: bytes,
        suggestedName: 'chuk_chat_image_$timestamp.png',
        dialogTitle: 'Save image',
        allowedExtensions: const ['png'],
      );
      if (!mounted) return;
      final l = AppLocalizations.of(context)!;
      switch (result.outcome) {
        case SaveOutcome.savedToFolder:
        case SaveOutcome.savedViaPicker:
          AppNotifications.show(context, l.savedToPath(result.path ?? ''));
        case SaveOutcome.savedViaShare:
        case SaveOutcome.cancelled:
          break;
        case SaveOutcome.failed:
          AppNotifications.show(context, l.unableToSaveImage);
      }
    } catch (e) {
      if (!mounted) return;
      AppNotifications.show(
        context,
        AppLocalizations.of(context)!.unableToSaveImage,
      );
    }
  }

  Future<void> _downloadSelectedImages() async {
    if (_selectedImages.isEmpty) return;

    int savedCount = 0;
    int failedCount = 0;
    int cancelledCount = 0;

    for (final path in _selectedImages.toList()) {
      try {
        final bytes = await ImageStorageService.downloadAndDecryptImage(path);
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final result = await FileSaveService.save(
          bytes: bytes,
          suggestedName: 'chuk_chat_image_${timestamp}_$savedCount.png',
          dialogTitle: 'Save image',
          allowedExtensions: const ['png'],
        );
        switch (result.outcome) {
          case SaveOutcome.savedToFolder:
          case SaveOutcome.savedViaPicker:
          case SaveOutcome.savedViaShare:
            savedCount++;
          case SaveOutcome.cancelled:
            cancelledCount++;
          case SaveOutcome.failed:
            failedCount++;
        }
      } catch (e) {
        failedCount++;
      }
    }

    if (!mounted) return;

    final parts = <String>['Saved $savedCount images'];
    if (failedCount > 0) parts.add('$failedCount failed');
    if (cancelledCount > 0) parts.add('$cancelledCount cancelled');
    AppNotifications.show(context, parts.join(', '));
  }

  String _formatFileSize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '';
    return '${date.day}/${date.month}/${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final iconFg = Theme.of(context).resolvedIconColor;
    final isMobile = MediaQuery.of(context).size.width < 800;

    // Embedded: the host (the desktop media modal) draws the title and the
    // close button, so the page adds only its own toolbar and the library.
    if (widget.embedded) {
      return Column(
        children: [
          _buildToolbar(l, iconFg),
          Expanded(child: _buildBody(isMobile, iconFg, l)),
        ],
      );
    }

    return Scaffold(
      // The page runs underneath the floating header.
      extendBodyBehindAppBar: true,
      appBar: FloatingAppBar(
        title: Text(
          _isSelectionMode
              ? '${_selectedImages.length} selected'
              : l.mediaManager,
        ),
        leading: _isSelectionMode
            ? FloatingHeaderButton(
                icon: Icons.close,
                tooltip: l.cancel,
                onPressed: _exitSelectionMode,
              )
            : FloatingHeaderButton(
                icon: Icons.arrow_back_rounded,
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: () => Navigator.pop(context),
              ),
        actions: [
          if (_isSelectionMode) ...[
            if (!kIsWeb)
              FloatingHeaderButton(
                icon: Icons.download,
                onPressed: _downloadSelectedImages,
                tooltip: l.downloadSelected,
              ),
            FloatingHeaderButton(
              icon: Icons.delete,
              color: Theme.of(context).colorScheme.error,
              onPressed: _deleteSelectedImages,
              tooltip: l.deleteSelected,
            ),
          ] else
            FloatingHeaderButton(
              icon: Icons.refresh,
              onPressed: _loadImages,
              tooltip: l.refresh,
            ),
        ],
      ),
      body: _buildBody(isMobile, iconFg, l),
    );
  }

  /// The one row of controls above the library: what is selected and what
  /// can be done with it, or — with nothing selected — the count and refresh.
  Widget _buildToolbar(AppLocalizations l, Color iconFg) {
    final ThemeData theme = Theme.of(context);
    final m3 = theme.m3;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 12, 4),
      child: SizedBox(
        height: kFloatingAppBarTarget,
        child: Row(
          children: [
            if (_isSelectionMode) ...[
              Text(
                '${_selectedImages.length} selected',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const Spacer(),
              if (!kIsWeb)
                FloatingHeaderButton(
                  icon: Icons.download_rounded,
                  onPressed: _downloadSelectedImages,
                  tooltip: l.downloadSelected,
                ),
              FloatingHeaderButton(
                icon: Icons.delete_outline_rounded,
                color: theme.colorScheme.error,
                onPressed: _deleteSelectedImages,
                tooltip: l.deleteSelected,
              ),
              FloatingHeaderButton(
                icon: Icons.close_rounded,
                onPressed: _exitSelectionMode,
                tooltip: l.cancel,
              ),
            ] else ...[
              Text(
                _filter == _MediaFilter.images
                    ? '${_images.length} image${_images.length == 1 ? '' : 's'}'
                    : '${_artifacts.length} page'
                          '${_artifacts.length == 1 ? '' : 's'}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: m3.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              FloatingHeaderButton(
                icon: Icons.refresh_rounded,
                onPressed: () {
                  _loadImages();
                  _loadArtifacts();
                },
                tooltip: l.refresh,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBody(bool isMobile, Color iconFg, AppLocalizations l) {
    if (_isLoading && _isLoadingArtifacts) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null && _filter == _MediaFilter.images) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AppIcon(Icons.error_outline, size: 64, color: Colors.red.shade300),
            const SizedBox(height: 16),
            Text(l.errorLoadingImages, style: TextStyle(color: iconFg)),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _loadImages,
              icon: const AppIcon(Icons.refresh),
              label: Text(l.retry),
            ),
          ],
        ),
      );
    }

    // The page runs behind the floating header, and so does the filter
    // track: both stay put and the library passes underneath them, the way
    // the chat list does. Only the scrollables carry the inset.
    final double headerTop = widget.embedded
        ? 0
        : floatingHeaderInset(context).top;
    const double filterBarHeight = kMediaFilterBarHeight;
    final double contentTop = headerTop + filterBarHeight + 8;

    return RefreshIndicator(
      onRefresh: () async {
        await Future.wait([_loadImages(), _loadArtifacts()]);
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: switch (_filter) {
              _MediaFilter.images =>
                _images.isEmpty
                    ? _buildImagesEmpty(iconFg, l)
                    : (isMobile
                          ? _buildMobileList(iconFg, contentTop)
                          : _buildDesktopGrid(iconFg, contentTop)),
              _MediaFilter.artifacts => _buildArtifactsView(iconFg, contentTop),
            },
          ),
          // One segmented track, the same control the model list uses for
          // All / Active / Inactive — two shapes for one job is one too many.
          Positioned(
            top: headerTop,
            left: 12,
            right: 12,
            child: _MediaFilterBar(
              value: _filter,
              imageCount: _images.length,
              artifactCount: _artifacts.length + _pdfs.length,
              onChanged: (next) => setState(() => _filter = next),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImagesEmpty(Color iconFg, AppLocalizations l) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AppIcon(
            Icons.image_not_supported,
            size: 64,
            color: iconFg.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          Text(
            l.noImagesStored,
            style: TextStyle(color: iconFg.withValues(alpha: 0.5)),
          ),
          const SizedBox(height: 8),
          Text(
            l.imagesAppearHere,
            style: TextStyle(
              color: iconFg.withValues(alpha: 0.3),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildArtifactsView(Color iconFg, double topPad) {
    final ArtifactDocument? previewing = _previewArtifact;
    if (previewing != null) {
      // The page itself, inside the library: the same preview, code view,
      // versions and exports as the side panel, without leaving this screen.
      return Padding(
        padding: EdgeInsets.only(top: topPad),
        child: ArtifactPanel(
          key: ValueKey<String>('media-preview-${previewing.id}'),
          artifact: previewing,
          showHeader: true,
          onClose: () => setState(() => _previewArtifact = null),
          onOpenSourceChat: (_) => _openArtifactBesideChat(previewing),
        ),
      );
    }
    if (_isLoadingArtifacts) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_artifacts.isEmpty && _pdfs.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AppIcon(
              Icons.description_outlined,
              size: 64,
              color: iconFg.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              'No pages yet',
              style: TextStyle(color: iconFg.withValues(alpha: 0.5)),
            ),
            const SizedBox(height: 8),
            Text(
              'Documents, HTML pages, drawings and PDFs the assistant '
              'makes show up here.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: iconFg.withValues(alpha: 0.3),
                fontSize: 12,
              ),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(16, topPad, 16, 16),
      itemCount: _artifacts.length + _pdfs.length,
      separatorBuilder: (_, i) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index >= _artifacts.length) {
          final StoredImage file = _pdfs[index - _artifacts.length];
          return _PdfFileTile(
            name: _pdfName(file),
            size: file.size,
            onTap: () => _openPdf(file),
          );
        }
        final artifact = _artifacts[index];
        return _ArtifactTile(
          artifact: artifact,
          onTap: () => _openArtifact(artifact),
        );
      },
    );
  }

  /// Desktop shows the page inside the library. The phone has no room for
  /// a second pane and keeps its full-screen sheet.
  void _openArtifact(ArtifactDocument artifact) {
    final bool isPhone = MediaQuery.sizeOf(context).width < 800;
    if (isPhone) {
      _showArtifactPreview(artifact);
      return;
    }
    setState(() => _previewArtifact = artifact);
  }

  /// Leaves the library and opens [artifact] next to the chat it came from.
  void _openArtifactBesideChat(ArtifactDocument artifact) {
    Navigator.of(context).maybePop();
    _showArtifactPreview(artifact);
  }

  void _showArtifactPreview(ArtifactDocument artifact) {
    // Reuse the chat UI's artifact flow: activate the artifact and fire an
    // open-request. Mobile's root wrapper opens the ArtifactBottomSheet,
    // desktop's shows ArtifactPanel in the side slot — same preview/code
    // toggle, versions, and exports as clicking an inline card in chat.
    ArtifactStorageService.activeArtifactNotifier.value = artifact;
    ArtifactStorageService.requestOpen(
      artifactId: artifact.id,
      version: artifact.version,
    );
  }

  Widget _buildDesktopGrid(Color iconFg, double topPad) {
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(20, topPad, 20, 20),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        childAspectRatio: 1,
      ),
      itemCount: _images.length,
      itemBuilder: (context, index) => _buildImageCard(_images[index], iconFg),
    );
  }

  Widget _buildMobileList(Color iconFg, double topPad) {
    return GridView.builder(
      // Edge to edge: the pictures are the page, so no margin is left at
      // the screen edges and the gaps between them are hairlines.
      padding: EdgeInsets.fromLTRB(0, topPad, 0, 20),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
        childAspectRatio: 1,
      ),
      itemCount: _images.length,
      itemBuilder: (context, index) =>
          _buildImageCard(_images[index], iconFg, compact: true),
    );
  }

  Widget _buildImageCard(
    StoredImage image,
    Color iconFg, {
    bool compact = false,
  }) {
    return _ImageTile(
      image: image,
      thumb: _thumb(image.path),
      selected: _selectedImages.contains(image.path),
      selectionMode: _isSelectionMode,
      compact: compact,
      dateLine: image.createdAt == null ? null : _formatDate(image.createdAt),
      sizeLine: image.size == null ? null : _formatFileSize(image.size),
      onTap: () {
        if (_isSelectionMode) {
          _toggleSelection(image.path);
        } else {
          _showImagePreview(image);
        }
      },
      onLongPress: () {
        if (!_isSelectionMode) _enterSelectionMode(image.path);
      },
      onRetry: () => _retryThumbnail(image.path),
      onDownload: kIsWeb ? null : () => _downloadImage(image),
      onDelete: () => _deleteImage(image),
      provenance: MediaProvenanceService.lookup(image.path),
      onInfo: () => _showImageInfo(image),
    );
  }

  Future<void> _showImageInfo(StoredImage image) {
    return showDialog<void>(
      context: context,
      builder: (context) => _ImageInfoDialog(
        image: image,
        thumb: _thumbs[image.path],
        provenance: MediaProvenanceService.lookup(image.path),
        formatDate: _formatDate,
        formatSize: _formatFileSize,
      ),
    );
  }

  void _showImagePreview(StoredImage image) {
    final initialIndex = _images.indexOf(image);
    if (initialIndex == -1) return;

    final allImagePaths = _images
        .map((img) => img.path)
        .toList(growable: false);

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ImageViewer(
          imageDataUrl: image.path,
          initialIndex: initialIndex,
          allImages: allImagePaths,
        ),
        fullscreenDialog: true,
      ),
    );
  }
}

/// What one thumbnail knows about itself.
/// Runs at most [maxInFlight] thumbnail downloads at a time, queueing the
/// rest in the order they were asked for.
class _ThumbGate {
  _ThumbGate({required this.maxInFlight});

  final int maxInFlight;
  int _running = 0;
  final List<Completer<void>> _waiting = <Completer<void>>[];

  Future<T> run<T>(Future<T> Function() task) async {
    if (_running >= maxInFlight) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _running++;
    try {
      return await task();
    } finally {
      _running--;
      if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
    }
  }
}

class _ThumbState {
  const _ThumbState.loading() : bytes = null, error = null;
  const _ThumbState.ready(Uint8List this.bytes) : error = null;
  const _ThumbState.failed(String this.error) : bytes = null;

  final Uint8List? bytes;

  /// A short reason, in the reader's terms, or null while it is fine.
  final String? error;

  bool get isLoading => bytes == null && error == null;
}

/// One image in the grid: the picture, what it costs to keep, and — on hover
/// — the two actions that apply to it.
///
/// The actions live under the pointer rather than permanently on top of the
/// picture: a grid of thumbnails each wearing two black buttons reads as a
/// toolbar, not as a photo library.
class _ImageTile extends StatefulWidget {
  const _ImageTile({
    required this.image,
    required this.thumb,
    required this.selected,
    required this.selectionMode,
    required this.compact,
    required this.onTap,
    required this.onLongPress,
    required this.onRetry,
    required this.onDelete,
    this.onDownload,
    this.dateLine,
    this.sizeLine,
    this.provenance,
    this.onInfo,
  });

  final StoredImage image;

  /// Where the picture came from; a generated one wears a small badge.
  final Future<ImageProvenance>? provenance;

  /// Opens the picture's details (prompt, model, dates).
  final VoidCallback? onInfo;
  final ValueNotifier<_ThumbState> thumb;
  final bool selected;
  final bool selectionMode;

  /// The phone grid: three across, no room for anything but the picture.
  final bool compact;

  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onRetry;
  final VoidCallback onDelete;

  /// Null on the web, which cannot save a file to disk.
  final VoidCallback? onDownload;

  final String? dateLine;
  final String? sizeLine;

  @override
  State<_ImageTile> createState() => _ImageTileState();
}

class _ImageTileState extends State<_ImageTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final m3 = theme.m3;
    final Color accent = theme.colorScheme.primary;
    // Edge-to-edge tiles: a big radius on a 2 px grid would show the page
    // through four corners of every picture.
    final double radius = widget.compact ? 6 : 18;
    final bool showChrome =
        !widget.compact && (_hovered || widget.selectionMode);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: m3.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: widget.selected ? accent : Colors.transparent,
              width: 2,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ValueListenableBuilder<_ThumbState>(
                valueListenable: widget.thumb,
                builder: (context, state, _) => _buildPicture(state),
              ),

              // A tile under the pointer lifts its picture out of the
              // background a touch, so the grid answers the mouse.
              if (_hovered && !widget.selectionMode)
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.12),
                    ),
                  ),
                ),

              if (widget.selectionMode)
                Positioned(
                  top: 8,
                  left: 8,
                  child: _Glass(
                    circle: true,
                    child: AppIcon(
                      widget.selected
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                      color: widget.selected ? accent : Colors.white,
                      size: 22,
                    ),
                  ),
                ),

              if (!widget.selectionMode && widget.provenance != null)
                Positioned(
                  top: 8,
                  left: 8,
                  child: FutureBuilder<ImageProvenance>(
                    future: widget.provenance,
                    builder: (context, snapshot) {
                      final ImageProvenance? info = snapshot.data;
                      if (info == null || !info.isGenerated) {
                        return const SizedBox.shrink();
                      }
                      return Tooltip(
                        message: info.model == null
                            ? 'Generated'
                            : 'Generated with ${info.model}',
                        child: const _Glass(child: _GeneratedBadge()),
                      );
                    },
                  ),
                ),

              if (showChrome && !widget.selectionMode)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.onInfo case final VoidCallback onInfo) ...[
                        _TileAction(
                          icon: Icons.info_outline_rounded,
                          tooltip: 'Info',
                          onTap: onInfo,
                        ),
                        const SizedBox(width: 6),
                      ],
                      if (widget.onDownload case final VoidCallback onDownload)
                        _TileAction(
                          icon: Icons.download_rounded,
                          tooltip: AppLocalizations.of(context)!.download,
                          onTap: onDownload,
                        ),
                      const SizedBox(width: 6),
                      _TileAction(
                        icon: Icons.delete_outline_rounded,
                        tooltip: AppLocalizations.of(context)!.delete,
                        tone: theme.colorScheme.error,
                        onTap: widget.onDelete,
                      ),
                    ],
                  ),
                ),

              // The two numbers only while the pointer is on the tile: a
              // permanent gradient band across every picture is the thing
              // that made the grid look busy.
              if (showChrome &&
                  (widget.dateLine != null || widget.sizeLine != null))
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(10, 14, 10, 8),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.66),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    child: Text(
                      [?widget.dateLine, ?widget.sizeLine].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPicture(_ThumbState state) {
    if (state.isLoading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    final Uint8List? bytes = state.bytes;
    if (bytes == null) {
      return _ThumbError(
        label: state.error ?? 'Failed to load',
        compact: widget.compact,
        onRetry: widget.onRetry,
      );
    }

    return Image.memory(
      bytes,
      fit: BoxFit.cover,
      // Decode to the cell, not to the file: a 4K generation decoded at full
      // size for a 200 px tile is what made a grid of them stutter.
      cacheWidth: widget.compact ? 280 : 420,
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, error, stackTrace) => _ThumbError(
        label: 'Broken file',
        compact: widget.compact,
        onRetry: widget.onRetry,
      ),
    );
  }
}

/// What a tile shows instead of a picture, with the reason and a way back.
class _ThumbError extends StatelessWidget {
  const _ThumbError({
    required this.label,
    required this.compact,
    required this.onRetry,
  });

  final String label;
  final bool compact;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color muted = theme.m3.onSurfaceVariant;
    // A compact tile has no room for a label and a button, so the tile
    // itself is the retry target.
    return GestureDetector(
      onTap: compact ? onRetry : null,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(
                Icons.image_not_supported_outlined,
                size: compact ? 18 : 22,
                color: muted,
              ),
              if (compact) ...[
                const SizedBox(height: 4),
                // Even a thumb-sized tile says why it is empty — a bare glyph
                // reads as lost data.
                Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 9, height: 1.2, color: muted),
                ),
              ],
              if (!compact) ...[
                const SizedBox(height: 6),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(color: muted),
                ),
                const SizedBox(height: 2),
                TextButton(
                  onPressed: onRetry,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: Text(AppLocalizations.of(context)!.retry),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A dark round pad behind a glyph drawn on top of a picture.
class _Glass extends StatelessWidget {
  const _Glass({required this.child, this.circle = false});

  final Widget child;
  final bool circle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        shape: circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circle ? null : BorderRadius.circular(12),
      ),
      child: child,
    );
  }
}

/// One hover action on a tile.
class _TileAction extends StatelessWidget {
  const _TileAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.tone,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  /// Null keeps the plain white glyph; a colour marks the destructive one.
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black.withValues(alpha: 0.5),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 30,
            height: 30,
            child: AppIcon(icon, size: 17, color: tone ?? Colors.white),
          ),
        ),
      ),
    );
  }
}

/// Images / Artifacts, as one segmented track with the count in the label.
class _MediaFilterBar extends StatelessWidget {
  const _MediaFilterBar({
    required this.value,
    required this.imageCount,
    required this.artifactCount,
    required this.onChanged,
  });

  final _MediaFilter value;
  final int imageCount;
  final int artifactCount;
  final ValueChanged<_MediaFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    // The library scrolls underneath this track, so it takes the same
    // near-opaque floating fill as the rest of the chrome. A translucent
    // track lets the pictures show through and reads as a rendering fault.
    return FloatingChromeSurface(
      radius: 999,
      padding: const EdgeInsets.all(4),
      child: SizedBox(
        height: kMediaFilterBarHeight - 8,
        child: Row(
          children: [
            Expanded(
              child: _segment(
                context,
                _MediaFilter.images,
                'Images',
                imageCount,
              ),
            ),
            Expanded(
              child: _segment(
                context,
                _MediaFilter.artifacts,
                // Artifacts are called Pages wherever the user reads it
                // (docs/PAGES.md). Code and storage keep the old name.
                'Pages',
                artifactCount,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _segment(
    BuildContext context,
    _MediaFilter filter,
    String label,
    int count,
  ) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    final bool selected = filter == value;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(filter),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(vertical: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? m3.selectedFill : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          count == 0 ? label : '$label  $count',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            color: selected ? m3.onSelectedFill : m3.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _ArtifactTile extends StatelessWidget {
  final ArtifactDocument artifact;
  final VoidCallback onTap;

  const _ArtifactTile({required this.artifact, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;
    return Material(
      color: m3.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: AppIcon(
                  _iconForType(artifact.type),
                  color: cs.onPrimaryContainer,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      artifact.title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          artifact.type.displayLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: m3.onSurfaceVariant,
                          ),
                        ),
                        Text(
                          ' · ',
                          style: TextStyle(color: m3.onSurfaceVariant),
                        ),
                        Text(
                          'v${artifact.version}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: m3.onSurfaceVariant,
                          ),
                        ),
                        Text(
                          ' · ',
                          style: TextStyle(color: m3.onSurfaceVariant),
                        ),
                        Expanded(
                          child: Text(
                            _relative(artifact.updatedAt),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: m3.onSurfaceVariant,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              AppIcon(Icons.chevron_right, color: m3.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  static String _relative(DateTime updatedAt) {
    final delta = DateTime.now().difference(updatedAt);
    if (delta.inMinutes < 1) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
    if (delta.inHours < 24) return '${delta.inHours}h ago';
    if (delta.inDays < 7) return '${delta.inDays}d ago';
    return '${updatedAt.day}/${updatedAt.month}/${updatedAt.year}';
  }

  static IconData _iconForType(ArtifactType type) => switch (type) {
    ArtifactType.svg => Icons.image_outlined,
    ArtifactType.html => Icons.html_outlined,
    ArtifactType.mermaid => Icons.account_tree_outlined,
    ArtifactType.technicalDrawing => Icons.architecture_outlined,
    ArtifactType.typst => Icons.picture_as_pdf_outlined,
    ArtifactType.excalidraw => Icons.draw_outlined,
    ArtifactType.code => Icons.code,
    ArtifactType.markdown => Icons.description_outlined,
  };
}

/// A PDF that sat in the image bucket, listed under Pages like a page.
class _PdfFileTile extends StatelessWidget {
  const _PdfFileTile({
    required this.name,
    required this.size,
    required this.onTap,
  });

  final String name;
  final int? size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;
    final int? bytes = size;
    final String detail = bytes == null
        ? 'PDF'
        : 'PDF · ${bytes < 1024 * 1024 ? '${(bytes / 1024).toStringAsFixed(0)} KB' : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'}';
    return Material(
      color: m3.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: AppIcon(
                  Icons.picture_as_pdf_outlined,
                  color: cs.onPrimaryContainer,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: m3.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              AppIcon(Icons.chevron_right, color: m3.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// The PDF itself, inside the media manager instead of the side panel.
class _PdfPreviewDialog extends StatelessWidget {
  const _PdfPreviewDialog({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.all(32),
      child: SizedBox(
        width: size.width * 0.8,
        height: size.height * 0.85,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      name,
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const AppIcon(Icons.close),
                    tooltip: MaterialLocalizations.of(context)
                        .closeButtonTooltip,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PdfViewer.data(
                bytes,
                sourceName: name,
                params: const PdfViewerParams(margin: 8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The small mark on a generated picture: a sparkle and "AI".
class _GeneratedBadge extends StatelessWidget {
  const _GeneratedBadge();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            height: 16,
            width: 16,
            child: Center(
              child: AppIcon(Icons.auto_awesome, color: Colors.white, size: 14),
            ),
          ),
          SizedBox(width: 4),
          Text(
            'AI',
            style: TextStyle(
              color: Colors.white,
              fontSize: 11,
              height: 16 / 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Everything known about one picture: where it came from (prompt, model,
/// seed for a generated one), its size and its dates.
class _ImageInfoDialog extends StatelessWidget {
  const _ImageInfoDialog({
    required this.image,
    required this.thumb,
    required this.provenance,
    required this.formatDate,
    required this.formatSize,
  });

  final StoredImage image;
  final ValueNotifier<_ThumbState>? thumb;
  final Future<ImageProvenance> provenance;
  final String Function(DateTime?) formatDate;
  final String Function(int?) formatSize;

  static String _dateTime(DateTime? value) {
    if (value == null) return '';
    final DateTime local = value.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  static String _originLabel(ImageOrigin origin) => switch (origin) {
    ImageOrigin.generated => 'Generated by AI',
    ImageOrigin.fetched => 'Loaded from the web',
    ImageOrigin.uploaded => 'Uploaded by you',
    ImageOrigin.unknown => 'Unknown',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Size screen = MediaQuery.sizeOf(context);
    return Dialog(
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.all(32),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 760,
          maxHeight: screen.height * 0.85,
        ),
        child: FutureBuilder<ImageProvenance>(
          future: provenance,
          builder: (context, snapshot) {
            final ImageProvenance? info = snapshot.data;
            final ValueListenable<_ThumbState>? thumbState = thumb;
            final Widget? picture = thumbState == null
                ? null
                : ValueListenableBuilder<_ThumbState>(
                    valueListenable: thumbState,
                    builder: (context, state, _) => switch (state.bytes) {
                      null => const SizedBox.shrink(),
                      final Uint8List bytes => ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Image.memory(
                          bytes,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                        ),
                      ),
                    },
                  );
            final rows = <Widget>[
              _InfoRow(
                label: 'Source',
                value: info == null
                    ? 'Looking it up...'
                    : _originLabel(info.origin),
              ),
              if (info?.prompt case final String prompt)
                _InfoRow(label: 'Prompt', value: prompt, copy: true),
              if (info?.model case final String model)
                _InfoRow(label: 'Model', value: model),
              if (info?.seed case final String seed)
                _InfoRow(label: 'Seed', value: seed, copy: true),
              if ((info?.width, info?.height) case (
                final int width,
                final int height,
              ))
                _InfoRow(label: 'Resolution', value: '$width × $height px'),
              if (info?.costEur case final double cost)
                _InfoRow(label: 'Cost', value: '€${cost.toStringAsFixed(2)}'),
              if (info?.sourceUrl case final String url)
                _InfoRow(label: 'From', value: url, copy: true),
              if (info?.chatTitle ?? info?.chatId case final String chat)
                _InfoRow(label: 'Chat', value: chat),
              if (info case ImageProvenance(
                createdAt: final DateTime createdAt,
                isGenerated: final bool generated,
              ))
                _InfoRow(
                  label: generated ? 'Generated' : 'Sent',
                  value: _dateTime(createdAt),
                ),
              if (image.createdAt != null)
                _InfoRow(label: 'Uploaded', value: _dateTime(image.createdAt)),
              if (image.updatedAt != null)
                _InfoRow(label: 'Changed', value: _dateTime(image.updatedAt)),
              if (image.size != null)
                _InfoRow(label: 'File size', value: formatSize(image.size)),
            ];
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 8, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Image info',
                          style: theme.textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        icon: const AppIcon(Icons.close),
                        tooltip: MaterialLocalizations.of(context)
                            .closeButtonTooltip,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (picture != null) ...[
                          SizedBox(width: 240, child: picture),
                          const SizedBox(width: 24),
                        ],
                        Expanded(
                          child: DefaultTextStyle.merge(
                            style: TextStyle(
                              color: theme.colorScheme.onSurface,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: rows,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// One label and its value in the image info, with an optional copy button.
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.copy = false});

  final String label;
  final String value;
  final bool copy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: m3.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
          ),
          if (copy)
            SizedBox(
              height: 21,
              child: IconButton(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                tooltip: 'Copy',
                icon: const AppIcon(Icons.copy_rounded, size: 16),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: value));
                  AppNotifications.show(context, 'Copied');
                },
              ),
            ),
        ],
      ),
    );
  }
}
