import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cowork/services/chat_storage_service.dart';
import 'package:cowork/services/storage/cowork_chat_store.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/widgets/chat_documents_panel.dart';
import 'package:cowork/widgets/chat_document_view.dart';

class _Relay implements CoworkRelayController, CoworkDocumentsControl {
  @override
  final ValueNotifier<CoworkRelayState> state = ValueNotifier(
    const CoworkRelayState(phase: CoworkRelayPhase.paired),
  );
  final events = StreamController<CoworkRelayInbound>.broadcast(sync: true);
  @override
  Stream<CoworkRelayInbound> get inbound => events.stream;
  final requests = <String?>[];
  int agentListRequests = 0;
  @override
  Future<void> requestDocuments(String sessionKey, {String? id}) async =>
      requests.add(id);
  @override
  Future<void> requestAgentList() async => agentListRequests++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  void send(Map<String, dynamic> payload) => events.add(
    CoworkRelayDocuments({'session_key': 'panel-test', ...payload}),
  );
}

/// A fixed, deliberately-not-today stamp: the freshness line then renders its
/// unambiguous `dd.MM. HH:mm` form, which is the same string on every run.
final stamp = DateTime(2026, 1, 5, 14, 3);

Map<String, dynamic> doc(
  String id,
  int version, {
  bool full = true,
  bool dated = false,
}) => {
  'id': id,
  'title': id,
  'version': version,
  'kind': 'table',
  if (dated) 'updated_at': stamp.millisecondsSinceEpoch / 1000,
  if (full) ...{
    'columns': ['Value'],
    'rows': [
      {'Value': '$id-$version'},
    ],
  },
};

Map<String, dynamic> file(String path, {int? size}) => {
  'id': 'file:$path',
  'title': path.split('/').last,
  'kind': 'file',
  'path': path,
  'size': ?size,
  'updated_at': stamp.millisecondsSinceEpoch / 1000,
};

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ChatStorageService.reset();
    await CoworkChatStore.reset();
  });
  Future<_Relay> mount(WidgetTester tester, {Size size = const Size(1200, 900)}) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final relay = _Relay();
    addTearDown(() async {
      await relay.events.close();
      relay.state.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ChatDocumentsPanel(sessionKey: 'panel-test', controller: relay),
      ),
    );
    await tester.pumpAndSettle();
    return relay;
  }

  testWidgets(
    'new catalog version hides old rows until matching content arrives',
    (tester) async {
      final relay = await mount(tester);
      relay.send({
        'documents': [doc('A', 1)],
      });
      await tester.pump();
      await tester.tap(find.text('A'));
      await tester.pump();
      expect(find.text('A-1'), findsOneWidget);
      relay.send({
        'documents': [doc('A', 2, full: false)],
      });
      await tester.pump();
      expect(find.text('A-1'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      relay.send({'selected': doc('A', 1)});
      await tester.pump();
      expect(find.text('A-1'), findsNothing);
      relay.send({'selected': doc('A', 2)});
      await tester.pumpAndSettle();
      expect(find.text('A-2'), findsOneWidget);
      relay.events.add(
        CoworkRelayFile(
          name: 'A.json',
          mimeType: 'application/json',
          declaredSize: 0,
          replay: true,
          document: {...doc('A', 1), 'session_key': 'panel-test'},
        ),
      );
      await tester.pump();
      expect(find.text('A-2'), findsOneWidget);
      relay.send({'selected': doc('A', 1)});
      await tester.pump();
      expect(
        tester
            .widget<ChatDocumentView>(find.byType(ChatDocumentView))
            .document['version'],
        2,
      );
    },
  );
  testWidgets(
    'late selection response does not switch the current document and reconnect refreshes',
    (tester) async {
      final relay = await mount(tester);
      relay.send({
        'documents': [
          doc('A', 1, full: false),
          doc('B', 1, full: false),
          {
            'id': 'file:note',
            'title': 'note.md',
            'kind': 'file',
            'path': 'notes/note.md',
          },
        ],
      });
      await tester.pump();
      expect(find.text('Saved in this chat'), findsOneWidget);
      expect(find.text('this coworker’s container'), findsOneWidget);
      await tester.tap(find.text('A'));
      await tester.pump();
      await tester.tap(find.text('B'));
      await tester.pump();
      relay.send({'error': 'Stale A read failed', 'id': 'A'});
      await tester.pump();
      expect(find.text('Stale A read failed'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      relay.send({'selected': doc('B', 1)});
      await tester.pumpAndSettle();
      relay.send({'selected': doc('A', 1)});
      await tester.pumpAndSettle();
      expect(find.text('B-1'), findsOneWidget);
      expect(find.text('A-1'), findsNothing);
      relay.state.value = const CoworkRelayState(
        phase: CoworkRelayPhase.closed,
      );
      relay.state.value = const CoworkRelayState(
        phase: CoworkRelayPhase.paired,
      );
      await tester.pump();
      expect(relay.requests.sublist(relay.requests.length - 2), [null, 'B']);
      expect(tester.takeException(), isNull);
    },
  );

  /// The lit/unlit state of the quiet "Updated" mark in the reader header.
  double updatedMark(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(
        find.ancestor(
          of: find.text('Updated'),
          matching: find.byType(AnimatedOpacity),
        ),
      )
      .opacity;

  testWidgets('an open document follows a newer version pushed by the agent', (
    tester,
  ) async {
    final relay = await mount(tester);
    relay.send({
      'documents': [doc('A', 1, dated: true)],
    });
    await tester.pump();
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    expect(find.text('A-1'), findsOneWidget);
    expect(find.text('1 rows · v1 · 05.01. 14:03'), findsOneWidget);
    expect(updatedMark(tester), 0);

    // What the agent's chat_document tool actually pushes on every write: a
    // file frame carrying the whole new document.
    relay.events.add(
      CoworkRelayFile(
        name: 'A.json',
        mimeType: 'application/vnd.cowork.document+json',
        declaredSize: 0,
        replay: false,
        document: {...doc('A', 2, dated: true), 'session_key': 'panel-test'},
      ),
    );
    await tester.pump();

    expect(find.text('A-2'), findsOneWidget);
    expect(find.text('A-1'), findsNothing);
    expect(find.text('1 rows · v2 · 05.01. 14:03'), findsOneWidget);
    expect(updatedMark(tester), 1);
    // The row in the list carries the same version, so the two never disagree.
    expect(find.text('Table · v2 · 05.01. 14:03'), findsOneWidget);

    // The mark is temporary; the freshness line is not.
    await tester.pump(const Duration(seconds: 7));
    expect(updatedMark(tester), 0);
    expect(find.text('1 rows · v2 · 05.01. 14:03'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching documents is not reported as an update', (
    tester,
  ) async {
    final relay = await mount(tester);
    relay.send({
      'documents': [doc('A', 1, dated: true), doc('B', 5, dated: true)],
    });
    await tester.pump();
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    expect(find.text('B-5'), findsOneWidget);
    expect(updatedMark(tester), 0);
  });

  testWidgets('workspace files are told apart by folder, not by file name', (
    tester,
  ) async {
    final relay = await mount(tester);
    relay.send({
      'documents': [
        file('skills/automations/SKILL.md'),
        file('skills/browser-to-curl/SKILL.md'),
        file('deep/nest/of/folders/SKILL.md'),
        file('README.md', size: 1536),
      ],
    });
    await tester.pump();
    // The name leads the row; the folder tells the three SKILL.md rows apart.
    expect(find.text('SKILL.md'), findsNWidgets(3));
    expect(
      find.text('skills/automations · 05.01. 14:03'),
      findsOneWidget,
    );
    expect(
      find.text('skills/browser-to-curl · 05.01. 14:03'),
      findsOneWidget,
    );
    expect(find.text('…/of/folders · 05.01. 14:03'), findsOneWidget);
    // A file at the workspace root has no folder line, only its own facts.
    expect(find.text('README.md'), findsOneWidget);
    expect(find.text('1.5 KB · 05.01. 14:03'), findsOneWidget);
  });

  testWidgets('a narrow window shows the list and the reader one at a time', (
    tester,
  ) async {
    final relay = await mount(tester, size: const Size(360, 780));
    relay.send({
      'documents': [doc('A', 1, dated: true)],
    });
    await tester.pump();
    expect(find.text('Saved in this chat'), findsOneWidget);
    expect(find.byType(ChatDocumentView), findsNothing);

    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    expect(find.byType(ChatDocumentView), findsOneWidget);
    expect(find.text('Saved in this chat'), findsNothing);

    await tester.tap(find.byTooltip('Back to the list'));
    await tester.pumpAndSettle();
    expect(find.text('Saved in this chat'), findsOneWidget);
    expect(find.byType(ChatDocumentView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the empty reading pane offers the most recent document', (
    tester,
  ) async {
    final relay = await mount(tester);
    relay.send({
      'documents': [doc('A', 1, dated: true), doc('B', 1)],
    });
    await tester.pump();
    expect(find.text('Select a document to read it'), findsOneWidget);
    await tester.tap(find.text('Open A'));
    await tester.pumpAndSettle();
    expect(find.text('A-1'), findsOneWidget);
    expect(find.text('Select a document to read it'), findsNothing);
  });

  testWidgets('the roster names the coworker whose container holds the rows', (
    tester,
  ) async {
    final relay = await mount(tester);
    // The panel asks for the roster itself; the thread key is the agent id.
    expect(relay.agentListRequests, 1);
    expect(find.text('this coworker · Documents'), findsOneWidget);

    relay.events.add(
      const CoworkRelayAgentList(
        agents: [
          CoworkHostAgentName(agentId: 'panel-test', name: 'Nova'),
          CoworkHostAgentName(agentId: 'someone-else', name: 'Rex'),
        ],
      ),
    );
    relay.send({
      'documents': [doc('A', 1, dated: true), file('notes/note.md', size: 42)],
    });
    await tester.pumpAndSettle();

    expect(find.text('Nova · Documents'), findsOneWidget);
    expect(find.text('Saved in this chat'), findsOneWidget);
    expect(find.text('Nova’s container'), findsOneWidget);
    expect(
      find.textContaining('Nova runs in its own container'),
      findsOneWidget,
    );
    // Name, size and time on the file row; the folder tells rows apart.
    expect(find.text('note.md'), findsOneWidget);
    expect(find.text('notes · 42 B · 05.01. 14:03'), findsOneWidget);
  });

  testWidgets('a caller that knows the coworker never says "this coworker"', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: ChatDocumentsPanel(sessionKey: 'panel-test', coworkerName: 'Ada'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Ada · Documents'), findsOneWidget);
    expect(find.textContaining('Ada runs in its own container'), findsOneWidget);
    expect(find.text('No documents yet'), findsWidgets);
  });
}
