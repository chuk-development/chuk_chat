// lib/widgets/image_viewer.dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    super.dispose();
  }

  Uint8List _base64ToBytes(String dataUrl) {
    final base64String = dataUrl.split(',').last;
    return base64Decode(base64String);
  }

  bool get _hasMultipleImages =>
      widget.allImages != null && widget.allImages!.length > 1;

  @override
  Widget build(BuildContext context) {
    final iconColor = Theme.of(context).colorScheme.onSurface;

    return Scaffold(
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
            : Text(
                'Image',
                style: TextStyle(color: iconColor),
              ),
        actions: [
          IconButton(
            icon: Icon(Icons.zoom_in, color: iconColor),
            onPressed: _zoomIn,
            tooltip: 'Zoom in',
          ),
          IconButton(
            icon: Icon(Icons.zoom_out, color: iconColor),
            onPressed: _zoomOut,
            tooltip: 'Zoom out',
          ),
          IconButton(
            icon: Icon(Icons.refresh, color: iconColor),
            onPressed: _resetZoom,
            tooltip: 'Reset zoom',
          ),
        ],
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
                      child: Icon(Icons.chevron_left,
                          color: Colors.white, size: 32),
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
                      child: Icon(Icons.chevron_right,
                          color: Colors.white, size: 32),
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
    );
  }

  Widget _buildImageView(String imageDataUrl) {
    return Center(
      child: InteractiveViewer(
        transformationController: _transformationController,
        minScale: 0.5,
        maxScale: 4.0,
        child: Image.memory(
          _base64ToBytes(imageDataUrl),
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) {
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
          },
        ),
      ),
    );
  }

  void _zoomIn() {
    final currentScale = _transformationController.value.getMaxScaleOnAxis();
    final newScale = (currentScale * 1.5).clamp(0.5, 4.0);
    _transformationController.value = Matrix4.identity()..scale(newScale);
  }

  void _zoomOut() {
    final currentScale = _transformationController.value.getMaxScaleOnAxis();
    final newScale = (currentScale / 1.5).clamp(0.5, 4.0);
    _transformationController.value = Matrix4.identity()..scale(newScale);
  }

  void _resetZoom() {
    _transformationController.value = Matrix4.identity();
  }
}
