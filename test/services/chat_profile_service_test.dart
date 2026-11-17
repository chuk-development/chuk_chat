// Tests for the Standard profile: the slug marker, how the server's profile
// JSON is parsed, the provider chain label, and the stored copy.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/chat_profile_service.dart';

const Map<String, Object?> _json = <String, Object?>{
  'id': 'standard',
  'name': 'Standard',
  'description': 'Best value',
  'model': <String, Object?>{
    'id': 'deepseek/deepseek-v4.1-flash-1017',
    'name': 'DeepSeek V4.1 Flash',
    'icon_url': 'https://example.com/ds.svg',
  },
  'providers': <Object?>[
    <String, Object?>{
      'slug': 'wafer',
      'name': 'Wafer (US)',
      'icon_url': 'https://example.com/w.svg',
    },
    <String, Object?>{'slug': 'inference-net', 'name': 'inference.net'},
    <String, Object?>{'slug': 'ionstream', 'name': 'Ionstream'},
  ],
};

void main() {
  setUp(() {
    ChatProfileService.resetForTest();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('profileIdOf', () {
    test('reads the id out of a marker slug', () {
      expect(ChatProfileService.profileIdOf('profile:standard'), 'standard');
      expect(ChatProfileService.profileIdOf('profile:other'), 'other');
      expect(ChatProfileService.standardMarker, 'profile:standard');
    });

    test('a real slug, an empty id or null is no profile', () {
      expect(ChatProfileService.profileIdOf('fireworks/serverless'), isNull);
      expect(ChatProfileService.profileIdOf('profile:'), isNull);
      expect(ChatProfileService.profileIdOf(''), isNull);
      expect(ChatProfileService.profileIdOf(null), isNull);
    });

    test('isProfileSlug follows profileIdOf', () {
      expect(ChatProfileService.isProfileSlug('profile:standard'), isTrue);
      expect(ChatProfileService.isProfileSlug('wafer'), isFalse);
      expect(ChatProfileService.isProfileSlug(null), isFalse);
    });
  });

  group('ChatProfile.fromJson', () {
    test('parses model and providers', () {
      final ChatProfile profile = ChatProfile.fromJson(_json)!;
      expect(profile.id, 'standard');
      expect(profile.name, 'Standard');
      expect(profile.description, 'Best value');
      expect(profile.modelId, 'deepseek/deepseek-v4.1-flash-1017');
      expect(profile.modelName, 'DeepSeek V4.1 Flash');
      expect(profile.modelIconUrl, 'https://example.com/ds.svg');
      expect(profile.providers.map((p) => p.slug), <String>[
        'wafer',
        'inference-net',
        'ionstream',
      ]);
      expect(profile.providers.first.iconUrl, 'https://example.com/w.svg');
      expect(profile.providers[1].iconUrl, isNull);
    });

    test('providerChainLabel joins names and drops the region tag', () {
      expect(
        ChatProfile.fromJson(_json)!.providerChainLabel,
        'Wafer → inference.net → Ionstream',
      );
    });

    test('a provider without a name shows its slug', () {
      final ChatProfile profile = ChatProfile.fromJson(<String, Object?>{
        'id': 'standard',
        'model': <String, Object?>{'id': 'a/b'},
        'providers': <Object?>[
          <String, Object?>{'slug': 'x'},
        ],
      })!;
      expect(profile.modelName, 'a/b');
      expect(profile.providerChainLabel, 'x');
    });

    test('bad input gives null', () {
      expect(ChatProfile.fromJson(null), isNull);
      expect(ChatProfile.fromJson('x'), isNull);
      expect(ChatProfile.fromJson(<String, Object?>{'id': 'standard'}), isNull);
      expect(
        ChatProfile.fromJson(<String, Object?>{
          'id': '',
          'model': <String, Object?>{'id': 'a/b'},
        }),
        isNull,
      );
      expect(
        ChatProfile.fromJson(<String, Object?>{
          'id': 'standard',
          'model': <String, Object?>{'id': ''},
        }),
        isNull,
      );
    });

    test('providers with a bad entry skip it', () {
      final ChatProfile profile = ChatProfile.fromJson(<String, Object?>{
        'id': 'standard',
        'model': <String, Object?>{'id': 'a/b'},
        'providers': <Object?>[
          'junk',
          <String, Object?>{'name': 'no slug'},
          <String, Object?>{'slug': 'ok', 'name': 'Ok'},
        ],
      })!;
      expect(profile.providers.map((p) => p.slug), <String>['ok']);
    });
  });

  group('the stored copy', () {
    test('before load, the built-in model is used', () {
      expect(ChatProfileService.standard.value, isNull);
      expect(
        ChatProfileService.standardModelId,
        ChatProfileService.builtinModelId,
      );
    });

    test('load reads the stored profile without the network', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'chat_profile_standard_v1': jsonEncode(_json),
      });
      final ChatProfile? loaded = await ChatProfileService.load();
      expect(loaded?.modelId, 'deepseek/deepseek-v4.1-flash-1017');
      expect(ChatProfileService.standard.value, same(loaded));
    });

    test('a stored model id replaces the built-in one', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'chat_profile_standard_v1': jsonEncode(<String, Object?>{
          ..._json,
          'model': <String, Object?>{'id': 'vendor/new', 'name': 'New'},
        }),
      });
      await ChatProfileService.load();
      expect(ChatProfileService.standardModelId, 'vendor/new');
    });

    test('a corrupt stored copy is ignored', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'chat_profile_standard_v1': 'not json',
      });
      expect(await ChatProfileService.load(), isNull);
      expect(
        ChatProfileService.standardModelId,
        ChatProfileService.builtinModelId,
      );
    });

    test('resetForTest clears the profile', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'chat_profile_standard_v1': jsonEncode(_json),
      });
      await ChatProfileService.load();
      ChatProfileService.resetForTest();
      expect(ChatProfileService.standard.value, isNull);
    });
  });
}
