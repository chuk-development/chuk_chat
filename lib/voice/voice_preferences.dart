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

  /// The engine for new calls, user-scoped. Kept in its own settings payload
  /// so the voice payload above never clobbers it.
  static const _engineService = 'voice_engine_preferences';
  static const _engineKey = 'voice_engine';

  static Future<String?> loadEngineLocal(String userId) async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString('voice_engine:$userId');
  }

  static Future<String?> loadEngineSynced(String userId) async {
    if (CurrentUser.id != userId) return null;
    final data = await ServiceCredentialsService.load(_engineService);
    if (CurrentUser.id != userId) return null;
    final engine = data?[_engineKey];
    if (engine is! String) return null;
    return engine;
  }

  static Future<void> saveEngineLocal(String userId, String engine) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('voice_engine:$userId', engine);
  }

  static Future<bool> saveEngineSynced(String userId, String engine) async {
    if (CurrentUser.id != userId) return false;
    return ServiceCredentialsService.save(_engineService, {
      _engineKey: engine,
    });
  }

  /// Marks that this device has an engine choice the cloud has not accepted
  /// yet (save pending or failed). Survives restarts so a stale remote value
  /// never overwrites the user's local choice.
  static const _enginePendingKey = 'voice_engine_pending';

  static Future<void> saveEnginePending(String userId, bool pending) async {
    final preferences = await SharedPreferences.getInstance();
    if (pending) {
      await preferences.setBool('$_enginePendingKey:$userId', true);
    } else {
      await preferences.remove('$_enginePendingKey:$userId');
    }
  }

  static Future<bool> loadEnginePending(String userId) async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool('$_enginePendingKey:$userId') ?? false;
  }
}
