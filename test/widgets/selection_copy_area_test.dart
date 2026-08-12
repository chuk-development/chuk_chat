import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/selection_copy_area.dart';

void main() {
  group('SelectionCopyShortcut.isCopyIntent', () {
    const KeyDownEvent keyCDown = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyC,
      logicalKey: LogicalKeyboardKey.keyC,
      timeStamp: Duration.zero,
    );
    const KeyUpEvent keyCUp = KeyUpEvent(
      physicalKey: PhysicalKeyboardKey.keyC,
      logicalKey: LogicalKeyboardKey.keyC,
      timeStamp: Duration.zero,
    );
    const KeyDownEvent keyVDown = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyV,
      logicalKey: LogicalKeyboardKey.keyV,
      timeStamp: Duration.zero,
    );

    bool intent(
      KeyEvent event, {
      bool control = false,
      bool meta = false,
      bool shift = false,
      bool alt = false,
      TargetPlatform platform = TargetPlatform.linux,
    }) => SelectionCopyShortcut.isCopyIntent(
      event: event,
      isControlPressed: control,
      isMetaPressed: meta,
      isShiftPressed: shift,
      isAltPressed: alt,
      platform: platform,
    );

    test('Ctrl+C is the copy shortcut on Linux and Windows', () {
      expect(intent(keyCDown, control: true), isTrue);
      expect(
        intent(keyCDown, control: true, platform: TargetPlatform.windows),
        isTrue,
      );
    });

    test('Cmd+C is the copy shortcut on macOS, Ctrl+C is not', () {
      expect(
        intent(keyCDown, meta: true, platform: TargetPlatform.macOS),
        isTrue,
      );
      expect(
        intent(keyCDown, control: true, platform: TargetPlatform.macOS),
        isFalse,
      );
    });

    test('bare C, key up, other keys and Shift/Alt variants are ignored', () {
      expect(intent(keyCDown), isFalse);
      expect(intent(keyCUp, control: true), isFalse);
      expect(intent(keyVDown, control: true), isFalse);
      expect(intent(keyCDown, control: true, shift: true), isFalse);
      expect(intent(keyCDown, control: true, alt: true), isFalse);
    });
  });

  group('SelectionCopyArea', () {
    late List<String> copied;
    String? clipboardText;

    setUp(() {
      copied = <String>[];
      clipboardText = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (
            MethodCall call,
          ) async {
            if (call.method == 'Clipboard.setData') {
              final text = (call.arguments as Map)['text'] as String;
              clipboardText = text;
              copied.add(text);
            }
            if (call.method == 'Clipboard.getData') {
              return <String, dynamic>{'text': clipboardText ?? ''};
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    /// Chat-like layout: a message on top, an autofocused composer below —
    /// the composer owns the focus, exactly as in the real chat screen.
    Future<void> pumpChatLike(
      WidgetTester tester, {
      required String message,
      TextEditingController? composerController,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SelectionCopyArea(
                  child: Text(message, textDirection: TextDirection.ltr),
                ),
                TextField(controller: composerController, autofocus: true),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> selectMessage(WidgetTester tester, String message) async {
      final Rect box = tester.getRect(find.text(message));
      final TestGesture gesture = await tester.startGesture(
        Offset(box.left + 2, box.center.dy),
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(Offset(box.right - 2, box.center.dy));
      await tester.pump();
      await gesture.up();
      await tester.pump();
    }

    Future<void> pressCopy(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    testWidgets('copies the selection while the composer holds the focus', (
      tester,
    ) async {
      const String message = 'hello from the assistant';
      await pumpChatLike(tester, message: message);

      // The composer has the focus — this is the case that used to copy nothing.
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<EditableText>(),
        isNotNull,
      );

      await selectMessage(tester, message);
      await pressCopy(tester);

      expect(copied, isNotEmpty);
      expect(copied.first, message);
    });

    testWidgets('strips embedded base64 image data from the copy', (
      tester,
    ) async {
      const String message =
          'before data:image/png;base64,AAAABBBBCCCCDDDD after';
      await pumpChatLike(tester, message: message);

      await selectMessage(tester, message);
      await pressCopy(tester);

      expect(copied, isNotEmpty);
      expect(copied.first, contains('[image removed]'));
      expect(copied.first, isNot(contains('base64,')));
    });

    testWidgets('does not touch the clipboard without a selection', (
      tester,
    ) async {
      await pumpChatLike(tester, message: 'nothing selected here');

      await pressCopy(tester);

      expect(copied, isEmpty);
    });

    testWidgets('leaves the copy to a text field that has its own selection', (
      tester,
    ) async {
      const String message = 'message text';
      final composer = TextEditingController(text: 'composer text');
      addTearDown(composer.dispose);
      await pumpChatLike(
        tester,
        message: message,
        composerController: composer,
      );

      await selectMessage(tester, message);

      // Now select inside the composer as well and give it the focus back.
      await tester.tap(find.byType(TextField));
      await tester.pump();
      composer.selection = const TextSelection(baseOffset: 0, extentOffset: 8);
      await tester.pump();

      await pressCopy(tester);

      // Our handler steps aside; whatever lands on the clipboard is not the
      // message selection.
      expect(copied, isNot(contains(message)));
    });

    testWidgets('removes its keyboard handler when disposed', (tester) async {
      await pumpChatLike(tester, message: 'gone soon');
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpAndSettle();

      await pressCopy(tester);

      expect(copied, isEmpty);
    });
  });
}
