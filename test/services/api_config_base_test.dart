import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/services/api_config_base.dart';

/// The model catalogue (`/v1/models_info`) is fetched from this base URL by
/// [ModelSelectorPage]. Upstream chuk_chat falls back to a local dev API server
/// in debug builds; CoWork has none, and its own host does not serve that
/// endpoint — so a debug build must reach the account backend like a release
/// build does, or the model dropdown is empty (bd cowork-zrq).
void main() {
  test('a debug build with no dart-define reaches the account backend', () {
    // `flutter test` runs in debug with no LOCAL_API_URL / API_BASE_URL set —
    // exactly the configuration that used to resolve to localhost:8000.
    expect(getConfiguredUrl(), isNull);
    expect(apiConfigLocalUrl, isEmpty);
    expect(getApiBaseUrl(), apiConfigDefaultProductionUrl);
    expect(getApiBaseUrl(), 'https://api.chuk.chat');
  });

  test('a local dev server is only used when the build asked for one', () {
    // isLocalApiServer must not claim a local server just because this is a
    // debug build; that flag now tracks an explicit LOCAL_API_URL.
    expect(isLocalApiServer, isFalse);
  });
}
