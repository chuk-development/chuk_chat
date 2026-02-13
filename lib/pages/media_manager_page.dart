// lib/pages/media_manager_page.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

class MediaManagerPage extends StatefulWidget {
  final bool embedded;

  const MediaManagerPage({super.key, this.embedded = false});

  @override
  State<MediaManagerPage> createState() => _MediaManagerPageState();
}

class _MediaManagerPageState extends State<MediaManagerPage> {
  List<StoredImage> _images = [];
  bool _isLoading = true;
  String? _error;
  final Set<String> _selectedImages = {};
  bool _isSelectionMode = false;

  // Cache for loaded image thumbnails
  final Map<String, Uint8List> _thumbnailCache = {};
  final Map<String, bool> _loadingImages = {};

  @override
  void initState() {
    super.initState();
    _loadImages();
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
        if (a.createdAt == null && b.createdAt == null) return 0;
        if (a.createdAt == null) return 1;
        if (b.createdAt == null) return -1;
        return b.createdAt!.compareTo(a.createdAt!);
      });

      if (mounted) {
        setState(() {
          _images = images;
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

  Future<Uint8List?> _loadThumbnail(String path) async {
    if (_thumbnailCache.containsKey(path)) {
      return _thumbnailCache[path];
    }

    if (_loadingImages[path] == true) {
      return null;
    }

    _loadingImages[path] = true;

    try {
      final bytes = await ImageStorageService.downloadAndDecryptImage(path);
      _thumbnailCache[path] = bytes;
      _loadingImages[path] = false;
      return bytes;
    } catch (e) {
      _loadingImages[path] = false;
      return null;
    }
  }

  Future<void> _deleteImage(StoredImage image) async {
    // First check if this image is used in any chats
    final chatsUsingImage = await ImageStorageService.findChatsUsingImage(
      image.path,
    );

    if (!mounted) return;

    bool shouldDelete = false;

    if (chatsUsingImage.isNotEmpty) {
      // Show warning dialog with chat names
      shouldDelete =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Image Used in Chats'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'This image is used in the following chats:',
                    style: TextStyle(fontWeight: FontWeight.w500),
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
                                    const Icon(
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
                  const Text(
                    'If you delete this image, it will show as "Image deleted" in those chats.',
                    style: TextStyle(
                      color: Colors.orange,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text('Are you sure you want to delete this image?'),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  child: const Text('Delete Anyway'),
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
              title: const Text('Delete Image'),
              content: const Text(
                'Are you sure you want to delete this image? This action cannot be undone.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  child: const Text('Delete'),
                ),
              ],
            ),
          ) ??
          false;
    }

    if (!shouldDelete || !mounted) return;

    try {
      await ImageStorageService.deleteEncryptedImage(image.path);
      _thumbnailCache.remove(image.path);
      setState(() {
        _images.removeWhere((i) => i.path == image.path);
        _selectedImages.remove(image.path);
      });

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Image deleted')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to delete image: $e')));
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

    if (usageMap.isNotEmpty) {
      // Show warning about images used in chats
      shouldDelete =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Some Images Are Used in Chats'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${usageMap.length} of ${_selectedImages.length} selected images are used in chats.',
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Deleted images will show as "Image deleted" in those chats.',
                    style: TextStyle(
                      color: Colors.orange,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text('Delete all ${_selectedImages.length} selected images?'),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  child: const Text('Delete All'),
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
              title: const Text('Delete Selected Images'),
              content: Text(
                'Delete ${_selectedImages.length} selected images? This action cannot be undone.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  child: const Text('Delete'),
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
        _thumbnailCache.remove(path);
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Deleted $deletedCount images, $failedCount failed'),
          ),
        );
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Deleted $deletedCount images')));
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
    final iconFg = Theme.of(context).resolvedIconColor;
    final isMobile = MediaQuery.of(context).size.width < 800;

    // In embedded mode, show simplified UI without Scaffold
    if (widget.embedded) {
      return Column(
        children: [
          // Toolbar for embedded mode
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                if (_isSelectionMode) ...[
                  Text(
                    '${_selectedImages.length} selected',
                    style: TextStyle(
                      color: iconFg,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: _deleteSelectedImages,
                    tooltip: 'Delete selected',
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: iconFg),
                    onPressed: _exitSelectionMode,
                    tooltip: 'Cancel',
                  ),
                ] else ...[
                  Text(
                    '${_images.length} image${_images.length == 1 ? '' : 's'}',
                    style: TextStyle(color: iconFg.withValues(alpha: 0.7)),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.refresh, color: iconFg),
                    onPressed: _loadImages,
                    tooltip: 'Refresh',
                  ),
                ],
              ],
            ),
          ),
          Expanded(child: _buildBody(isMobile, iconFg)),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isSelectionMode
              ? '${_selectedImages.length} selected'
              : 'Media Manager',
        ),
        leading: _isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _exitSelectionMode,
              )
            : IconButton(
                icon: Icon(Icons.arrow_back, color: iconFg),
                onPressed: () => Navigator.pop(context),
              ),
        actions: [
          if (_isSelectionMode)
            IconButton(
              icon: const Icon(Icons.delete, color: Colors.red),
              onPressed: _deleteSelectedImages,
              tooltip: 'Delete selected',
            )
          else
            IconButton(
              icon: Icon(Icons.refresh, color: iconFg),
              onPressed: _loadImages,
              tooltip: 'Refresh',
            ),
        ],
      ),
      body: _buildBody(isMobile, iconFg),
    );
  }

  Widget _buildBody(bool isMobile, Color iconFg) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: Colors.red.shade300),
            const SizedBox(height: 16),
            Text('Error loading images', style: TextStyle(color: iconFg)),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _loadImages,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_images.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.image_not_supported,
              size: 64,
              color: iconFg.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              'No images stored',
              style: TextStyle(color: iconFg.withValues(alpha: 0.5)),
            ),
            const SizedBox(height: 8),
            Text(
              'Images you send in chats will appear here',
              style: TextStyle(
                color: iconFg.withValues(alpha: 0.3),
                fontSize: 12,
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadImages,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Stats bar
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '${_images.length} image${_images.length == 1 ? '' : 's'}',
              style: TextStyle(
                color: iconFg.withValues(alpha: 0.7),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          // Grid/List
          Expanded(
            child: isMobile
                ? _buildMobileList(iconFg)
                : _buildDesktopGrid(iconFg),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopGrid(Color iconFg) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1,
      ),
      itemCount: _images.length,
      itemBuilder: (context, index) => _buildImageCard(_images[index], iconFg),
    );
  }

  Widget _buildMobileList(Color iconFg) {
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
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
    final isSelected = _selectedImages.contains(image.path);
    final accentColor = Theme.of(context).colorScheme.primary;

    return GestureDetector(
      onTap: () {
        if (_isSelectionMode) {
          _toggleSelection(image.path);
        } else {
          _showImagePreview(image);
        }
      },
      onLongPress: () {
        if (!_isSelectionMode) {
          _enterSelectionMode(image.path);
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Image thumbnail
          Card(
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: isSelected
                  ? BorderSide(color: accentColor, width: 3)
                  : BorderSide.none,
            ),
            child: FutureBuilder<Uint8List?>(
              future: _loadThumbnail(image.path),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting &&
                    !_thumbnailCache.containsKey(image.path)) {
                  return Container(
                    color: iconFg.withValues(alpha: 0.1),
                    child: const Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  );
                }

                final bytes = _thumbnailCache[image.path];
                if (bytes == null) {
                  return Container(
                    color: iconFg.withValues(alpha: 0.1),
                    child: Icon(
                      Icons.broken_image,
                      color: iconFg.withValues(alpha: 0.3),
                    ),
                  );
                }

                return Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  cacheWidth: 400, // 200px grid cell × 2 for retina
                  errorBuilder: (context, error, stackTrace) => Container(
                    color: iconFg.withValues(alpha: 0.1),
                    child: Icon(
                      Icons.broken_image,
                      color: iconFg.withValues(alpha: 0.3),
                    ),
                  ),
                );
              },
            ),
          ),

          // Selection checkbox
          if (_isSelectionMode)
            Positioned(
              top: 8,
              left: 8,
              child: Container(
                decoration: BoxDecoration(
                  color: isSelected ? accentColor : Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isSelected ? Icons.check_circle : Icons.circle_outlined,
                  color: Colors.white,
                  size: 24,
                ),
              ),
            ),

          // Delete button (non-selection mode, desktop only)
          if (!_isSelectionMode && !compact)
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                icon: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Icon(
                    Icons.delete,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
                onPressed: () => _deleteImage(image),
                tooltip: 'Delete',
              ),
            ),

          // Info overlay (desktop only)
          if (!compact)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.7),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (image.createdAt != null)
                      Text(
                        _formatDate(image.createdAt),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                    if (image.size != null)
                      Text(
                        _formatFileSize(image.size),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _showImagePreview(StoredImage image) {
    final initialIndex = _images.indexOf(image);
    if (initialIndex == -1) return;

    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black87,
        pageBuilder: (context, animation, secondaryAnimation) {
          return _FullScreenImageViewer(
            images: _images,
            initialIndex: initialIndex,
            thumbnailCache: _thumbnailCache,
            onDelete: (img) {
              Navigator.pop(context);
              _deleteImage(img);
            },
            onLoadImage: _loadThumbnail,
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    );
  }
}

class _FullScreenImageViewer extends StatefulWidget {
  final List<StoredImage> images;
  final int initialIndex;
  final Map<String, Uint8List> thumbnailCache;
  final void Function(StoredImage) onDelete;
  final Future<Uint8List?> Function(String) onLoadImage;

  const _FullScreenImageViewer({
    required this.images,
    required this.initialIndex,
    required this.thumbnailCache,
    required this.onDelete,
    required this.onLoadImage,
  });

  @override
  State<_FullScreenImageViewer> createState() => _FullScreenImageViewerState();
}

class _FullScreenImageViewerState extends State<_FullScreenImageViewer> {
  late PageController _pageController;
  late int _currentIndex;
  final Map<String, Uint8List> _loadedImages = {};
  final FocusNode _focusNode = FocusNode();
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
    _loadedImages.addAll(widget.thumbnailCache);

    // Preload adjacent images
    _preloadAdjacentImages(_currentIndex);
  }

  @override
  void didUpdateWidget(covariant _FullScreenImageViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.images.length != oldWidget.images.length) {
      if (widget.images.isEmpty && mounted) {
        Navigator.pop(context);
        return;
      }
      if (_currentIndex >= widget.images.length) {
        _currentIndex = widget.images.length - 1;
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pageController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
    } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      if (_currentIndex > 0) {
        _pageController.previousPage(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
    } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      if (_currentIndex < widget.images.length - 1) {
        _pageController.nextPage(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
    }
  }

  Future<void> _preloadAdjacentImages(int index) async {
    final indicesToLoad = [
      index - 1,
      index,
      index + 1,
    ].where((i) => i >= 0 && i < widget.images.length).toList();

    for (final i in indicesToLoad) {
      final path = widget.images[i].path;
      if (!_loadedImages.containsKey(path)) {
        final bytes = await widget.onLoadImage(path);
        if (bytes != null && !_disposed && mounted) {
          setState(() {
            _loadedImages[path] = bytes;
          });
        }
      }
    }
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
    });
    _preloadAdjacentImages(index);
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '';
    return '${date.day}/${date.month}/${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    if (_currentIndex >= widget.images.length) return const SizedBox.shrink();
    final currentImage = widget.images[_currentIndex];

    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            // PageView for swiping — outer GestureDetector dismisses on tap
            // outside image, inner GestureDetector absorbs taps on the image.
            PageView.builder(
              controller: _pageController,
              onPageChanged: _onPageChanged,
              itemCount: widget.images.length,
              itemBuilder: (context, index) {
                final image = widget.images[index];
                final bytes = _loadedImages[image.path];

                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.pop(context),
                  child: Center(
                    child: GestureDetector(
                      onTap: () {}, // Absorb taps on the image itself
                      child: bytes != null
                          ? InteractiveViewer(
                              minScale: 0.5,
                              maxScale: 4.0,
                              child: Image.memory(bytes, fit: BoxFit.contain),
                            )
                          : const CircularProgressIndicator(
                              color: Colors.white,
                            ),
                    ),
                  ),
                );
              },
            ),

            // Top bar with close button and counter
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 16,
              right: 16,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Close button
                  _buildIconButton(
                    icon: Icons.close,
                    onTap: () => Navigator.pop(context),
                  ),
                  // Image counter
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      '${_currentIndex + 1} / ${widget.images.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  // Placeholder for symmetry
                  const SizedBox(width: 40),
                ],
              ),
            ),

            // Bottom bar with info and delete
            Positioned(
              bottom: MediaQuery.of(context).padding.bottom + 16,
              left: 16,
              right: 16,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Image info
                  if (currentImage.createdAt != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        _formatDate(currentImage.createdAt),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  // Delete button
                  ElevatedButton.icon(
                    onPressed: () => widget.onDelete(currentImage),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Left arrow (if not first)
            if (_currentIndex > 0)
              Positioned(
                left: 8,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _buildIconButton(
                    icon: Icons.chevron_left,
                    onTap: () {
                      _pageController.previousPage(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      );
                    },
                  ),
                ),
              ),

            // Right arrow (if not last)
            if (_currentIndex < widget.images.length - 1)
              Positioned(
                right: 8,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _buildIconButton(
                    icon: Icons.chevron_right,
                    onTap: () {
                      _pageController.nextPage(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildIconButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: const BoxDecoration(
          color: Colors.black54,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 24),
      ),
    );
  }
}
