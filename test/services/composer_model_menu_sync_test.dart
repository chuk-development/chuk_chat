// The composer's model menu must follow the model screen at once.
//
// Bug (2026-11-03): a model enabled in the settings (provider set to Auto)
// was missing from the composer's menu. The menu list was only rebuilt when
// the model screen was opened from the composer itself, so after a change
// through the settings it stayed stale until some unrelated action. The
// refresh event that every provider change fires now rebuilds it.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/core/model_selection_events.dart';
import 'package:chuk_chat/platform_specific/chat/chat_model_selection_mixin.dart';
import 'package:chuk_chat/platform_specific/chat/model_provider_resolution_mixin.dart';
import 'package:chuk_chat/services/chat_model_selection_service.dart';
import 'package:chuk_chat/services/model_cache_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart'
    show kAutoCheapestProviderSlug;

import '../support/kv_cache_test_env.dart';

const String _flash = 'deepseek/deepseek-v4.1-flash-1017';

class _Composer extends StatefulWidget {
  const _Composer({super.key});
  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer>
    with ModelProviderResolutionMixin, ChatModelSelectionMixin {
  int menuRebuilds = 0;

  @override
  String? get activeChatId => null;

  @override
  Future<void> refreshPickedModels() async => menuRebuilds++;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Same mixin, with the real [applyPickedModels] reachable.
class _RealMenu extends StatefulWidget {
  const _RealMenu({super.key});
  @override
  State<_RealMenu> createState() => _RealMenuState();
}

class _RealMenuState extends State<_RealMenu>
    with ModelProviderResolutionMixin, ChatModelSelectionMixin {
  @override
  String? get activeChatId => null;

  // Reads Supabase; the menu content is what is under test here.
  @override
  Future<void> refreshPickedModels() async {}

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// The catalogue the menu takes names from. Real disk IO, so call it inside
/// `tester.runAsync`.
Future<void> _seedCatalogue() =>
    ModelCacheService.saveAvailableModels(<Map<String, dynamic>>[
      <String, dynamic>{'id': _flash, 'name': 'DeepSeek: V4.1 Flash 1017'},
      <String, dynamic>{'id': 'z-ai/glm-5.3-flash', 'name': 'Z.ai: GLM 5.3 Flash'},
    ]);

void main() {
  late Directory kv;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ChatModelSelectionService.instance.clearMemoryForTesting();
    kv = await useTempKvCache();
    ModelCacheService.debugClearMemo();
  });

  tearDown(() async => disposeTempKvCache(kv));

  testWidgets('a provider change rebuilds the composer menu', (tester) async {
    final key = GlobalKey<_ComposerState>();
    await tester.pumpWidget(MaterialApp(home: _Composer(key: key)));
    expect(key.currentState!.menuRebuilds, 0);

    // What the model screen does after the reader picks Auto.
    await UserPreferencesService.refreshModelSelections();
    await tester.pump();
    await tester.pump();

    expect(key.currentState!.menuRebuilds, 1);
  });

  testWidgets('a disposed composer stops listening', (tester) async {
    final key = GlobalKey<_ComposerState>();
    await tester.pumpWidget(MaterialApp(home: _Composer(key: key)));
    final state = key.currentState!;
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    ModelSelectionEventBus().notifyRefresh();
    await tester.pump();
    expect(state.menuRebuilds, 0);
  });

  testWidgets('a model pinned to Auto is in the menu, with its name', (
    tester,
  ) async {
    await tester.runAsync(() => _seedCatalogue());
    final key = GlobalKey<_RealMenuState>();
    await tester.pumpWidget(MaterialApp(home: _RealMenu(key: key)));

    await tester.runAsync(
      () => key.currentState!.applyPickedModels(<String, String>{
        _flash: kAutoCheapestProviderSlug,
      }),
    );
    await tester.pump();

    final picked = key.currentState!.pickedModels;
    final flash = picked.where((m) => m.id == _flash);
    expect(flash, hasLength(1));
    expect(flash.single.name, 'DeepSeek: V4.1 Flash 1017');
  });

  testWidgets('an unpinned model leaves the menu', (tester) async {
    await tester.runAsync(() => _seedCatalogue());
    final key = GlobalKey<_RealMenuState>();
    await tester.pumpWidget(MaterialApp(home: _RealMenu(key: key)));

    await tester.runAsync(
      () => key.currentState!.applyPickedModels(<String, String>{_flash: ''}),
    );
    await tester.pump();

    expect(key.currentState!.pickedModels.any((m) => m.id == _flash), isFalse);
  });
}
