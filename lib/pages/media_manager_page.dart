// lib/pages/media_manager_page.dart

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:chuk_chat/services/file_save_service.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/image_viewer.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';

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
      _thumbnailCache.remove(image.path);
      setState(() {
        _images.removeWhere((i) => i.path == image.path);
        _selectedImages.remove(image.path);
      });

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.imageDeleted)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.failedToDeleteImage(e.toString()))));
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
            content: Text(l.deletedImagesResult(deletedCount, failedCount)),
          ),
        );
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.deletedImagesSuccess(deletedCount))));
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
      final bytes = await _loadThumbnail(image.path);
      if (bytes == null) throw Exception('Failed to load image');
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l.savedToPath(result.path ?? ''))),
          );
        case SaveOutcome.savedViaShare:
        case SaveOutcome.cancelled:
          break;
        case SaveOutcome.failed:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l.unableToSaveImage)),
          );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context)!.unableToSaveImage)),
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
        final bytes = await _loadThumbnail(path);
        if (bytes == null) {
          failedCount++;
          continue;
        }
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final result = await FileSaveService.save(
          bytes: bytes,
          suggestedName:
              'chuk_chat_image_${timestamp}_$savedCount.png',
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(parts.join(', '))),
    );
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
                  if (!kIsWeb)
                    IconButton(
                      icon: Icon(Icons.download, color: iconFg),
                      onPressed: _downloadSelectedImages,
                      tooltip: l.downloadSelected,
                    ),
                  IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: _deleteSelectedImages,
                    tooltip: l.deleteSelected,
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: iconFg),
                    onPressed: _exitSelectionMode,
                    tooltip: l.cancel,
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
                    tooltip: l.refresh,
                  ),
                ],
              ],
            ),
          ),
          Expanded(child: _buildBody(isMobile, iconFg, l)),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isSelectionMode
              ? '${_selectedImages.length} selected'
              : l.mediaManager,
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
          if (_isSelectionMode) ...[
            if (!kIsWeb)
              IconButton(
                icon: Icon(Icons.download, color: iconFg),
                onPressed: _downloadSelectedImages,
                tooltip: l.downloadSelected,
              ),
            IconButton(
              icon: const Icon(Icons.delete, color: Colors.red),
              onPressed: _deleteSelectedImages,
              tooltip: l.deleteSelected,
            ),
          ] else
            IconButton(
              icon: Icon(Icons.refresh, color: iconFg),
              onPressed: _loadImages,
              tooltip: l.refresh,
            ),
        ],
      ),
      body: _buildBody(isMobile, iconFg, l),
    );
  }

  Widget _buildBody(bool isMobile, Color iconFg, AppLocalizations l) {
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
            Text(l.errorLoadingImages, style: TextStyle(color: iconFg)),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _loadImages,
              icon: const Icon(Icons.refresh),
              label: Text(l.retry),
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

          // Action buttons (non-selection mode, desktop only)
          if (!_isSelectionMode && !compact)
            Positioned(
              top: 4,
              right: 4,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!kIsWeb)
                    IconButton(
                      icon: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Icon(
                          Icons.download,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                      onPressed: () => _downloadImage(image),
                      tooltip: AppLocalizations.of(context)!.download,
                    ),
                  IconButton(
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
                    tooltip: AppLocalizations.of(context)!.delete,
                  ),
                ],
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
