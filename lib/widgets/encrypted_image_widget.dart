// lib/widgets/encrypted_image_widget.dart
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:chuk_chat/services/image_storage_service.dart';

/// Widget that downloads, decrypts, and displays an encrypted image from storage
class EncryptedImageWidget extends StatefulWidget {
  const EncryptedImageWidget({
    super.key,
    required this.storagePath,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
  });

  final String storagePath;
  final BoxFit fit;
  final double? width;
  final double? height;

  @override
  State<EncryptedImageWidget> createState() => _EncryptedImageWidgetState();
}

class _EncryptedImageWidgetState extends State<EncryptedImageWidget> {
  Uint8List? _imageBytes;
  bool _isLoading = true;
  String? _error;
  bool _isDeleted = false;
  StreamSubscription<String>? _deletionSubscription;

  @override
  void initState() {
    super.initState();
    _loadImage();
    _listenForDeletion();
  }

  @override
  void dispose() {
    _deletionSubscription?.cancel();
    super.dispose();
  }

  void _listenForDeletion() {
    _deletionSubscription = ImageStorageService.onImageDeleted.listen((deletedPath) {
      if (deletedPath == widget.storagePath && mounted) {
        setState(() {
          _imageBytes = null;
          _isDeleted = true;
          _isLoading = false;
          _error = null;
        });
      }
    });
  }

  @override
  void didUpdateWidget(EncryptedImageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storagePath != widget.storagePath) {
      _loadImage();
    }
  }

  Future<void> _loadImage() async {
    // Skip loading if already marked as deleted
    if (_isDeleted) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final bytes = await ImageStorageService.downloadAndDecryptImage(
        widget.storagePath,
      );
      if (mounted) {
        setState(() {
          _imageBytes = bytes;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        final errorStr = e.toString().toLowerCase();
        // Check if the error indicates the image was deleted/not found
        final isNotFound = errorStr.contains('not found') ||
            errorStr.contains('404') ||
            errorStr.contains('does not exist') ||
            errorStr.contains('object not found');

        setState(() {
          _isDeleted = isNotFound;
          _error = isNotFound ? null : 'Failed to load image: $e';
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: Center(
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(
              Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      );
    }

    // Show "Image deleted" placeholder when image was not found
    if (_isDeleted) {
      return Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.image_not_supported_outlined,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                size: 32,
              ),
              const SizedBox(height: 8),
              Text(
                'Image deleted',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                color: Theme.of(context).colorScheme.error,
                size: 32,
              ),
              const SizedBox(height: 8),
              Text(
                'Failed to load',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_imageBytes == null) {
      return SizedBox(width: widget.width, height: widget.height);
    }

    return Image.memory(
      _imageBytes!,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
    );
  }
}
