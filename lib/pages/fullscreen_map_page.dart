import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' as fm;
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:maplibre/maplibre.dart';
import 'package:url_launcher/url_launcher.dart';

class FullscreenMapPage extends StatefulWidget {
  final LatLng center;
  final double zoom;
  final String title;
  final List<Map<String, dynamic>>? places;
  final List<Map<String, dynamic>>? markers;
  final List<LatLng>? fitPoints;
  final double? routeFromLat;
  final double? routeFromLon;
  final double? routeToLat;
  final double? routeToLon;
  final String? routeFromLabel;
  final String? routeToLabel;
  final int? initialSelectedPlaceIndex;

  const FullscreenMapPage({
    super.key,
    required this.center,
    required this.zoom,
    required this.title,
    this.places,
    this.markers,
    this.fitPoints,
    this.routeFromLat,
    this.routeFromLon,
    this.routeToLat,
    this.routeToLon,
    this.routeFromLabel,
    this.routeToLabel,
    this.initialSelectedPlaceIndex,
  });

  @override
  State<FullscreenMapPage> createState() => _FullscreenMapPageState();
}

class _FullscreenMapPageState extends State<FullscreenMapPage> {
  static const String _kMapStyleUrl =
      'https://tiles.openfreemap.org/styles/bright';
  static const String _kOsrmBaseUrl = 'https://router.project-osrm.org';
  static const Map<String, String> _kApiHeaders = {
    'Accept': 'application/json',
    'User-Agent': 'chuk-chat/1.0',
  };

  MapController? _mapLibreController;
  final fm.MapController _fallbackMapController = fm.MapController();
  int? _selectedPlaceIndex;
  int? _selectedMarkerIndex;
  LatLng? _currentLocation;
  List<LatLng>? _activeRoutePoints;
  double? _routeDistanceKm;
  double? _routeDurationMin;
  bool _loadingLocation = false;
  bool _loadingRoute = false;
  bool _initialCameraApplied = false;
  bool _initialSelectionApplied = false;

  bool get _supportsMapLibre {
    if (kIsWeb) return true;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => true,
      TargetPlatform.iOS => true,
      TargetPlatform.macOS => true,
      TargetPlatform.linux => false,
      TargetPlatform.windows => false,
      TargetPlatform.fuchsia => false,
    };
  }

  bool get _hasPlaces => widget.places != null && widget.places!.isNotEmpty;
  bool get _hasMarkers => widget.markers != null && widget.markers!.isNotEmpty;
  bool get _hasRouteEndpoints =>
      widget.routeFromLat != null &&
      widget.routeFromLon != null &&
      widget.routeToLat != null &&
      widget.routeToLon != null;

  LatLng? get _routeStart => _hasRouteEndpoints
      ? LatLng(widget.routeFromLat!, widget.routeFromLon!)
      : null;

  LatLng? get _routeEnd => _hasRouteEndpoints
      ? LatLng(widget.routeToLat!, widget.routeToLon!)
      : null;

  @override
  void initState() {
    super.initState();
    _selectedPlaceIndex = widget.initialSelectedPlaceIndex;
    if (!_supportsMapLibre) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_applyInitialCamera());
        unawaited(_applyInitialSelection());
      });
    }
    if (_hasRouteEndpoints) {
      _loadingRoute = true;
      unawaited(_loadRouteForEndpoints());
    }
    if (_hasPlaces || _hasRouteEndpoints) {
      unawaited(_ensureCurrentLocation());
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasLocationControls = _hasPlaces || _hasRouteEndpoints;
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.surface,
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        title: Text(widget.title, style: const TextStyle(fontSize: 16)),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          if (hasLocationControls)
            IconButton(
              tooltip: 'My location',
              onPressed: _loadingLocation
                  ? null
                  : () => unawaited(_centerOnCurrentLocation()),
              icon: _loadingLocation
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.my_location),
            ),
        ],
      ),
      body: Stack(
        children: [
          _buildMapWidget(),
          if (_loadingRoute)
            _buildStatusChip(
              context,
              icon: Icons.alt_route,
              text: 'Calculating route...',
            ),
          if (!_loadingRoute &&
              _routeDistanceKm != null &&
              _routeDurationMin != null)
            _buildStatusChip(
              context,
              icon: Icons.directions_car,
              text:
                  '${_routeDistanceKm!.toStringAsFixed(1)} km · ${_routeDurationMin!.round()} min',
            ),
          if (_hasPlaces && _selectedPlaceIndex != null)
            _buildPlacePopup(
              context,
              widget.places![_selectedPlaceIndex!],
              _selectedPlaceIndex! + 1,
            ),
        ],
      ),
    );
  }

  Widget _buildMapWidget() {
    if (_supportsMapLibre) {
      return _buildMapLibreWidget();
    }
    return _buildFallbackMapWidget();
  }

  Widget _buildMapLibreWidget() {
    return MapLibreMap(
      options: MapOptions(
        initStyle: _kMapStyleUrl,
        initCenter: Geographic(
          lon: widget.center.longitude,
          lat: widget.center.latitude,
        ),
        initZoom: widget.zoom,
        initPitch: (_hasPlaces || _hasRouteEndpoints) ? 50 : 40,
        maxPitch: 60,
      ),
      layers: _buildMapLayers(),
      onMapCreated: _onMapCreated,
      onStyleLoaded: _onStyleLoaded,
      onEvent: _onMapEvent,
      children: const [
        Positioned(top: 12, left: 12, child: MapCompass()),
        Positioned(right: 12, bottom: 12, child: SourceAttribution()),
      ],
    );
  }

  Widget _buildFallbackMapWidget() {
    final routePoints = _activeRoutePoints;
    final routeStart = _routeStart;
    final routeEnd = _routeEnd;

    final children = <Widget>[
      fm.TileLayer(
        urlTemplate:
            'https://cartodb-basemaps-{s}.global.ssl.fastly.net/light_all/{z}/{x}/{y}.png',
        subdomains: const ['a', 'b', 'c', 'd'],
      ),
    ];

    if (routePoints != null && routePoints.length > 1) {
      children.add(
        fm.PolylineLayer(
          polylines: [
            fm.Polyline(
              points: routePoints,
              color: Colors.blue.shade600,
              strokeWidth: 5,
            ),
          ],
        ),
      );
    }

    if (routeStart != null && routeEnd != null) {
      children.add(
        fm.MarkerLayer(
          markers: [
            fm.Marker(
              point: routeStart,
              width: 28,
              height: 28,
              child: GestureDetector(
                onTap: () => unawaited(_animateTo(routeStart, zoom: 16.0)),
                child: const Icon(
                  Icons.trip_origin,
                  color: Colors.green,
                  size: 24,
                ),
              ),
            ),
            fm.Marker(
              point: routeEnd,
              width: 30,
              height: 30,
              child: GestureDetector(
                onTap: () => unawaited(_animateTo(routeEnd, zoom: 16.0)),
                child: const Icon(
                  Icons.location_on,
                  color: Colors.red,
                  size: 28,
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (_hasMarkers) {
      children.add(
        fm.MarkerLayer(
          markers: List.generate(widget.markers!.length, (i) {
            final marker = widget.markers![i];
            final point = LatLng(
              _toDouble(marker['lat']),
              _toDouble(marker['lon']),
            );
            final isSelected = _selectedMarkerIndex == i;
            return fm.Marker(
              point: point,
              width: isSelected ? 36 : 30,
              height: isSelected ? 36 : 30,
              child: GestureDetector(
                onTap: () => unawaited(_focusMarker(i)),
                child: Icon(
                  Icons.location_on,
                  color: isSelected ? Colors.orange.shade700 : Colors.redAccent,
                  size: isSelected ? 32 : 28,
                ),
              ),
            );
          }),
        ),
      );
    }

    if (_hasPlaces) {
      children.add(
        fm.MarkerLayer(
          markers: List.generate(widget.places!.length, (i) {
            final place = widget.places![i];
            final point = LatLng(
              _toDouble(place['lat']),
              _toDouble(place['lon']),
            );
            final isSelected = _selectedPlaceIndex == i;
            return fm.Marker(
              point: point,
              width: isSelected ? 34 : 28,
              height: isSelected ? 34 : 28,
              child: GestureDetector(
                onTap: () => unawaited(_selectPlace(i)),
                child: Container(
                  decoration: BoxDecoration(
                    color: isSelected
                        ? Colors.orange.shade700
                        : Colors.red.shade600,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${i + 1}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      );
    }

    if (_currentLocation != null) {
      children.add(
        fm.MarkerLayer(
          markers: [
            fm.Marker(
              point: _currentLocation!,
              width: 22,
              height: 22,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.blue.shade700,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return fm.FlutterMap(
      mapController: _fallbackMapController,
      options: _buildFallbackMapOptions(),
      children: children,
    );
  }

  fm.MapOptions _buildFallbackMapOptions() {
    final fitPoints =
        widget.fitPoints ??
        (_routeStart != null && _routeEnd != null
            ? <LatLng>[_routeStart!, _routeEnd!]
            : null);

    final useFit = fitPoints != null && _hasPointSpread(fitPoints);

    if (useFit) {
      return fm.MapOptions(
        initialCameraFit: fm.CameraFit.bounds(
          bounds: fm.LatLngBounds.fromPoints(fitPoints),
          padding: const EdgeInsets.all(64),
        ),
        onTap: (tapPosition, point) {
          if (!mounted) return;
          setState(() {
            _selectedPlaceIndex = null;
            _selectedMarkerIndex = null;
            if (_hasPlaces) {
              _activeRoutePoints = null;
              _routeDistanceKm = null;
              _routeDurationMin = null;
            }
          });
        },
      );
    }

    return fm.MapOptions(
      initialCenter: widget.center,
      initialZoom: widget.zoom,
      onTap: (tapPosition, point) {
        if (!mounted) return;
        setState(() {
          _selectedPlaceIndex = null;
          _selectedMarkerIndex = null;
          if (_hasPlaces) {
            _activeRoutePoints = null;
            _routeDistanceKm = null;
            _routeDurationMin = null;
          }
        });
      },
    );
  }

  void _onMapCreated(MapController controller) {
    _mapLibreController = controller;
    unawaited(_applyInitialCamera());
    unawaited(_applyInitialSelection());
  }

  void _onStyleLoaded(StyleController _) {
    final controller = _mapLibreController;
    if (controller != null && (_hasPlaces || _hasRouteEndpoints)) {
      unawaited(_enableNativeLocation(controller));
    }
  }

  void _onMapEvent(MapEvent event) {
    if (event is! MapEventClick) return;

    final controller = _mapLibreController;
    if (controller == null) return;

    int? tappedPlaceIndex;
    int? tappedMarkerIndex;

    try {
      final features = controller.featuresAtPoint(event.screenPoint);
      for (final feature in features) {
        final kind = feature.properties['kind']?.toString();
        if (kind == 'place') {
          final parsed = _toInt(feature.properties['index']);
          if (parsed != null) {
            tappedPlaceIndex = parsed;
            break;
          }
        }
        if (kind == 'marker') {
          final parsed = _toInt(feature.properties['index']);
          if (parsed != null) {
            tappedMarkerIndex = parsed;
          }
        }
        if (kind == 'route-start' && _routeStart != null) {
          unawaited(_animateTo(_routeStart!, zoom: 16.0));
          return;
        }
        if (kind == 'route-end' && _routeEnd != null) {
          unawaited(_animateTo(_routeEnd!, zoom: 16.0));
          return;
        }
      }
    } catch (_) {}

    if (tappedPlaceIndex != null) {
      unawaited(_selectPlace(tappedPlaceIndex));
      return;
    }

    if (tappedMarkerIndex != null) {
      unawaited(_focusMarker(tappedMarkerIndex));
      return;
    }

    if (!mounted) return;
    setState(() {
      _selectedPlaceIndex = null;
      _selectedMarkerIndex = null;
      if (_hasPlaces) {
        _activeRoutePoints = null;
        _routeDistanceKm = null;
        _routeDurationMin = null;
      }
    });
  }

  Future<void> _applyInitialCamera() async {
    if (_initialCameraApplied) return;
    if (_supportsMapLibre && _mapLibreController == null) return;

    final fitPoints = widget.fitPoints;
    if (fitPoints != null && _hasPointSpread(fitPoints)) {
      _initialCameraApplied = true;
      await _fitToPoints(fitPoints);
      return;
    }

    if (_hasRouteEndpoints && _routeStart != null && _routeEnd != null) {
      final points = [_routeStart!, _routeEnd!];
      if (_hasPointSpread(points)) {
        _initialCameraApplied = true;
        await _fitToPoints(points);
        return;
      }
    }

    _initialCameraApplied = true;
  }

  Future<void> _applyInitialSelection() async {
    if (_initialSelectionApplied) return;
    final selected = _selectedPlaceIndex;
    if (selected == null) return;
    if (_supportsMapLibre && _mapLibreController == null) return;

    _initialSelectionApplied = true;
    await _selectPlace(selected);
  }

  Future<void> _fitToPoints(List<LatLng> points) async {
    if (points.isEmpty) return;
    if (!_supportsMapLibre) {
      try {
        _fallbackMapController.fitCamera(
          fm.CameraFit.bounds(
            bounds: fm.LatLngBounds.fromPoints(points),
            padding: const EdgeInsets.all(64),
          ),
        );
      } catch (_) {}
      return;
    }

    final controller = _mapLibreController;
    if (controller == null) return;

    try {
      await controller.fitBounds(
        bounds: LngLatBounds.fromPoints(
          points.map(_toGeographic).toList(growable: false),
        ),
        pitch: 50,
        padding: const EdgeInsets.all(64),
        nativeDuration: const Duration(milliseconds: 800),
        webMaxDuration: const Duration(milliseconds: 800),
      );
    } catch (_) {}
  }

  Future<void> _focusMarker(int index) async {
    if (!_hasMarkers) return;
    if (index < 0 || index >= widget.markers!.length) return;

    final marker = widget.markers![index];
    final point = LatLng(_toDouble(marker['lat']), _toDouble(marker['lon']));

    if (!mounted) return;
    setState(() {
      _selectedMarkerIndex = index;
      _selectedPlaceIndex = null;
    });

    await _animateTo(point, zoom: 16.0);
  }

  Future<void> _selectPlace(int index) async {
    if (!_hasPlaces) return;
    if (index < 0 || index >= widget.places!.length) return;

    final place = widget.places![index];
    final destination = LatLng(
      _toDouble(place['lat']),
      _toDouble(place['lon']),
    );

    if (!mounted) return;
    setState(() {
      _selectedPlaceIndex = index;
      _selectedMarkerIndex = null;
      _loadingRoute = true;
      _routeDistanceKm = null;
      _routeDurationMin = null;
    });

    await _animateTo(destination, zoom: 16.4);

    final origin = await _ensureCurrentLocation();
    if (origin == null) {
      if (!mounted || _selectedPlaceIndex != index) return;
      setState(() {
        _activeRoutePoints = null;
        _loadingRoute = false;
      });
      return;
    }

    await _loadRoute(from: origin, to: destination, expectedPlaceIndex: index);
  }

  Future<void> _loadRouteForEndpoints() async {
    final start = _routeStart;
    final end = _routeEnd;
    if (start == null || end == null) return;
    await _loadRoute(from: start, to: end);
  }

  Future<void> _loadRoute({
    required LatLng from,
    required LatLng to,
    int? expectedPlaceIndex,
  }) async {
    try {
      final route = await _fetchRouteGeometry(from: from, to: to);
      if (!mounted) return;
      if (expectedPlaceIndex != null &&
          _selectedPlaceIndex != expectedPlaceIndex) {
        return;
      }
      setState(() {
        _activeRoutePoints = route.points;
        _routeDistanceKm = route.distanceMeters != null
            ? route.distanceMeters! / 1000
            : null;
        _routeDurationMin = route.durationSeconds != null
            ? route.durationSeconds! / 60
            : null;
        _loadingRoute = false;
      });
    } catch (_) {
      if (!mounted) return;
      if (expectedPlaceIndex != null &&
          _selectedPlaceIndex != expectedPlaceIndex) {
        return;
      }
      setState(() {
        _activeRoutePoints = [from, to];
        _routeDistanceKm = null;
        _routeDurationMin = null;
        _loadingRoute = false;
      });
    }
  }

  Future<_RouteGeometry> _fetchRouteGeometry({
    required LatLng from,
    required LatLng to,
  }) async {
    final uri = Uri.parse(
      '$_kOsrmBaseUrl/route/v1/driving/'
      '${from.longitude},${from.latitude};${to.longitude},${to.latitude}'
      '?overview=full&geometries=geojson',
    );

    final response = await http
        .get(uri, headers: _kApiHeaders)
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw StateError('Route lookup failed (${response.statusCode})');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final routes = decoded['routes'] as List?;
    if (routes == null || routes.isEmpty) {
      throw StateError('No route found');
    }

    final route = routes.first as Map<String, dynamic>;
    final geometry = route['geometry'] as Map<String, dynamic>?;
    final coords = geometry?['coordinates'] as List?;
    if (coords == null || coords.isEmpty) {
      throw StateError('Route geometry missing');
    }

    final points = coords
        .map((c) {
          final pair = c as List;
          return LatLng(_toDouble(pair[1]), _toDouble(pair[0]));
        })
        .toList(growable: false);

    return _RouteGeometry(
      points: points,
      distanceMeters: (route['distance'] as num?)?.toDouble(),
      durationSeconds: (route['duration'] as num?)?.toDouble(),
    );
  }

  Future<void> _animateTo(LatLng target, {double? zoom}) async {
    if (!_supportsMapLibre) {
      try {
        final effectiveZoom = zoom ?? _fallbackMapController.camera.zoom;
        _fallbackMapController.move(target, effectiveZoom);
      } catch (_) {
        _fallbackMapController.move(target, zoom ?? widget.zoom);
      }
      return;
    }

    final controller = _mapLibreController;
    if (controller == null) return;

    final destination = Geographic(lon: target.longitude, lat: target.latitude);
    try {
      await controller.animateCamera(
        center: destination,
        zoom: zoom,
        pitch: 52,
        nativeDuration: const Duration(milliseconds: 700),
        webMaxDuration: const Duration(milliseconds: 700),
      );
    } catch (_) {
      await controller.moveCamera(center: destination, zoom: zoom, pitch: 52);
    }
  }

  Future<void> _centerOnCurrentLocation() async {
    final current = await _ensureCurrentLocation();
    if (current == null) return;
    await _animateTo(current, zoom: 15.8);
  }

  Future<LatLng?> _ensureCurrentLocation() async {
    if (_currentLocation != null) {
      return _currentLocation;
    }
    if (_loadingLocation) {
      return null;
    }

    if (mounted) {
      setState(() => _loadingLocation = true);
    }

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return null;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );

      final current = LatLng(position.latitude, position.longitude);
      if (mounted) {
        setState(() {
          _currentLocation = current;
        });
      }

      return current;
    } catch (_) {
      return null;
    } finally {
      if (mounted) {
        setState(() => _loadingLocation = false);
      }
    }
  }

  Future<void> _enableNativeLocation(MapController controller) async {
    try {
      await controller.enableLocation();
    } catch (_) {}
  }

  List<Layer> _buildMapLayers() {
    final layers = <Layer>[];

    final activeRoute = _activeRoutePoints;
    if (activeRoute != null && activeRoute.length > 1) {
      layers.add(
        PolylineLayer(
          polylines: [
            Feature(
              id: 'active-route',
              geometry: LineString.from(
                activeRoute.map(_toGeographic).toList(growable: false),
              ),
            ),
          ],
          color: Colors.blue.shade600,
          width: 5,
        ),
      );
    }

    if (_hasRouteEndpoints && _routeStart != null && _routeEnd != null) {
      layers.add(
        CircleLayer(
          points: [
            Feature(
              id: 'route-start',
              properties: const {'kind': 'route-start'},
              geometry: Point(_toGeographic(_routeStart!)),
            ),
          ],
          radius: 8,
          color: Colors.green.shade600,
          strokeWidth: 2,
          strokeColor: Colors.white,
        ),
      );
      layers.add(
        CircleLayer(
          points: [
            Feature(
              id: 'route-end',
              properties: const {'kind': 'route-end'},
              geometry: Point(_toGeographic(_routeEnd!)),
            ),
          ],
          radius: 9,
          color: Colors.red.shade600,
          strokeWidth: 2,
          strokeColor: Colors.white,
        ),
      );
    }

    if (_hasMarkers) {
      final markerFeatures = <Feature<Point>>[];
      final selectedMarkerFeatures = <Feature<Point>>[];

      for (var i = 0; i < widget.markers!.length; i++) {
        final marker = widget.markers![i];
        final feature = Feature<Point>(
          id: 'marker-$i',
          properties: {'kind': 'marker', 'index': i},
          geometry: Point(
            Geographic(
              lon: _toDouble(marker['lon']),
              lat: _toDouble(marker['lat']),
            ),
          ),
        );

        if (_selectedMarkerIndex == i) {
          selectedMarkerFeatures.add(feature);
        } else {
          markerFeatures.add(feature);
        }
      }

      if (markerFeatures.isNotEmpty) {
        layers.add(
          CircleLayer(
            points: markerFeatures,
            radius: 8,
            color: Colors.redAccent.shade700,
            strokeWidth: 2,
            strokeColor: Colors.white,
          ),
        );
      }

      if (selectedMarkerFeatures.isNotEmpty) {
        layers.add(
          CircleLayer(
            points: selectedMarkerFeatures,
            radius: 11,
            color: Colors.orange.shade700,
            strokeWidth: 3,
            strokeColor: Colors.white,
          ),
        );
      }
    }

    if (_hasPlaces) {
      final placeFeatures = <Feature<Point>>[];
      final selectedPlaceFeatures = <Feature<Point>>[];

      for (var i = 0; i < widget.places!.length; i++) {
        final place = widget.places![i];
        final feature = Feature<Point>(
          id: 'place-$i',
          properties: {'kind': 'place', 'index': i},
          geometry: Point(
            Geographic(
              lon: _toDouble(place['lon']),
              lat: _toDouble(place['lat']),
            ),
          ),
        );

        if (_selectedPlaceIndex == i) {
          selectedPlaceFeatures.add(feature);
        } else {
          placeFeatures.add(feature);
        }
      }

      if (placeFeatures.isNotEmpty) {
        layers.add(
          CircleLayer(
            points: placeFeatures,
            radius: 7,
            color: Colors.red.shade500,
            strokeWidth: 2,
            strokeColor: Colors.white,
          ),
        );
      }

      if (selectedPlaceFeatures.isNotEmpty) {
        layers.add(
          CircleLayer(
            points: selectedPlaceFeatures,
            radius: 10,
            color: Colors.orange.shade700,
            strokeWidth: 3,
            strokeColor: Colors.white,
          ),
        );
      }
    }

    if (_currentLocation != null) {
      final currentFeature = Feature<Point>(
        id: 'current-location',
        properties: const {'kind': 'current-location'},
        geometry: Point(_toGeographic(_currentLocation!)),
      );

      layers.add(
        CircleLayer(
          points: [currentFeature],
          radius: 14,
          color: Colors.blue.withValues(alpha: 0.2),
        ),
      );
      layers.add(
        CircleLayer(
          points: [currentFeature],
          radius: 7,
          color: Colors.blue.shade700,
          strokeWidth: 2,
          strokeColor: Colors.white,
        ),
      );
    }

    return layers;
  }

  Widget _buildStatusChip(
    BuildContext context, {
    required IconData icon,
    required String text,
  }) {
    return Positioned(
      top: 14,
      right: 14,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 6),
            Text(
              text,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlacePopup(
    BuildContext context,
    Map<String, dynamic> place,
    int number,
  ) {
    final name = place['name'] as String? ?? 'Unknown';
    final cuisine = place['cuisine'] as String?;
    final address = place['address'] as String?;
    final phone = place['phone'] as String?;
    final website = place['website'] as String?;
    final hours = place['opening_hours'] as String?;
    final lat = place['lat'] != null ? _toDouble(place['lat']) : null;
    final lon = place['lon'] != null ? _toDouble(place['lon']) : null;
    final rating = place['rating'] != null ? _toDouble(place['rating']) : null;
    final reviewCount = place['review_count'] != null
        ? (place['review_count'] is num
              ? (place['review_count'] as num).toInt()
              : int.tryParse(place['review_count'].toString()))
        : null;
    final priceRange = place['price_range'] as String?;

    return Positioned(
      left: 12,
      right: 12,
      bottom: 16 + MediaQuery.of(context).padding.bottom,
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: Colors.orange.shade600,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '$number',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      name,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => setState(() {
                      _selectedPlaceIndex = null;
                    }),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Icons.close,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
              if (rating != null || cuisine != null || priceRange != null)
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Row(
                    children: [
                      if (rating != null) ...[
                        _buildStarRating(rating),
                        const SizedBox(width: 4),
                        Text(
                          rating.toStringAsFixed(1),
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.amber.shade700,
                          ),
                        ),
                        if (reviewCount != null) ...[
                          const SizedBox(width: 3),
                          Text(
                            '($reviewCount)',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        if (cuisine != null || priceRange != null)
                          const SizedBox(width: 10),
                      ],
                      if (priceRange != null) ...[
                        Text(
                          priceRange,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: Colors.green.shade600,
                          ),
                        ),
                        if (cuisine != null) const SizedBox(width: 10),
                      ],
                      if (cuisine != null)
                        Flexible(
                          child: Text(
                            cuisine,
                            style: TextStyle(
                              color: Colors.orange.shade900,
                              fontSize: 13,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
              if (_loadingRoute)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Calculating route from your location...',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (!_loadingRoute &&
                  _routeDistanceKm != null &&
                  _routeDurationMin != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'From your location: ${_routeDistanceKm!.toStringAsFixed(1)} km · ${_routeDurationMin!.round()} min',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              if (address != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Icon(
                        Icons.place,
                        size: 14,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          address,
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (hours != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Icon(
                        Icons.access_time,
                        size: 14,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          hours,
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (phone != null ||
                  website != null ||
                  (lat != null && lon != null))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      if (phone != null)
                        _buildPopupAction(
                          icon: Icons.phone,
                          label: phone,
                          color: Colors.green,
                          onTap: () async {
                            final uri = Uri.tryParse('tel:$phone');
                            if (uri != null) {
                              await launchUrl(uri);
                            }
                          },
                        ),
                      if (phone != null &&
                          (website != null || (lat != null && lon != null)))
                        const SizedBox(width: 8),
                      if (website != null)
                        _buildPopupAction(
                          icon: Icons.language,
                          label: 'Website',
                          color: Colors.blue,
                          onTap: () async {
                            final urlStr = website.startsWith('http')
                                ? website
                                : 'https://$website';
                            final uri = Uri.tryParse(urlStr);
                            if (uri != null) {
                              await launchUrl(uri);
                            }
                          },
                        ),
                      if ((website != null || phone != null) &&
                          lat != null &&
                          lon != null)
                        const SizedBox(width: 8),
                      if (lat != null && lon != null)
                        _buildPopupAction(
                          icon: Icons.center_focus_strong,
                          label: 'Zoom',
                          color: Colors.blue,
                          onTap: () {
                            unawaited(_animateTo(LatLng(lat, lon), zoom: 17.0));
                          },
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPopupAction({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(color: color, fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStarRating(double rating, {double size = 15}) {
    final clamped = rating.clamp(0.0, 5.0);
    final fullStars = clamped.floor();
    final hasHalf = (clamped - fullStars) >= 0.3;
    final emptyStars = 5 - fullStars - (hasHalf ? 1 : 0);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < fullStars; i++)
          Icon(Icons.star, size: size, color: Colors.amber.shade500),
        if (hasHalf)
          Icon(Icons.star_half, size: size, color: Colors.amber.shade500),
        for (var i = 0; i < emptyStars; i++)
          Icon(Icons.star_border, size: size, color: Colors.amber.shade700),
      ],
    );
  }

  Geographic _toGeographic(LatLng point) =>
      Geographic(lon: point.longitude, lat: point.latitude);

  static bool _hasPointSpread(List<LatLng> points) {
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

  static double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  static int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

class _RouteGeometry {
  final List<LatLng> points;
  final double? distanceMeters;
  final double? durationSeconds;

  const _RouteGeometry({
    required this.points,
    this.distanceMeters,
    this.durationSeconds,
  });
}
