// COWORK STUB. Upstream: chuk_chat/lib/pages/workspace_management_page.dart @ d31526a229fdde27c82adf3661d5d3a149db8340.
// Reason: hosted-only — workspaces (projects) are a chuk_chat feature. The page
// is reachable only from workspace UI that is itself stubbed out.
// Keep the public API signature-compatible with upstream so the imported chat UI compiles unchanged. Do not "improve" this file.

import 'package:cowork/pages/coming_soon_page.dart';
import 'package:flutter/material.dart';

class WorkspaceManagementPage extends StatelessWidget {
  final String workspaceId;
  final Function(String? workspaceId)? onStartNewChat;

  const WorkspaceManagementPage({
    super.key,
    required this.workspaceId,
    this.onStartNewChat,
  });

  @override
  Widget build(BuildContext context) => const ComingSoonPage(title: 'Projects');
}
