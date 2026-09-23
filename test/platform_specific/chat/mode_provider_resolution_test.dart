// The provider picked for Fast or Thinking must be the one a send uses, even
// when the same model carries a different per-model pin. The per-model pin
// used to overwrite the mode's provider on every mode switch.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/platform_specific/chat/model_provider_resolution_mixin.dart';
import 'package:chuk_chat/services/chat_mode_service.dart';

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
  ChatMode chatMode = ChatMode.fast;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

const String _model = 'z-ai/glm-5.3-flash';
const String _modeProvider = 'wafer';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<_HostState> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(const _Host());
    return tester.state<_HostState>(find.byType(_Host));
  }

  testWidgets('Fast mode resolves to its own provider', (tester) async {
    await tester.runAsync(() async {
      await ChatModeService.setModelForMode(
        ChatMode.fast,
        modelId: _model,
        providerSlug: _modeProvider,
      );
    });
    final host = await pumpHost(tester);
    host.selectedProviderSlug = 'fireworks/serverless';

    await tester.runAsync(
      () => host.loadProviderSlugForModel(_model, forceFromPrefs: true),
    );

    expect(host.selectedProviderSlug, _modeProvider);
  });

  testWidgets('send-time lookup replaces a stale cached slug', (tester) async {
    await tester.runAsync(() async {
      await ChatModeService.setModelForMode(
        ChatMode.fast,
        modelId: _model,
        providerSlug: _modeProvider,
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

  testWidgets('the mode provider is ignored for another model', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await ChatModeService.setModelForMode(
        ChatMode.fast,
        modelId: _model,
        providerSlug: _modeProvider,
      );
    });
    final host = await pumpHost(tester);

    final String? slug = await tester.runAsync<String?>(
      () => host.modeProviderSlugFor('deepseek/deepseek-v4-pro-0813'),
    );

    expect(slug, isNull);
  });

  testWidgets('custom mode keeps the per-model pin path', (tester) async {
    await tester.runAsync(() async {
      await ChatModeService.setModelForMode(
        ChatMode.custom,
        modelId: _model,
        providerSlug: _modeProvider,
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
