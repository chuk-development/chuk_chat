import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/expressive_screen.dart';
import 'package:chuk_chat/ui/expressive/icon_map.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/settings/debug_settings.dart';
import 'package:chuk_chat/services/settings/verbose_service.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';

/// Developer options: the endpoints the app talks to, and a couple of local
/// debug toggles. Read-mostly — nothing here changes how a task runs, it just
/// surfaces what the build is pointed at.
class DeveloperSettingsPage extends StatefulWidget {
  const DeveloperSettingsPage({super.key});

  @override
  State<DeveloperSettingsPage> createState() => _DeveloperSettingsPageState();
}

class _DeveloperSettingsPageState extends State<DeveloperSettingsPage> {
  bool _captureContext = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // The verbose switch now lives in [VerboseService], the one true store, so
    // this page and the main Settings switch always agree.
    await VerboseService.instance.load();
    final capture = await DebugSettings.captureContext();
    if (!mounted) return;
    setState(() {
      _captureContext = capture;
      _loading = false;
    });
  }

  Future<void> _setCaptureContext(bool value) async {
    setState(() => _captureContext = value);
    await DebugSettings.setCaptureContext(value);
  }

  @override
  Widget build(BuildContext context) {
    final apiBase = ApiConfigService.apiBaseUrl;
    return ExpressiveScreen(
      title: 'Developer',
      builder: (BuildContext context) => _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                MediaQuery.paddingOf(context).top + 8,
                16,
                MediaQuery.paddingOf(context).bottom + 32,
              ),
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
                        icon: const AppIcon(Icons.copy, size: 18),
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
                    // The same verbose-view switch as the main Settings page.
                    // Both drive [VerboseService], so they always agree.
                    ListenableBuilder(
                      listenable: VerboseService.instance,
                      builder: (context, _) {
                        final verbose = VerboseService.instance;
                        return ExpressiveSwitchRow(
                          icon: Icons.receipt_long_outlined,
                          title: 'Verbose view',
                          subtitle:
                              'Show every command, tool call, and browser '
                              'action in the thread',
                          value: verbose.enabled,
                          onChanged: verbose.setEnabled,
                        );
                      },
                    ),
                    ExpressiveSwitchRow(
                      icon: Icons.data_object,
                      title: 'Capture model context (debug)',
                      subtitle:
                          'Send each task with debug on and keep the raw '
                          'model context, so it can be copied from the thread',
                      value: _captureContext,
                      onChanged: _setCaptureContext,
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
