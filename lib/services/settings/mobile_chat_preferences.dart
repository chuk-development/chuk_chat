import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mobile presentation only. Never changes the model's reasoning effort or
/// whether the host executes tools. Desktop settings remain independent.
class MobileChatPreferences extends ChangeNotifier {
  static final instance = MobileChatPreferences();
  static const reasoningKey = 'cowork_mobile_show_thinking';
  static const activityKey = 'cowork_mobile_show_activity';
  static const typographyKey = 'cowork_mobile_messenger_typography';

  bool showThinking = false;
  bool showActivity = false;
  bool messengerTypography = true;
  Future<void>? _loading;
  Future<void> _writes = Future<void>.value();

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      showThinking = prefs.getBool(reasoningKey) ?? false;
      showActivity = prefs.getBool(activityKey) ?? false;
      messengerTypography = prefs.getBool(typographyKey) ?? true;
      notifyListeners();
    } catch (_) {
      // A locked store leaves the quiet defaults.
    }
  }

  Future<void> setThinking(bool value) async {
    await load();
    showThinking = value;
    notifyListeners();
    await _save(reasoningKey, value);
  }

  Future<void> setActivity(bool value) async {
    await load();
    showActivity = value;
    notifyListeners();
    await _save(activityKey, value);
  }

  Future<void> setMessengerTypography(bool value) async {
    await load();
    messengerTypography = value;
    notifyListeners();
    await _save(typographyKey, value);
  }

  Future<void> _save(String key, bool value) {
    _writes = _writes.then((_) async {
      try {
        await (await SharedPreferences.getInstance()).setBool(key, value);
      } catch (_) {
        // Keep the choice in this session if storage is unavailable.
      }
    });
    return _writes;
  }
}
