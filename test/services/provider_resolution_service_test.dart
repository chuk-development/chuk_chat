// "Auto (cheapest)" is a provider choice, not a provider. These tests pin the
// rules that keep a send with Auto working:
//
// - the Auto marker never reaches the server; it becomes the cheapest real
//   provider of the model at send time, priced for a whole turn (prompt
//   and output), not by output price alone,
// - the provider list comes from the model catalogue, not from a widget
//   (the old resolver read a dropdown that is never built, so every send
//   with Auto failed with "No provider is configured"),
// - a model that is missing from the cached catalogue triggers one fetch,
// - every send path (composer, helpers) resolves it.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/platform_specific/chat/model_provider_resolution_mixin.dart';
import 'package:chuk_chat/services/chat_model_selection_service.dart';
import 'package:chuk_chat/services/model_cache_service.dart';
import 'package:chuk_chat/services/provider_resolution_service.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart'
    show kAutoCheapestProviderSlug;

import '../support/kv_cache_test_env.dart';

const String _flash = 'deepseek/deepseek-v4.1-flash-1017';

/// The shape `/v1/models_info` returns. Prices are per token, as strings
/// and as numbers, because the server has sent both.
Map<String, dynamic> _model(String id, List<List<Object>> providers) =>
    <String, dynamic>{
      'id': id,
      'name': 'DeepSeek: DeepSeek V4.1 Flash 1017',
      'providers': <Map<String, dynamic>>[
        for (final p in providers)
          <String, dynamic>{
            'slug': p[0],
            'name': p[0],
            'pricing': <String, dynamic>{'prompt': p[1], 'completion': p[2]},
          },
      ],
    };

final List<Map<String, dynamic>> _catalogue = <Map<String, dynamic>>[
  _model(_flash, <List<Object>>[
    <Object>['wafer', '0.000000038', '0.0000005'],
    <Object>['sail', 0.000000101, 0.00000015],
    <Object>['digitalocean', '0.00000018', '0.00000072'],
  ]),
];

class _Composer extends StatefulWidget {
  const _Composer({super.key, required this.modelId, required this.slug});
  final String modelId;
  final String? slug;
  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer>
    with ModelProviderResolutionMixin {
  @override
  String get selectedModelId => widget.modelId;
  @override
  late String? selectedProviderSlug = widget.slug;
  @override
  String? get modelSelectionChatId => null;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Map<String, dynamic>> cache;
  late int refreshes;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ChatModelSelectionService.instance.clearMemoryForTesting();
    cache = List<Map<String, dynamic>>.from(_catalogue);
    refreshes = 0;
    ProviderResolutionService.loadCatalogue = () async => cache;
    ProviderResolutionService.refreshCatalogue = () async => refreshes++;
  });

  tearDown(ProviderResolutionService.resetForTesting);

  group('resolveForSend', () {
    test('Auto becomes the cheapest provider for a typical turn', () async {
      expect(
        await ProviderResolutionService.resolveForSend(
          _flash,
          kAutoCheapestProviderSlug,
        ),
        'wafer',
      );
      expect(refreshes, 0);
    });

    test('Auto with spaces around it is still Auto', () async {
      expect(
        await ProviderResolutionService.resolveForSend(
          _flash,
          ' $kAutoCheapestProviderSlug ',
        ),
        'wafer',
      );
    });

    test('a concrete provider is sent unchanged', () async {
      expect(
        await ProviderResolutionService.resolveForSend(_flash, 'digitalocean'),
        'digitalocean',
      );
    });

    test('nothing stored falls back to the cheapest provider', () async {
      expect(
        await ProviderResolutionService.resolveForSend(_flash, null),
        'wafer',
      );
      expect(
        await ProviderResolutionService.resolveForSend(_flash, ''),
        'wafer',
      );
    });

    test('a model missing from the cache is fetched once', () async {
      cache = <Map<String, dynamic>>[];
      ProviderResolutionService.refreshCatalogue = () async {
        refreshes++;
        cache = List<Map<String, dynamic>>.from(_catalogue);
      };
      expect(
        await ProviderResolutionService.resolveForSend(
          _flash,
          kAutoCheapestProviderSlug,
        ),
        'wafer',
      );
      expect(refreshes, 1);
    });

    test('no provider anywhere gives null, never the Auto marker', () async {
      cache = <Map<String, dynamic>>[];
      expect(
        await ProviderResolutionService.resolveForSend(
          _flash,
          kAutoCheapestProviderSlug,
        ),
        isNull,
      );
      expect(refreshes, 1);
    });

    test('a failing catalogue gives null instead of throwing', () async {
      ProviderResolutionService.loadCatalogue = () async =>
          throw StateError('cache locked');
      ProviderResolutionService.refreshCatalogue = () async =>
          throw StateError('offline');
      expect(
        await ProviderResolutionService.resolveForSend(
          _flash,
          kAutoCheapestProviderSlug,
        ),
        isNull,
      );
    });

    test('a tie keeps the first listed provider', () {
      final slug = ProviderResolutionService.cheapestSlugIn(
        <Map<String, dynamic>>[
          _model('x/y', <List<Object>>[
            <Object>['first', 0, 1],
            <Object>['second', 0, 1],
          ]),
        ],
        'x/y',
      );
      expect(slug, 'first');
    });
  });

  test('the real model cache feeds the resolver', () async {
    final Directory kv = await useTempKvCache();
    addTearDown(() => disposeTempKvCache(kv));
    ModelCacheService.debugClearMemo();
    ProviderResolutionService.resetForTesting();
    ProviderResolutionService.refreshCatalogue = () async => refreshes++;
    await ModelCacheService.saveAvailableModels(_catalogue);
    expect(
      await ProviderResolutionService.resolveForSend(
        _flash,
        kAutoCheapestProviderSlug,
      ),
      'wafer',
    );
    expect(refreshes, 0);
  });

  group('send paths', () {
    testWidgets('composer with Auto sends the cheapest provider', (
      tester,
    ) async {
      final key = GlobalKey<_ComposerState>();
      await tester.pumpWidget(
        MaterialApp(
          home: _Composer(
            key: key,
            modelId: _flash,
            slug: kAutoCheapestProviderSlug,
          ),
        ),
      );
      final String? sent = await key.currentState!
          .ensureProviderSlugForCurrentModel();
      expect(sent, 'wafer');
      // The choice stays Auto for the next send.
      expect(key.currentState!.selectedProviderSlug, kAutoCheapestProviderSlug);
    });

    test('helper path resolves Auto too', () async {
      expect(
        await ChatUiHelpers.ensureProviderSlug(
          _flash,
          kAutoCheapestProviderSlug,
        ),
        'wafer',
      );
      expect(
        await ChatUiHelpers.ensureProviderSlug(_flash, 'digitalocean'),
        'digitalocean',
      );
    });
  });
}
