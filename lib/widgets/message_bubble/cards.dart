// lib/widgets/message_bubble/cards.dart
//
// Part of message_bubble.dart — the self-contained widgets the bubble embeds:
// the caching image thumbnail, the reactive inline artifact card, its error
// chip, and the news article card. These are real State/Stateless widgets
// rather than extensions, so they carry their own state and lifecycle.

part of '../message_bubble.dart';

/// Cached image thumbnail that decodes once and caches the bytes
class _CachedImageThumbnail extends StatefulWidget {
  const _CachedImageThumbnail({
    required this.imageDataUrl,
    required this.width,
    required this.height,
    required this.onTap,
    this.borderRadius = 8,
    this.fit = BoxFit.cover,
    this.naturalAspect = false,
    this.maxNaturalHeight,
  });

  /// Can be either:
  /// - A Base64 data URL: "data:image/jpeg;base64,..."
  /// - A storage path: "user-id/uuid.enc"
  final String imageDataUrl;
  final double width;

  /// Used as a fixed tile height in the default (cropped) mode, and as the
  /// placeholder height while bytes are still loading in [naturalAspect] mode.
  final double height;
  final double borderRadius;
  final BoxFit fit;

  /// When true the tile renders at [width] and follows the decoded image's own
  /// aspect ratio (no cropping), capped at [maxNaturalHeight]. The decode-time
  /// [height] is only the placeholder size shown before the ratio is known.
  final bool naturalAspect;

  /// Upper bound on height in [naturalAspect] mode so an extreme portrait /
  /// panorama can't take over the chat. Ignored when [naturalAspect] is false.
  final double? maxNaturalHeight;

  final VoidCallback onTap;

  @override
  State<_CachedImageThumbnail> createState() => _CachedImageThumbnailState();
}

class _CachedImageThumbnailState extends State<_CachedImageThumbnail>
    with AutomaticKeepAliveClientMixin {
  Uint8List? _cachedBytes;
  bool _isLoading = true;

  /// True when the storage object 404'd — i.e. the image was deleted from the
  /// backend (a manual Media-Manager delete, or a purged bucket). Distinguished
  /// from a generic load failure so the tile can say "deleted" instead of a
  /// bare broken-image icon.
  bool _notFound = false;

  /// Intrinsic width/height of the decoded image. Only resolved (and only
  /// used) in [_CachedImageThumbnail.naturalAspect] mode.
  double? _aspectRatio;

  StreamSubscription<String>? _deletionSub;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadImage();
    // Live-swap to the "Image deleted" state the moment this exact storage
    // object is removed anywhere (chat right-click, Media Manager) — no reload
    // needed. Data: URIs have no storage object, so skip the subscription.
    if (!widget.imageDataUrl.startsWith('data:image/')) {
      _deletionSub = ImageStorageService.onImageDeleted.listen((deletedPath) {
        if (deletedPath == widget.imageDataUrl && mounted) {
          setState(() {
            _cachedBytes = null;
            _notFound = true;
            _isLoading = false;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _deletionSub?.cancel();
    super.dispose();
  }

  Future<void> _loadImage() async {
    final stopwatch = Stopwatch()..start();
    try {
      if (widget.imageDataUrl.startsWith('data:image/')) {
        // Base64 data URI — decode inline (used by tool-generated images
        // like QR codes, or as fallback when Supabase upload fails).
        final commaIndex = widget.imageDataUrl.indexOf(',');
        if (commaIndex >= 0) {
          try {
            _cachedBytes = base64Decode(
              widget.imageDataUrl.substring(commaIndex + 1),
            );
          } catch (e) {
            if (kDebugMode) {
              debugPrint('Failed to decode Base64 image: $e');
            }
          }
        }
      } else {
        // Storage path - download and decrypt
        _cachedBytes = await ImageStorageService.downloadAndDecryptImage(
          widget.imageDataUrl,
        );
      }
    } catch (e) {
      // Detect a deleted/missing storage object (404) so the tile can show a
      // clear "Image deleted" state rather than a generic broken-image icon.
      // Mirrors the heuristic in EncryptedImageWidget.
      final errorStr = e.toString().toLowerCase();
      _notFound =
          errorStr.contains('not found') ||
          errorStr.contains('404') ||
          errorStr.contains('does not exist') ||
          errorStr.contains('object not found');
      if (kDebugMode) {
        debugPrint('Failed to load image: $e');
      }
    }

    // In natural-aspect mode, decode the intrinsic dimensions so the tile can
    // size itself to the real ratio instead of a placeholder square.
    if (widget.naturalAspect && _cachedBytes != null) {
      try {
        final codec = await ui.instantiateImageCodec(_cachedBytes!);
        final frame = await codec.getNextFrame();
        final img = frame.image;
        if (img.height > 0) {
          _aspectRatio = img.width / img.height;
        }
        img.dispose();
        codec.dispose();
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Failed to decode image dimensions: $e');
        }
      }
    }

    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }

    stopwatch.stop();
    if (stopwatch.elapsedMilliseconds >= 250) {
      final bool isDataUri = widget.imageDataUrl.startsWith('data:image/');
      unawaited(
        DiagnosticsLogService.timing(
          'chat_ui',
          isDataUri ? 'decode_base64_thumbnail' : 'download_decrypt_thumbnail',
          stopwatch.elapsedMilliseconds,
          data: {
            'source_type': isDataUri ? 'data_uri' : 'storage_path',
            'width': widget.width.round(),
            'height': widget.height.round(),
            'bytes_loaded': _cachedBytes?.length ?? 0,
          },
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin

    // Resolve the height this tile should occupy. In natural-aspect mode we
    // follow the decoded ratio once it is known (capped), otherwise we fall
    // back to the placeholder square; in default mode it is always the fixed
    // tile height.
    final double renderHeight;
    if (widget.naturalAspect && _aspectRatio != null && _aspectRatio! > 0) {
      final double natural = widget.width / _aspectRatio!;
      final double cap = widget.maxNaturalHeight ?? double.infinity;
      renderHeight = natural > cap ? cap : natural;
    } else {
      renderHeight = widget.height;
    }

    // In natural-aspect mode the placeholder → real-image height change is
    // animated so the bubble grows/shrinks smoothly instead of snapping.
    Widget wrap(Widget child) {
      if (!widget.naturalAspect) return child;
      return AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        child: child,
      );
    }

    if (_isLoading) {
      return wrap(
        Container(
          width: widget.width,
          height: renderHeight,
          decoration: BoxDecoration(
            color: Colors.grey.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(widget.borderRadius),
          ),
          child: const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      );
    }

    if (_cachedBytes == null) {
      // Only show the text label when the tile is tall enough for icon + gap +
      // caption, so a small grid thumbnail can't overflow vertically.
      final bool showLabel = renderHeight >= 64;
      final Color fg = Theme.of(context).colorScheme.onSurfaceVariant;
      return wrap(
        Container(
          width: widget.width,
          height: renderHeight,
          decoration: BoxDecoration(
            color: Colors.grey.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(widget.borderRadius),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _notFound ? Icons.image_not_supported_outlined : Icons.broken_image,
                  size: 32,
                  color: fg,
                ),
                if (showLabel) ...[
                  const SizedBox(height: 8),
                  Text(
                    _notFound ? 'Image deleted' : 'Failed to load',
                    style: TextStyle(
                      color: fg,
                      fontSize: 12,
                      fontStyle: _notFound
                          ? FontStyle.italic
                          : FontStyle.normal,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return wrap(
      InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            child: Image.memory(
              _cachedBytes!,
              width: widget.width,
              height: renderHeight,
              fit: widget.fit,
              // Only constrain cacheWidth to preserve aspect ratio during
              // decode. Setting both cacheWidth AND cacheHeight distorts the
              // image before BoxFit.cover can crop it properly.
              cacheWidth: (widget.width * 2).toInt(),
              gaplessPlayback: true,
              errorBuilder: (context, error, stackTrace) {
                return Container(
                  width: widget.width,
                  height: renderHeight,
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(widget.borderRadius),
                  ),
                  child: const Icon(Icons.broken_image, size: 32),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact artifact card shown inline in chat after artifact_manager calls.
/// Clicking it opens the artifact panel (Claude.ai-style UX).
///
/// The card is *reactive*: it always shows the latest current version of the
/// referenced artifact, looked up live from [ArtifactStorageService]. The
/// version originally captured when the assistant message was authored
/// ([authoredVersion]) is used only to show a subtle "(was vN)" hint when the
/// artifact has moved on, never as the primary label. This keeps old chat
/// bubbles in sync with the artifact's current state instead of advertising
/// stale snapshot numbers.
///
/// If the artifact has been deleted (e.g. by a regenerate rollback that
/// removed the version that created it), the card degrades to a disabled
/// "Artifact removed" state instead of dangling open a 404. While the
/// artifact has not yet been resolved (chat still loading, network in
/// flight) the card falls back to the authored title/version to avoid a
/// flash of "Removed".
class _ArtifactInlineCard extends StatefulWidget {
  const _ArtifactInlineCard({
    required this.artifactId,
    required this.title,
    required this.type,
    this.authoredVersion,
  });

  final String artifactId;

  /// Title captured at message-author time. Used as a fallback before the
  /// live artifact has been resolved, and as the title when the artifact
  /// has been deleted.
  final String title;

  /// Type captured at message-author time (e.g. `excalidraw`, `markdown`).
  /// Drives the icon and type label. Type can't change for an artifact id,
  /// so we don't need a live lookup for this.
  final String type;

  /// The artifact's version at the time the assistant message was authored.
  /// Used to render the "(was vN)" hint when the artifact has been rewritten
  /// since, and as the fallback label while the live lookup is in flight.
  final int? authoredVersion;

  @override
  State<_ArtifactInlineCard> createState() => _ArtifactInlineCardState();
}

class _ArtifactInlineCardState extends State<_ArtifactInlineCard> {
  /// Latest live snapshot of the artifact, or `null` until the first load
  /// resolves. Distinct from [_resolved] so we can tell "not loaded yet"
  /// (show authored fallback) from "loaded and confirmed missing" (show
  /// removed state).
  ArtifactDocument? _live;

  /// `true` once we've completed at least one resolution attempt — even if
  /// it returned `null`. Used to differentiate the initial loading state
  /// from a confirmed-deleted state.
  bool _resolved = false;

  StreamSubscription<void>? _changesSub;

  @override
  void initState() {
    super.initState();
    _refresh();
    _changesSub = ArtifactStorageService.changes.listen((_) => _refresh());
  }

  @override
  void dispose() {
    _changesSub?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final doc = await ArtifactStorageService.loadArtifactById(
        widget.artifactId,
      );
      if (!mounted) return;
      setState(() {
        _live = doc;
        _resolved = true;
      });
    } catch (_) {
      // Resolution failure is non-fatal — keep showing the authored fallback.
      if (!mounted) return;
      // Do NOT flip _resolved here. A transient network error must not
      // collapse the card into the "Removed" state. The next changes-stream
      // event (or a retry) can still upgrade us to a live snapshot.
    }
  }

  IconData get _icon {
    switch (widget.type) {
      case 'code':
        return Icons.code;
      case 'markdown':
        return Icons.article_outlined;
      case 'html':
        return Icons.html;
      case 'mermaid':
        return Icons.account_tree_outlined;
      case 'svg':
        return Icons.image_outlined;
      case 'technical_drawing':
        return Icons.architecture;
      case 'typst':
        return Icons.picture_as_pdf;
      case 'excalidraw':
        return Icons.brush_outlined;
      default:
        return Icons.description_outlined;
    }
  }

  String get _typeLabel {
    switch (widget.type) {
      case 'code':
        return 'Code';
      case 'markdown':
        return 'Document · MD';
      case 'html':
        return 'HTML';
      case 'mermaid':
        return 'Diagram · Mermaid';
      case 'svg':
        return 'Image · SVG';
      case 'technical_drawing':
        return 'Technical drawing';
      case 'typst':
        return 'Typst · PDF';
      case 'excalidraw':
        return 'Excalidraw sketch';
      default:
        return 'Artifact';
    }
  }

  Future<void> _open(BuildContext context) async {
    // Always try to resolve and activate the clicked artifact — even when the
    // panel is already showing something with a matching id. Users may have
    // multiple cards for the same artifact (e.g. create + rewrite) and expect
    // each click to refocus that artifact at the live version.
    //
    // loadArtifactById hits Supabase directly and does not depend on
    // ArtifactStorageService.activeChatId. The deferred setActiveChat() call
    // in RootWrapperDesktop runs ~2s after launch, so guarding on activeChatId
    // here would silently no-op for any tap that lands during that window —
    // exactly the "first start, artifact card does nothing" symptom.
    try {
      ArtifactDocument? match = await ArtifactStorageService.loadArtifactById(
        widget.artifactId,
      );
      final chatId = ArtifactStorageService.activeChatId;
      if (match == null && chatId != null && chatId.isNotEmpty) {
        match = (await ArtifactStorageService.loadArtifactsForChat(
          chatId,
        )).where((a) => a.id == widget.artifactId).firstOrNull;
      }

      if (match != null) {
        final current = ArtifactStorageService.activeArtifactNotifier.value;
        if (!identical(current, match)) {
          ArtifactStorageService.activeArtifactNotifier.value = match;
        }
      }
    } catch (_) {
      // Request open anyway below; resolution failures are non-fatal.
    }
    // Fire the open-request event last so the listener reads a fresh
    // active artifact. Using requestOpen() ensures repeated taps reopen the
    // sheet even when panelOpenNotifier is already true.
    //
    // Pass `version: null` so the panel opens at the LATEST version, not
    // the snapshot captured at message-author time. The card's whole point
    // is to point at the live artifact; pinning to an old version on click
    // would be inconsistent with the label we just rendered.
    ArtifactStorageService.requestOpen(
      artifactId: widget.artifactId,
      version: null,
    );
  }

  /// Saves the artifact's source to a file. Mirrors the file card's Download so
  /// artifacts and sent files expose the same Open + Download actions. The
  /// panel header still offers richer rendered exports (PDF/DOCX/PNG); this is
  /// the always-available source download.
  Future<void> _download(BuildContext context) async {
    try {
      final art =
          _live ??
          await ArtifactStorageService.loadArtifactById(widget.artifactId);
      if (art == null) {
        if (context.mounted) {
          NiceSnackBar.showError(context, 'Artifact is no longer available.');
        }
        return;
      }
      final rawTitle = art.title.trim();
      final safeTitle = rawTitle.isEmpty ? 'artifact' : rawTitle;
      final ext = art.type.defaultExtension;
      final name = safeTitle.toLowerCase().endsWith('.$ext')
          ? safeTitle
          : '$safeTitle.$ext';
      final result = await FileSaveService.save(
        bytes: Uint8List.fromList(utf8.encode(art.content)),
        suggestedName: name,
        dialogTitle: 'Save $name',
      );
      if (!context.mounted) return;
      switch (result.outcome) {
        case SaveOutcome.savedToFolder:
        case SaveOutcome.savedViaPicker:
        case SaveOutcome.savedViaShare:
          NiceSnackBar.show(context, 'Saved $name');
        case SaveOutcome.cancelled:
          break;
        case SaveOutcome.failed:
          NiceSnackBar.showError(context, 'Could not save file');
      }
    } catch (e) {
      if (context.mounted) {
        NiceSnackBar.showError(context, 'Download failed: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final borderColor = theme.colorScheme.outline.withValues(alpha: 0.3);

    // Artifact is confirmed-deleted: render a disabled "removed" state.
    // We keep the authored title so the user knows WHICH artifact is gone.
    final bool removed = _resolved && _live == null;

    // Build the secondary label.
    //   - Removed:                  "Artifact removed"
    //   - Live + version moved:     "Excalidraw sketch · v3 (was v1)"
    //   - Live + same version:      "Excalidraw sketch · v3"
    //   - Not yet resolved:         "Excalidraw sketch · v1" (authored)
    //   - No version info anywhere: "Excalidraw sketch"
    final String secondaryLabel;
    if (removed) {
      secondaryLabel = 'Artifact removed';
    } else {
      final liveVersion = _live?.version;
      final authoredVersion = widget.authoredVersion;
      final shownVersion = liveVersion ?? authoredVersion;
      if (shownVersion == null) {
        secondaryLabel = _typeLabel;
      } else if (liveVersion != null &&
          authoredVersion != null &&
          liveVersion != authoredVersion) {
        secondaryLabel = '$_typeLabel · v$liveVersion (was v$authoredVersion)';
      } else {
        secondaryLabel = '$_typeLabel · v$shownVersion';
      }
    }

    // Prefer the live title once resolved (artifact may have been renamed
    // via rewrite). Fall back to the authored title for the loading
    // window and for the removed state.
    final String shownTitle = _live?.title ?? widget.title;

    final bool enabled = !removed;
    final secondaryColor = removed
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: enabled ? () => _open(context) : null,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 44,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                alignment: Alignment.center,
                child: Icon(
                  removed ? Icons.delete_outline : _icon,
                  size: 20,
                  color: removed ? theme.colorScheme.error : null,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      shownTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      secondaryLabel,
                      style: TextStyle(fontSize: 12, color: secondaryColor),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (enabled)
                TextButton(
                  onPressed: () => _download(context),
                  child: const Text('Download'),
                ),
              TextButton(
                onPressed: enabled ? () => _open(context) : null,
                child: const Text('Open'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Visible error chip when an inline artifact tag (or artifact_manager tool
/// call) fails. Without this the failure is invisible — the protocol tag is
/// stripped from display but no chip replaces it, leaving the bubble empty.
class _ArtifactErrorCard extends StatelessWidget {
  const _ArtifactErrorCard({required this.toolName, required this.message});

  final String toolName;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = message.replaceFirst(RegExp(r'^Error:\s*'), '');
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.error.withValues(alpha: 0.4)),
        color: scheme.errorContainer.withValues(alpha: 0.25),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Artifact could not be created',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: scheme.error,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  text,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onErrorContainer,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// News article card: thumbnail (left, 96x96), title, publisher · age, summary,
/// tap anywhere → opens the article URL. Stretches to full bubble width.
class _NewsCard extends StatelessWidget {
  const _NewsCard({required this.item, required this.colorScheme});

  final Map<String, dynamic> item;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final title = (item['title'] as String? ?? '').trim();
    final publisher = (item['publisher'] as String? ?? '').trim();
    final age = (item['age'] as String? ?? '').trim();
    final summary =
        (item['summary'] as String? ?? item['description'] as String? ?? '')
            .trim();
    final url = (item['url'] as String? ?? '').trim();
    final rawThumbnail =
        (item['thumbnail'] as String? ?? item['thumbnail_url'] as String? ?? '')
            .trim();
    // The thumbnail URL comes from model output. Image.network fetches it
    // automatically, so gate it to http/https (same rule as _openUrl) — a
    // non-http scheme would leak the user IP/user-agent to an arbitrary host.
    final thumbUri = Uri.tryParse(rawThumbnail);
    final thumbnail =
        thumbUri != null &&
            const {'http', 'https'}.contains(thumbUri.scheme.toLowerCase())
        ? rawThumbnail
        : '';
    final breaking = item['breaking'] == true;

    final metaParts = <String>[
      if (publisher.isNotEmpty) publisher,
      if (age.isNotEmpty) age,
    ];

    final cardBg = Theme.of(context).brightness == Brightness.dark
        ? colorScheme.surface.withValues(alpha: 0.6)
        : colorScheme.surface;

    return Material(
      color: cardBg,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: url.isEmpty ? null : () => _openUrl(context, url),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: colorScheme.outlineVariant.withValues(alpha: 0.5),
              width: 1,
            ),
          ),
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (thumbnail.isNotEmpty) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.network(
                    thumbnail,
                    width: 96,
                    height: 96,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      width: 96,
                      height: 96,
                      color: colorScheme.surfaceContainerHighest,
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    loadingBuilder: (ctx, child, progress) {
                      if (progress == null) return child;
                      return Container(
                        width: 96,
                        height: 96,
                        color: colorScheme.surfaceContainerHighest,
                        alignment: Alignment.center,
                        child: const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (breaking)
                      Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.error,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'BREAKING',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                            color: colorScheme.onError,
                          ),
                        ),
                      ),
                    Text(
                      title.isEmpty ? '(untitled)' : title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                        color: colorScheme.onSurface,
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (metaParts.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        metaParts.join(' · '),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: colorScheme.primary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (summary.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        summary,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.35,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (url.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(
                            Icons.open_in_new,
                            size: 12,
                            color: colorScheme.onSurfaceVariant.withValues(
                              alpha: 0.7,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              Uri.tryParse(url)?.host ?? url,
                              style: TextStyle(
                                fontSize: 11,
                                color: colorScheme.onSurfaceVariant.withValues(
                                  alpha: 0.7,
                                ),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openUrl(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (!const {'http', 'https'}.contains(uri.scheme.toLowerCase())) return;
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
