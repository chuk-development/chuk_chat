import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/current_user.dart';
import 'package:chuk_chat/services/service_credentials_service.dart';

/// User-scoped local default, mirrored encrypted to the existing settings store.
abstract final class VoicePreferences {
  static const _service = 'voice_preferences';

  static Future<String?> loadLocal(String userId) async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString('voice_default:$userId');
  }

  static Future<String?> loadSynced(String userId) async {
    if (CurrentUser.id != userId) return null;
    final data = await ServiceCredentialsService.load(_service);
    if (CurrentUser.id != userId) return null;
    final voice = data?['voice_id'];
    if (voice is! String) return null;
    return voice;
  }

  static Future<void> saveLocal(String userId, String voice) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('voice_default:$userId', voice);
  }

  static Future<void> saveSynced(String userId, String voice) async {
    if (CurrentUser.id != userId) return;
    await ServiceCredentialsService.save(_service, {'voice_id': voice});
  }
}
