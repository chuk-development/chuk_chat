// lib/widgets/image_viewer.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:chuk_chat/services/file_save_service.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/utils/image_clipboard_service.dart';
import 'package:chuk_chat/widgets/nice_snackbar.dart';

/// Full-screen image viewer with zoom and pan capabilities
class ImageViewer extends StatefulWidget {
  const ImageViewer({
    super.key,
    required this.imageDataUrl,
    this.initialIndex = 0,
    this.allImages,
    this.models,
  });

  final String imageDataUrl;
  final int initialIndex;
  final List<String>? allImages;

  /// Per-image generator model labels (aligned with [allImages]). Entries may
  /// be null for user-uploaded or web-fetched images. Shown top-right next to
  /// the copy/download actions for the current image.
  final List<String?>? models;

  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer> {
  late PageController _pageController;
  late int _currentIndex;
  final TransformationController _transformationController =
      TransformationController();
  final FocusNode _focusNode = FocusNode();
  final Map<int, GlobalKey> _imageKeys = <int, GlobalKey>{};

  /// Cache for loaded image bytes (storage path -> bytes).
  /// Bounded LRU-ish FIFO to keep RAM in check across long galleries.
  final Map<String, Uint8List> _imageCache = <String, Uint8List>{};
  static const int _kMaxCachedImages = 8;

  /// Stable per-source futures so FutureBuilder doesn't re-trigger on rebuild.
  final Map<String, Future<Uint8List>> _loadFutures =
      <String, Future<Uint8List>>{};

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _transformationController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
    } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      if (_hasMultipleImages && _currentIndex > 0) {
        _pageController.previousPage(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
    } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      if (_hasMultipleImages && _currentIndex < widget.allImages!.length - 1) {
        _pageController.nextPage(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
    }
  }

  /// Returns a stable Future for the given source. Re-using the same Future
  /// across rebuilds keeps FutureBuilder from flashing the loading spinner
  /// each time the surrounding widget tree rebuilds (e.g., PageView swipe).
  Future<Uint8List> _futureFor(String imageSource) {
    return _loadFutures.putIfAbsent(
      imageSource,
      () => _loadImageBytes(imageSource),
    );
  }

  /// Load image bytes from Base64 data URL or storage path.
  Future<Uint8List> _loadImageBytes(String imageSource) async {
    final cached = _imageCache[imageSource];
    if (cached != null) return cached;

    Uint8List bytes;
    if (imageSource.startsWith('data:image/')) {
      final commaIndex = imageSource.indexOf(',');
      if (commaIndex < 0) {
        throw const FormatException('Invalid Base64 data URI');
      }
      bytes = base64Decode(imageSource.substring(commaIndex + 1));
    } else if (imageSource.startsWith('http://') ||
        imageSource.startsWith('https://')) {
      const maxImageBytes = 20 * 1024 * 1024;
      final resp = await http
          .get(Uri.parse(imageSource))
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode} fetching image');
      }
      if (resp.bodyBytes.length > maxImageBytes) {
        throw Exception(
          'Image exceeds maximum size of $maxImageBytes bytes',
        );
      }
      bytes = resp.bodyBytes;
    } else {
      bytes = await ImageStorageService.downloadAndDecryptImage(imageSource);
    }

    _imageCache[imageSource] = bytes;
    while (_imageCache.length > _kMaxCachedImages) {
      final firstKey = _imageCache.keys.first;
      _imageCache.remove(firstKey);
      _loadFutures.remove(firstKey);
    }
    return bytes;
  }

  bool get _hasMultipleImages =>
      widget.allImages != null && widget.allImages!.length > 1;

  /// Generator model label for the currently-shown image, or null when none.
  String? get _currentModel {
    final models = widget.models;
    if (models == null || _currentIndex < 0 || _currentIndex >= models.length) {
      return null;
    }
    final model = models[_currentIndex]?.trim();
    if (model == null || model.isEmpty) return null;
    return model;
  }

  GlobalKey _imageKeyForIndex(int index) {
    return _imageKeys.putIfAbsent(
      index,
      () => GlobalKey(debugLabel: 'viewer_image_$index'),
    );
  }

  void _handleOutsideImageTap(PointerDownEvent event) {
    if (_hasMultipleImages) {
      return;
    }

    // Tap-to-close only at default zoom.
    final scale = _transformationController.value.getMaxScaleOnAxis();
    if ((scale - 1.0).abs() > 0.01) {
      return;
    }

    final imageContext = _imageKeyForIndex(_currentIndex).currentContext;
    if (imageContext == null) {
      return;
    }

    final renderObject = imageContext.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return;
    }

    final imageRect =
        renderObject.localToGlobal(Offset.zero) & renderObject.size;
    if (!imageRect.contains(event.position)) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final iconColor = Theme.of(context).colorScheme.onSurface;

    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black.withValues(alpha: 0.7),
          leading: IconButton(
            icon: Icon(Icons.close, color: iconColor),
            onPressed: () => Navigator.of(context).pop(),
            tooltip: 'Close',
          ),
          actions: [
            if (_currentModel != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(100),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.auto_awesome,
                            size: 12, color: iconColor.withValues(alpha: 0.9)),
                        const SizedBox(width: 4),
                        Text(
                          _currentModel!,
                          style: TextStyle(
                            color: iconColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            IconButton(
              icon: Icon(Icons.file_copy_outlined,
                  color: iconColor, size: 20),
              onPressed: _copyCurrentImage,
              tooltip: 'Copy image',
            ),
            if (!kIsWeb)
              IconButton(
                icon: Icon(Icons.file_download_outlined,
                    color: iconColor, size: 22),
                onPressed: _downloadCurrentImage,
                tooltip: 'Download image',
              ),
          ],
          title: _hasMultipleImages
              ? Text(
                  'Image ${_currentIndex + 1} of ${widget.allImages!.length}',
                  style: TextStyle(color: iconColor),
                )
              : Text('Image', style: TextStyle(color: iconColor)),
        ),
        body: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _handleOutsideImageTap,
          child: Stack(
            children: [
              // Main image viewer
              _hasMultipleImages
                  ? PageView.builder(
                      controller: _pageController,
                      itemCount: widget.allImages!.length,
                      onPageChanged: (index) {
                        setState(() {
                          _currentIndex = index;
                          _resetZoom();
                        });
                      },
                      itemBuilder: (context, index) {
                        return _buildImageView(widget.allImages![index], index);
                      },
                    )
                  : _buildImageView(widget.imageDataUrl, 0),

              // Navigation arrows for multiple images
              if (_hasMultipleImages) ...[
                if (_currentIndex > 0)
                  Positioned(
                    left: 16,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: IconButton(
                        icon: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.5),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.chevron_left,
                            color: Colors.white,
                            size: 32,
                          ),
                        ),
                        onPressed: () {
                          _pageController.previousPage(
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeInOut,
                          );
                        },
                      ),
                    ),
                  ),
                if (_currentIndex < widget.allImages!.length - 1)
                  Positioned(
                    right: 16,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: IconButton(
                        icon: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.5),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.chevron_right,
                            color: Colors.white,
                            size: 32,
                          ),
                        ),
                        onPressed: () {
                          _pageController.nextPage(
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeInOut,
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImageView(String imageSource, int imageIndex) {
    return FutureBuilder<Uint8List>(
      future: _futureFor(imageSource),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: Colors.white),
          );
        }

        if (snapshot.hasError || !snapshot.hasData) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.broken_image, size: 64, color: Colors.grey),
                const SizedBox(height: 16),
                Text(
                  'Failed to load image',
                  style: TextStyle(color: Colors.grey[400]),
                ),
              ],
            ),
          );
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            return InteractiveViewer(
              transformationController: _transformationController,
              minScale: 0.5,
              maxScale: 4.0,
              // No boundaryMargin at default zoom - prevents panning into
              // black space when the image already fits on screen.
              // Users can still zoom in and then pan freely.
              boundaryMargin: EdgeInsets.zero,
              child: Center(
                child: Image.memory(
                  key: _imageKeyForIndex(imageIndex),
                  snapshot.data!,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.broken_image,
                            size: 64,
                            color: Colors.grey,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Failed to load image',
                            style: TextStyle(color: Colors.grey[400]),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _downloadCurrentImage() async {
    try {
      final source = _hasMultipleImages
          ? widget.allImages![_currentIndex]
          : widget.imageDataUrl;
      final bytes = await _loadImageBytes(source);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final result = await FileSaveService.save(
        bytes: bytes,
        suggestedName: 'chuk_chat_image_$timestamp.png',
        dialogTitle: 'Save image',
        allowedExtensions: const ['png'],
      );
      if (!mounted) return;
      _showSaveSnackBar(result);
    } catch (e) {
      if (!mounted) return;
      NiceSnackBar.showError(context, 'Unable to save image');
    }
  }

  Future<void> _copyCurrentImage() async {
    try {
      final source = _hasMultipleImages
          ? widget.allImages![_currentIndex]
          : widget.imageDataUrl;
      final bytes = await _loadImageBytes(source);
      final copied = await ImageClipboardService.copyImageBytes(bytes);
      if (!mounted) return;
      if (copied) {
        NiceSnackBar.show(context, 'Image copied');
      } else {
        NiceSnackBar.showError(context, 'Unable to copy image');
      }
    } catch (_) {
      if (!mounted) return;
      NiceSnackBar.showError(context, 'Unable to copy image');
    }
  }

  void _showSaveSnackBar(SaveResult result) {
    switch (result.outcome) {
      case SaveOutcome.savedToFolder:
      case SaveOutcome.savedViaPicker:
        NiceSnackBar.show(context, 'Saved to ${result.path}');
      case SaveOutcome.savedViaShare:
        NiceSnackBar.show(context, 'Image shared');
      case SaveOutcome.cancelled:
        break;
      case SaveOutcome.failed:
        NiceSnackBar.showError(context, 'Unable to save image');
    }
  }

  void _resetZoom() {
    _transformationController.value = Matrix4.identity();
  }
}
