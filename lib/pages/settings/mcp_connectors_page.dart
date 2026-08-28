import 'package:flutter/material.dart';

import 'package:cowork/widgets/expressive_settings.dart';

/// Placeholder MCP connectors page. The real connector list, add/edit flow and
/// storage land in the MCP port; this keeps the settings hub complete until
/// then.
class McpConnectorsPage extends StatelessWidget {
  const McpConnectorsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MCP Connectors')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: const [
          ExpressiveTitle(
            'MCP Connectors',
            subtitle: 'Model Context Protocol servers',
          ),
          SizedBox(height: 16),
          ExpressiveInfoCard(
            text: 'Connector management is being wired up.',
          ),
        ],
      ),
    );
  }
}
