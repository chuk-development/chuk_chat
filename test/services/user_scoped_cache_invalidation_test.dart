import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/per_model_system_prompt_service.dart';
import 'package:chuk_chat/services/title_generation_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';

/// Guards the cross-user leak fix: the static caches in these services are
/// keyed by user id and self-invalidate on every access, so a second user
/// signing in without an app restart cannot read the first user's data.
///
/// These drive the user-change path through `@visibleForTesting` seams because
/// the production entry points read the active user id from
/// `SupabaseService.auth`, which needs a live backend. The seams call the very
/// same private `_syncCacheToCurrentUser` the entry points do.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const userA = 'aaaaaaaa-0000-0000-0000-000000000001';
  const userB = 'bbbbbbbb-0000-0000-0000-000000000002';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UserPreferencesService.debugPrimeCachesForUser(null);
    PerModelSystemPromptService.debugReset();
    TitleGenerationService.debugPrimeCachesForUser(null);
  });

  group('UserPreferencesService user-keyed invalidation', () {
    test('drops the system prompt when a different user becomes active', () {
      UserPreferencesService.debugPrimeCachesForUser(
        userA,
        systemPrompt: 'user A private prompt',
      );

      UserPreferencesService.debugSyncCacheToUser(userB);

      expect(UserPreferencesService.debugSystemPromptMemCache, isNull);
      expect(UserPreferencesService.debugCacheOwnerUserId, userB);
    });

    test('drops every per-user cache, not just the system prompt', () {
      UserPreferencesService.debugPrimeCachesForUser(
        userA,
        systemPrompt: 'user A private prompt',
        selectedModel: 'user-a/model',
        providerPreferences: {'user-a/model': 'provider-a'},
      );

      UserPreferencesService.debugSyncCacheToUser(userB);

      expect(UserPreferencesService.debugSystemPromptMemCache, isNull);
      expect(UserPreferencesService.debugSelectedModelCache, isNull);
      expect(UserPreferencesService.debugProviderPreferencesCache, isNull);
    });

    test('keeps the cache when the same user is still active', () {
      UserPreferencesService.debugPrimeCachesForUser(
        userA,
        systemPrompt: 'user A private prompt',
        selectedModel: 'user-a/model',
      );

      UserPreferencesService.debugSyncCacheToUser(userA);

      expect(
        UserPreferencesService.debugSystemPromptMemCache,
        'user A private prompt',
      );
      expect(UserPreferencesService.debugSelectedModelCache, 'user-a/model');
    });

    test('signing out drops the cache too (userId becomes null)', () {
      UserPreferencesService.debugPrimeCachesForUser(
        userA,
        systemPrompt: 'user A private prompt',
      );

      UserPreferencesService.debugSyncCacheToUser(null);

      expect(UserPreferencesService.debugSystemPromptMemCache, isNull);
    });

    test(
      'a user with no prompt set caches "" and does not inherit it on switch',
      () {
        // '' means "loaded, no prompt set" and stops the send path re-hitting
        // the network; null means "not loaded". The distinction is load-bearing,
        // so invalidation must reset to null, never to ''.
        UserPreferencesService.debugPrimeCachesForUser(userA, systemPrompt: '');
        expect(UserPreferencesService.debugSystemPromptMemCache, '');

        UserPreferencesService.debugSyncCacheToUser(userB);

        expect(
          UserPreferencesService.debugSystemPromptMemCache,
          isNull,
          reason: 'must be "not loaded", not "loaded and empty"',
        );
      },
    );

    test('re-priming the same user preserves the "" sentinel', () {
      UserPreferencesService.debugPrimeCachesForUser(userA, systemPrompt: '');

      UserPreferencesService.debugSyncCacheToUser(userA);

      expect(UserPreferencesService.debugSystemPromptMemCache, '');
    });
  });

  group('UserPreferencesService system-prompt prefs key namespacing', () {
    test('the cache key is namespaced by user id', () {
      final keyA = UserPreferencesService.systemPromptCacheKeyForUser(userA);
      final keyB = UserPreferencesService.systemPromptCacheKeyForUser(userB);

      expect(keyA, isNot(keyB));
      expect(keyA, contains(userA));
      expect(keyB, contains(userB));
    });

    test('the namespaced key is not the legacy shared key', () {
      expect(
        UserPreferencesService.systemPromptCacheKeyForUser(userA),
        isNot(UserPreferencesService.legacySystemPromptCacheKey),
      );
      expect(
        UserPreferencesService.legacySystemPromptCacheKey,
        'cached_system_prompt',
      );
    });

    test('a local read drops the legacy key instead of migrating it', () async {
      // An install from before namespacing: one un-namespaced blob whose owner
      // is unknowable. Dropping it costs a re-fetch; adopting it would be the
      // leak itself.
      SharedPreferences.setMockInitialValues({
        UserPreferencesService.legacySystemPromptCacheKey:
            'ciphertext-of-user-A',
      });

      await UserPreferencesService.debugLoadSystemPromptLocalForUser(userB);

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.containsKey(UserPreferencesService.legacySystemPromptCacheKey),
        isFalse,
        reason: 'legacy key must be deleted',
      );
      expect(
        prefs.getString(
          UserPreferencesService.systemPromptCacheKeyForUser(userB),
        ),
        isNull,
        reason: 'legacy value must never be adopted by the current user',
      );
    });

    test('one user cannot read another user namespaced entry', () async {
      SharedPreferences.setMockInitialValues({
        UserPreferencesService.systemPromptCacheKeyForUser(userA):
            'ciphertext-of-user-A',
      });

      // Returns null: user B's key holds nothing. (Decryption of A's blob is
      // never even attempted — the read is scoped to B's key.)
      final result =
          await UserPreferencesService.debugLoadSystemPromptLocalForUser(userB);

      expect(result, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(
          UserPreferencesService.systemPromptCacheKeyForUser(userA),
        ),
        'ciphertext-of-user-A',
        reason: "another user's namespaced entry must be left untouched",
      );
    });
  });

  group('PerModelSystemPromptService user-keyed invalidation', () {
    test('drops decrypted per-model prompts on user change', () {
      PerModelSystemPromptService.debugPrimeCacheForUser(userA, {
        'user-a/model': const ModelPromptConfig(
          prompt: 'user A per-model prompt',
          mode: ModelPromptMode.append,
        ),
      });

      PerModelSystemPromptService.debugSyncCacheToUser(userB);

      expect(PerModelSystemPromptService.debugCache, isNull);
    });

    test('keeps decrypted per-model prompts for the same user', () {
      PerModelSystemPromptService.debugPrimeCacheForUser(userA, {
        'user-a/model': const ModelPromptConfig(
          prompt: 'user A per-model prompt',
          mode: ModelPromptMode.append,
        ),
      });

      PerModelSystemPromptService.debugSyncCacheToUser(userA);

      expect(PerModelSystemPromptService.debugCache, isNotNull);
      expect(
        PerModelSystemPromptService.debugCache!['user-a/model']!.prompt,
        'user A per-model prompt',
      );
    });

    test('the local key is namespaced and differs from the legacy key', () {
      expect(
        PerModelSystemPromptService.localCacheKeyForUser(userA),
        isNot(PerModelSystemPromptService.localCacheKeyForUser(userB)),
      );
      expect(
        PerModelSystemPromptService.localCacheKeyForUser(userA),
        isNot(PerModelSystemPromptService.legacyLocalCacheKey),
      );
      expect(
        PerModelSystemPromptService.legacyLocalCacheKey,
        'cached_model_system_prompts',
      );
    });
  });

  group('TitleGenerationService user-keyed invalidation', () {
    test('drops the custom title prompt on user change', () {
      TitleGenerationService.debugPrimeCachesForUser(
        userA,
        autoGenerateTitles: true,
        customSystemPrompt: 'user A title prompt',
      );

      TitleGenerationService.debugSyncCacheToUser(userB);

      expect(TitleGenerationService.debugCustomSystemPrompt, isNull);
      expect(TitleGenerationService.debugAutoGenerateTitlesEnabled, isNull);
    });

    test('keeps the custom title prompt for the same user', () {
      TitleGenerationService.debugPrimeCachesForUser(
        userA,
        autoGenerateTitles: true,
        customSystemPrompt: 'user A title prompt',
      );

      TitleGenerationService.debugSyncCacheToUser(userA);

      expect(
        TitleGenerationService.debugCustomSystemPrompt,
        'user A title prompt',
      );
      expect(TitleGenerationService.debugAutoGenerateTitlesEnabled, isTrue);
    });

    test('keys are namespaced by user id', () {
      expect(
        TitleGenerationService.systemPromptKeyForUser(userA),
        isNot(TitleGenerationService.systemPromptKeyForUser(userB)),
      );
      expect(
        TitleGenerationService.settingsKeyForUser(userA),
        isNot(TitleGenerationService.settingsKeyForUser(userB)),
      );
      expect(
        TitleGenerationService.systemPromptKeyForUser(userA),
        isNot(TitleGenerationService.legacySystemPromptKey),
      );
    });

    test('legacy plaintext keys are dropped, never migrated', () async {
      // This prompt was stored as plaintext under a shared key — no encryption
      // mismatch would have stopped user B from reading it.
      SharedPreferences.setMockInitialValues({
        TitleGenerationService.legacySystemPromptKey: 'user A title prompt',
        TitleGenerationService.legacySettingsKey: true,
      });

      final prefs = await SharedPreferences.getInstance();
      await TitleGenerationService.debugDropLegacyKeys(prefs);

      expect(
        prefs.containsKey(TitleGenerationService.legacySystemPromptKey),
        isFalse,
      );
      expect(
        prefs.containsKey(TitleGenerationService.legacySettingsKey),
        isFalse,
      );
      expect(
        prefs.getString(TitleGenerationService.systemPromptKeyForUser(userB)),
        isNull,
        reason: "user B must not inherit user A's plaintext title prompt",
      );
    });
  });
}
