// lib/widgets/map_features_block.dart
//
// Renders the `features` form of a <map> block: closures as red lines,
// roadworks orange, detours dashed blue, areas as polygons, each with an
// icon, a legend row and a detail sheet (what, when, detour).
//
// Coordinates the model wrote draw at once; named roads, areas and feed
// refs are looked up by `MapFeatureResolver` and appear when they arrive.
// A feature that cannot be resolved stays in the legend, marked as not on
// the map, so bad data never blanks the block.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:chuk_chat/services/map_feature_resolver.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/utils/map_features.dart';
import 'package:chuk_chat/utils/map_geometry.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/widgets/icons/huge_icon.dart';
import 'package:chuk_chat/widgets/map_tiles.dart';

/// Fixed signal colours: they mean the same on every theme, like road signs.
Color mapFeatureColor(MapFeatureKind kind) => switch (kind) {
  MapFeatureKind.closure => const Color(0xFFD32F2F),
  MapFeatureKind.roadworks => const Color(0xFFEF6C00),
  MapFeatureKind.detour => const Color(0xFF1E6FD9),
  MapFeatureKind.info => const Color(0xFF546E7A),
};

HugeIconData _kindIcon(MapFeatureKind kind) => switch (kind) {
  MapFeatureKind.closure => HugeIcons.minusSignCircle,
  MapFeatureKind.roadworks => HugeIcons.alert02,
  MapFeatureKind.detour => HugeIcons.route01,
  MapFeatureKind.info => HugeIcons.informationCircle,
};

String _kindName(BuildContext context, MapFeatureKind kind) {
  final de = Localizations.maybeLocaleOf(context)?.languageCode == 'de';
  return switch (kind) {
    MapFeatureKind.closure => de ? 'Sperrung' : 'Closure',
    MapFeatureKind.roadworks => de ? 'Baustelle' : 'Roadworks',
    MapFeatureKind.detour => de ? 'Umleitung' : 'Detour',
    MapFeatureKind.info => de ? 'Hinweis' : 'Note',
  };
}

bool _isDe(BuildContext context) =>
    Localizations.maybeLocaleOf(context)?.languageCode == 'de';

/// Holds the specs of one block and their geometry as it resolves.
class _FeatureState {
  _FeatureState(this.spec) : geometry = spec.inlineGeometry;

  final MapFeatureSpec spec;
  ResolvedGeometry geometry;
  bool resolving = false;
}

class MapFeaturesBlock extends StatefulWidget {
  const MapFeaturesBlock({super.key, required this.data});

  final Map<String, dynamic> data;

  @override
  State<MapFeaturesBlock> createState() => _MapFeaturesBlockState();
}

class _MapFeaturesBlockState extends State<MapFeaturesBlock> {
  late MapFeaturesBlockData _block;
  late List<_FeatureState> _features;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant MapFeaturesBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data.toString() != widget.data.toString()) _load();
  }

  void _load() {
    _generation++;
    final gen = _generation;
    _block = parseMapFeatures(widget.data);
    _features = _block.features.map(_FeatureState.new).toList();
    for (final f in _features) {
      if (!f.spec.needsResolve) continue;
      f.resolving = true;
      unawaited(
        MapFeatureResolver.instance.resolve(f.spec).then((g) {
          if (!mounted || gen != _generation) return;
          setState(() {
            f.geometry = f.spec.inlineGeometry.merge(g);
            f.resolving = false;
          });
        }),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_features.isEmpty) return const SizedBox.shrink();
    final resolving = _features.any((f) => f.resolving);
    final drawn = _features.where((f) => !f.geometry.isEmpty).toList();
    final title = _block.title;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
              child: Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: scheme.onSurface,
                ),
              ),
            ),
          SizedBox(
            height: _previewHeight(context),
            child: Stack(
              children: [
                Positioned.fill(
                  child: drawn.isEmpty
                      ? _EmptyMap(resolving: resolving)
                      : GestureDetector(
                          onTap: () => _openFullscreen(context),
                          child: AbsorbPointer(
                            child: _FeaturesMap(
                              // Recreate when geometry arrives, so the camera
                              // fits the new extent.
                              key: ValueKey(_fitKey(drawn)),
                              features: drawn,
                              interactive: false,
                            ),
                          ),
                        ),
                ),
                if (drawn.isNotEmpty)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: _MapChip(
                      icon: HugeIcons.maps,
                      label: _isDe(context) ? 'Vollbild' : 'Expand',
                      onTap: () => _openFullscreen(context),
                    ),
                  ),
                if (resolving && drawn.isNotEmpty)
                  const Positioned(
                    left: 10,
                    top: 10,
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
          ),
          for (var i = 0; i < _features.length; i++)
            _LegendRow(
              state: _features[i],
              onTap: () => showMapFeatureDetails(context, _features[i].spec),
            ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  void _openFullscreen(BuildContext context) {
    final drawn = _features.where((f) => !f.geometry.isEmpty).toList();
    if (drawn.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _FeaturesFullscreenPage(
          title: _block.title ?? (_isDe(context) ? 'Karte' : 'Map'),
          features: drawn,
        ),
      ),
    );
  }
}

String _fitKey(List<_FeatureState> drawn) => drawn
    .map((f) => '${f.geometry.allPoints.length}')
    .join(',');

double _previewHeight(BuildContext context) {
  final h = MediaQuery.sizeOf(context).height;
  if (h < 600) return 200;
  if (h < 800) return 240;
  return 280;
}

class _EmptyMap extends StatelessWidget {
  const _EmptyMap({required this.resolving});

  final bool resolving;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final de = _isDe(context);
    return ColoredBox(
      color: scheme.surfaceContainerHigh,
      child: Center(
        child: resolving
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    de ? 'Straßenverlauf wird geladen' : 'Loading road geometry',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ],
              )
            : Text(
                de
                    ? 'Kein Ort konnte auf der Karte gefunden werden'
                    : 'None of these places could be found on the map',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
      ),
    );
  }
}

class _MapChip extends StatelessWidget {
  const _MapChip({required this.icon, required this.label, this.onTap});

  final HugeIconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              HugeIcon(icon, size: 15, color: Colors.white),
              const SizedBox(width: 5),
              Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The round kind badge used on the map and in the legend.
class _KindBadge extends StatelessWidget {
  const _KindBadge({required this.kind, this.size = 28});

  final MapFeatureKind kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: mapFeatureColor(kind),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: HugeIcon(_kindIcon(kind), size: size * 0.55, color: Colors.white),
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({required this.state, required this.onTap});

  final _FeatureState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final spec = state.spec;
    final missing = !state.resolving && state.geometry.isEmpty;
    final sub = [
      _kindName(context, spec.kind),
      ?spec.dates,
      if (missing) _isDe(context) ? 'nicht auf der Karte' : 'not on the map',
    ].join(' · ');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _KindBadge(kind: spec.kind, size: 26),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    spec.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                  Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            HugeIcon(
              HugeIcons.arrowRight01,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// The map itself, shared by the preview and the full screen page.
class _FeaturesMap extends StatefulWidget {
  const _FeaturesMap({
    super.key,
    required this.features,
    required this.interactive,
    this.onFeatureTap,
  });

  final List<_FeatureState> features;
  final bool interactive;
  final void Function(MapFeatureSpec spec)? onFeatureTap;

  @override
  State<_FeaturesMap> createState() => _FeaturesMapState();
}

class _FeaturesMapState extends State<_FeaturesMap> {
  final LayerHitNotifier<int> _lineHits = ValueNotifier(null);
  final LayerHitNotifier<int> _polygonHits = ValueNotifier(null);

  @override
  void dispose() {
    _lineHits.dispose();
    _polygonHits.dispose();
    super.dispose();
  }

  void _onHit(LayerHitNotifier<int> notifier) {
    final hit = notifier.value;
    final cb = widget.onFeatureTap;
    if (hit == null || hit.hitValues.isEmpty || cb == null) return;
    cb(widget.features[hit.hitValues.first].spec);
  }

  @override
  Widget build(BuildContext context) {
    final features = widget.features;
    final points = features.expand((f) => f.geometry.allPoints).toList();

    final polylines = <Polyline<int>>[];
    final polygons = <Polygon<int>>[];
    final markers = <Marker>[];
    // Detours under closures under roadworks markers: the closure is the
    // news, so it paints last.
    final order = List<int>.generate(features.length, (i) => i)
      ..sort(
        (a, b) => _paintRank(
          features[a].spec.kind,
        ).compareTo(_paintRank(features[b].spec.kind)),
      );
    for (final i in order) {
      final f = features[i];
      final color = mapFeatureColor(f.spec.kind);
      final dashed = f.spec.kind == MapFeatureKind.detour;
      for (final ring in f.geometry.polygons.where((p) => p.length >= 3)) {
        polygons.add(
          Polygon<int>(
            points: ring,
            color: color.withValues(alpha: 0.22),
            borderColor: color,
            borderStrokeWidth: 2.5,
            hitValue: i,
          ),
        );
      }
      for (final line in f.geometry.lines.where((l) => l.length >= 2)) {
        polylines.add(
          Polyline<int>(
            points: line,
            color: color,
            strokeWidth: dashed ? 4.5 : 6,
            borderColor: Colors.white,
            borderStrokeWidth: dashed ? 0 : 1.5,
            pattern: dashed
                ? StrokePattern.dashed(segments: const [12, 8])
                : const StrokePattern.solid(),
            hitValue: i,
          ),
        );
      }
      final anchor = f.geometry.labelPoint;
      if (anchor != null) {
        markers.add(
          Marker(
            point: anchor,
            width: 34,
            height: 34,
            child: GestureDetector(
              onTap: widget.onFeatureTap == null
                  ? null
                  : () => widget.onFeatureTap!(f.spec),
              child: Semantics(
                button: true,
                label: f.spec.label,
                child: _KindBadge(kind: f.spec.kind, size: 30),
              ),
            ),
          ),
        );
      }
    }

    final MapOptions options = hasPointSpread(points)
        ? MapOptions(
            maxZoom: kMapMaxZoom,
            initialCameraFit: CameraFit.bounds(
              bounds: LatLngBounds.fromPoints(points),
              padding: EdgeInsets.fromLTRB(
                40,
                widget.interactive ? 110 : 44,
                40,
                44,
              ),
              maxZoom: 17,
            ),
          )
        : MapOptions(
            maxZoom: kMapMaxZoom,
            initialCenter: points.isEmpty ? const LatLng(54.32, 10.13) : points.first,
            initialZoom: zoomForSpan(points),
          );

    return FlutterMap(
      options: options,
      children: [
        buildBaseTileLayer(),
        if (polygons.isNotEmpty)
          GestureDetector(
            onTap: () => _onHit(_polygonHits),
            child: PolygonLayer<int>(
              polygons: polygons,
              hitNotifier: widget.interactive ? _polygonHits : null,
            ),
          ),
        if (polylines.isNotEmpty)
          GestureDetector(
            onTap: () => _onHit(_lineHits),
            child: PolylineLayer<int>(
              polylines: polylines,
              hitNotifier: widget.interactive ? _lineHits : null,
            ),
          ),
        MarkerLayer(markers: markers),
        buildOsmAttribution(),
      ],
    );
  }
}

int _paintRank(MapFeatureKind kind) => switch (kind) {
  MapFeatureKind.detour => 0,
  MapFeatureKind.info => 1,
  MapFeatureKind.roadworks => 2,
  MapFeatureKind.closure => 3,
};

class _FeaturesFullscreenPage extends StatelessWidget {
  const _FeaturesFullscreenPage({required this.title, required this.features});

  final String title;
  final List<_FeatureState> features;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: FloatingAppBar(
        scrim: false,
        title: Text(title, style: const TextStyle(fontSize: 16)),
        leading: FloatingHeaderButton(
          icon: Icons.close,
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _FeaturesMap(
        features: features,
        interactive: true,
        onFeatureTap: (spec) => showMapFeatureDetails(context, spec),
      ),
    );
  }
}

/// The detail sheet of one feature: what, when, detour, source.
Future<void> showMapFeatureDetails(BuildContext context, MapFeatureSpec spec) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (ctx) => _FeatureDetails(spec: spec),
  );
}

class _FeatureDetails extends StatelessWidget {
  const _FeatureDetails({required this.spec});

  final MapFeatureSpec spec;

  @override
  Widget build(BuildContext context) {
    final de = _isDe(context);
    final url = spec.url;
    final where = [
      if (spec.road != null) spec.road!,
      if (spec.from?.street != null && spec.to?.street != null)
        de
            ? 'zwischen ${spec.from!.street} und ${spec.to!.street}'
            : 'between ${spec.from!.street} and ${spec.to!.street}',
      if (spec.areaName != null) spec.areaName!,
      if (spec.town != null) spec.town!,
    ].join(', ');

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _KindBadge(kind: spec.kind, size: 30),
                const SizedBox(width: 10),
                Text(
                  _kindName(context, spec.kind),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: mapFeatureColor(spec.kind),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              spec.label,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (where.isNotEmpty && where != spec.label)
              _DetailLine(icon: HugeIcons.mapPin, text: where),
            if (spec.dates != null)
              _DetailLine(icon: HugeIcons.calendar03, text: spec.dates!),
            if (spec.info != null)
              _DetailLine(icon: HugeIcons.informationCircle, text: spec.info!),
            if (spec.detour != null)
              _DetailLine(
                icon: HugeIcons.route01,
                text: '${de ? 'Umleitung' : 'Detour'}: ${spec.detour}',
              ),
            if (url != null && Uri.tryParse(url)?.hasScheme == true)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: ExpressiveButton(
                  icon: Icons.open_in_new,
                  label: de ? 'Quelle öffnen' : 'Open source',
                  tonal: true,
                  dense: true,
                  onTap: () => launchUrl(
                    Uri.parse(url),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.icon, required this.text});

  final HugeIconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 20,
            child: Center(
              child: HugeIcon(icon, size: 18, color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 14, height: 20 / 14, color: scheme.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}
