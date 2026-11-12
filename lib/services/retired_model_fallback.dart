// lib/services/retired_model_fallback.dart
//
// A saved model the server no longer serves. The server retires old models
// in one table (api_server `model_info/retired_models.py`) and tags each
// successor in `/v1/models_info` with `replaces: [<retired ids>]`. The app
// reads that tag here, so a mode that still points at a retired model moves
// to its successor instead of sending a request the server would refuse.

/// The model to use instead of [modelId], or null when [modelId] can stay.
///
/// - [catalog] empty (not loaded yet, offline first start): null. With no
///   catalog there is no evidence that the model is gone.
/// - [modelId] in [catalog]: null.
/// - A catalog entry lists [modelId] in `replaces`: that entry's id.
/// - Otherwise: [fallbackModelId], the mode's default.
String? replacementForRetiredModel(
  String modelId,
  List<Map<String, dynamic>> catalog, {
  required String fallbackModelId,
}) {
  final String wanted = modelId.trim().toLowerCase();
  if (wanted.isEmpty || catalog.isEmpty) return null;
  String? successor;
  for (final Map<String, dynamic> entry in catalog) {
    final Object? id = entry['id'];
    if (id is! String) continue;
    if (id.toLowerCase() == wanted) return null;
    final Object? replaces = entry['replaces'];
    if (successor == null &&
        replaces is List &&
        replaces.any((r) => r is String && r.toLowerCase() == wanted)) {
      successor = id;
    }
  }
  return successor ?? fallbackModelId;
}
