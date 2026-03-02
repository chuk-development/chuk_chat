// lib/widgets/route_map_widget.dart

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

/// Displays a route map with OSRM polyline, start/end markers,
/// summary bar, optional turn-by-turn steps, and "Route in Maps" button.
class RouteMapWidget extends StatefulWidget {
  final double fromLat, fromLon, toLat, toLon;
  final double centerLat, centerLon, zoom;
  final String fromLabel, toLabel, distKm, durMin, routeTitle;
  final List<Map<String, dynamic>> steps;
  final double mapHeight;
  final VoidCallback? onTapFullscreen;

  const RouteMapWidget({
    super.key,
    required this.fromLat,
    required this.fromLon,
    required this.toLat,
    required this.toLon,
    required this.fromLabel,
    required this.toLabel,
    required this.distKm,
    required this.durMin,
    required this.routeTitle,
    required this.centerLat,
    required this.centerLon,
    required this.zoom,
    required this.steps,
    required this.mapHeight,
    this.onTapFullscreen,
  });

  @override
  State<RouteMapWidget> createState() => _RouteMapWidgetState();
}

class _RouteMapWidgetState extends State<RouteMapWidget> {
  List<LatLng>? _routePoints;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetchRouteGeometry();
  }

  Future<void> _fetchRouteGeometry() async {
    try {
      final url =
          'https://router.project-osrm.org/route/v1/driving/'
          '${widget.fromLon},${widget.fromLat};${widget.toLon},${widget.toLat}'
          '?overview=full&geometries=geojson';
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final routes = data['routes'] as List?;
        if (routes != null && routes.isNotEmpty) {
          final geometry = routes[0]['geometry'] as Map<String, dynamic>?;
          final coords = geometry?['coordinates'] as List?;
          if (coords != null && coords.isNotEmpty) {
            final points = coords
                .map((c) => LatLng((c as List)[1].toDouble(), c[0].toDouble()))
                .toList();
            if (mounted) {
              setState(() {
                _routePoints = points;
                _loading = false;
              });
              return;
            }
          }
        }
      }
    } catch (_) {
      // Fall through to straight-line fallback
    }
    if (mounted) {
      setState(() {
        _routePoints = [
          LatLng(widget.fromLat, widget.fromLon),
          LatLng(widget.toLat, widget.toLon),
        ];
        _loading = false;
      });
    }
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

  @override
  Widget build(BuildContext context) {
    final routeLine =
        _routePoints ??
        [
          LatLng(widget.fromLat, widget.fromLon),
          LatLng(widget.toLat, widget.toLon),
        ];

    final mapLayers = <Widget>[
      TileLayer(
        urlTemplate:
            'https://cartodb-basemaps-{s}.global.ssl.fastly.net/dark_all/{z}/{x}/{y}.png',
        subdomains: const ['a', 'b', 'c', 'd'],
      ),
      PolylineLayer(
        polylines: [
          Polyline(
            points: routeLine,
            strokeWidth: 4,
            color: Colors.blue.shade400,
          ),
        ],
      ),
      MarkerLayer(
        markers: [
          Marker(
            point: LatLng(widget.fromLat, widget.fromLon),
            width: 34,
            height: 34,
            child: const Icon(Icons.trip_origin, color: Colors.green, size: 28),
          ),
          Marker(
            point: LatLng(widget.toLat, widget.toLon),
            width: 34,
            height: 34,
            child: const Icon(Icons.location_on, color: Colors.red, size: 32),
          ),
        ],
      ),
    ];

    final fitPoints = <LatLng>[
      LatLng(widget.fromLat, widget.fromLon),
      LatLng(widget.toLat, widget.toLon),
    ];
    final mapOptions = _hasPointSpread(fitPoints)
        ? MapOptions(
            initialCameraFit: CameraFit.bounds(
              bounds: LatLngBounds.fromPoints(fitPoints),
              padding: const EdgeInsets.all(44),
            ),
          )
        : MapOptions(
            initialCenter: LatLng(widget.centerLat, widget.centerLon),
            initialZoom: widget.zoom,
          );

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
          // Map preview with loading overlay
          GestureDetector(
            onTap: widget.onTapFullscreen,
            child: SizedBox(
              height: widget.mapHeight,
              child: Stack(
                children: [
                  AbsorbPointer(
                    child: FlutterMap(options: mapOptions, children: mapLayers),
                  ),
                  if (_loading)
                    const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(
                        Icons.fullscreen,
                        color: Colors.white70,
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Route summary row
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Row(
              children: [
                Icon(
                  Icons.directions_car,
                  size: 18,
                  color: Colors.blue.shade300,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.routeTitle,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${widget.distKm} km · ${widget.durMin} min',
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          // "Route in Maps" button
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () async {
                  final uri = Uri.tryParse(
                    'geo:${widget.toLat},${widget.toLon}'
                    '?q=${widget.toLat},${widget.toLon}'
                    '(${Uri.encodeComponent(widget.toLabel)})',
                  );
                  if (uri != null) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
                icon: const Icon(Icons.navigation, size: 16),
                label: const Text('Route in Maps'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.blue.shade300,
                  side: BorderSide(
                    color: Colors.blue.shade300.withValues(alpha: 0.4),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  textStyle: const TextStyle(fontSize: 13),
                ),
              ),
            ),
          ),
          // Turn-by-turn steps
          if (widget.steps.isNotEmpty) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: widget.steps.take(6).map((step) {
                  final distM = step['distance_m'] as int? ?? 0;
                  final distStr = distM > 1000
                      ? '${(distM / 1000).toStringAsFixed(1)} km'
                      : '$distM m';
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.subdirectory_arrow_right,
                          size: 14,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${step['instruction']}  ($distStr)',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
            if (widget.steps.length > 6)
              Padding(
                padding: const EdgeInsets.only(left: 10, bottom: 10),
                child: Text(
                  '... and ${widget.steps.length - 6} more steps',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}
