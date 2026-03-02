// lib/pages/fullscreen_map_page.dart

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

/// Full-screen interactive map page.
///
/// Supports two modes:
/// - Generic map layers (markers, polylines, etc.) passed via [mapChildren]
/// - Places mode: numbered tappable markers with detail popups
class FullscreenMapPage extends StatefulWidget {
  final LatLng center;
  final double zoom;
  final List<Widget> mapChildren;
  final String title;
  final List<Map<String, dynamic>>? places;
  final List<LatLng>? fitPoints;

  const FullscreenMapPage({
    super.key,
    required this.center,
    required this.zoom,
    required this.mapChildren,
    required this.title,
    this.places,
    this.fitPoints,
  });

  @override
  State<FullscreenMapPage> createState() => _FullscreenMapPageState();
}

class _FullscreenMapPageState extends State<FullscreenMapPage> {
  int? _selectedIndex;

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
    final hasPlaces = widget.places != null && widget.places!.isNotEmpty;

    final fitPoints = hasPlaces
        ? widget.places!
              .where((p) => p['lat'] != null && p['lon'] != null)
              .map((p) => LatLng(_toDouble(p['lat']), _toDouble(p['lon'])))
              .toList()
        : widget.fitPoints;
    final useFit = fitPoints != null && _hasPointSpread(fitPoints);

    final options = useFit
        ? MapOptions(
            initialCameraFit: CameraFit.bounds(
              bounds: LatLngBounds.fromPoints(fitPoints),
              padding: const EdgeInsets.all(64),
            ),
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all,
            ),
            onTap: (_, _) => setState(() => _selectedIndex = null),
          )
        : MapOptions(
            initialCenter: widget.center,
            initialZoom: widget.zoom,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all,
            ),
            onTap: (_, _) => setState(() => _selectedIndex = null),
          );

    final List<Widget> layers;
    if (hasPlaces) {
      layers = [
        TileLayer(
          urlTemplate:
              'https://cartodb-basemaps-{s}.global.ssl.fastly.net/dark_all/{z}/{x}/{y}.png',
          subdomains: const ['a', 'b', 'c', 'd'],
        ),
        MarkerLayer(markers: _buildInteractivePlaceMarkers(widget.places!)),
      ];
    } else {
      layers = widget.mapChildren;
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title, style: const TextStyle(fontSize: 16)),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Stack(
        children: [
          FlutterMap(options: options, children: layers),
          if (hasPlaces && _selectedIndex != null)
            _buildPlacePopup(
              context,
              widget.places![_selectedIndex!],
              _selectedIndex! + 1,
            ),
        ],
      ),
    );
  }

  List<Marker> _buildInteractivePlaceMarkers(
    List<Map<String, dynamic>> places,
  ) {
    return List.generate(places.length, (i) {
      final p = places[i];
      final lat = _toDouble(p['lat']);
      final lon = _toDouble(p['lon']);
      final name = p['name'] as String? ?? '';
      final markerNum = i + 1;
      final isSelected = _selectedIndex == i;

      return Marker(
        point: LatLng(lat, lon),
        width: 160,
        height: 56,
        alignment: Alignment.bottomCenter,
        child: GestureDetector(
          onTap: () => setState(() {
            _selectedIndex = _selectedIndex == i ? null : i;
          }),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (name.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: isSelected ? Colors.orange.shade800 : Colors.black87,
                    borderRadius: BorderRadius.circular(4),
                    border: isSelected
                        ? Border.all(color: Colors.orange.shade300, width: 1)
                        : null,
                  ),
                  child: Text(
                    name,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              Container(
                width: isSelected ? 32 : 28,
                height: isSelected ? 32 : 28,
                decoration: BoxDecoration(
                  color: isSelected
                      ? Colors.orange.shade600
                      : Colors.redAccent.shade700,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white,
                    width: isSelected ? 2.5 : 1.5,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black54,
                      blurRadius: 4,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: Text(
                  '$markerNum',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    });
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
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white24),
            boxShadow: const [
              BoxShadow(
                color: Colors.black87,
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
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => setState(() => _selectedIndex = null),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.close, color: Colors.white54, size: 20),
                    ),
                  ),
                ],
              ),
              // Rating + cuisine + price row
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
                            color: Colors.amber.shade300,
                          ),
                        ),
                        if (reviewCount != null) ...[
                          const SizedBox(width: 3),
                          Text(
                            '($reviewCount)',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white54,
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
                            color: Colors.green.shade300,
                          ),
                        ),
                        if (cuisine != null) const SizedBox(width: 10),
                      ],
                      if (cuisine != null)
                        Flexible(
                          child: Text(
                            cuisine,
                            style: TextStyle(
                              color: Colors.orange.shade200,
                              fontSize: 13,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
              if (address != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      const Icon(Icons.place, size: 14, color: Colors.white54),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          address,
                          style: const TextStyle(
                            color: Colors.white70,
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
                      const Icon(
                        Icons.access_time,
                        size: 14,
                        color: Colors.white54,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          hours,
                          style: const TextStyle(
                            color: Colors.white70,
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
                          context,
                          icon: Icons.phone,
                          label: phone,
                          color: Colors.green,
                          onTap: () async {
                            final uri = Uri.tryParse('tel:$phone');
                            if (uri != null) await launchUrl(uri);
                          },
                        ),
                      if (phone != null &&
                          (website != null || (lat != null && lon != null)))
                        const SizedBox(width: 8),
                      if (website != null)
                        _buildPopupAction(
                          context,
                          icon: Icons.language,
                          label: 'Website',
                          color: Colors.blue,
                          onTap: () async {
                            final urlStr = website.startsWith('http')
                                ? website
                                : 'https://$website';
                            final uri = Uri.tryParse(urlStr);
                            if (uri != null) await launchUrl(uri);
                          },
                        ),
                      if ((website != null || phone != null) &&
                          lat != null &&
                          lon != null)
                        const SizedBox(width: 8),
                      if (lat != null && lon != null)
                        _buildPopupAction(
                          context,
                          icon: Icons.directions,
                          label: 'Directions',
                          color: Colors.blue,
                          onTap: () async {
                            final uri = Uri.tryParse(
                              'geo:$lat,$lon?q=$lat,$lon(${Uri.encodeComponent(name)})',
                            );
                            if (uri != null) await launchUrl(uri);
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

  Widget _buildPopupAction(
    BuildContext context, {
    required IconData icon,
    required String label,
    required MaterialColor color,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
          decoration: BoxDecoration(
            color: color.shade900.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: color.shade300),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(color: color.shade300, fontSize: 12),
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
        for (int i = 0; i < fullStars; i++)
          Icon(Icons.star, size: size, color: Colors.amber.shade400),
        if (hasHalf)
          Icon(Icons.star_half, size: size, color: Colors.amber.shade400),
        for (int i = 0; i < emptyStars; i++)
          Icon(Icons.star_border, size: size, color: Colors.amber.shade700),
      ],
    );
  }

  static double _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }
}
