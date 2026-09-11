// lib/services/herenow/herenow_store.dart
//
// Storage for the here.now publishing connector. Two settings, no secrets: is
// the connector on, and does a public publish need per-publish approval (`ask`)
// or not (`auto`). Both live as one JSON object in SharedPreferences under
// `herenow_connector_v1`.
//
// The store also assembles the one thing the Python side reads from here: the
// forward payload `{enabled, approval}` the app puts on the task frame, exactly
// like McpStore.forwardPayloads() feeds `mcp_servers`. A disabled connector
// forwards nothing, so the key is left off the frame and the executor registers
// no publish tool at all.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether a public publish must be approved each time (`ask`, the default and
/// the safe answer) or may publish without asking (`auto`, an explicit opt-in).
enum HereNowApproval {
  ask,
  auto;

  /// The wire value the Python side reads (`ask` / `auto`).
  String get wire => name;

  /// Parse a wire value, defaulting to [ask] — an unknown mode must never read
  /// as the less-guarded `auto`.
  static HereNowApproval fromWire(Object? value) =>
      value == 'auto' ? HereNowApproval.auto : HereNowApproval.ask;
}

/// The connector's settings: on/off and the approval mode.
@immutable
class HereNowSettings {
  const HereNowSettings({
    this.enabled = false,
    this.approval = HereNowApproval.ask,
  });

  final bool enabled;
  final HereNowApproval approval;

  HereNowSettings copyWith({bool? enabled, HereNowApproval? approval}) =>
      HereNowSettings(
        enabled: enabled ?? this.enabled,
        approval: approval ?? this.approval,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'enabled': enabled,
    'approval': approval.wire,
  };

  factory HereNowSettings.fromJson(Map<String, dynamic> json) =>
      HereNowSettings(
        enabled: json['enabled'] == true,
        approval: HereNowApproval.fromWire(json['approval']),
      );
}

class HereNowStore {
  HereNowStore();

  /// The connector config.
  static const String prefsKey = 'herenow_connector_v1';

  /// The stored settings. Never throws — a corrupt record reads as the default
  /// (disabled), so a bad value can never leave publishing silently enabled.
  Future<HereNowSettings> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw == null || raw.isEmpty) return const HereNowSettings();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const HereNowSettings();
      return HereNowSettings.fromJson(Map<String, dynamic>.from(decoded));
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ [HereNow] Could not read settings: $e');
      return const HereNowSettings();
    }
  }

  /// Persist the whole settings object.
  Future<void> save(HereNowSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, jsonEncode(settings.toJson()));
  }

  /// The payload the app forwards on the task frame — `{enabled, approval}` —
  /// or null when the connector is off. Null leaves the `herenow` key off the
  /// frame, so an old host and a user who never enabled it both keep working
  /// unchanged, and the executor registers no publish tool.
  Future<Map<String, dynamic>?> forwardPayload() async {
    final settings = await load();
    if (!settings.enabled) return null;
    return <String, dynamic>{
      'enabled': true,
      'approval': settings.approval.wire,
    };
  }
}
