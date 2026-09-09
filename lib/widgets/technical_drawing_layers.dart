// lib/widgets/technical_drawing_layers.dart

/// Paint order for one element of a technical drawing.
///
/// Low numbers go down first, so the reader sees the important strokes on top:
///
///  0 = construction lines (centerline, dashed, hidden)
///  1 = thin solid geometry (extension, hatch, auxiliary)
///  2 = thick solid geometry (main contours)
///  3 = dimensions
///  4 = notes (always on top, opaque background)
///
/// The on-screen painter and the SVG export both sort by this, which is the
/// only way an exported drawing looks like the one on screen.
int technicalDrawingLayerPriority(Map<String, dynamic> element) {
  // Read without a cast: the map comes straight from model JSON, and a field
  // of an unexpected type must fall through to the default priority rather
  // than throw in the middle of a paint or an export.
  final type = element['type'];
  if (type == 'note') return 4;
  if (type == 'dimension') return 3;
  final style = element['lineStyle'];
  if (style == 'centerline' || style == 'dashed' || style == 'hidden') {
    return 0;
  }
  return element['weight'] == 'thick' ? 2 : 1;
}
