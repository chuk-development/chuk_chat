import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chuk_chat/services/settings/mobile_chat_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'messenger typography is independent and can restore the custom font',
    () async {
      SharedPreferences.setMockInitialValues({
        'chatFontFamily': 'JetBrainsMono',
      });
      final first = MobileChatPreferences();
      final restored = MobileChatPreferences();
      addTearDown(first.dispose);
      addTearDown(restored.dispose);
      await first.load();
      expect(first.messengerTypography, isTrue);
      await first.setMessengerTypography(false);
      await restored.load();
      expect(restored.messengerTypography, isFalse);
      expect(
        (await SharedPreferences.getInstance()).getString('chatFontFamily'),
        'JetBrainsMono',
      );
    },
  );

  test(
    'mobile presentation defaults off independently of legacy settings',
    () async {
      SharedPreferences.setMockInitialValues({
        'showReasoningTokens': true,
        'show_reasoning_tokens': true,
        'verbose_view_enabled': true,
        'dev_verbose_logging': true,
        'reasoning_effort': 'high',
      });
      final preferences = MobileChatPreferences();
      addTearDown(preferences.dispose);
      expect(preferences.showThinking, isFalse);
      expect(preferences.showActivity, isFalse);
      await preferences.load();
      expect(preferences.showThinking, isFalse);
      expect(preferences.showActivity, isFalse);
      final stored = await SharedPreferences.getInstance();
      expect(stored.getBool('verbose_view_enabled'), isTrue);
      expect(stored.getBool('showReasoningTokens'), isTrue);
      expect(stored.getString('reasoning_effort'), 'high');
    },
  );

  test(
    'choices persist independently and restore into a fresh instance',
    () async {
      SharedPreferences.setMockInitialValues({});
      final first = MobileChatPreferences();
      final restored = MobileChatPreferences();
      addTearDown(first.dispose);
      addTearDown(restored.dispose);
      await first.setThinking(true);
      expect(first.showActivity, isFalse);
      await first.setActivity(true);
      await first.setThinking(false);
      await restored.load();
      expect(restored.showThinking, isFalse);
      expect(restored.showActivity, isTrue);
    },
  );

  test(
    'rapid choices preserve the last selection in memory and storage',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = MobileChatPreferences();
      addTearDown(preferences.dispose);
      await Future.wait([
        preferences.setThinking(true),
        preferences.setActivity(true),
        preferences.setThinking(false),
        preferences.setActivity(false),
        preferences.setThinking(true),
      ]);
      final stored = await SharedPreferences.getInstance();
      expect(preferences.showThinking, isTrue);
      expect(preferences.showActivity, isFalse);
      expect(stored.getBool(MobileChatPreferences.reasoningKey), isTrue);
      expect(stored.getBool(MobileChatPreferences.activityKey), isFalse);
    },
  );
}
