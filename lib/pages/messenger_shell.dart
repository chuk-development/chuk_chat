import 'package:flutter/material.dart';

import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/auth_service.dart';
import 'package:cowork/services/models_service.dart';

/// Skeletal messenger layout: an account panel on the left (which proves the
/// captured session token works by listing the account's models) and a thread
/// view on the right. The real roster and streaming run come with the executor
/// milestones.
class MessengerShell extends StatefulWidget {
  const MessengerShell({super.key, this.modelsService});

  /// Injectable so widget tests can supply a service backed by a mocked HTTP
  /// client instead of the live backend. Defaults to the real Supabase-backed
  /// service.
  final ModelsService? modelsService;

  @override
  State<MessengerShell> createState() => _MessengerShellState();
}

class _MessengerShellState extends State<MessengerShell> {
  late final ModelsService _modelsService;
  late Future<List<AccountModel>> _modelsFuture;

  @override
  void initState() {
    super.initState();
    _modelsService =
        widget.modelsService ??
        ModelsService(sessionSource: const SupabaseAccountSession());
    _modelsFuture = _modelsService.fetchModels();
  }

  void _reload() {
    setState(() => _modelsFuture = _modelsService.fetchModels());
  }

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
        children: [
          SizedBox(
            width: 280,
            child: _AccountModelsPanel(
              modelsFuture: _modelsFuture,
              onReload: _reload,
            ),
          ),
          const VerticalDivider(width: 1),
          const Expanded(child: _ThreadView()),
        ],
      ),
    );
  }
}

/// Left panel: lists the account's available models. A populated list is the
/// visible proof that the session access token authenticated against the
/// backend.
class _AccountModelsPanel extends StatelessWidget {
  const _AccountModelsPanel({
    required this.modelsFuture,
    required this.onReload,
  });

  final Future<List<AccountModel>> modelsFuture;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Account models',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                ),
              ),
              IconButton(
                tooltip: 'Reload',
                icon: const Icon(Icons.refresh),
                onPressed: onReload,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: FutureBuilder<List<AccountModel>>(
            future: modelsFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      '${snapshot.error}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                );
              }
              final models = snapshot.data ?? const <AccountModel>[];
              if (models.isEmpty) {
                return Center(
                  child: Text(
                    'No models available',
                    style: TextStyle(color: Theme.of(context).hintColor),
                  ),
                );
              }
              return ListView.builder(
                itemCount: models.length,
                itemBuilder: (context, index) {
                  final model = models[index];
                  return ListTile(
                    dense: true,
                    title: Text(model.name),
                    subtitle: Text(model.id),
                  );
                },
              );
            },
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
