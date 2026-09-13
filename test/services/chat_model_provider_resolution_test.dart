import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chuk_chat/platform_specific/chat/model_provider_resolution_mixin.dart';
import 'package:chuk_chat/services/chat_model_selection_service.dart';

class _Harness extends StatefulWidget {
  const _Harness({super.key, required this.chat});
  final String chat;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> with ModelProviderResolutionMixin {
  @override
  String get selectedModelId => 'same-model';
  @override
  String? selectedProviderSlug;
  @override
  String? get modelSelectionChatId => widget.chat;
  @override
  Widget build(BuildContext context) => Text(selectedProviderSlug ?? 'empty');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ChatModelSelectionService.instance.clearMemoryForTesting();
  });

  testWidgets('provider lookup honors each chat pin even for same model', (
    tester,
  ) async {
    final store = ChatModelSelectionService.instance;
    await store.save(
      'a',
      const ChatModelSelection(modelId: 'same-model', providerSlug: 'one'),
    );
    await store.save(
      'b',
      const ChatModelSelection(modelId: 'same-model', providerSlug: 'two'),
    );
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        home: _Harness(key: key, chat: 'a'),
      ),
    );
    await key.currentState!.loadProviderSlugForModel(
      'same-model',
      forceFromPrefs: true,
    );
    await tester.pump();
    expect(key.currentState!.selectedProviderSlug, 'one');
    await tester.pumpWidget(
      MaterialApp(
        home: _Harness(key: key, chat: 'b'),
      ),
    );
    await key.currentState!.loadProviderSlugForModel(
      'same-model',
      forceFromPrefs: true,
    );
    await tester.pump();
    expect(key.currentState!.selectedProviderSlug, 'two');
    expect(await key.currentState!.ensureProviderSlugForCurrentModel(), 'two');
  });
}
