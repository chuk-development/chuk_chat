// COWORK STUB. Upstream: chuk_chat/lib/widgets/workspace_panel.dart @ d31526a229fdde27c82adf3661d5d3a149db8340.
// Reason: hosted-only — workspaces (projects) are a chuk_chat feature. CoWork's
// sidebar lists agents, so the panel renders nothing.
// Keep the public API signature-compatible with upstream so the imported chat UI compiles unchanged. Do not "improve" this file.

import 'package:flutter/material.dart';

class WorkspacePanel extends StatelessWidget {
  final String workspaceId;
  final VoidCallback? onClose;

  const WorkspacePanel({super.key, required this.workspaceId, this.onClose});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
