// Under Standard the provider a send uses is the profile marker (the server
// picks), even when the same model carries a different per-model pin or an
// old stored provider. The per-model pin used to overwrite the mode's
// provider on every mode switch.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/platform_specific/chat/model_provider_resolution_mixin.dart';
import 'package:chuk_chat/services/chat_mode_service.dart';
import 'package:chuk_chat/services/chat_profile_service.dart';

class _Host extends StatefulWidget {
  const _Host();

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with ModelProviderResolutionMixin<_Host> {
  @override
  String selectedModelId = '';

  @override
  String? selectedProviderSlug;

  @override
  ChatMode chatMode = ChatMode.standard;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

const String _model = 'deepseek/deepseek-v4.1-flash-1017';
const String _modeProvider = ChatProfileService.standardMarker;
const String _storedProvider = 'wafer';

void main() {
  setUp(() {
    ChatProfileService.resetForTest();
    SharedPreferences.setMockInitialValues({});
  });

  Future<_HostState> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(const _Host());
    return tester.state<_HostState>(find.byType(_Host));
  }

  testWidgets('Standard mode resolves to the profile marker', (tester) async {
    await tester.runAsync(() async {
      await ChatModeService.setModelForMode(
        ChatMode.standard,
        modelId: _model,
        providerSlug: _storedProvider,
      );
    });
    final host = await pumpHost(tester);
    host.selectedModelId = _model;
    host.selectedProviderSlug = 'fireworks/serverless';

    await tester.runAsync(
      () => host.loadProviderSlugForModel(_model, forceFromPrefs: true),
    );

    expect(host.selectedProviderSlug, _modeProvider);
  });

  testWidgets('send-time lookup replaces a stale cached slug', (tester) async {
    await tester.runAsync(() async {
      await ChatModeService.setModelForMode(
        ChatMode.standard,
        modelId: _model,
        providerSlug: _storedProvider,
      );
    });
    final host = await pumpHost(tester);
    host.selectedModelId = _model;
    host.selectedProviderSlug = 'fireworks/serverless';

    final String? slug = await tester.runAsync<String?>(
      () => host.ensureProviderSlugForCurrentModel(),
    );

    expect(slug, _modeProvider);
    expect(host.selectedProviderSlug, _modeProvider);
  });

  testWidgets('a lookup made obsolete by a mode switch is dropped', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await ChatModeService.setModelForMode(
        ChatMode.standard,
        modelId: _model,
        providerSlug: _storedProvider,
      );
    });
    final host = await pumpHost(tester);
    host.selectedModelId = _model;
    host.selectedProviderSlug = 'fireworks/serverless';

    await tester.runAsync(() async {
      final Future<void> lookup = host.loadProviderSlugForModel(
        _model,
        forceFromPrefs: true,
      );
      host.chatMode = ChatMode.custom;
      await lookup;
    });

    expect(host.selectedProviderSlug, 'fireworks/serverless');
  });

  testWidgets('the Standard marker is ignored for another model', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await ChatModeService.setModelForMode(
        ChatMode.standard,
        modelId: _model,
        providerSlug: _storedProvider,
      );
    });
    final host = await pumpHost(tester);

    final String? slug = await tester.runAsync<String?>(
      () => host.modeProviderSlugFor('deepseek/deepseek-v4-pro-0813'),
    );

    expect(slug, isNull);
  });

  testWidgets('Custom mode keeps the per-model pin path', (tester) async {
    await tester.runAsync(() async {
      await ChatModeService.setModelForMode(
        ChatMode.custom,
        modelId: _model,
        providerSlug: _storedProvider,
      );
    });
    final host = await pumpHost(tester);
    host.chatMode = ChatMode.custom;

    final String? slug = await tester.runAsync<String?>(
      () => host.modeProviderSlugFor(_model),
    );

    expect(slug, isNull);
  });
}
