import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/core/model_selection_events.dart';
import 'package:chuk_chat/services/per_model_system_prompt_service.dart';
import 'package:chuk_chat/services/title_generation_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';

/// The sign-out-mid-flight race: an operation starts as user A, A signs out and
/// B signs in *while it is suspended on an await*, and the continuation then
/// resumes. Nothing has called a public entry point in between, so
/// `_cacheOwnerUserId` still says "A" — which is precisely why ownership must be
/// re-checked against **live auth** and not against the cached owner.
///
/// Each test flips [debugCurrentUserIdOverride] between starting a future and
/// awaiting it. That is a real suspension point (the first `await` inside the
/// call has already yielded), so the switch genuinely lands mid-flight.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const userA = 'aaaaaaaa-0000-0000-0000-000000000001';
  const userB = 'bbbbbbbb-0000-0000-0000-000000000002';

  String? activeUser;

  setUp(() {
    activeUser = null;
    SharedPreferences.setMockInitialValues({});
    UserPreferencesService.debugCurrentUserIdOverride = () => activeUser;
    PerModelSystemPromptService.debugCurrentUserIdOverride = () => activeUser;
    TitleGenerationService.debugCurrentUserIdOverride = () => activeUser;
    UserPreferencesService.debugPrimeCachesForUser(null);
    PerModelSystemPromptService.debugReset();
    TitleGenerationService.debugPrimeCachesForUser(null);
  });

  tearDown(() {
    UserPreferencesService.debugCurrentUserIdOverride = null;
    PerModelSystemPromptService.debugCurrentUserIdOverride = null;
    TitleGenerationService.debugCurrentUserIdOverride = null;
    UserPreferencesService.debugPrimeCachesForUser(null);
    PerModelSystemPromptService.debugReset();
    TitleGenerationService.debugPrimeCachesForUser(null);
  });

  group('_stillOwns consults live auth, not the cached owner', () {
    // This is the root defect. `_cacheOwnerUserId` only advances when a public
    // entry point runs, so after a silent A->B switch it still names A. A
    // predicate that only compares against it answers "A still owns this" while
    // B is signed in.
    test(
      'is false once live auth moved to B, though cached owner still says A',
      () {
        activeUser = userA;
        UserPreferencesService.debugPrimeCachesForUser(
          userA,
          systemPrompt: 'user A private prompt',
        );

        // A signs out, B signs in. No entry point has run.
        activeUser = userB;

        expect(
          UserPreferencesService.debugCacheOwnerUserId,
          userA,
          reason: 'cached owner is stale by design — that is the whole point',
        );
        expect(UserPreferencesService.debugStillOwns(userA), isFalse);
      },
    );

    test('is false once signed out entirely', () {
      activeUser = userA;
      UserPreferencesService.debugPrimeCachesForUser(userA);
      activeUser = null;
      expect(UserPreferencesService.debugStillOwns(userA), isFalse);
    });

    test('is true while the same user is still live', () {
      activeUser = userA;
      UserPreferencesService.debugPrimeCachesForUser(userA);
      expect(UserPreferencesService.debugStillOwns(userA), isTrue);
    });

    test('a null userId never owns anything', () {
      activeUser = null;
      UserPreferencesService.debugPrimeCachesForUser(null);
      expect(UserPreferencesService.debugStillOwns(null), isFalse);
    });

    test('holds for every service that keys a cache', () {
      activeUser = userA;
      PerModelSystemPromptService.debugPrimeCacheForUser(userA, {});
      TitleGenerationService.debugPrimeCachesForUser(userA);

      activeUser = userB;

      expect(PerModelSystemPromptService.debugStillOwns(userA), isFalse);
      expect(TitleGenerationService.debugStillOwns(userA), isFalse);
    });
  });

  group('UserPreferencesService: A data is not returned to B', () {
    test(
      'selected model read as A, resumed after switch to B, returns null',
      () async {
        // ModelCacheService stores this plaintext under a user-keyed prefs key.
        SharedPreferences.setMockInitialValues({
          'cached_selected_model_$userA': 'user-a/secret-model',
        });
        activeUser = userA;

        final future = UserPreferencesService.loadSelectedModel();
        // The local prefs read has yielded; A signs out and B signs in here.
        activeUser = userB;
        final result = await future;

        expect(
          result,
          isNull,
          reason: "A's model must not be handed to B through the return value",
        );
        expect(UserPreferencesService.debugSelectedModelCache, isNull);
      },
    );

    test(
      'no stale model-selection event reaches B on that raced load',
      () async {
        SharedPreferences.setMockInitialValues({
          'cached_selected_model_$userA': 'user-a/secret-model',
        });
        final emitted = <String>[];
        final sub = ModelSelectionEventBus().modelSelectedStream.listen(
          emitted.add,
        );
        addTearDown(sub.cancel);

        activeUser = userA;
        final future = UserPreferencesService.loadSelectedModel();
        activeUser = userB;
        await future;
        // Let any fire-and-forget background sync settle.
        await Future<void>.delayed(Duration.zero);

        expect(
          emitted,
          isEmpty,
          reason: "B's UI must not be told to select A's model",
        );
      },
    );

    test(
      'provider preferences read as A, resumed after switch to B, return empty',
      () async {
        SharedPreferences.setMockInitialValues({
          'cached_provider_prefs_$userA': jsonEncode({
            'user-a/model': 'user-a-provider',
          }),
        });
        activeUser = userA;

        final future = UserPreferencesService.loadAllProviderPreferences();
        activeUser = userB;
        final result = await future;

        expect(result, isEmpty);
        expect(UserPreferencesService.debugProviderPreferencesCache, isNull);
      },
    );

    test('the same read completes normally when nobody switches', () async {
      SharedPreferences.setMockInitialValues({
        'cached_selected_model_$userA': 'user-a/secret-model',
      });
      activeUser = userA;

      // No switch: the guard must not break the happy path.
      final result = await UserPreferencesService.loadSelectedModel();

      expect(result, 'user-a/secret-model');
      expect(
        UserPreferencesService.debugSelectedModelCache,
        'user-a/secret-model',
      );
    });
  });

  group('PerModelSystemPromptService: A prompts are not returned to B', () {
    // Mode-only entries (empty ciphertext) round-trip without an encryption
    // key, so loadAll() yields a non-empty map in a unit test.
    String blobFor(String modelId) => jsonEncode({
      modelId: {'prompt': '', 'mode': 'replace'},
    });

    test(
      'loadAll started as A, resumed after switch to B, returns empty',
      () async {
        SharedPreferences.setMockInitialValues({
          PerModelSystemPromptService.localCacheKeyForUser(userA): blobFor(
            'user-a/model',
          ),
        });
        activeUser = userA;

        final future = PerModelSystemPromptService.loadAll();
        activeUser = userB;
        final result = await future;

        expect(
          result,
          isEmpty,
          reason: "A's decrypted per-model map must not be returned to B",
        );
        expect(PerModelSystemPromptService.debugCache, isNull);
      },
    );

    test('loadAll completes normally when nobody switches', () async {
      SharedPreferences.setMockInitialValues({
        PerModelSystemPromptService.localCacheKeyForUser(userA): blobFor(
          'user-a/model',
        ),
      });
      activeUser = userA;

      final result = await PerModelSystemPromptService.loadAll();

      expect(result.keys, contains('user-a/model'));
    });
  });

  group('TitleGenerationService: A settings are not returned to B', () {
    test(
      'getSystemPrompt started as A, resumed after switch, returns default',
      () async {
        SharedPreferences.setMockInitialValues({
          TitleGenerationService.systemPromptKeyForUser(userA):
              'user A private title prompt',
        });
        activeUser = userA;

        final future = TitleGenerationService.getSystemPrompt();
        activeUser = userB;
        final result = await future;

        expect(
          result,
          TitleGenerationService.defaultSystemPrompt,
          reason: "A's plaintext title prompt must never reach B",
        );
        expect(TitleGenerationService.debugCustomSystemPrompt, isNull);
      },
    );

    test(
      'isEnabled started as A, resumed after switch to B, returns false',
      () async {
        SharedPreferences.setMockInitialValues({
          TitleGenerationService.settingsKeyForUser(userA): true,
        });
        activeUser = userA;

        final future = TitleGenerationService.isEnabled();
        activeUser = userB;
        final result = await future;

        expect(result, isFalse);
        expect(TitleGenerationService.debugAutoGenerateTitlesEnabled, isNull);
      },
    );

    test('getSystemPrompt returns A prompt when nobody switches', () async {
      SharedPreferences.setMockInitialValues({
        TitleGenerationService.systemPromptKeyForUser(userA):
            'user A private title prompt',
      });
      activeUser = userA;

      final result = await TitleGenerationService.getSystemPrompt();

      expect(result, 'user A private title prompt');
    });

    test(
      'a local write as A does not land under B key when the user switches',
      () async {
        activeUser = userA;

        final future = TitleGenerationService.setSystemPrompt('A prompt');
        activeUser = userB;
        await future;

        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString(TitleGenerationService.systemPromptKeyForUser(userB)),
          isNull,
          reason: "A's prompt must never appear under B's namespace",
        );
        expect(
          TitleGenerationService.debugCustomSystemPrompt,
          isNull,
          reason: "A's prompt must not sit in the cache while B is active",
        );
      },
    );
  });
}
