# lib/services/herenow · Signaturen

## lib/services/herenow/herenow_store.dart  (104 Z.)
- L21 `enum HereNowApproval`  — Whether a public publish must be approved each time (`ask`, the default and
  - L22 `ask`
  - L23 `auto`
  - L26 `String get wire`  — The wire value the Python side reads (`ask` / `auto`).
  - L30 `static HereNowApproval fromWire(Object? value)`  — Parse a wire value, defaulting to [ask] — an unknown mode must never read
- L35 `@immutable class HereNowSettings`  — The connector's settings: on/off and the approval mode.
  - L37 `const HereNowSettings({ this.enabled = false, this.approval = HereNowApproval.ask, })`
  - L42 `final bool enabled`
  - L43 `final HereNowApproval approval`
  - L45 `HereNowSettings copyWith({bool? enabled, HereNowApproval? approval})`
  - L51 `Map<String, dynamic> toJson()`
  - L56 `factory HereNowSettings.fromJson(Map<String, dynamic> json)`
- L63 `class HereNowStore`
  - L64 `HereNowStore()`
  - L67 `static const String prefsKey = 'herenow_connector_v1'`  — The connector config.
  - L71 `Future<HereNowSettings> load()`  — The stored settings. Never throws — a corrupt record reads as the default
  - L86 `Future<void> save(HereNowSettings settings)`  — Persist the whole settings object.
  - L95 `Future<Map<String, dynamic>?> forwardPayload()`  — The payload the app forwards on the task frame — `{enabled, approval}` —
