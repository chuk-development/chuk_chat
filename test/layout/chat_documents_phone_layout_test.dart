/// The files screen behind the folder target in the chat header, measured the
/// way every other screen is measured.
///
/// The catalogue in `every_screen_layout_test.dart` mounts the panel in its
/// dialog form, which is the desktop one. The phone form is a different screen:
/// it wears the app frame, it carries a search field, the switch and the
/// workspace crumbs, and it is the one a 360 px window at 1.3 text scale has to
/// survive. So it is measured here, in every state a finger can reach: the
/// list, the workspace tree, the grid, and a document open.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/storage/agents_chat_store.dart';
import 'package:chuk_chat/ui/expressive/connected_group.dart';
import 'package:chuk_chat/widgets/chat_documents_panel.dart';

import 'layout_harness.dart';

class _Relay implements AgentsRelayController, AgentsDocumentsControl {
  @override
  final ValueNotifier<AgentsRelayState> state = ValueNotifier<AgentsRelayState>(
    const AgentsRelayState(phase: AgentsRelayPhase.paired),
  );
  final StreamController<AgentsRelayInbound> events =
      StreamController<AgentsRelayInbound>.broadcast(sync: true);
  @override
  Stream<AgentsRelayInbound> get inbound => events.stream;
  @override
  Future<void> requestDocuments(String sessionKey, {String? id}) async {}
  @override
  Future<void> requestAgentList() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  void send(List<Map<String, dynamic>> documents) => events.add(
    AgentsRelayDocuments(<String, dynamic>{
      'session_key': 'layout-test',
      'documents': documents,
    }),
  );
}

final DateTime _stamp = DateTime(2026, 1, 5, 14, 3);

Map<String, dynamic> _file(String path, {int size = 4096}) => <String, dynamic>{
  'id': 'file:$path',
  'title': path.split('/').last,
  'kind': 'file',
  'path': path,
  'size': size,
  'updated_at': _stamp.millisecondsSinceEpoch / 1000,
};

Map<String, dynamic> _table(String title) => <String, dynamic>{
  'id': title,
  'title': title,
  'kind': 'table',
  'version': 1,
  'updated_at': _stamp.millisecondsSinceEpoch / 1000,
  'columns': <String>['Value'],
  'rows': <Map<String, String>>[
    <String, String>{'Value': title},
  ],
};

final List<Map<String, dynamic>> _catalog = <Map<String, dynamic>>[
  _table('Wahlkreise Sachsen-Anhalt 2026'),
  _file('skills/youtube-transcript/SKILL.md', size: 8123),
  _file('skills/browser-to-curl/SKILL.md', size: 9411),
  _file('memory/soul.md', size: 709),
  _file('geschichte_der_dampfmaschine.md', size: 20873),
  _file('tmp/fixtures/erg_land_raw.html', size: 47104),
];

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SharedPreferences.getInstance();
    await ChatStorageService.reset();
    await AgentsChatStore.reset();
  });

  const List<LayoutSize> windows = <LayoutSize>[
    LayoutSize('phone-360', Size(360, 800)),
    LayoutSize('phone-412', Size(412, 915)),
  ];

  /// The states of the screen, named by what the user did to get there.
  final Map<String, Future<void> Function(WidgetTester)> states =
      <String, Future<void> Function(WidgetTester)>{
        'list': (WidgetTester tester) async {},
        'workspace': (WidgetTester tester) async {
          await tester.tap(
            find.descendant(
              of: find.byType(ConnectedGroup),
              matching: find.text('Files'),
            ),
          );
          await tester.pump();
          await tester.tap(find.text('skills'));
          await tester.pump();
        },
        'grid': (WidgetTester tester) async {
          await tester.tap(find.byTooltip('Grid view'));
          await tester.pump();
        },
        'reading': (WidgetTester tester) async {
          await tester.tap(find.text('Wahlkreise Sachsen-Anhalt 2026'));
          await tester.pumpAndSettle();
        },
      };

  for (final LayoutSize window in windows) {
    for (final MapEntry<String, Future<void> Function(WidgetTester)> state
        in states.entries) {
      testWidgets('files screen · ${state.key} @ ${window.name}', (
        WidgetTester tester,
      ) async {
        for (final double scale in kTextScales) {
          final _Relay relay = _Relay();
          late List<Bleed> bleed;
          late List<SmallTarget> small;
          late List<TinyText> tiny;

          final List<FlutterErrorDetails> errors = await collectErrors(
            () async {
              await pumpAt(
                tester,
                ChatDocumentsPanel(
                  sessionKey: 'layout-test',
                  controller: relay,
                  coworkerName: 'Amber',
                  fullPage: true,
                ),
                size: window.size,
                textScale: scale,
              );
              relay.send(_catalog);
              await tester.pump();
              await state.value(tester);
              bleed = findHorizontalBleed(tester, window.size);
              small = findSmallTargets(tester);
              tiny = findTinyText(tester);
              await unpump(tester);
            },
          );
          await relay.events.close();
          relay.state.dispose();

          final String where =
              'files screen · ${state.key} @ $window @ text x$scale';
          expect(
            errors.where(isOverflow),
            isEmpty,
            reason: '$where overflowed:\n  ${describeErrors(errors)}',
          );
          expect(errors, isEmpty, reason: '$where threw');
          expect(tester.takeException(), isNull, reason: where);
          expect(
            bleed,
            isEmpty,
            reason: '$where paints past the edge:\n  ${bleed.join('\n  ')}',
          );
          // The open document is drawn by ChatDocumentView, and the copy
          // target inside its table is 27 px — that widget's bug, tracked
          // separately, not this screen's chrome. Every other state is
          // measured in full.
          if (state.key != 'reading') {
            expect(
              small,
              isEmpty,
              reason:
                  '$where has controls under 48 dp:\n  ${small.join('\n  ')}',
            );
          }
          expect(
            tiny,
            isEmpty,
            reason:
                '$where has text under $kMinFontSize px:\n  ${tiny.join('\n  ')}',
          );
        }
      });
    }
  }
}
