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

double _toDouble(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0.0;
  return 0.0;
}

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
  required List<Widget> mapChildren,
  String? title,
  List<Map<String, dynamic>>? places,
  List<LatLng>? fitPoints,
}) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (ctx) => FullscreenMapPage(
        center: center,
        zoom: zoom,
        mapChildren: mapChildren,
        title: title ?? 'Map',
        places: places,
        fitPoints: fitPoints,
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
}) {
  final height = _mapPreviewHeight(context);
  return GestureDetector(
    onTap: () => _openFullscreenMap(
      context,
      center: center,
      zoom: zoom,
      mapChildren: mapChildren,
      title: title,
      places: places,
      fitPoints: fitPoints,
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
    final markers =
        (data['markers'] as List?)?.cast<Map<String, dynamic>>() ?? [];
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
        urlTemplate:
            'https://cartodb-basemaps-{s}.global.ssl.fastly.net/dark_all/{z}/{x}/{y}.png',
        subdomains: const ['a', 'b', 'c', 'd'],
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
    final places =
        (data['places'] as List?)?.cast<Map<String, dynamic>>() ?? [];
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
        urlTemplate:
            'https://cartodb-basemaps-{s}.global.ssl.fastly.net/dark_all/{z}/{x}/{y}.png',
        subdomains: const ['a', 'b', 'c', 'd'],
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
            (i) => _PlaceCard(place: places[i], number: i + 1),
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

  const _PlaceCard({required this.place, required this.number});

  @override
  Widget build(BuildContext context) {
    final name = place['name'] as String? ?? 'Unknown';
    final cuisine = place['cuisine'] as String?;
    final phone = place['phone'] as String?;
    final website = place['website'] as String?;
    final hours = place['opening_hours'] as String?;
    final address = place['address'] as String?;
    final lat = place['lat'] != null ? _toDouble(place['lat']) : null;
    final lon = place['lon'] != null ? _toDouble(place['lon']) : null;
    final rating = place['rating'] != null ? _toDouble(place['rating']) : null;
    final reviewCount = place['review_count'] != null
        ? (place['review_count'] is num
              ? (place['review_count'] as num).toInt()
              : int.tryParse(place['review_count'].toString()))
        : null;
    final priceRange = place['price_range'] as String?;

    return Container(
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
              if (lat != null && lon != null)
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () => launchUrl(
                      Uri.parse(
                        'geo:$lat,$lon?q=$lat,$lon(${Uri.encodeComponent(name)})',
                      ),
                      mode: LaunchMode.externalApplication,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        Icons.navigation,
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
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
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
          if (phone != null || hours != null || website != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Wrap(
                spacing: 10,
                children: [
                  if (phone != null)
                    _buildInfoChip(
                      Icons.phone,
                      phone,
                      onTap: () => launchUrl(Uri.parse('tel:$phone')),
                    ),
                  if (hours != null) _buildInfoChip(Icons.access_time, hours),
                  if (website != null)
                    _buildInfoChip(
                      Icons.language,
                      'Website',
                      onTap: () => launchUrl(
                        Uri.parse(
                          website.startsWith('http')
                              ? website
                              : 'https://$website',
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
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
    final steps = (data['steps'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    final fromLat = from['lat'] != null ? _toDouble(from['lat']) : 0.0;
    final fromLon = from['lon'] != null ? _toDouble(from['lon']) : 0.0;
    final toLat = to['lat'] != null ? _toDouble(to['lat']) : 0.0;
    final toLon = to['lon'] != null ? _toDouble(to['lon']) : 0.0;
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
          mapChildren: [
            TileLayer(
              urlTemplate:
                  'https://cartodb-basemaps-{s}.global.ssl.fastly.net/dark_all/{z}/{x}/{y}.png',
              subdomains: const ['a', 'b', 'c', 'd'],
            ),
            MarkerLayer(
              markers: [
                Marker(
                  point: LatLng(fromLat, fromLon),
                  width: 34,
                  height: 34,
                  child: const Icon(
                    Icons.trip_origin,
                    color: Colors.green,
                    size: 28,
                  ),
                ),
                Marker(
                  point: LatLng(toLat, toLon),
                  width: 34,
                  height: 34,
                  child: const Icon(
                    Icons.location_on,
                    color: Colors.red,
                    size: 32,
                  ),
                ),
              ],
            ),
          ],
          title: routeTitle,
          fitPoints: fitPoints,
        );
      },
    );
  }
}
