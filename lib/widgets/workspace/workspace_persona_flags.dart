// lib/widgets/workspace/workspace_persona_flags.dart
//
// The two persona switches of a workspace (`Workspace.complete`,
// `Workspace.includeRuntimeContext`). Each tap saves at once. A chat reads
// the flags into its prompt snapshot at its first request, so a change
// applies to new chats only (docs/GOTCHAS.md, "Prompt cache").

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/workspace_model.dart';
import 'package:chuk_chat/services/workspace_storage_service.dart';
import 'package:chuk_chat/widgets/app_notification.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';

/// Saves one flag change. Replaceable in tests.
typedef PersonaFlagSaver =
    Future<void> Function(
      String workspaceId, {
      bool? complete,
      bool? includeRuntimeContext,
    });

Future<void> _defaultSave(
  String workspaceId, {
  bool? complete,
  bool? includeRuntimeContext,
}) => WorkspaceStorageService.updateProject(
  workspaceId,
  complete: complete,
  includeRuntimeContext: includeRuntimeContext,
);

class WorkspacePersonaFlags extends StatefulWidget {
  const WorkspacePersonaFlags({
    super.key,
    required this.workspace,
    this.save = _defaultSave,
  });

  final Workspace workspace;
  final PersonaFlagSaver save;

  @override
  State<WorkspacePersonaFlags> createState() => _WorkspacePersonaFlagsState();
}

class _WorkspacePersonaFlagsState extends State<WorkspacePersonaFlags> {
  late bool _complete = widget.workspace.complete;
  late bool _runtime = widget.workspace.includeRuntimeContext;
  bool _saving = false;

  @override
  void didUpdateWidget(WorkspacePersonaFlags oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_saving) return;
    _complete = widget.workspace.complete;
    _runtime = widget.workspace.includeRuntimeContext;
  }

  Future<void> _set({bool? complete, bool? runtime}) async {
    final l =
        AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));
    final oldComplete = _complete;
    final oldRuntime = _runtime;
    setState(() {
      _saving = true;
      if (complete != null) _complete = complete;
      if (runtime != null) _runtime = runtime;
    });
    try {
      await widget.save(
        widget.workspace.id,
        complete: complete,
        includeRuntimeContext: runtime,
      );
      if (mounted) setState(() => _saving = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _complete = oldComplete;
        _runtime = oldRuntime;
      });
      AppNotifications.show(context, l.projectSaveFailed(e.toString()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l =
        AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));
    return ExpressiveGroup(
      children: [
        ExpressiveSwitchRow(
          icon: Icons.description_outlined,
          title: l.workspacePersonaComplete,
          subtitle: l.workspacePersonaCompleteSubtitle,
          value: _complete,
          onChanged: _saving ? null : (v) => _set(complete: v),
        ),
        ExpressiveSwitchRow(
          icon: Icons.schedule,
          title: l.workspacePersonaRuntimeContext,
          subtitle: l.workspacePersonaRuntimeContextSubtitle,
          value: _runtime,
          onChanged: _saving ? null : (v) => _set(runtime: v),
        ),
      ],
    );
  }
}
