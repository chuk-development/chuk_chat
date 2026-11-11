import 'package:chuk_chat/l10n/strings_de.dart';
import 'package:chuk_chat/l10n/strings_en.dart';
import 'package:chuk_chat/services/shortcut_registry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('ids are unique and every entry has a label and a description', () {
    final Set<String> ids = <String>{};
    for (final ShortcutEntry e in AppShortcuts.entries) {
      expect(ids.add(e.id), isTrue, reason: 'duplicate ${e.id}');
      expect(AppShortcuts.label(e.id), isNotEmpty);
      expect(stringsEn[e.descriptionKey], isNotNull, reason: e.id);
      expect(stringsDe[e.descriptionKey], isNotNull, reason: e.id);
      expect(AppShortcuts.describe(e.id), stringsEn[e.descriptionKey]);
      if (e.bindable) {
        expect(AppShortcuts.activator(e.id), isNotNull, reason: e.id);
      } else {
        expect(AppShortcuts.activator(e.id), isNull);
      }
    }
  });

  test('labels use Ctrl on Linux and Cmd on macOS', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(AppShortcuts.label(AppShortcuts.showShortcuts), 'Ctrl+/');
    expect(AppShortcuts.keyCaps(AppShortcuts.newRoom), <String>[
      'Ctrl',
      'Shift',
      'N',
    ]);
    expect(AppShortcuts.tooltip('Send', AppShortcuts.send), 'Send (Enter)');
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(AppShortcuts.label(AppShortcuts.showShortcuts), '⌘/');
    expect(AppShortcuts.keyCaps(AppShortcuts.newRoom), <String>[
      '⌘',
      'Shift',
      'N',
    ]);
  });

  test('activators map Ctrl to control, or meta on macOS', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final SingleActivator a = AppShortcuts.activator(AppShortcuts.newRoom)!;
    expect(a.trigger, LogicalKeyboardKey.keyN);
    expect(a.control, isTrue);
    expect(a.meta, isFalse);
    expect(a.shift, isTrue);
    expect(
      AppShortcuts.activator(AppShortcuts.showShortcuts)!.trigger,
      LogicalKeyboardKey.slash,
    );
    expect(
      AppShortcuts.activator(AppShortcuts.cancelEdit)!.trigger,
      LogicalKeyboardKey.escape,
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final SingleActivator m = AppShortcuts.activator(
      AppShortcuts.showShortcuts,
    )!;
    expect(m.meta, isTrue);
    expect(m.control, isFalse);
  });

  test('an unknown id throws', () {
    expect(() => AppShortcuts.label('nope'), throwsArgumentError);
  });
}
