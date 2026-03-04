// lib/widgets/image_viewer.dart
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/services/image_storage_service.dart';

/// Full-screen image viewer with zoom and pan capabilities
class ImageViewer extends StatefulWidget {
  const ImageViewer({
    super.key,
    required this.imageDataUrl,
    this.initialIndex = 0,
    this.allImages,
  });

  final String imageDataUrl;
  final int initialIndex;
  final List<String>? allImages;

  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer> {
  late PageController _pageController;
  late int _currentIndex;
  final TransformationController _transformationController =
      TransformationController();
  final FocusNode _focusNode = FocusNode();

  /// Cache for loaded image bytes (storage path -> bytes)
  final Map<String, Uint8List> _imageCache = {};

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

  /// Load image bytes from Base64 data URL or storage path.
  Future<Uint8List> _loadImageBytes(String imageSource) async {
    // Check cache first
    if (_imageCache.containsKey(imageSource)) {
      return _imageCache[imageSource]!;
    }

    Uint8List bytes;
    if (imageSource.startsWith('data:image/')) {
      // Base64 data URI — decode inline (tool-generated images like QR codes)
      final commaIndex = imageSource.indexOf(',');
      if (commaIndex < 0) {
        throw Exception('Invalid Base64 data URI');
      }
      bytes = base64Decode(imageSource.substring(commaIndex + 1));
    } else {
      // Storage path - download and decrypt
      bytes = await ImageStorageService.downloadAndDecryptImage(imageSource);
    }

    // Cache the result
    _imageCache[imageSource] = bytes;
    return bytes;
  }

  bool get _hasMultipleImages =>
      widget.allImages != null && widget.allImages!.length > 1;

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
          title: _hasMultipleImages
              ? Text(
                  'Image ${_currentIndex + 1} of ${widget.allImages!.length}',
                  style: TextStyle(color: iconColor),
                )
              : Text('Image', style: TextStyle(color: iconColor)),
        ),
        body: Stack(
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
                      return _buildImageView(widget.allImages![index]);
                    },
                  )
                : _buildImageView(widget.imageDataUrl),

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
                        child: Icon(
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
                        child: Icon(
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
    );
  }

  Widget _buildImageView(String imageSource) {
    return FutureBuilder<Uint8List>(
      future: _loadImageBytes(imageSource),
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

  void _resetZoom() {
    _transformationController.value = Matrix4.identity();
  }
}
