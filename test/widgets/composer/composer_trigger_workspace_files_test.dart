// The `@` menu lists the files stored in the open chat's workspace
// (bead chuk_chat-280z): chips like the chat's own files, newest first,
// filterable by the typed query, nothing without a workspace.

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/skill.dart';
import 'package:chuk_chat/models/workspace_model.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/composer/composer_trigger.dart';
import 'package:chuk_chat/widgets/composer/chip_text_controller.dart';
import 'package:chuk_chat/widgets/composer/composer_trigger_sources.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

WorkspaceFile _file(String id, String name, int day) => WorkspaceFile(
  id: id,
  workspaceId: 'ws1',
  fileName: name,
  storagePath: 'u/ws1/$id',
  fileType: 'text/plain',
  fileSize: 10,
  uploadedAt: DateTime(2026, 1, day),
);

Workspace _workspace(List<WorkspaceFile> files) => Workspace(
  id: 'ws1',
  name: 'Taxes',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  chatIds: const <String>['me'],
  files: files,
);

void main() {
  final l = AppLocalizations(const Locale('en'));

  test('workspace files: newest first, chips, workspace as detail', () {
    final items = workspaceFileItems(
      _workspace(<WorkspaceFile>[
        _file('a', 'old.csv', 1),
        _file('b', 'new.pdf', 9),
        _file('c', '  ', 5),
      ]),
    );
    expect(items.map((i) => i.id), <String>['wsfile:b', 'wsfile:a']);
    expect(items.first.label, 'new.pdf');
    expect(items.first.detail, 'Taxes');
    expect(items.first.group, TriggerGroup.files);
    expect(items.first.chipLiteral, '@new.pdf');
    expect(items.first.chipKind, ComposerChipKind.file);
    expect(items.first.onPicked, isNull);
  });

  test('no workspace: no entries', () {
    expect(workspaceFileItems(null), isEmpty);
    expect(workspaceFileItems(_workspace(const <WorkspaceFile>[])), isEmpty);
  });

  test('a name the chat already lists is not listed twice', () {
    final items = workspaceFileItems(
      _workspace(<WorkspaceFile>[
        _file('a', 'plan.pdf', 1),
        _file('b', 'notes.md', 2),
        _file('c', 'notes.md', 3),
      ]),
      skip: <String>{'plan.pdf'},
    );
    expect(items.map((i) => i.label), <String>['notes.md']);
  });

  Future<List<TriggerItem>> at({Workspace? workspace}) =>
      Future<List<TriggerItem>>.value(
        buildComposerTriggerSource(
          l: l,
          chatId: 'me',
          messages: <Map<String, String>>[
            <String, String>{
              'sender': 'user',
              'text': 'x',
              'attachments': '[{"fileName":"plan.pdf","markdownContent":"m"}]',
            },
          ],
          agentsThread: false,
          skills: const <Skill>[],
          chats: const <StoredChat>[],
          workspace: workspace,
        ).at(),
      );

  test('the @ source lists workspace files after the chat files', () async {
    final items = await at(
      workspace: _workspace(<WorkspaceFile>[
        _file('a', 'plan.pdf', 1),
        _file('b', 'receipts.xlsx', 2),
        _file('c', 'budget-2026.csv', 3),
      ]),
    );
    expect(items.map((i) => i.id), <String>[
      'file:plan.pdf',
      'wsfile:c',
      'wsfile:b',
    ]);

    final filtered = filterTriggerItems(items, 'rec');
    expect(filtered.map((i) => i.id), <String>['wsfile:b']);
    expect(filterTriggerItems(items, 'budg').single.id, 'wsfile:c');
    expect(filterTriggerItems(items, 'zzz'), isEmpty);
  });

  test('the @ source without a workspace lists only the chat files', () async {
    // FEATURE_WORKSPACES is off in tests and no workspace is handed in.
    final items = await at();
    expect(items.map((i) => i.id), <String>['file:plan.pdf']);
  });

  test('the controller shows workspace files for a typed query', () async {
    final text = ChipTextEditingController();
    final menu = ComposerTriggerController(
      text: text,
      source: () => buildComposerTriggerSource(
        l: l,
        chatId: 'me',
        messages: const <Map<String, String>>[],
        agentsThread: false,
        skills: const <Skill>[],
        chats: const <StoredChat>[],
        workspace: _workspace(<WorkspaceFile>[
          _file('a', 'contract.docx', 1),
          _file('b', 'invoice.pdf', 2),
        ]),
      ),
    );
    addTearDown(menu.dispose);
    addTearDown(text.dispose);
    text.value = const TextEditingValue(
      text: '@inv',
      selection: TextSelection.collapsed(offset: 4),
    );
    await Future<void>.delayed(Duration.zero);
    expect(menu.visible.map((i) => i.id), <String>['wsfile:b']);
  });
}
