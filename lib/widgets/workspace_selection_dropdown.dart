// COWORK STUB. Upstream: chuk_chat/lib/widgets/workspace_selection_dropdown.dart @ d31526a229fdde27c82adf3661d5d3a149db8340.
// Reason: hosted-only — workspaces (projects) are a chuk_chat feature. Nothing
// to pick from, so the dropdown renders nothing.
// Keep the public API signature-compatible with upstream so the imported chat UI compiles unchanged. Do not "improve" this file.

import 'package:flutter/material.dart';

class WorkspaceSelectionDropdown extends StatelessWidget {
  final String? selectedWorkspaceId;
  final ValueChanged<String?> onWorkspaceSelected;
  final FocusNode textFieldFocusNode;

  const WorkspaceSelectionDropdown({
    super.key,
    required this.selectedWorkspaceId,
    required this.onWorkspaceSelected,
    required this.textFieldFocusNode,
  });

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
