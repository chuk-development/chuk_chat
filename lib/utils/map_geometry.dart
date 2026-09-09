// lib/utils/map_geometry.dart

import 'package:latlong2/latlong.dart';

/// True when [points] cover more than one place on the map.
///
/// A route or a marker set whose points all sit on the same coordinate has no
/// extent to fit a camera to. `fitCamera` on a zero-size bounds zooms to the
/// maximum level, so callers check this first and centre on the single point
/// instead. The 1e-6 degree threshold is about 10 cm — below the precision any
/// of our sources report.
bool hasPointSpread(List<LatLng> points) {
  if (points.length < 2) return false;
  final first = points.first;
  return points.skip(1).any(
        (p) =>
            (p.latitude - first.latitude).abs() > 1e-6 ||
            _shortestLonDelta(p.longitude, first.longitude) > 1e-6,
      );
}

/// Degrees between two longitudes the short way round.
///
/// 179.9 and -179.9 are 0.2 degrees apart, not 359.8 — a plain subtraction
/// would call a route that crosses the antimeridian world-sized and fit the
/// camera to the whole globe.
double _shortestLonDelta(double a, double b) {
  return (((a - b + 540) % 360) - 180).abs();
}
