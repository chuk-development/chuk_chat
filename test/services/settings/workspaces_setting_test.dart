import 'package:chuk_chat/services/settings/workspaces_setting.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    WorkspacesSetting.instance.resetForTest();
  });

  test('off by default, also after load with nothing stored', () async {
    expect(workspacesEnabled, isFalse);
    await WorkspacesSetting.instance.load();
    expect(workspacesEnabled, isFalse);
  });

  test('a stored choice is read on load', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      WorkspacesSetting.prefsKey: true,
    });
    await WorkspacesSetting.instance.load();
    expect(workspacesEnabled, isTrue);
  });

  test('setEnabled changes the live value, notifies and persists', () async {
    var notified = 0;
    void listener() => notified++;
    WorkspacesSetting.instance.addListener(listener);
    addTearDown(() => WorkspacesSetting.instance.removeListener(listener));

    await WorkspacesSetting.instance.setEnabled(true);
    expect(workspacesEnabled, isTrue);
    expect(notified, 1);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(WorkspacesSetting.prefsKey), isTrue);

    await WorkspacesSetting.instance.setEnabled(false);
    expect(prefs.getBool(WorkspacesSetting.prefsKey), isFalse);
  });

  testWidgets('sidebar shows the Workspaces row only when the setting is on', (
    WidgetTester tester,
  ) async {
    Widget sidebar() => MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => ListView(
            children: buildSidebarNavigationCards(
              context: context,
              showWorkspaces: true,
              onWorkspacesTapped: () {},
              onMediaTapped: () {},
              onNewChatTapped: () {},
              searchEntry: const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(sidebar());
    expect(find.text('Workspaces'), findsNothing);

    await WorkspacesSetting.instance.setEnabled(true);
    await tester.pumpWidget(sidebar());
    await tester.pump();
    expect(find.text('Workspaces'), findsOneWidget);
  });
}
