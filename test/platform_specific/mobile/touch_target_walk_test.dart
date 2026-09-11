/// Every interactive target on the phone surfaces is at least
/// [MobileLayout.minTouchTarget] in both directions.
///
/// The precedent is the named-chip check in `mobile_chat_chrome_test.dart`,
/// which names the four chips it looks at. This one names nothing: it WALKS
/// the tree of the mobile chat chrome and of the attachment bar, collects
/// every widget that takes a tap, and measures it. A new control that is added
/// too small therefore fails here without anyone remembering to list it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/models/chat_model.dart';
import 'package:cowork/platform_specific/mobile/mobile_chat_chrome.dart';
import 'package:cowork/platform_specific/mobile/mobile_layout.dart';
import 'package:cowork/services/cowork/cowork_relay_link.dart';
import 'package:cowork/ui/expressive/motion.dart';
import 'package:cowork/widgets/attachment_preview_bar.dart';

import 'mobile_support.dart';

/// True for a widget that takes a tap and is therefore a touch target.
///
/// A [GestureDetector] with no tap callback (a drag or a scroll listener) is
/// not a target; neither is a disabled button, which cannot be hit at all.
bool _isTarget(Widget w) {
  if (w is InkResponse) return w.onTap != null || w.onLongPress != null;
  if (w is GestureDetector) return w.onTap != null || w.onLongPress != null;
  if (w is IconButton) return w.onPressed != null;
  if (w is MorphTap) return w.onTap != null || w.onLongPress != null;
  if (w is TextButton || w is ElevatedButton || w is OutlinedButton) {
    return true;
  }
  return false;
}

/// Measures every target under [root] and fails on the first one that is
/// smaller than Material's minimum in either direction.
void expectAllTargetsAreBigEnough(WidgetTester tester, Finder root) {
  final Finder targets = find.descendant(
    of: root,
    matching: find.byWidgetPredicate(_isTarget, description: 'tap target'),
    matchRoot: true,
  );
  final List<Element> found = targets.evaluate().toList();
  expect(found, isNotEmpty, reason: 'no tap target found under $root');

  for (final Element element in found) {
    final Widget widget = element.widget;
    final Size size = tester.getSize(find.byWidget(widget));
    expect(
      size.height,
      greaterThanOrEqualTo(MobileLayout.minTouchTarget),
      reason: '${widget.runtimeType} height ${size.height}',
    );
    expect(
      size.width,
      greaterThanOrEqualTo(MobileLayout.minTouchTarget),
      reason: '${widget.runtimeType} width ${size.width}',
    );
  }
}

void main() {
  tearDown(() => CoworkRelayLink.instance.reset());

  testWidgets('every target in the mobile chat chrome is 48 dp', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      MobileChatChrome(
        agent: agent(id: 'a1', name: 'Chief of Staff', role: 'ops'),
        onBack: () {},
        onOpenProfile: () {},
        onOpenFiles: () {},
        onOpenBrowser: () {},
        onMore: () {},
      ),
    );

    expectAllTargetsAreBigEnough(tester, find.byType(MobileChatChrome));
  });

  testWidgets('every target in the attachment bar is 48 dp', (tester) async {
    await pumpPhone(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: AttachmentPreviewBar(
          files: <AttachedFile>[
            AttachedFile(
              id: 'doc',
              fileName: 'notes.txt',
              fileSizeBytes: 2048,
              markdownContent: 'hello',
            ),
            AttachedFile(
              id: 'img',
              fileName: 'shot.png',
              fileSizeBytes: 40960,
              isImage: true,
            ),
          ],
          onRemove: (_) {},
        ),
      ),
    );

    expectAllTargetsAreBigEnough(tester, find.byType(AttachmentPreviewBar));
  });

  testWidgets('the attachment remove target stays 48 dp with large text', (
    tester,
  ) async {
    await pumpPhone(
      tester,
      MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 844),
          textScaler: TextScaler.linear(2),
        ),
        child: Align(
          alignment: Alignment.topLeft,
          child: AttachmentPreviewBar(
            files: <AttachedFile>[
              AttachedFile(id: 'img', fileName: 'shot.png', isImage: true),
            ],
            onRemove: (_) {},
          ),
        ),
      ),
    );

    expectAllTargetsAreBigEnough(tester, find.byType(AttachmentPreviewBar));
    expect(tester.takeException(), isNull);
  });
}
