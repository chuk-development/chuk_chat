import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:url_launcher/url_launcher.dart';

import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/utils/favicon.dart';
import 'package:chuk_chat/voice/voice_call_models.dart';
import 'package:chuk_chat/voice/voice_image_cards.dart';
import 'package:chuk_chat/voice/widgets/voice_agent_card.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';

/// Card kinds that never lift the bars: a search stays a line under them.
const Set<String> kVoiceSearchCardKinds = <String>{'search', 'news'};

/// Tools that show the search line while they run.
const Set<String> kVoiceSearchTools = <String>{
  'search_web',
  'read_page',
  'get_news',
};

const double kVoiceStageRadius = 28;

/// The rounded sheet under the bars.
class VoiceStageFrame extends StatelessWidget {
  const VoiceStageFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(kVoiceStageRadius),
        border: Border.all(color: scheme.outline),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(kVoiceStageRadius - 1),
        child: child,
      ),
    );
  }
}

/// A small pill laid over a picture: an icon and an optional word.
class VoiceStageChip extends StatelessWidget {
  const VoiceStageChip({super.key, required this.icon, this.label, this.dot});

  final HugeIconData icon;
  final String? label;

  /// A coloured dot before the icon (the live camera).
  final Color? dot;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(8, 6, label == null ? 8 : 10, 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (dot != null) ...<Widget>[
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
            ],
            HugeIcon(icon, size: 14, color: scheme.onSurface),
            if (label != null) ...<Widget>[
              const SizedBox(width: 6),
              Text(
                label!,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The live camera: the local track, a live mark and the flip control.
class VoiceCameraStage extends StatelessWidget {
  const VoiceCameraStage({
    super.key,
    required this.track,
    required this.mirrored,
    required this.onFlip,
  });

  final lk.VideoTrack? track;
  final bool mirrored;
  final VoidCallback onFlip;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final lk.VideoTrack? live = track;
    return Stack(
      key: const ValueKey('voice-camera-preview'),
      fit: StackFit.expand,
      children: <Widget>[
        if (live != null)
          lk.VideoTrackRenderer(
            live,
            fit: lk.VideoViewFit.cover,
            mirrorMode: mirrored
                ? lk.VideoViewMirrorMode.mirror
                : lk.VideoViewMirrorMode.off,
          )
        else
          Center(
            child: Text(
              'Starting camera…',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        Positioned(
          left: 12,
          top: 12,
          child: Semantics(
            label: 'Your camera',
            child: VoiceStageChip(icon: HugeIcons.camera01, dot: scheme.error),
          ),
        ),
        if (live != null)
          Positioned(
            right: 10,
            bottom: 10,
            child: Semantics(
              identifier: 'voice-switch-camera',
              child: FloatingHeaderButton(
                tooltip: 'Switch camera',
                onPressed: onFlip,
                hugeIcon: HugeIcons.repeat,
              ),
            ),
          ),
      ],
    );
  }
}

/// What the agent put on screen: a picture, found pictures, a set of
/// places, or any other card. Searches are not drawn here.
class VoiceCardStage extends StatelessWidget {
  const VoiceCardStage({super.key, required this.card, required this.onClose});

  final VoiceCard card;
  final VoidCallback onClose;

  /// Places draw as their own floating cards, without the frame.
  static bool isFrameless(VoiceCard card) =>
      _placeKinds.contains(card.kind) && _places(card).isNotEmpty;

  static const Set<String> _placeKinds = <String>{'places', 'hotels', 'stays'};

  static List<Map<String, dynamic>> _places(VoiceCard card) =>
      card.list('items');

  @override
  Widget build(BuildContext context) {
    final Widget close = Positioned(
      right: 5,
      top: 8,
      child: _CloseChip(onTap: onClose),
    );
    if (isFrameless(card)) {
      return Stack(
        children: <Widget>[
          Positioned.fill(
            child: VoicePlaceCarousel(
              key: ValueKey(card.id),
              places: _places(card),
            ),
          ),
          close,
        ],
      );
    }
    final Widget body = switch (card.kind) {
      'image' when card.data['generating'] == true => const _GeneratingImage(),
      'image' when _imageUrl(card) != null => _GeneratedImage(card: card),
      'images' when card.list('items').isNotEmpty => _FoundImages(card: card),
      _ => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
        child: VoiceAgentCard(card: card),
      ),
    };
    return VoiceStageFrame(
      child: Stack(fit: StackFit.expand, children: <Widget>[body, close]),
    );
  }
}

class _CloseChip extends StatelessWidget {
  const _CloseChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The app's close chip: opaque, so it reads over any card image.
    return FloatingHeaderButton(
      tooltip: 'Hide',
      onPressed: onTap,
      hugeIcon: HugeIcons.cancel01,
    );
  }
}

String? _hostOf(Object? url) {
  final Uri? uri = Uri.tryParse(url?.toString().trim() ?? '');
  if (uri == null || !uri.hasAuthority) return null;
  final String host = uri.host;
  return host.startsWith('www.') ? host.substring(4) : host;
}

void _openLink(Object? url) {
  final Uri? uri = Uri.tryParse(url?.toString().trim() ?? '');
  if (uri == null || !uri.hasAuthority) return;
  if (uri.scheme != 'https' && uri.scheme != 'http') return;
  unawaited(
    launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    ).then((_) {}, onError: (Object _) {}),
  );
}

String? _imageUrl(VoiceCard card) => resolveVoiceImageUrl(card.text('url'));

class _GeneratingImage extends StatelessWidget {
  const _GeneratingImage();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            HugeIcon(
              HugeIcons.sparkles,
              size: 28,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 10),
            Text(
              'Generating image…',
              style: TextStyle(
                color: scheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _networkImage(BuildContext context, String url) {
  final ColorScheme scheme = Theme.of(context).colorScheme;
  return Image.network(
    url,
    fit: BoxFit.cover,
    gaplessPlayback: true,
    errorBuilder: (_, _, _) => ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: HugeIcon(
          HugeIcons.image01,
          size: 24,
          color: scheme.onSurfaceVariant,
        ),
      ),
    ),
    loadingBuilder: (_, Widget child, ImageChunkEvent? progress) =>
        progress == null
        ? child
        : ColoredBox(color: scheme.surfaceContainerHighest),
  );
}

class _GeneratedImage extends StatelessWidget {
  const _GeneratedImage({required this.card});

  final VoiceCard card;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        _networkImage(context, _imageUrl(card)!),
        Positioned(
          left: 12,
          top: 12,
          child: VoiceStageChip(
            icon: card.source == null ? HugeIcons.sparkles : HugeIcons.image01,
            label: card.title.isEmpty || card.title == 'Image'
                ? null
                : card.title,
          ),
        ),
      ],
    );
  }
}

class _FoundImages extends StatelessWidget {
  const _FoundImages({required this.card});

  final VoiceCard card;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<Map<String, dynamic>> items = card
        .list('items')
        .take(4)
        .toList();
    Widget tile(Map<String, dynamic> item) {
      final String? url = (item['url'] ?? item['image'])?.toString();
      final String? host = _hostOf(item['source'] ?? item['page'] ?? url);
      return ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: GestureDetector(
          onTap: () => _openLink(item['page'] ?? item['source'] ?? url),
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              if (url != null)
                _networkImage(context, url)
              else
                ColoredBox(color: scheme.surfaceContainerHighest),
              if (host != null)
                Positioned(
                  left: 8,
                  bottom: 8,
                  child: FaviconImage(
                    host: host,
                    size: 18,
                    fallbackColor: scheme.onSurface,
                    borderRadius: 4,
                  ),
                ),
            ],
          ),
        ),
      );
    }

    final List<Widget> rows = <Widget>[];
    for (var i = 0; i < items.length; i += 2) {
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 8));
      rows.add(
        Expanded(
          child: Row(
            children: <Widget>[
              Expanded(child: tile(items[i])),
              const SizedBox(width: 8),
              Expanded(
                child: i + 1 < items.length
                    ? tile(items[i + 1])
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(children: rows),
    );
  }
}

/// Places as separate cards floating on the page. The next one peeks in;
/// swipe, the dots or the arrow move along.
class VoicePlaceCarousel extends StatefulWidget {
  const VoicePlaceCarousel({super.key, required this.places});

  final List<Map<String, dynamic>> places;

  @override
  State<VoicePlaceCarousel> createState() => _VoicePlaceCarouselState();
}

class _VoicePlaceCarouselState extends State<VoicePlaceCarousel> {
  static const double _fraction = 0.86;
  final PageController _pages = PageController(viewportFraction: _fraction);
  int _index = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _go(int index) {
    unawaited(
      _pages.animateToPage(
        index,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final int count = widget.places.length;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final double inset = box.maxWidth * (1 - _fraction) / 2 + 6;
        return Column(
          children: <Widget>[
            Expanded(
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context)
                    .copyWith(dragDevices: PointerDeviceKind.values.toSet()),
                child: PageView.builder(
                  controller: _pages,
                  itemCount: count,
                  onPageChanged: (int i) => setState(() => _index = i),
                  itemBuilder: (BuildContext context, int i) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: _PlaceCard(place: widget.places[i]),
                  ),
                ),
              ),
            ),
            if (count > 1)
              Padding(
                padding: EdgeInsets.fromLTRB(inset, 10, inset - 8, 0),
                child: Row(
                  children: <Widget>[
                    for (var i = 0; i < count; i++)
                      GestureDetector(
                        onTap: () => _go(i),
                        behavior: HitTestBehavior.opaque,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 3,
                            vertical: 8,
                          ),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 220),
                            width: i == _index ? 18 : 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: i == _index
                                  ? scheme.primary
                                  : scheme.onSurface.withValues(alpha: 0.24),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(width: 10),
                    Text(
                      '${_index + 1} / $count',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Next',
                      onPressed: () => _go((_index + 1) % count),
                      icon: HugeIcon(
                        HugeIcons.arrowRight01,
                        size: 20,
                        color: scheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _PlaceCard extends StatelessWidget {
  const _PlaceCard({required this.place});

  final Map<String, dynamic> place;

  String? _text(String key) {
    final Object? v = place[key];
    if (v == null) return null;
    final String s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String title = _text('name') ?? _text('title') ?? '';
    final String? where = _text('location') ?? _text('address');
    final String? rating = _text('rating');
    final String? price = _text('price');
    final String? unit = _text('price_unit');
    final String? badge = _text('badge');
    final String? image = _text('image') ?? _text('image_url');
    final String? url = _text('url');
    final List<String> tags = <String>[
      if (place['tags'] is List)
        for (final Object? t in place['tags'] as List)
          if (t != null && t.toString().trim().isNotEmpty) t.toString().trim(),
    ].take(3).toList();

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(kVoiceStageRadius),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    if (image != null)
                      _networkImage(context, image)
                    else
                      ColoredBox(color: scheme.surfaceContainerHighest),
                    if (badge != null)
                      Positioned(
                        left: 10,
                        top: 10,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            child: Text(
                              badge,
                              style: TextStyle(
                                color: scheme.onSurface,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (where != null || rating != null) ...<Widget>[
                    const SizedBox(height: 4),
                    Row(
                      children: <Widget>[
                        if (where != null) ...<Widget>[
                          HugeIcon(
                            HugeIcons.mapPin,
                            size: 14,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              where,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: scheme.onSurfaceVariant,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                        if (rating != null) ...<Widget>[
                          const SizedBox(width: 10),
                          HugeIcon(
                            HugeIcons.star,
                            size: 14,
                            color: scheme.primary,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            rating,
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                  if (tags.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        for (final String tag in tags)
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              child: Text(
                                tag,
                                style: TextStyle(
                                  color: scheme.onSurface,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      if (price != null)
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              children: <InlineSpan>[
                                TextSpan(
                                  text: price,
                                  style: TextStyle(
                                    color: scheme.onSurface,
                                    fontSize: 19,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (unit != null)
                                  TextSpan(
                                    text: ' $unit',
                                    style: TextStyle(
                                      color: scheme.onSurfaceVariant,
                                      fontSize: 13,
                                    ),
                                  ),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        )
                      else
                        const Spacer(),
                      if (url != null)
                        Material(
                          color: scheme.primary,
                          shape: const StadiumBorder(),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => _openLink(url),
                            child: SizedBox(
                              height: 44,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                ),
                                child: Center(
                                  child: Text(
                                    'Details',
                                    style: TextStyle(
                                      color: scheme.onPrimary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One small line under the bars while the agent searches. Then it walks
/// the sources the search came back with: favicon and host, then the
/// favicon alone, and drops away.
class VoiceSearchLine extends StatefulWidget {
  const VoiceSearchLine({
    super.key,
    required this.searching,
    required this.label,
    this.result,
  });

  /// A search tool is running.
  final bool searching;

  /// What the running tool says it does.
  final String label;

  /// The newest search card; its hosts are walked once when it arrives.
  final VoiceCard? result;

  @override
  State<VoiceSearchLine> createState() => _VoiceSearchLineState();
}

class _VoiceSearchLineState extends State<VoiceSearchLine> {
  static const Duration _step = Duration(milliseconds: 900);

  Timer? _timer;
  List<String> _hosts = const <String>[];
  int _tick = 0;
  String? _shownId;

  @override
  void initState() {
    super.initState();
    _shownId = widget.result?.id;
  }

  @override
  void didUpdateWidget(covariant VoiceSearchLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    final VoiceCard? result = widget.result;
    if (result != null && result.id != _shownId) {
      _shownId = result.id;
      _walk(result);
    }
  }

  void _walk(VoiceCard card) {
    final List<String> hosts = <String>[];
    for (final Map<String, dynamic> entry in <Map<String, dynamic>>[
      ...card.list('results'),
      ...card.list('items'),
    ]) {
      final String? host = _hostOf(entry['url']);
      if (host != null && !hosts.contains(host)) hosts.add(host);
      if (hosts.length == 3) break;
    }
    _timer?.cancel();
    if (hosts.isEmpty) return;
    setState(() {
      _hosts = hosts;
      _tick = 0;
    });
    _timer = Timer.periodic(_step, (Timer timer) {
      if (!mounted) return;
      setState(() => _tick++);
      if (_tick >= _hosts.length * 2) {
        timer.cancel();
        setState(() => _hosts = const <String>[]);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color ink = scheme.onSurface.withValues(alpha: 0.7);
    final TextStyle style = TextStyle(color: ink, fontSize: 13);
    Widget? line;
    if (_hosts.isNotEmpty) {
      final String host = _hosts[(_tick ~/ 2).clamp(0, _hosts.length - 1)];
      line = Row(
        key: ValueKey('$host-${_tick.isEven}'),
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FaviconImage(
            key: ValueKey(host),
            host: host,
            size: 16,
            fallbackColor: ink,
            borderRadius: 3,
          ),
          if (_tick.isEven) ...<Widget>[
            const SizedBox(width: 8),
            Text(host, style: style),
          ],
        ],
      );
    } else if (widget.searching) {
      line = Row(
        key: const ValueKey('searching'),
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          HugeIcon(HugeIcons.search01, size: 16, color: ink),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              widget.label,
              style: style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }
    return SizedBox(
      height: 24,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: line ?? const SizedBox.shrink(),
      ),
    );
  }
}
