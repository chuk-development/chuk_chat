// lib/widgets/link_preview_card.dart
//
// Link previews in chat messages (plain Chat and Agents), Grok Bot style:
//
// * A link reads as its short name (the markdown link text; a bare URL shows
//   as `host/path`), underlined, with the small site icon in front of it
//   ([LinkFavicon]).
// * Desktop: resting the mouse on the link opens a floating card above or
//   below it ([LinkPreviewHover]).
// * Touch: a long press on the link shows the same card; a short tap opens
//   the link as before ([linkPreviewRecognizer]).
//
// No card under messages. The data comes from [LinkPreviewService]
// (server-side fetch, cached). No data means no card and the neutral link
// glyph in front of the link: nothing here ever shows an error.
//
// Hook point (keep it when you change the markdown):
// `lib/widgets/markdown_message.dart`, `AccentLinkNode.build()`.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:url_launcher/url_launcher.dart';

import 'package:chuk_chat/constants.dart' show kRadiusLg, kRadiusXs;
import 'package:chuk_chat/services/link_preview_service.dart';
import 'package:chuk_chat/widgets/icons/huge_icon.dart';

/// Width of the floating card.
const double kLinkPreviewCardWidth = 300;

/// Whether [url] is a web link that gets an icon and a card.
bool isPreviewableUrl(String url) {
  final Uri? uri = Uri.tryParse(url);
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.contains('.');
}

Future<void> _openLink(String url) async {
  final Uri? uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    // Nothing to open with: stay quiet, the link text is still there.
  }
}

/// The site icon of [url], [size] square. Starts loading the card at once
/// (so the icon is ready before anyone looks), and shows the neutral link
/// glyph until the icon arrives or when the site has none.
class LinkFavicon extends StatefulWidget {
  const LinkFavicon({
    super.key,
    required this.url,
    required this.size,
    this.color,
  });

  final String url;
  final double size;

  /// Colour of the fallback glyph.
  final Color? color;

  @override
  State<LinkFavicon> createState() => _LinkFaviconState();
}

class _LinkFaviconState extends State<LinkFavicon> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(LinkFavicon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _load();
  }

  void _load() {
    _bytes = LinkPreviewService.peekIcon(widget.url);
    if (_bytes != null) return;
    final String url = widget.url;
    LinkPreviewService.icon(url).then((Uint8List? b) {
      if (!mounted || widget.url != url || b == null) return;
      setState(() => _bytes = b);
    });
  }

  @override
  Widget build(BuildContext context) {
    final double s = widget.size;
    final Widget glyph = HugeIcon(
      HugeIcons.link01,
      size: s * 0.86,
      color: widget.color ?? Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final Uint8List? bytes = _bytes;
    final double dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2;
    return SizedBox.square(
      dimension: s,
      child: bytes == null
          ? Center(child: glyph)
          : ClipRRect(
              borderRadius: BorderRadius.circular(kRadiusXs),
              child: Image.memory(
                bytes,
                width: s,
                height: s,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
                cacheWidth: (s * dpr).ceil().clamp(16, 256),
                errorBuilder: (_, _, _) => Center(child: glyph),
              ),
            ),
    );
  }
}

/// The floating card. With an og:image the picture fills the top at full
/// card width; without one the card is compact (title · site, description,
/// footer).
class LinkPreviewCard extends StatelessWidget {
  const LinkPreviewCard({super.key, required this.preview, this.onTap});

  final LinkPreview preview;
  final VoidCallback? onTap;

  static const double _pad = 12;

  String _compactTitle() {
    final String title = preview.title ?? shortUrlLabel(preview.url);
    final String? site = preview.siteName;
    if (site == null ||
        site == preview.host ||
        title.toLowerCase().contains(site.toLowerCase())) {
      return title;
    }
    return '$title · $site';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String? image = preview.imageUrl;
    final bool withImage = image != null;
    final TextStyle titleStyle =
        (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w600,
          fontSize: 13,
          height: 1.35,
        );
    final TextStyle descStyle = (theme.textTheme.bodySmall ?? const TextStyle())
        .copyWith(color: scheme.onSurfaceVariant, fontSize: 12.5, height: 1.4);
    final TextStyle footStyle = descStyle.copyWith(fontSize: 12);

    final Widget footer = Row(
      children: <Widget>[
        LinkFavicon(url: preview.url, size: 14),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            shortUrlLabel(preview.url),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: footStyle,
          ),
        ),
        const SizedBox(width: 8),
        HugeIcon(
          HugeIcons.arrowUpRight01,
          size: 14,
          color: scheme.onSurfaceVariant,
        ),
      ],
    );

    final String? description = preview.description;
    final Widget body = Padding(
      padding: const EdgeInsets.all(_pad),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            withImage
                ? (preview.title ?? shortUrlLabel(preview.url))
                : _compactTitle(),
            maxLines: withImage ? 2 : 1,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          ),
          if (description != null) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              description,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: descStyle,
            ),
          ],
          const SizedBox(height: 8),
          footer,
        ],
      ),
    );

    return Semantics(
      link: true,
      label: preview.title ?? preview.host,
      child: Material(
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusLg),
          side: BorderSide(color: scheme.outlineVariant, width: 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          mouseCursor: onTap == null
              ? MouseCursor.defer
              : SystemMouseCursors.click,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (withImage)
                AspectRatio(
                  aspectRatio: 1.91,
                  child: _ProxiedImage(url: image),
                ),
              body,
            ],
          ),
        ),
      ),
    );
  }
}

/// A picture loaded through the server proxy (never from the site itself).
/// While it loads, and when it fails, the slot keeps a quiet fill so the
/// card does not jump.
class _ProxiedImage extends StatefulWidget {
  const _ProxiedImage({required this.url});

  final String url;

  @override
  State<_ProxiedImage> createState() => _ProxiedImageState();
}

class _ProxiedImageState extends State<_ProxiedImage> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = LinkPreviewService.peekImage(widget.url);
    if (_bytes == null) {
      final String url = widget.url;
      LinkPreviewService.image(url).then((Uint8List? b) {
        if (!mounted || widget.url != url || b == null) return;
        setState(() => _bytes = b);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget empty = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
    );
    final Uint8List? bytes = _bytes;
    if (bytes == null) return empty;
    final double dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2;
    return Image.memory(
      bytes,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      cacheWidth: (kLinkPreviewCardWidth * dpr).round().clamp(64, 2048),
      errorBuilder: (_, _, _) => empty,
    );
  }
}

/// Tap recognizer for a link span: a short tap calls [onOpen], a long press
/// (touch) shows the preview card instead. One recognizer, because a span
/// carries only one; the long press is a timer on tap-down, which fires
/// before a surrounding SelectionArea starts selecting (500 ms).
TapGestureRecognizer linkPreviewRecognizer(
  BuildContext context,
  String url,
  VoidCallback onOpen,
) {
  Timer? timer;
  bool longPressed = false;
  return TapGestureRecognizer()
    ..onTapDown = (TapDownDetails d) {
      longPressed = false;
      timer?.cancel();
      if (d.kind == PointerDeviceKind.mouse) return;
      timer = Timer(LinkPreviewHover.longPressDelay, () {
        longPressed = true;
        if (context.mounted) {
          unawaited(
            LinkPreviewHover.showForTouch(context, url, d.globalPosition),
          );
        }
      });
    }
    ..onTapCancel = () {
      timer?.cancel();
    }
    ..onTap = () {
      timer?.cancel();
      if (longPressed) {
        longPressed = false;
        return;
      }
      LinkPreviewHover.hide();
      onOpen();
    };
}

/// The floating card: on mouse hover (desktop) and on long press (touch).
class LinkPreviewHover {
  LinkPreviewHover._();

  static const Duration showDelay = Duration(milliseconds: 400);
  static const Duration hideDelay = Duration(milliseconds: 180);
  static const Duration longPressDelay = Duration(milliseconds: 420);

  static OverlayEntry? _entry;
  static String? _url;
  static Timer? _showTimer;
  static Timer? _hideTimer;
  static bool _overCard = false;

  /// Whether a card is on screen (tests).
  @visibleForTesting
  static bool get isShowing => _entry != null;

  /// Mouse entered a link pointing at [url].
  static void enter(BuildContext context, String url, PointerEnterEvent event) {
    if (!isPreviewableUrl(url)) return;
    if (event.kind != PointerDeviceKind.mouse) return;
    _hideTimer?.cancel();
    if (_url == url && _entry != null) return;
    _showTimer?.cancel();
    final Offset at = event.position;
    unawaited(LinkPreviewService.get(url)); // warm while the delay runs
    _showTimer = Timer(showDelay, () async {
      final LinkPreview? preview = await LinkPreviewService.get(url);
      if (preview == null || !context.mounted) return;
      _show(context, url, preview, at, touch: false);
    });
  }

  /// Mouse left the link.
  static void exit() {
    _showTimer?.cancel();
    _scheduleHide();
  }

  /// Long press on a link (touch).
  static Future<void> showForTouch(
    BuildContext context,
    String url,
    Offset at,
  ) async {
    if (!isPreviewableUrl(url)) return;
    final LinkPreview? preview = await LinkPreviewService.get(url);
    if (preview == null || !context.mounted) return;
    unawaited(HapticFeedback.selectionClick());
    _show(context, url, preview, at, touch: true);
  }

  static void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(hideDelay, () {
      if (!_overCard) hide();
    });
  }

  static void hide() {
    _showTimer?.cancel();
    _hideTimer?.cancel();
    _entry?.remove();
    _entry = null;
    _url = null;
    _overCard = false;
  }

  static void _show(
    BuildContext context,
    String url,
    LinkPreview preview,
    Offset at, {
    required bool touch,
  }) {
    final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    hide();
    _url = url;
    final RenderBox? box = overlay.context.findRenderObject() as RenderBox?;
    final Offset local = box?.globalToLocal(at) ?? at;
    final Widget card = LinkPreviewCard(
      preview: preview,
      onTap: () {
        hide();
        _openLink(preview.url);
      },
    );
    final OverlayEntry entry = OverlayEntry(
      builder: (BuildContext ctx) {
        final Size size = MediaQuery.sizeOf(ctx);
        // Close to the link: above it when there is room (like Grok), else
        // below. The pointer sits about mid-line: half a line plus a gap.
        const double gap = 16;
        final double estimated = preview.imageUrl != null ? 300 : 130;
        final bool above = local.dy - gap - estimated > 8;
        final double left = (local.dx - 40).clamp(
          8.0,
          (size.width - kLinkPreviewCardWidth - 8).clamp(8.0, double.infinity),
        );
        final Widget positioned = Positioned(
          left: left,
          top: above ? null : local.dy + gap,
          bottom: above ? size.height - local.dy + gap : null,
          width: kLinkPreviewCardWidth,
          child: MouseRegion(
            onEnter: (_) {
              _overCard = true;
              _hideTimer?.cancel();
            },
            onExit: (_) {
              _overCard = false;
              _scheduleHide();
            },
            child: _CardFrame(above: above, child: card),
          ),
        );
        if (!touch) return positioned;
        // Touch: a tap anywhere else closes the card.
        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: hide,
                onVerticalDragStart: (_) => hide(),
              ),
            ),
            positioned,
          ],
        );
      },
    );
    _entry = entry;
    overlay.insert(entry);
  }
}

class _CardFrame extends StatefulWidget {
  const _CardFrame({required this.above, required this.child});

  final bool above;
  final Widget child;

  @override
  State<_CardFrame> createState() => _CardFrameState();
}

class _CardFrameState extends State<_CardFrame>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final CurvedAnimation curve = CurvedAnimation(
      parent: _c,
      curve: Curves.easeOutCubic,
    );
    // A small neutral shadow, like the menus (DESIGN.md §6, §8: no glow).
    return FadeTransition(
      opacity: curve,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.97, end: 1).animate(curve),
        alignment: widget.above ? Alignment.bottomLeft : Alignment.topLeft,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(kRadiusLg),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x24000000),
                blurRadius: 14,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
