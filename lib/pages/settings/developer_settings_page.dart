import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cowork/services/api_config_service.dart';
import 'package:cowork/widgets/expressive_settings.dart';

/// Developer options: the endpoints the app talks to, and a couple of local
/// debug toggles. Read-mostly — nothing here changes how a task runs, it just
/// surfaces what the build is pointed at.
class DeveloperSettingsPage extends StatefulWidget {
  const DeveloperSettingsPage({super.key});

  @override
  State<DeveloperSettingsPage> createState() => _DeveloperSettingsPageState();
}

class _DeveloperSettingsPageState extends State<DeveloperSettingsPage> {
  static const String _verboseKey = 'dev_verbose_logging';

  bool _verbose = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    bool verbose = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      verbose = prefs.getBool(_verboseKey) ?? false;
    } catch (_) {
      // Default off when the store is unavailable.
    }
    if (!mounted) return;
    setState(() {
      _verbose = verbose;
      _loading = false;
    });
  }

  Future<void> _setVerbose(bool value) async {
    setState(() => _verbose = value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_verboseKey, value);
    } catch (_) {
      // The live toggle still holds for the session.
    }
  }

  @override
  Widget build(BuildContext context) {
    final apiBase = ApiConfigService.apiBaseUrl;
    return Scaffold(
      appBar: AppBar(title: const Text('Developer')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                const ExpressiveTitle(
                  'Developer',
                  subtitle: 'Endpoints and local debug options',
                ),
                const ExpressiveSectionHeader('Endpoints'),
                ExpressiveGroup(
                  children: [
                    ExpressiveRow(
                      icon: Icons.cloud_outlined,
                      title: 'API base',
                      subtitle: apiBase,
                      trailing: IconButton(
                        tooltip: 'Copy',
                        icon: const Icon(Icons.copy, size: 18),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: apiBase));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('API base copied')),
                          );
                        },
                      ),
                    ),
                  ],
                ),
                const ExpressiveSectionHeader('Debug'),
                ExpressiveGroup(
                  children: [
                    ExpressiveSwitchRow(
                      icon: Icons.bug_report_outlined,
                      title: 'Verbose logging',
                      subtitle: 'Extra client-side logs (this device only)',
                      value: _verbose,
                      onChanged: _setVerbose,
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
