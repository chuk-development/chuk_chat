import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

/// Standard OpenStreetMap tiles — the one base map every map in the app uses.
///
/// Replaces the Esri World Gray Canvas, which has no data past roughly zoom
/// 16 in many places and then paints "Map data not yet available" into every
/// tile. OSM's standard layer is rendered down to zoom 19 everywhere; past
/// that the last native tiles are scaled up instead of going blank.
const String kOsmTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

/// Deepest zoom the OSM tile server renders.
const int kOsmMaxNativeZoom = 19;

/// Deepest zoom the user may go to; tiles past [kOsmMaxNativeZoom] are
/// upscaled.
const double kMapMaxZoom = 20;

/// The base tile layer. OSM's tile policy asks for an identifying user
/// agent; the app id is enough and carries no user data.
TileLayer buildBaseTileLayer() {
  return TileLayer(
    urlTemplate: kOsmTileUrl,
    maxNativeZoom: kOsmMaxNativeZoom,
    maxZoom: kMapMaxZoom,
    userAgentPackageName: 'dev.chuk.chat',
  );
}

/// The attribution OSM's licence requires: a small info chip in the corner
/// that opens the credit on tap, so it does not cover a small inline map.
Widget buildOsmAttribution() {
  return const RichAttributionWidget(
    showFlutterMapAttribution: false,
    attributions: [TextSourceAttribution('OpenStreetMap contributors')],
  );
}
