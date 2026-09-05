// lib/widgets/message_bubble/images.dart
//
// Part of message_bubble.dart — the image side of a message: the responsive
// image grid, the "generating…" loader grid for in-flight generate_image
// calls, the fullscreen preview + right-click delete flow, and the document
// attachment chips.

// ignore_for_file: invalid_use_of_protected_member

part of '../message_bubble.dart';

extension _MessageBubbleImages on _MessageBubbleState {
  /// Human-readable generator model for the image at [index], or null when
  /// unknown (legacy images, user uploads, web-fetched images).
  String? _modelFor(int index) {
    final metas = widget.imageMetas;
    if (metas == null || index < 0 || index >= metas.length) return null;
    final model = metas[index].model?.trim();
    if (model == null || model.isEmpty) return null;
    return model;
  }

  /// A round can fan out N `generate_image` tool calls that produce N images.
  /// While ANY of them is still running we render a single unified grid —
  /// already-arrived images in their real tiles, still-running ones as loader
  /// tiles — laid out exactly like the final [_buildImagesGrid] so nothing
  /// reflows when a loader is swapped for the finished image.
  ///
  /// We deliberately do NOT gate on [MessageBubble.isStreamingMessage]: a
  /// `generate_image` call with status running/pending and no IMAGE result is
  /// in flight by definition, and the desktop streaming flag flips false during
  /// the tool-execution phase (so gating on it hid the loaders entirely). A
  /// finalized message has its stale tool calls flipped to error by
  /// [finalizeStaleToolCalls], so they won't match here.
  ///
  /// [includeArrived] folds already-finished images into this grid (content-
  /// blocks layout, where it replaces the normal grid). The classic layout
  /// renders arrived images separately, so it passes false (loaders only).
  ///
  /// Returns null when no image generation is in flight for [roundToolCalls].
  Widget? _buildGeneratingImagesGrid(
    List<ToolCall> roundToolCalls, {
    required bool includeArrived,
  }) {
    int runningCount = 0;
    int completedWithImage = 0;
    ToolCall? firstPending;
    for (final tc in roundToolCalls) {
      if (tc.name != 'generate_image') continue;
      final String? r = tc.result;
      final bool hasImage =
          r != null && (r.startsWith('IMAGE:') || r.startsWith('IMAGE_DATA:'));
      if (hasImage) {
        completedWithImage++;
        continue;
      }
      final bool running =
          tc.status == ToolCallStatus.running ||
          tc.status == ToolCallStatus.pending;
      if (running) {
        runningCount++;
        firstPending ??= tc;
      }
    }

    final List<String> arrived = includeArrived
        ? (widget.images ?? const <String>[])
        : const <String>[];
    final int arrivedCount = arrived.length;

    // Keep a loader for every generate_image that is still running AND for
    // every completed-with-result image whose bytes haven't been folded into
    // [widget.images] yet — the fetch/encrypt/upload step after the tool
    // result lands. This keeps the tile count stable (no reflow) and stops a
    // finished-but-not-yet-displayed image from briefly vanishing.
    final int unfetched = includeArrived
        ? (completedWithImage - arrivedCount).clamp(0, completedWithImage)
        : 0;
    final int loaderCount = runningCount + unfetched;
    if (loaderCount == 0) return null;
    final int total = arrivedCount + loaderCount;

    return LayoutBuilder(
      builder: (context, constraints) {
        final double maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.of(context).size.width * 0.8;

        // Single loader: follow the requested aspect ratio, like a lone AI
        // image renders at its natural ratio.
        if (total == 1) {
          final size = firstPending != null
              ? _pendingImageSize(firstPending.arguments)
              : MapEntry<double, String>(1024 / 768, '');
          final double height = (maxWidth / size.key).clamp(
            80.0,
            maxWidth * 1.9,
          );
          return _loaderTile(
            width: maxWidth,
            height: height,
            borderRadius: 12,
            label: size.value,
          );
        }

        // Multi: mirror _buildImagesGrid's Wrap layout exactly so arrived
        // images and loaders share one consistent grid.
        final int columns = total == 3 ? 3 : (maxWidth > 520 ? 3 : 2);
        final double tileWidth = ((maxWidth - ((columns - 1) * 8)) / columns)
            .clamp(90.0, 260.0);

        final List<Widget> cells = <Widget>[];
        for (int i = 0; i < arrived.length; i++) {
          final String src = arrived[i];
          cells.add(
            _captionedTile(
              imageSource: src,
              width: tileWidth,
              height: tileWidth,
              borderRadius: 10,
              model: _modelFor(i),
              onTap: () => _openImagePreview(
                imageSource: src,
                images: arrived,
                index: i,
              ),
            ),
          );
        }
        for (int i = 0; i < loaderCount; i++) {
          cells.add(
            _loaderTile(
              width: tileWidth,
              height: tileWidth,
              borderRadius: 10,
            ),
          );
        }

        return Wrap(spacing: 8, runSpacing: 8, children: cells);
      },
    );
  }

  /// A grey rounded loader tile for an image that is being *generated*. The
  /// sparkle icon + "Generating…" caption deliberately distinguish it from the
  /// plain spinner [_CachedImageThumbnail] shows while merely *fetching* an
  /// already-generated image from storage — so it's clear the AI is still
  /// creating the picture, not just downloading it.
  ///
  /// The caption text is shown only on tiles wide enough to fit it; [label]
  /// (a resolution / aspect hint) is appended on larger single tiles.
  Widget _loaderTile({
    required double width,
    required double height,
    required double borderRadius,
    String? label,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final Color fg = colorScheme.onSurface.withValues(alpha: 0.6);
    final bool roomForText = width >= 150 && height >= 110;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome, size: 18, color: fg),
            const SizedBox(height: 8),
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            if (roomForText) ...[
              const SizedBox(height: 10),
              Text(
                AppLocalizations.of(context)?.generatingImage ?? 'Generating…',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
              if (label != null && label.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    color: colorScheme.onSurface.withValues(alpha: 0.45),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  /// Best-effort target size for a pending `generate_image` call: returns
  /// (aspectRatio = width / height, human label). Models express size via
  /// `resolution` ("1024x768"), `aspect_ratio` ("16:9"), or an `image_size`
  /// preset; the server falls back to landscape_4_3 when none is given.
  MapEntry<double, String> _pendingImageSize(Map<String, dynamic> args) {
    final resolution = args['resolution'];
    if (resolution is String) {
      final m = RegExp(r'(\d+)\s*[x×]\s*(\d+)').firstMatch(resolution);
      if (m != null) {
        // tryParse, not parse: the model writes these args, and an
        // over-long digit run ("99999999999999999999x1") would throw a
        // FormatException from inside the LayoutBuilder build path.
        final w = int.tryParse(m.group(1)!);
        final h = int.tryParse(m.group(2)!);
        if (w != null && h != null && w > 0 && h > 0) {
          return MapEntry(w / h, '$w × $h');
        }
      }
    }
    final aspectRatio = args['aspect_ratio'];
    if (aspectRatio is String) {
      final m = RegExp(r'(\d+)\s*[:x×]\s*(\d+)').firstMatch(aspectRatio);
      if (m != null) {
        final w = int.tryParse(m.group(1)!);
        final h = int.tryParse(m.group(2)!);
        if (w != null && h != null && w > 0 && h > 0) {
          return MapEntry(w / h, aspectRatio);
        }
      }
    }
    const presets = <String, List<int>>{
      'square_hd': [1024, 1024],
      'square': [512, 512],
      'portrait_4_3': [768, 1024],
      'portrait_16_9': [576, 1024],
      'landscape_4_3': [1024, 768],
      'landscape_16_9': [1024, 576],
    };
    final imageSize = args['image_size'];
    if (imageSize is String && presets.containsKey(imageSize)) {
      final dims = presets[imageSize]!;
      return MapEntry(dims[0] / dims[1], '${dims[0]} × ${dims[1]}');
    }
    return MapEntry(1024 / 768, '');
  }

  /// Renders the image grid (1, 2+1, or N-col Wrap) for the message.
  /// Renders NO external margin — callers add `_kBlockGap` after the
  /// grid to separate it from the next block.
  Widget _buildImagesGrid(List<String> images) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.of(context).size.width * 0.8;
        final bool compactQrLayout = _isQrImageMessage && images.length == 1;

        if (compactQrLayout) {
          final String imageSource = images.first;
          final double squareSize =
              (kPlatformMobile ? maxWidth * 0.55 : maxWidth * 0.4).clamp(
                150.0,
                240.0,
              );

          return Align(
            alignment: Alignment.center,
            child: _captionedTile(
              imageSource: imageSource,
              width: squareSize,
              height: squareSize,
              borderRadius: 12,
              fit: BoxFit.contain,
              model: _modelFor(0),
              onTap: () => _openImagePreview(
                imageSource: imageSource,
                images: images,
                index: 0,
              ),
            ),
          );
        }

        if (images.length == 1) {
          final String imageSource = images.first;
          // User uploads render as a square preview (width == height) so the
          // aspect ratio stays predictable on both mobile and desktop.
          // Mobile stays compact (~140 px side); desktop gets a larger square
          // sized to ~45 % of the bubble's max width, clamped.
          if (widget.isUser) {
            final double userSquare = kPlatformMobile
                ? 140.0
                : (maxWidth * 0.45).clamp(200.0, 320.0);
            // Outer Column already right-aligns user messages via
            // CrossAxisAlignment.end — do NOT wrap in Align here, or the frame
            // stretches to full width and shows an asymmetric gap on the left.
            return _captionedTile(
              imageSource: imageSource,
              width: userSquare,
              height: userSquare,
              borderRadius: 12,
              fit: BoxFit.cover,
              model: _modelFor(0),
              onTap: () => _openImagePreview(
                imageSource: imageSource,
                images: images,
                index: 0,
              ),
            );
          }

          // AI-generated images render full bubble width and follow the
          // image's *real* aspect ratio (same as web-fetched <image> blocks),
          // instead of being cropped into a fixed-height box. A tall portrait
          // (e.g. 9:16 phone wallpaper) keeps its height; height is capped so a
          // freak panorama can't dominate the chat. Until the bytes decode, a
          // placeholder of the same width reserves space and shows a spinner,
          // then the tile resizes to the true ratio.
          return _captionedTile(
            imageSource: imageSource,
            width: maxWidth,
            height: maxWidth, // placeholder height before decode (square)
            borderRadius: 12,
            naturalAspect: true,
            maxNaturalHeight: maxWidth * 1.9,
            model: _modelFor(0),
            onTap: () => _openImagePreview(
              imageSource: imageSource,
              images: images,
              index: 0,
            ),
          );
        }

        // 3 images always render as a single 3-wide row — the 2+1 layout
        // from the generic mobile 2-column grid looks unbalanced.
        final int columns = images.length == 3 ? 3 : (maxWidth > 520 ? 3 : 2);
        final double tileWidth = ((maxWidth - ((columns - 1) * 8)) / columns)
            .clamp(90.0, 260.0);

        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: images.asMap().entries.map((entry) {
            final int index = entry.key;
            final String imageSource = entry.value;

            return _captionedTile(
              imageSource: imageSource,
              width: tileWidth,
              height: tileWidth,
              borderRadius: 10,
              model: _modelFor(index),
              onTap: () => _openImagePreview(
                imageSource: imageSource,
                images: images,
                index: index,
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _captionedTile({
    required String imageSource,
    required double width,
    required double height,
    required double borderRadius,
    required VoidCallback onTap,
    String? model,
    BoxFit fit = BoxFit.cover,
    bool naturalAspect = false,
    double? maxNaturalHeight,
  }) {
    Widget thumbnail = _CachedImageThumbnail(
      imageDataUrl: imageSource,
      width: width,
      height: height,
      borderRadius: borderRadius,
      fit: fit,
      naturalAspect: naturalAspect,
      maxNaturalHeight: maxNaturalHeight,
      onTap: onTap,
    );

    // Right-click (desktop) / long-press (mobile) on a stored image opens a
    // context menu to delete it from storage. Skip data: URIs (QR codes,
    // base64 fallbacks) — there is no storage object to remove.
    if (!imageSource.startsWith('data:image/')) {
      thumbnail = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapDown: (d) =>
            _showImageContextMenu(d.globalPosition, imageSource),
        onLongPressStart: (d) =>
            _showImageContextMenu(d.globalPosition, imageSource),
        child: thumbnail,
      );
    }

    final hasModel = model != null && model.trim().isNotEmpty;
    if (!hasModel) return thumbnail;

    // The generator model is overlaid as a small pill in the bottom-right
    // corner of the image itself — the only place it is shown (no duplicate
    // caption row below the image). Works for single and multi-image grids.
    return Stack(
      children: [
        thumbnail,
        Positioned(
          right: 6,
          bottom: 6,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width - 12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.auto_awesome,
                    size: 10,
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      model,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        height: 1.0,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _openImagePreview({
    required String imageSource,
    required List<String> images,
    required int index,
    // _modelFor indexes widget.imageMetas, which is aligned with
    // widget.images. When [images] is a different list (e.g. an <image>
    // block's single web URL), those indices don't correspond, so callers
    // pass false to avoid mislabelling the preview with unrelated metadata.
    bool resolveModels = true,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ImageViewer(
          imageDataUrl: imageSource,
          initialIndex: index,
          allImages: images,
          models: [
            for (int i = 0; i < images.length; i++)
              resolveModels ? _modelFor(i) : null,
          ],
        ),
        fullscreenDialog: true,
      ),
    );
  }

  /// Context menu shown on right-click / long-press of a stored chat image.
  /// Currently a single Delete action; deletion removes the encrypted object
  /// from storage (like the Media Manager) and the tile live-updates to
  /// "Image deleted" via [ImageStorageService.onImageDeleted].
  Future<void> _showImageContextMenu(Offset globalPosition, String path) async {
    final l = AppLocalizations.of(context)!;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;

    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem<String>(
          value: 'delete',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.delete_outline, size: 18, color: Colors.red),
              const SizedBox(width: 8),
              Text(l.delete, style: const TextStyle(color: Colors.red)),
            ],
          ),
        ),
      ],
    );

    if (selected == 'delete' && mounted) {
      await _confirmDeleteImage(path);
    }
  }

  /// Confirms and deletes a stored image's encrypted object. Mirrors the Media
  /// Manager flow: warn (but still allow) when the image is referenced by
  /// chats, then delete. The tile repaints to "Image deleted" via the deletion
  /// broadcast, so no message mutation is needed here.
  Future<void> _confirmDeleteImage(String path) async {
    final l = AppLocalizations.of(context)!;

    List<ChatUsingImage> usedIn = const [];
    try {
      usedIn = await ImageStorageService.findChatsUsingImage(path);
    } catch (_) {
      // Best-effort: if the usage lookup fails, fall back to a plain confirm.
    }
    if (!mounted) return;

    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l.deleteImageTitle),
            content: Text(
              usedIn.isNotEmpty
                  ? '${l.deleteImageShowDeleted}\n\n${l.deleteImageConfirm}'
                  : l.deleteImageBody,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: Text(usedIn.isNotEmpty ? l.deleteAnyway : l.delete),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed || !mounted) return;

    try {
      await ImageStorageService.deleteEncryptedImage(path);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.imageDeleted)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.deleteFailed(e.toString()))));
      }
    }
  }

  /// Renders document attachment chips as a Wrap. Renders NO external
  /// margin — callers add `_kBlockGap` between the chip row and the
  /// next block.
  Widget _buildAttachmentsChips(List<DocumentAttachment> attachments) {
    final iconColor = Theme.of(context).colorScheme.onSurface;
    final accentColor = Theme.of(context).colorScheme.primary;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: attachments.map((attachment) {
        return InkWell(
          borderRadius: kBorderRadiusRow,
          onTap: () {
            // Open document viewer
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => DocumentViewer(
                  fileName: attachment.fileName,
                  markdownContent: attachment.markdownContent,
                ),
                fullscreenDialog: true,
              ),
            );
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: accentColor.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: accentColor.withValues(alpha: 0.5),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.description, size: 18, color: iconColor),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      attachment.fileName,
                      style: TextStyle(
                        color: iconColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.open_in_new,
                    size: 14,
                    color: iconColor.withValues(alpha: 0.7),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
