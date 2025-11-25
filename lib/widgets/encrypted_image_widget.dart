// lib/widgets/encrypted_image_widget.dart
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

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void didUpdateWidget(EncryptedImageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storagePath != widget.storagePath) {
      _loadImage();
    }
  }

  Future<void> _loadImage() async {
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
        setState(() {
          _error = 'Failed to load image: $e';
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
