// B1 media: Image, ImageBlock, ImageGallery.
//
// Network images only (http and https). While an image loads, a calm
// tile holds its place; the box has a fixed shape, so nothing jumps
// when the image arrives. A broken image shows a quiet icon and the
// alt text. A tap opens the app's own image viewer.

part of '../content_layout.dart';

/// The corner of an image tile.
const double _kImageRadius = OpenUiTokens.radiusInner;

/// The tallest an Image or a one-image gallery gets.
const double _kImageMaxHeight = 360;

/// The tallest a gallery tile gets; a wide column then crops it.
const double _kGalleryTileMaxHeight = 220;

/// The height of an ImageBlock (upstream: 240).
const double _kImageBlockHeight = 240;

/// Opens the app's full-screen image viewer on [urls] at [index].
void _openImageViewer(BuildContext context, List<String> urls, int index) {
  if (urls.isEmpty) return;
  final i = index.clamp(0, urls.length - 1);
  Navigator.maybeOf(context)?.push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) =>
          ImageViewer(imageDataUrl: urls[i], initialIndex: i, allImages: urls),
    ),
  );
}

// ---------------------------------------------------------------------
// Image: a 3:2 tile, the image cropped to fill it (upstream default).
// On a wide column the tile stops at [_kImageMaxHeight] and crops more.
// ---------------------------------------------------------------------

Widget _buildImage(BuildContext context, OpenUiProps props) {
  final alt = props.string('alt').trim();
  final raw = props.string('src').trim();
  if (alt.isEmpty && raw.isEmpty) return const SizedBox.shrink();
  final url = _webUrl(raw);
  final tile = _ImageTile(
    url: url,
    alt: alt,
    broken: raw.isNotEmpty && url == null,
    onTap: url == null ? null : () => _openImageViewer(context, [url], 0),
  );
  return LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth.isFinite
          ? constraints.maxWidth
          : OpenUiTokens.chatColumnWidth;
      return SizedBox(
        width: width,
        height: math.min(width * 2 / 3, _kImageMaxHeight),
        child: tile,
      );
    },
  );
}

/// A rounded tile that fills its box with an image, or with a calm
/// placeholder while it loads or when it fails.
class _ImageTile extends StatelessWidget {
  const _ImageTile({
    required this.url,
    required this.alt,
    this.broken = false,
    this.onTap,
    this.showAlt = true,
  });

  final String? url;
  final String alt;

  /// Whether the source is known to be bad (not a web URL).
  final bool broken;
  final VoidCallback? onTap;

  /// Whether a failed tile prints the alt text (off for small tiles).
  final bool showAlt;

  @override
  Widget build(BuildContext context) {
    final src = url;
    final Widget image = src == null
        ? _ImagePlaceholder(alt: alt, broken: broken, showAlt: showAlt)
        : Image.network(
            src,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            semanticLabel: alt.isEmpty ? null : alt,
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
              if (wasSynchronouslyLoaded) return child;
              return Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  const _ImagePlaceholder(alt: '', showAlt: false),
                  AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: kExpressiveShort,
                    curve: kExpressiveDecelerate,
                    child: child,
                  ),
                ],
              );
            },
            errorBuilder: (_, _, _) =>
                _ImagePlaceholder(alt: alt, broken: true, showAlt: showAlt),
          );
    final clipped = ClipRRect(
      borderRadius: BorderRadius.circular(_kImageRadius),
      child: image,
    );
    if (onTap == null) return clipped;
    return MorphTap(
      onTap: onTap,
      pressedScale: 0.98,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_kImageRadius),
      ),
      pressedShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_kImageRadius),
      ),
      child: clipped,
    );
  }
}

/// The sunk tile that stands in for an image: an image icon while it
/// loads, a "not found" icon and the alt text when it failed.
class _ImagePlaceholder extends StatelessWidget {
  const _ImagePlaceholder({
    required this.alt,
    this.broken = false,
    this.showAlt = true,
    this.filled = true,
  });

  final String alt;
  final bool broken;
  final bool showAlt;

  /// Whether the tile paints its own sunk fill. Off inside an
  /// ImageBlock, which is sunk already.
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final caption = showAlt && alt.isNotEmpty;
    return ColoredBox(
      color: filled ? t.sunkColor : Colors.transparent,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 6,
            children: <Widget>[
              HugeIcon(
                broken ? HugeIcons.imageNotFound01 : HugeIcons.image01,
                size: 22,
                color: t.mutedColor.withValues(alpha: 0.6),
              ),
              if (caption)
                Flexible(
                  child: Text(
                    alt,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: t.captionStyle,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// ImageBlock: a fixed-height sunk block, the whole image fitted inside
// with rounded corners. The block holds its height while it loads.
// ---------------------------------------------------------------------

Widget _buildImageBlock(BuildContext context, OpenUiProps props) {
  final raw = props.string('src').trim();
  if (raw.isEmpty) return const SizedBox.shrink();
  final alt = props.string('alt').trim();
  final url = _webUrl(raw);
  final t = OpenUiTheme.of(context);
  final Widget inner = url == null
      ? _ImagePlaceholder(alt: alt, broken: true, filled: false)
      : Padding(
          padding: const EdgeInsets.all(12),
          child: Center(
            child: Image.network(
              url,
              semanticLabel: alt.isEmpty ? null : alt,
              gaplessPlayback: true,
              frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                if (frame == null && !wasSynchronouslyLoaded) {
                  return const _ImagePlaceholder(
                    alt: '',
                    showAlt: false,
                    filled: false,
                  );
                }
                return ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: child,
                );
              },
              errorBuilder: (_, _, _) =>
                  _ImagePlaceholder(alt: alt, broken: true, filled: false),
            ),
          ),
        );
  final block = SizedBox(
    height: _kImageBlockHeight,
    width: double.infinity,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(OpenUiTokens.radiusCard),
      child: ColoredBox(color: t.sunkColor, child: inner),
    ),
  );
  if (url == null) return block;
  return MorphTap(
    onTap: () => _openImageViewer(context, [url], 0),
    pressedScale: 0.98,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(OpenUiTokens.radiusCard),
    ),
    pressedShape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(OpenUiTokens.radiusCard),
    ),
    child: block,
  );
}

// ---------------------------------------------------------------------
// ImageGallery: a grid. One image is a 3:2 tile; two or four make two
// columns; else three. A tap opens the viewer on all images.
// ---------------------------------------------------------------------

typedef _GalleryImage = ({String? url, String alt, bool broken});

Widget _buildImageGallery(BuildContext context, OpenUiProps props) {
  final images = <_GalleryImage>[
    for (final m in props.mapList('images'))
      if (m['src'] is String && (m['src']! as String).trim().isNotEmpty)
        (
          url: _webUrl(m['src']),
          alt: m['alt'] is String ? (m['alt']! as String).trim() : '',
          broken: _webUrl(m['src']) == null,
        ),
  ];
  if (images.isEmpty) return const SizedBox.shrink();
  return _Gallery(images: images);
}

class _Gallery extends StatelessWidget {
  const _Gallery({required this.images});

  final List<_GalleryImage> images;

  static const double _gap = 6;

  @override
  Widget build(BuildContext context) {
    final urls = <String>[
      for (final i in images)
        if (i.url != null) i.url!,
    ];
    final n = images.length;
    final columns = n == 1 ? 1 : (n == 2 || n == 4 ? 2 : 3);
    final aspect = n == 1 ? 3 / 2 : 1.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : OpenUiTokens.chatColumnWidth;
        final tile = ((width - _gap * (columns - 1)) / columns).floorToDouble();
        if (tile <= 0) return const SizedBox.shrink();
        return Wrap(
          spacing: _gap,
          runSpacing: _gap,
          children: <Widget>[
            for (final img in images)
              SizedBox(
                width: tile,
                height: math.min(
                  tile / aspect,
                  n == 1 ? _kImageMaxHeight : _kGalleryTileMaxHeight,
                ),
                child: _ImageTile(
                  url: img.url,
                  alt: img.alt,
                  broken: img.broken,
                  showAlt: n == 1,
                  onTap: img.url == null
                      ? null
                      : () => _openImageViewer(
                          context,
                          urls,
                          urls.indexOf(img.url!),
                        ),
                ),
              ),
          ],
        );
      },
    );
  }
}
