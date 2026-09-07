// COWORK STUB. Upstream: chuk_chat/lib/widgets/workspace_file_viewer.dart @ d31526a229fdde27c82adf3661d5d3a149db8340.
// Reason: hosted-only — workspaces (projects) are a chuk_chat feature. Nothing
// in the imported closure reaches this file; it exists so a future re-sync has
// a landing place instead of pulling the Supabase-backed original in.
// Keep the public API signature-compatible with upstream so the imported chat UI compiles unchanged. Do not "improve" this file.

import 'package:cowork/models/workspace_model.dart';
import 'package:flutter/material.dart';

class WorkspaceFileViewer extends StatelessWidget {
  final WorkspaceFile file;

  const WorkspaceFileViewer({super.key, required this.file});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
