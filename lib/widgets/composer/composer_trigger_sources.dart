// lib/widgets/composer/composer_trigger_sources.dart
//
// What the composer's `/` and `@` menu lists, read from the app's stores
// when the menu opens. The screens hand in the actions they own (new chat,
// model, export, compact, attach a chat reference, pick a workspace); an
// action that is null is not listed. When the chat belongs to a workspace,
// `@` also lists that workspace's files.
import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/skill.dart';
import 'package:chuk_chat/models/workspace_model.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/services/agents/agent_roster_store.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/agents/agents_thread_modes.dart';
import 'package:chuk_chat/services/chat_reference_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/composer/composer_trigger.dart';
import 'package:chuk_chat/services/skills/skill_registry.dart';
import 'package:chuk_chat/services/workspace_storage_service.dart';
import 'package:chuk_chat/widgets/composer/chip_text_controller.dart';

/// The most chats the `@` menu lists (newest first).
const int kTriggerMaxChats = 200;

/// The chip text for a name: one line, at most 40 characters.
String triggerChipName(String name) {
  final String flat = name.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length > 40 ? '${flat.substring(0, 40)}…' : flat;
}

/// File names attached to [messages] (documents and images), oldest first,
/// without repeats.
List<String> chatFileNames(List<Map<String, String>> messages) {
  final List<String> names = <String>[];
  void add(Object? raw) {
    if (raw is! String || raw.isEmpty) return;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final Object? f in decoded) {
        if (f is Map && f['fileName'] is String) {
          final String name = (f['fileName'] as String).trim();
          if (name.isNotEmpty && !names.contains(name)) names.add(name);
        }
      }
    } catch (_) {
      // A malformed field lists nothing.
    }
  }

  for (final Map<String, String> m in messages) {
    add(m['attachments']);
    add(m['attachedFilesJson']);
  }
  return names;
}

/// The workspace the open chat belongs to: [workspaceId] (the one the
/// screen has selected) first, else the workspace that holds [chatId].
Workspace? triggerWorkspaceFor({String? workspaceId, String? chatId}) {
  if (workspaceId != null && workspaceId.isNotEmpty) {
    return WorkspaceStorageService.getWorkspace(workspaceId);
  }
  if (chatId != null && chatId.isNotEmpty) {
    return WorkspaceStorageService.getWorkspaceForChat(chatId);
  }
  return null;
}

/// The `@` entries for the files stored in [workspace], newest first. They
/// are chips like the chat's own files (the workspace files already reach
/// the model through the workspace context). Names in [skip] are already
/// listed and left out.
List<TriggerItem> workspaceFileItems(
  Workspace? workspace, {
  Set<String> skip = const <String>{},
}) {
  if (workspace == null) return const <TriggerItem>[];
  final List<WorkspaceFile> files = List<WorkspaceFile>.of(workspace.files)
    ..sort((a, b) => b.uploadedAt.compareTo(a.uploadedAt));
  final Set<String> seen = <String>{...skip};
  return <TriggerItem>[
    for (final WorkspaceFile f in files)
      if (f.fileName.trim().isNotEmpty && seen.add(f.fileName.trim()))
        TriggerItem(
          id: 'wsfile:${f.id}',
          label: f.fileName.trim(),
          detail: workspace.name,
          group: TriggerGroup.files,
          icon: Icons.insert_drive_file_outlined,
          chipLiteral: '@${triggerChipName(f.fileName)}',
          chipKind: ComposerChipKind.file,
        ),
  ];
}

ComposerTriggerSource buildComposerTriggerSource({
  required AppLocalizations l,
  required String? chatId,
  required List<Map<String, String>> messages,
  required bool agentsThread,
  String? workspaceId,
  VoidCallback? onCompact,
  VoidCallback? onModel,
  VoidCallback? onExport,
  VoidCallback? onNewChat,
  void Function(String chatId)? onReferenceChat,
  void Function(String workspaceId)? onSelectWorkspace,
  @visibleForTesting List<Skill>? skills,
  @visibleForTesting List<StoredChat>? chats,
  @visibleForTesting Workspace? workspace,
}) {
  List<TriggerItem> slash() {
    final List<Skill> skillList =
        skills ?? (kFeatureSkills ? SkillRegistry.all : const <Skill>[]);
    final String? planKey = agentsThread ? chatId : null;
    return <TriggerItem>[
      for (final Skill s in skillList)
        TriggerItem(
          id: 'skill:${s.name}',
          label: s.name,
          detail: s.description,
          group: TriggerGroup.skills,
          icon: Icons.auto_awesome,
          chipLiteral: '/${s.name}',
          chipKind: ComposerChipKind.skill,
        ),
      if (planKey != null && planKey.isNotEmpty)
        TriggerItem(
          id: 'mode:plan',
          label: l.composerModePlan,
          detail: l.composerModePlanDetail,
          group: TriggerGroup.modes,
          icon: Icons.list,
          onPicked: () {
            final AgentsThreadModes modes = AgentsThreadModes.instance;
            modes.setPlanWanted(planKey, !modes.planToggleOf(planKey));
          },
        ),
      if (onCompact != null)
        TriggerItem(
          id: 'cmd:compact',
          label: l.composerCmdCompact,
          group: TriggerGroup.commands,
          icon: Icons.layers_outlined,
          onPicked: onCompact,
        ),
      if (onModel != null)
        TriggerItem(
          id: 'cmd:model',
          label: l.composerCmdModel,
          group: TriggerGroup.commands,
          icon: Icons.tune,
          onPicked: onModel,
        ),
      if (onExport != null)
        TriggerItem(
          id: 'cmd:export',
          label: l.composerCmdExport,
          group: TriggerGroup.commands,
          icon: Icons.download,
          onPicked: onExport,
        ),
      if (onNewChat != null)
        TriggerItem(
          id: 'cmd:new',
          label: l.composerCmdNewChat,
          group: TriggerGroup.commands,
          icon: Icons.edit_square,
          onPicked: onNewChat,
        ),
    ];
  }

  Future<List<TriggerItem>> at() async {
    final List<String> chatFiles = chatFileNames(messages);
    final List<TriggerItem> items = <TriggerItem>[
      for (final String name in chatFiles)
        TriggerItem(
          id: 'file:$name',
          label: name,
          group: TriggerGroup.files,
          icon: Icons.insert_drive_file_outlined,
          chipLiteral: '@${triggerChipName(name)}',
          chipKind: ComposerChipKind.file,
        ),
    ];
    if (workspace != null) {
      items.addAll(workspaceFileItems(workspace, skip: chatFiles.toSet()));
    } else if (kFeatureWorkspaces) {
      try {
        await WorkspaceStorageService.loadFromCache();
        items.addAll(
          workspaceFileItems(
            triggerWorkspaceFor(workspaceId: workspaceId, chatId: chatId),
            skip: chatFiles.toSet(),
          ),
        );
      } catch (_) {
        // No workspace store: no workspace files in the menu.
      }
    }
    if (agentsChatCore) {
      try {
        final AgentRosterSnapshot roster = await AgentRosterStore.instance
            .load();
        for (final agent in roster.agents) {
          if (roster.hidden.contains(agent.id)) continue;
          items.add(
            TriggerItem(
              id: 'agent:${agent.id}',
              label: agent.name,
              group: TriggerGroup.agents,
              icon: Icons.smart_toy_outlined,
              chipLiteral: '@${triggerChipName(agent.name)}',
              chipKind: ComposerChipKind.agent,
            ),
          );
        }
      } catch (_) {
        // No roster: no agents in the menu.
      }
    }
    if (kFeatureWorkspaces) {
      for (final w in WorkspaceStorageService.activeProjects) {
        items.add(
          TriggerItem(
            id: 'workspace:${w.id}',
            label: w.name,
            detail: w.description,
            group: TriggerGroup.workspaces,
            icon: Icons.folder_outlined,
            chipLiteral: '@${triggerChipName(w.name)}',
            chipKind: ComposerChipKind.workspace,
            onPicked: onSelectWorkspace == null
                ? null
                : () => onSelectWorkspace(w.id),
          ),
        );
      }
    }
    final List<StoredChat> all = chats ?? ChatStorageService.savedChats;
    int listed = 0;
    for (final StoredChat chat in all) {
      if (chat.id == chatId || chat.isLocked) continue;
      if (listed++ >= kTriggerMaxChats) break;
      final String title = ChatReferenceService.chatTitle(chat);
      if (title.isEmpty) continue;
      items.add(
        TriggerItem(
          id: 'chat:${chat.id}',
          label: title,
          group: TriggerGroup.chats,
          icon: Icons.chat_bubble_outline,
          chipLiteral: '@${triggerChipName(title)}',
          chipKind: ComposerChipKind.chat,
          onPicked: onReferenceChat == null
              ? null
              : () => onReferenceChat(chat.id),
        ),
      );
    }
    return items;
  }

  return ComposerTriggerSource(slash: slash, at: at);
}
