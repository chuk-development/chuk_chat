import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'all avatar shapes round-trip and old/unknown shapes remain compatible',
    () {
      for (final shape in AgentAvatarShape.values) {
        final profile = AgentProfile(
          shape: shape,
          colorValue: 0xFF00BFA5,
          photoPath: '/photo.png',
        );
        final restored = AgentProfile.fromJson(profile.toJson());
        expect(restored.shape, shape);
        expect(restored.colorValue, profile.colorValue);
        expect(restored.photoPath, profile.photoPath);
      }
      expect(AgentProfile.fromJson({'color': 0xFF123456}).shape, isNull);
      expect(AgentProfile.fromJson({'shape': 'futureShape'}).shape, isNull);
      expect(
        const AgentProfile(shape: AgentAvatarShape.round).isEmpty,
        isFalse,
      );
    },
  );

  test(
    'shape persists while unrelated edits preserve shape and existing colour',
    () async {
      final store = AgentProfileStore();
      final restored = AgentProfileStore();
      addTearDown(store.dispose);
      addTearDown(restored.dispose);
      await store.update(
        'alex',
        colorValue: 0xFF00BFA5,
        photoPath: '/photo.png',
      );
      await store.update('alex', shape: AgentAvatarShape.oval);
      await store.update('alex', role: 'Research');
      await restored.load();
      final profile = restored.profileOf('alex');
      expect(profile.shape, AgentAvatarShape.oval);
      expect(profile.colorValue, 0xFF00BFA5);
      expect(profile.photoPath, '/photo.png');
      expect(profile.role, 'Research');
      await restored.update('alex', clearShape: true);
      expect(restored.profileOf('alex').shape, isNull);
      expect(restored.profileOf('alex').colorValue, 0xFF00BFA5);
    },
  );
}
