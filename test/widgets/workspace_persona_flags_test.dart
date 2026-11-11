import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/workspace_model.dart';
import 'package:chuk_chat/widgets/workspace/workspace_persona_flags.dart';

import '../support/test_app.dart';

Workspace _ws({bool complete = false, bool runtime = true}) => Workspace(
  id: 'ws-1',
  name: 'Persona',
  createdAt: DateTime.utc(2026, 11, 1),
  updatedAt: DateTime.utc(2026, 11, 1),
  complete: complete,
  includeRuntimeContext: runtime,
);

void main() {
  testWidgets('a tap saves the flag it changed', (tester) async {
    final saved = <String>[];
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: WorkspacePersonaFlags(
            workspace: _ws(),
            save: (id, {complete, includeRuntimeContext}) async {
              saved.add('$id c=$complete r=$includeRuntimeContext');
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final switches = find.byType(Switch);
    expect(switches, findsNWidgets(2));
    expect(tester.widget<Switch>(switches.first).value, isFalse);
    expect(tester.widget<Switch>(switches.last).value, isTrue);

    await tester.tap(find.text('Send instructions as the whole prompt'));
    await tester.pumpAndSettle();
    expect(saved, ['ws-1 c=true r=null']);
    expect(tester.widget<Switch>(switches.first).value, isTrue);

    await tester.tap(find.text('Tell the AI the time'));
    await tester.pumpAndSettle();
    expect(saved.last, 'ws-1 c=null r=false');
    expect(tester.widget<Switch>(switches.last).value, isFalse);
  });

  testWidgets('a failed save puts the switch back', (tester) async {
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: WorkspacePersonaFlags(
            workspace: _ws(),
            save: (id, {complete, includeRuntimeContext}) async =>
                throw StateError('offline'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send instructions as the whole prompt'));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch).first).value, isFalse);
  });
}
