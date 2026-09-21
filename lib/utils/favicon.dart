import 'package:flutter/material.dart';

import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// Where a site logo is fetched from, best source first.
///
/// DuckDuckGo comes first on purpose. `google.com/s2/favicons` sits on the
/// tracker lists that Brave Shields, uBlock Origin and most content blockers
/// ship, so it is blocked for a large share of users — on the web build there
/// is nothing the app can do about that, and every source chip fell back to a
/// grey globe. DuckDuckGo's icon service is not on those lists, answers with
/// the image directly instead of a redirect to `gstatic.com`, and keeps
/// Google as the second try for hosts it does not know.
List<String> faviconUrls(String host, {int size = 64}) {
  final String clean = host.trim().toLowerCase();
  if (clean.isEmpty) return const <String>[];
  return <String>[
    'https://icons.duckduckgo.com/ip3/$clean.ico',
    'https://www.google.com/s2/favicons?domain=$clean&sz=$size',
  ];
}

/// The logo of [host], falling back through [faviconUrls] and ending on a
/// globe when every source fails or while the first one loads.
class FaviconImage extends StatefulWidget {
  const FaviconImage({
    super.key,
    required this.host,
    required this.size,
    required this.fallbackColor,
    this.borderRadius = 5,
    this.fallbackIcon = Icons.public_rounded,
  });

  final String host;
  final double size;
  final Color fallbackColor;
  final double borderRadius;
  final IconData fallbackIcon;

  @override
  State<FaviconImage> createState() => _FaviconImageState();
}

class _FaviconImageState extends State<FaviconImage> {
  int _attempt = 0;

  @override
  void didUpdateWidget(FaviconImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.host != widget.host) _attempt = 0;
  }

  @override
  Widget build(BuildContext context) {
    final List<String> urls = faviconUrls(
      widget.host,
      size: widget.size.round() * 2,
    );
    final Widget fallback = Center(
      child: AppIcon(
        widget.fallbackIcon,
        size: widget.size * 0.85,
        color: widget.fallbackColor,
      ),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: _attempt >= urls.length
            ? fallback
            : Image.network(
                urls[_attempt],
                width: widget.size,
                height: widget.size,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) {
                  // Try the next service on the next frame; setState during
                  // build is not allowed.
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && _attempt < urls.length) {
                      setState(() => _attempt++);
                    }
                  });
                  return fallback;
                },
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : fallback,
              ),
      ),
    );
  }
}
