import 'package:flutter/material.dart';

import 'package:cowork/services/auth_service.dart';

/// Skeletal messenger layout: an "Agents" roster on the left and a thread
/// view on the right. Both are empty placeholders — the real roster and
/// streaming run come with the executor milestones.
class MessengerShell extends StatelessWidget {
  const MessengerShell({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('CoWork'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () => const AuthService().signOut(),
          ),
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: const [
          SizedBox(width: 280, child: _AgentsRoster()),
          VerticalDivider(width: 1),
          Expanded(child: _ThreadView()),
        ],
      ),
    );
  }
}

class _AgentsRoster extends StatelessWidget {
  const _AgentsRoster();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Agents',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Center(
            child: Text(
              'No agents yet',
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
          ),
        ),
      ],
    );
  }
}

class _ThreadView extends StatelessWidget {
  const _ThreadView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'Select an agent to start a thread',
        style: TextStyle(color: Theme.of(context).hintColor),
      ),
    );
  }
}
