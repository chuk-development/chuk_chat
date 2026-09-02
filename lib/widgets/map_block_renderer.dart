// lib/widgets/map_block_renderer.dart
//
// Parses and renders <map> blocks embedded in AI message text.
// The AI writes JSON inside <map>...</map> tags as part of its response.

import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:chuk_chat/pages/fullscreen_map_page.dart';
import 'package:chuk_chat/utils/input_validator.dart';
import 'package:chuk_chat/widgets/route_map_widget.dart';

/// Regex to find <map> blocks in message content.
final RegExp mapBlockRegex = RegExp(r'<map>([\s\S]*?)</map>', multiLine: true);

/// Returns true if [content] contains at least one <map> block.
bool hasMapBlocks(String content) => content.contains('<map>');

/// Splits message content into text segments and map widgets.
///
/// Use this from [_buildMessageBody] to interleave plain text with
/// rendered map blocks.
List<MapContentSegment> parseMapSegments(String content) {
  if (!hasMapBlocks(content)) {
    return [MapContentSegment.text(content)];
  }

  final segments = <MapContentSegment>[];
  var lastEnd = 0;

  for (final match in mapBlockRegex.allMatches(content)) {
    final textBefore = content.substring(lastEnd, match.start).trim();
    if (textBefore.isNotEmpty) {
      segments.add(MapContentSegment.text(textBefore));
    }

    final blockJson = match.group(1)!.trim();
    segments.add(MapContentSegment.map(blockJson));
    lastEnd = match.end;
  }

  final textAfter = content.substring(lastEnd).trim();
  if (textAfter.isNotEmpty) {
    segments.add(MapContentSegment.text(textAfter));
  }

  return segments;
}

/// A segment of message content — either plain text or a map block.
class MapContentSegment {
  final bool isMap;
  final String content;

  const MapContentSegment._(this.isMap, this.content);
  factory MapContentSegment.text(String text) =>
      MapContentSegment._(false, text);
  factory MapContentSegment.map(String json) => MapContentSegment._(true, json);
}

/// Renders a single <map> JSON block as a Flutter widget.
class MapBlockWidget extends StatelessWidget {
  final String jsonString;

  const MapBlockWidget({super.key, required this.jsonString});

  @override
  Widget build(BuildContext context) {
    try {
      final parsed = _tryParseJson(jsonString);
      if (parsed is! Map<String, dynamic>) {
        throw FormatException(
          'Expected JSON object, got ${parsed.runtimeType}',
        );
      }
      final data = parsed;
      final type = data['type'] as String? ?? 'markers';
      return switch (type) {
        'markers' => _MarkersMapBlock(data: data),
        'places' => _PlacesMapBlock(data: data),
        'route' => _RouteMapBlock(data: data),
        _ => _MarkersMapBlock(data: data),
      };
    } catch (e) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).colorScheme.errorContainer.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          'Map parse error: $e',
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.error,
          ),
        ),
      );
    }
  }

  /// Lenient JSON parser — handles common LLM mistakes like trailing commas.
  static dynamic _tryParseJson(String raw) {
    var s = raw.trim();
    try {
      return jsonDecode(s);
    } catch (_) {}
    // Strip trailing ] if the JSON is an object
    if (s.startsWith('{') && s.endsWith(']')) {
      s = s.substring(0, s.length - 1).trim();
      if (s.endsWith('}')) {
        try {
          return jsonDecode(s);
        } catch (_) {}
      }
    }
    // Strip trailing commas before } or ]
    s = s.replaceAll(RegExp(r',\s*([}\]])'), r'$1');
    try {
      return jsonDecode(s);
    } catch (_) {}
    return jsonDecode(raw.trim());
  }
}

// ──────────────────────────────────────────────────────────
// Shared helpers
// ──────────────────────────────────────────────────────────

// Esri World Gray Canvas basemaps — keyless, clean light/dark grey styles that
// match the app's minimal look. Note the {z}/{y}/{x} order (y before x) and the
// single host (no {s} subdomain). Replaces CARTO, whose anonymous tiles started
// baking a "get an API key" watermark into the image itself.
const String _kLightTilesUrl =
    'https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Light_Gray_Base/MapServer/tile/{z}/{y}/{x}';
const String _kDarkTilesUrl =
    'https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Base/MapServer/tile/{z}/{y}/{x}';
const List<String> _kTileSubdomains = <String>[];

String _tileUrlForBrightness(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? _kDarkTilesUrl
      : _kLightTilesUrl;
}

double _toDouble(dynamic v) {
  if (v is num) {
    final d = v.toDouble();
    return d.isFinite ? d : 0.0;
  }
  if (v is String) {
    final d = double.tryParse(v);
    return (d != null && d.isFinite) ? d : 0.0;
  }
  return 0.0;
}

bool _isValidLatLon(dynamic latRaw, dynamic lonRaw) {
  if (latRaw == null || lonRaw == null) return false;
  final lat = _toDouble(latRaw);
  final lon = _toDouble(lonRaw);
  if (!lat.isFinite || !lon.isFinite) return false;
  if (lat < -90 || lat > 90) return false;
  if (lon < -180 || lon > 180) return false;
  // _toDouble silently coerces garbage like `"abc"` or `{}` to 0.0, which
  // would otherwise paint a marker on Null Island. Only accept (0,0) when
  // the raw inputs were actually numeric zeros.
  if (lat == 0.0 && lon == 0.0) {
    return _isExplicitNumericZero(latRaw) && _isExplicitNumericZero(lonRaw);
  }
  return true;
}

bool _isExplicitNumericZero(dynamic v) {
  if (v is num) return v == 0;
  if (v is String) {
    final parsed = double.tryParse(v);
    return parsed != null && parsed == 0;
  }
  return false;
}

List<Map<String, dynamic>> _filterValidCoordItems(
  List<dynamic>? items,
) {
  if (items == null) return const [];
  final valid = items
      .whereType<Map<String, dynamic>>()
      .where((m) => _isValidLatLon(m['lat'], m['lon']))
      .toList();
  return _dedupeCoordItems(valid);
}

/// Drops repeated places / markers from one block. A multi-pass answer often
/// lists the same restaurant twice — once per tool round — which put the same
/// pin and the same card on screen twice.
///
/// Two entries are the same when they carry the same name (case-insensitive)
/// AND sit at the same coordinates to five decimals (~1 m); when neither is
/// named, the coordinates alone decide. So a chain's two branches with one
/// name stay separate — merging them by name would drop a marker — while the
/// same place returned twice at one spot folds into one. The first entry wins
/// and the later copy only fills fields the first one is missing, so a
/// duplicate that carries the phone number is not thrown away.
List<Map<String, dynamic>> _dedupeCoordItems(List<Map<String, dynamic>> items) {
  final byKey = <String, Map<String, dynamic>>{};
  final ordered = <Map<String, dynamic>>[];

  for (final item in items) {
    final name = (item['name'] ?? item['label'] ?? '').toString().trim();
    final coordKey = '${_toDouble(item['lat']).toStringAsFixed(5)},'
        '${_toDouble(item['lon']).toStringAsFixed(5)}';
    final key = name.isNotEmpty ? 'n:${name.toLowerCase()}:$coordKey' : 'c:$coordKey';

    final existing = byKey[key];
    if (existing == null) {
      final copy = Map<String, dynamic>.of(item);
      byKey[key] = copy;
      ordered.add(copy);
      continue;
    }
    item.forEach((field, value) {
      final present = existing[field];
      final isEmpty = present == null ||
          (present is String && present.trim().isEmpty);
      if (isEmpty && value != null) existing[field] = value;
    });
  }

  return ordered;
}

/// Test-only view of [_filterValidCoordItems] + [_dedupeCoordItems].
@visibleForTesting
List<Map<String, dynamic>> debugFilterAndDedupeCoordItems(List<dynamic>? items) =>
    _filterValidCoordItems(items);

double _mapPreviewHeight(BuildContext context) {
  final h = MediaQuery.of(context).size.height;
  if (h < 600) return 180;
  if (h < 800) return 220;
  return 260;
}

double _calculateZoom(List<double> lats, List<double> lons) {
  if (lats.length <= 1) return 14;
  final latSpan = lats.reduce(max) - lats.reduce(min);
  final lonSpan = lons.reduce(max) - lons.reduce(min);
  final maxSpan = max(latSpan, lonSpan);

  if (maxSpan < 0.005) return 16;
  if (maxSpan < 0.01) return 15;
  if (maxSpan < 0.02) return 14;
  if (maxSpan < 0.05) return 13;
  if (maxSpan < 0.1) return 12;
  if (maxSpan < 0.3) return 11;
  if (maxSpan < 0.5) return 10;
  if (maxSpan < 1.0) return 9;
  return 8;
}

double _calculateRouteZoom(
  double fromLat,
  double fromLon,
  double toLat,
  double toLon,
) {
  final latSpan = (fromLat - toLat).abs();
  final lonSpan = (fromLon - toLon).abs();
  final spanMax = max(latSpan, lonSpan);

  if (spanMax < 0.003) return 14;
  if (spanMax < 0.008) return 13;
  if (spanMax < 0.02) return 12;
  if (spanMax < 0.05) return 11;
  if (spanMax < 0.1) return 10;
  if (spanMax < 0.3) return 9;
  if (spanMax < 0.5) return 8;
  if (spanMax < 1.0) return 7;
  if (spanMax < 2.0) return 6;
  return 5;
}

bool _hasPointSpread(List<LatLng> points) {
  if (points.length < 2) return false;
  final first = points.first;
  return points
      .skip(1)
      .any(
        (p) =>
            (p.latitude - first.latitude).abs() > 1e-6 ||
            (p.longitude - first.longitude).abs() > 1e-6,
      );
}

MapOptions _buildMapOptions({
  required LatLng center,
  required double zoom,
  List<LatLng>? fitPoints,
}) {
  if (fitPoints != null && _hasPointSpread(fitPoints)) {
    return MapOptions(
      initialCameraFit: CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(fitPoints),
        padding: const EdgeInsets.all(44),
      ),
    );
  }
  return MapOptions(initialCenter: center, initialZoom: zoom);
}

void _openFullscreenMap(
  BuildContext context, {
  required LatLng center,
  required double zoom,
  String? title,
  List<Map<String, dynamic>>? places,
  List<Map<String, dynamic>>? markers,
  List<LatLng>? fitPoints,
  double? routeFromLat,
  double? routeFromLon,
  double? routeToLat,
  double? routeToLon,
  String? routeFromLabel,
  String? routeToLabel,
  int? initialSelectedPlaceIndex,
}) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (ctx) => FullscreenMapPage(
        center: center,
        zoom: zoom,
        title: title ?? 'Map',
        places: places,
        markers: markers,
        fitPoints: fitPoints,
        routeFromLat: routeFromLat,
        routeFromLon: routeFromLon,
        routeToLat: routeToLat,
        routeToLon: routeToLon,
        routeFromLabel: routeFromLabel,
        routeToLabel: routeToLabel,
        initialSelectedPlaceIndex: initialSelectedPlaceIndex,
      ),
    ),
  );
}

Widget _buildMapPreview(
  BuildContext context, {
  required LatLng center,
  required double zoom,
  required List<Widget> mapChildren,
  String? title,
  List<LatLng>? fitPoints,
  List<Map<String, dynamic>>? places,
  List<Map<String, dynamic>>? markers,
  int? initialSelectedPlaceIndex,
  double? routeFromLat,
  double? routeFromLon,
  double? routeToLat,
  double? routeToLon,
  String? routeFromLabel,
  String? routeToLabel,
}) {
  final height = _mapPreviewHeight(context);
  return GestureDetector(
    onTap: () => _openFullscreenMap(
      context,
      center: center,
      zoom: zoom,
      title: title,
      places: places,
      markers: markers,
      fitPoints: fitPoints,
      routeFromLat: routeFromLat,
      routeFromLon: routeFromLon,
      routeToLat: routeToLat,
      routeToLon: routeToLon,
      routeFromLabel: routeFromLabel,
      routeToLabel: routeToLabel,
      initialSelectedPlaceIndex: initialSelectedPlaceIndex,
    ),
    child: SizedBox(
      height: height,
      child: Stack(
        children: [
          AbsorbPointer(
            child: FlutterMap(
              options: _buildMapOptions(
                center: center,
                zoom: zoom,
                fitPoints: fitPoints,
              ),
              children: mapChildren,
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.touch_app, color: Colors.white70, size: 16),
                  SizedBox(width: 4),
                  Text(
                    'Tap to explore',
                    style: TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

// ──────────────────────────────────────────────────────────
// Markers map
// ──────────────────────────────────────────────────────────

class _MarkersMapBlock extends StatelessWidget {
  final Map<String, dynamic> data;

  const _MarkersMapBlock({required this.data});

  @override
  Widget build(BuildContext context) {
    final title = data['title'] as String?;
    final markers = _filterValidCoordItems(data['markers'] as List?);
    if (markers.isEmpty) return const SizedBox.shrink();

    final lats = markers.map((m) => _toDouble(m['lat'])).toList();
    final lons = markers.map((m) => _toDouble(m['lon'])).toList();
    final markerPoints = markers
        .map((m) => LatLng(_toDouble(m['lat']), _toDouble(m['lon'])))
        .toList();
    final centerLat = lats.reduce((a, b) => a + b) / lats.length;
    final centerLon = lons.reduce((a, b) => a + b) / lons.length;
    final zoom = _calculateZoom(lats, lons);

    final mapLayers = <Widget>[
      TileLayer(
        urlTemplate: _tileUrlForBrightness(context),
        subdomains: _kTileSubdomains,
      ),
      MarkerLayer(
        markers: markers.map((m) {
          final label = m['label'] as String? ?? '';
          return Marker(
            point: LatLng(_toDouble(m['lat']), _toDouble(m['lon'])),
            width: 140,
            height: 48,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (label.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      label,
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                const Icon(
                  Icons.location_on,
                  color: Colors.redAccent,
                  size: 26,
                ),
              ],
            ),
          );
        }).toList(),
      ),
    ];

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(
            context,
          ).colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
          _buildMapPreview(
            context,
            center: LatLng(centerLat, centerLon),
            zoom: zoom,
            mapChildren: mapLayers,
            title: title,
            fitPoints: markerPoints,
            markers: markers,
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────
// Places map
// ──────────────────────────────────────────────────────────

class _PlacesMapBlock extends StatelessWidget {
  final Map<String, dynamic> data;

  const _PlacesMapBlock({required this.data});

  @override
  Widget build(BuildContext context) {
    final title = data['title'] as String?;
    final places = _filterValidCoordItems(data['places'] as List?);
    if (places.isEmpty) return const SizedBox.shrink();

    final lats = places.map((p) => _toDouble(p['lat'])).toList();
    final lons = places.map((p) => _toDouble(p['lon'])).toList();
    final placePoints = places
        .map((p) => LatLng(_toDouble(p['lat']), _toDouble(p['lon'])))
        .toList();
    final centerLat = lats.reduce((a, b) => a + b) / lats.length;
    final centerLon = lons.reduce((a, b) => a + b) / lons.length;
    final zoom = _calculateZoom(lats, lons);

    final mapLayers = <Widget>[
      TileLayer(
        urlTemplate: _tileUrlForBrightness(context),
        subdomains: _kTileSubdomains,
      ),
      MarkerLayer(markers: _buildLabeledPlaceMarkers(places)),
    ];

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(
            context,
          ).colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
          _buildMapPreview(
            context,
            center: LatLng(centerLat, centerLon),
            zoom: zoom,
            mapChildren: mapLayers,
            title: title,
            places: places,
            fitPoints: placePoints,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
            child: Text(
              '${places.length} results',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          ...List.generate(
            places.length > 10 ? 10 : places.length,
            (i) => _PlaceCard(
              place: places[i],
              number: i + 1,
              onShowOnMap: () {
                final p = places[i];
                final lat = _toDouble(p['lat']);
                final lon = _toDouble(p['lon']);
                _openFullscreenMap(
                  context,
                  center: LatLng(lat, lon),
                  zoom: zoom < 15 ? 15 : zoom,
                  title: title,
                  places: places,
                  fitPoints: placePoints,
                  initialSelectedPlaceIndex: i,
                );
              },
            ),
          ),
          if (places.length > 10)
            Padding(
              padding: const EdgeInsets.all(10),
              child: Text(
                '... and ${places.length - 10} more',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  static List<Marker> _buildLabeledPlaceMarkers(
    List<Map<String, dynamic>> places,
  ) {
    return List.generate(places.length, (i) {
      final p = places[i];
      final name = p['name'] as String? ?? '';
      return Marker(
        point: LatLng(_toDouble(p['lat']), _toDouble(p['lon'])),
        width: 150,
        height: 52,
        alignment: Alignment.bottomCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (name.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: Colors.redAccent.shade700,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black54,
                    blurRadius: 3,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: Text(
                '${i + 1}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      );
    });
  }
}

// ──────────────────────────────────────────────────────────
// Place card (used by places map)
// ──────────────────────────────────────────────────────────

class _PlaceCard extends StatelessWidget {
  final Map<String, dynamic> place;
  final int number;
  final VoidCallback? onShowOnMap;

  const _PlaceCard({
    required this.place,
    required this.number,
    this.onShowOnMap,
  });

  @override
  Widget build(BuildContext context) {
    final name = place['name'] as String? ?? 'Unknown';
    final cuisine = place['cuisine'] as String?;
    final phone = place['phone'] as String?;
    final website = place['website'] as String?;
    final hours = place['opening_hours'] as String?;
    final address = place['address'] as String?;
    final rating = place['rating'] != null ? _toDouble(place['rating']) : null;
    final reviewCount = place['review_count'] != null
        ? (place['review_count'] is num
              ? (place['review_count'] as num).toInt()
              : int.tryParse(place['review_count'].toString()))
        : null;
    final priceRange = place['price_range'] as String?;
    final description = place['description'] as String?;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onShowOnMap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: Theme.of(
                context,
              ).colorScheme.outlineVariant.withValues(alpha: 0.3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: Colors.redAccent.shade700,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '$number',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      name,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                  if (onShowOnMap != null)
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: onShowOnMap,
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Icon(
                            Icons.map,
                            size: 22,
                            color: Colors.blue.shade300,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              if (rating != null || cuisine != null || priceRange != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      if (rating != null) ...[
                        _buildStarRating(rating),
                        const SizedBox(width: 4),
                        Text(
                          rating.toStringAsFixed(1),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.amber.shade300,
                          ),
                        ),
                        if (reviewCount != null) ...[
                          const SizedBox(width: 3),
                          Text(
                            '($reviewCount)',
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        if (cuisine != null || priceRange != null)
                          const SizedBox(width: 8),
                      ],
                      if (priceRange != null) ...[
                        Text(
                          priceRange,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: Colors.green.shade300,
                          ),
                        ),
                        if (cuisine != null) const SizedBox(width: 8),
                      ],
                      if (cuisine != null)
                        Flexible(
                          child: Text(
                            cuisine,
                            style: TextStyle(
                              color: Colors.orange.shade200,
                              fontSize: 12,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
              if (address != null)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    address,
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (description != null && description.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    description,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.3,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (phone != null || hours != null || website != null)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Wrap(
                    spacing: 10,
                    children: [
                      if (phone != null)
                        () {
                          // AI-controlled input — validate before launching.
                          final uri = InputValidator.safeTelUri(phone);
                          return _buildInfoChip(
                            Icons.phone,
                            phone,
                            onTap: uri == null
                                ? null
                                : () => launchUrl(uri),
                          );
                        }(),
                      if (hours != null)
                        _buildInfoChip(Icons.access_time, hours),
                      if (website != null)
                        () {
                          // AI-controlled input — validate before launching.
                          final uri = InputValidator.safeHttpUri(website);
                          return _buildInfoChip(
                            Icons.language,
                            'Website',
                            onTap: uri == null
                                ? null
                                : () => launchUrl(uri),
                          );
                        }(),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoChip(IconData icon, String label, {VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.white54),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: onTap != null ? Colors.blue.shade300 : Colors.white54,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  static Widget _buildStarRating(double rating, {double size = 14}) {
    final clamped = rating.clamp(0.0, 5.0);
    final fullStars = clamped.floor();
    final hasHalf = (clamped - fullStars) >= 0.3;
    final emptyStars = 5 - fullStars - (hasHalf ? 1 : 0);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < fullStars; i++)
          Icon(Icons.star, size: size, color: Colors.amber.shade400),
        if (hasHalf)
          Icon(Icons.star_half, size: size, color: Colors.amber.shade400),
        for (int i = 0; i < emptyStars; i++)
          Icon(Icons.star_border, size: size, color: Colors.amber.shade700),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────
// Route map
// ──────────────────────────────────────────────────────────

class _RouteMapBlock extends StatelessWidget {
  final Map<String, dynamic> data;

  const _RouteMapBlock({required this.data});

  @override
  Widget build(BuildContext context) {
    final from = data['from'] as Map<String, dynamic>? ?? {};
    final to = data['to'] as Map<String, dynamic>? ?? {};
    final distKm = data['distance_km']?.toString() ?? '?';
    final durMin = data['duration_min']?.toString() ?? '?';
    final steps =
        (data['steps'] as List?)?.whereType<Map<String, dynamic>>().toList() ??
            const [];

    if (!_isValidLatLon(from['lat'], from['lon']) ||
        !_isValidLatLon(to['lat'], to['lon'])) {
      return const SizedBox.shrink();
    }

    final fromLat = _toDouble(from['lat']);
    final fromLon = _toDouble(from['lon']);
    final toLat = _toDouble(to['lat']);
    final toLon = _toDouble(to['lon']);
    final fromLabel = from['label'] as String? ?? 'Start';
    final toLabel = to['label'] as String? ?? 'Destination';

    final centerLat = (fromLat + toLat) / 2;
    final centerLon = (fromLon + toLon) / 2;
    final routeZoom = _calculateRouteZoom(fromLat, fromLon, toLat, toLon);
    final routeTitle = '$fromLabel → $toLabel';
    final mapHeight = _mapPreviewHeight(context);

    return RouteMapWidget(
      fromLat: fromLat,
      fromLon: fromLon,
      toLat: toLat,
      toLon: toLon,
      fromLabel: fromLabel,
      toLabel: toLabel,
      distKm: distKm,
      durMin: durMin,
      routeTitle: routeTitle,
      centerLat: centerLat,
      centerLon: centerLon,
      zoom: routeZoom,
      steps: steps,
      mapHeight: mapHeight,
      onTapFullscreen: () {
        final fitPoints = [LatLng(fromLat, fromLon), LatLng(toLat, toLon)];
        _openFullscreenMap(
          context,
          center: LatLng(centerLat, centerLon),
          zoom: routeZoom,
          title: routeTitle,
          fitPoints: fitPoints,
          routeFromLat: fromLat,
          routeFromLon: fromLon,
          routeToLat: toLat,
          routeToLon: toLon,
          routeFromLabel: fromLabel,
          routeToLabel: toLabel,
        );
      },
    );
  }
}
