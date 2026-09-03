// lib/pages/desktop_settings_modal.dart
//
// Desktop settings as a modal popup over the chat UI — a proper desktop
// settings surface with a left navigation rail and a right content pane,
// instead of the phone-style full-screen drill-down list (SettingsPage).
//
// The right pane hosts each existing settings page verbatim inside its own
// nested Navigator, so every page keeps its Scaffold/AppBar, its detail
// pushes (skill editor, connector detail, color picker) and its dialogs —
// but all of it stays inside the modal instead of covering the whole app.
//
// Mobile still uses SettingsPage. This modal is desktop-only chrome.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:chuk_chat/widgets/settings_list_view.dart';
import 'package:flutter/services.dart';

import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/utils/io_helper.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

import 'package:chuk_chat/pages/about_page.dart';
import 'package:chuk_chat/pages/account_settings_page.dart';
import 'package:chuk_chat/pages/customization_page.dart';
import 'package:chuk_chat/pages/diagnostics_settings_page.dart';
import 'package:chuk_chat/pages/mcp_connectors_page.dart';
import 'package:chuk_chat/pages/pricing_page.dart';
import 'package:chuk_chat/pages/sandbox_management_page.dart';
import 'package:chuk_chat/pages/skills_settings_page.dart';
import 'package:chuk_chat/pages/system_prompt_page.dart';
import 'package:chuk_chat/pages/theme_page.dart';
import 'package:chuk_chat/pages/tool_calling_settings_page.dart';
import 'package:chuk_chat/model_selector_page.dart';

import 'package:chuk_chat/services/app_theme_service.dart';
import 'package:chuk_chat/services/auth_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/developer_options_service.dart';
import 'package:chuk_chat/services/onboarding_tour_controller.dart';

/// Opens the desktop settings modal over the current chat UI.
Future<void> showDesktopSettingsModal(
  BuildContext context, {
  required AppShellConfig config,
  String? initialSectionId,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: const Duration(milliseconds: 180),
    routeSettings: const RouteSettings(name: 'tour:settings'),
    pageBuilder: (dialogContext, anim, secondaryAnim) =>
        DesktopSettingsModal(config: config, initialSectionId: initialSectionId),
    transitionBuilder: (dialogContext, animation, secondaryAnim, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.98, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// A settings destination: either a page shown in the right pane, or an
/// inline action (export, replay onboarding) that runs on tap.
class _SettingsDest {
  const _SettingsDest({
    required this.id,
    required this.icon,
    required this.label,
    this.keywords = '',
    this.builder,
    this.onAction,
    this.tone,
  });

  final String id;
  final IconData icon;
  final String label;

  /// Extra search terms covering the rows INSIDE this page, so the settings
  /// search finds a submenu control (e.g. "color" finds the Theme page) and
  /// not just the top-level label. Matched together with [label].
  final String keywords;

  /// Page to show in the right pane. Null for action-only destinations.
  final WidgetBuilder? builder;

  /// Runs on tap instead of showing a page. Receives the modal context.
  final Future<void> Function(BuildContext modalContext)? onAction;

  /// Optional accent tone for the icon (e.g. destructive/dev).
  final Color? tone;

  bool get isPage => builder != null;
}

class _SettingsGroup {
  const _SettingsGroup(this.title, this.items);
  final String title;
  final List<_SettingsDest> items;
}

class DesktopSettingsModal extends StatefulWidget {
  const DesktopSettingsModal({
    super.key,
    required this.config,
    this.initialSectionId,
  });

  final AppShellConfig config;

  /// Section to open on first show (e.g. `'model'`). Null starts on Account.
  final String? initialSectionId;

  @override
  State<DesktopSettingsModal> createState() => _DesktopSettingsModalState();
}

class _DesktopSettingsModalState extends State<DesktopSettingsModal> {
  late String _selectedId = widget.initialSectionId ?? 'account';
  String _query = '';
  final TextEditingController _searchController = TextEditingController();
  bool _developerOptions = false;

  /// Whether the modal is in single-column (small window) layout. Computed in
  /// build; read by the tap handler that runs after build.
  bool _compact = false;

  /// In compact layout, the page currently drilled into (null = the nav list).
  late String? _compactPageId = widget.initialSectionId;

  @override
  void initState() {
    super.initState();
    _developerOptions = DeveloperOptionsService.enabledNotifier.value;
    DeveloperOptionsService.enabledNotifier.addListener(_onDevOptions);
  }

  @override
  void dispose() {
    DeveloperOptionsService.enabledNotifier.removeListener(_onDevOptions);
    _searchController.dispose();
    super.dispose();
  }

  void _onDevOptions() {
    if (!mounted) return;
    setState(
      () => _developerOptions = DeveloperOptionsService.enabledNotifier.value,
    );
  }

  List<_SettingsGroup> _groups(AppLocalizations l) {
    return [
      _SettingsGroup('Account', [
        _SettingsDest(
          id: 'account',
          icon: Icons.person_outline,
          label: l.accountSettings,
          keywords: 'account profile email password sign out log out logout '
              'delete account konto profil abmelden passwort',
          builder: (_) => const AccountSettingsPage(),
        ),
        _SettingsDest(
          id: 'pricing',
          icon: Icons.credit_card,
          label: l.pricingPlans,
          keywords: 'pricing plan plans credits subscription billing payment '
              'upgrade buy stripe invoice preis guthaben abo zahlung rechnung',
          builder: (_) => const PricingPage(),
        ),
      ]),
      _SettingsGroup('AI & Chat', [
        _SettingsDest(
          id: 'model',
          icon: Icons.smart_toy_outlined,
          label: l.modelSelection,
          keywords: 'model models ai llm gpt deepseek glm provider selection '
              'default modell auswahl',
          builder: (_) => const ModelSelectorPage(),
        ),
        _SettingsDest(
          id: 'identity',
          icon: Icons.fingerprint,
          label: l.aiIdentityMemory,
          keywords: 'identity memory system prompt name persona custom '
              'instructions identität gedächtnis erinnerung anweisungen',
          builder: (_) => const SystemPromptPage(),
        ),
        _SettingsDest(
          id: 'tools',
          icon: Icons.build_circle_outlined,
          label: l.toolCalling,
          keywords: 'tools tool calling function functions artifacts code '
              'sandbox web search discovery activity werkzeuge funktionen',
          builder: (_) => ToolCallingSettingsPage(config: widget.config),
        ),
        if (kFeatureMcp && !kIsWeb)
          _SettingsDest(
            id: 'connectors',
            icon: Icons.extension_outlined,
            label: l.connectors,
            keywords: 'connectors mcp integrations github slack gmail calendar '
                'notion email nextcloud oauth verbindungen integration',
            builder: (_) => const McpConnectorsPage(),
          ),
        _SettingsDest(
          id: 'skills',
          icon: Icons.auto_awesome_outlined,
          label: l.skills,
          keywords: 'skills agent skills procedures abilities fähigkeiten',
          builder: (_) => const SkillsSettingsPage(),
        ),
        _SettingsDest(
          id: 'sandboxes',
          icon: Icons.developer_board,
          label: 'Sandboxes',
          keywords: 'sandbox sandboxes code execution container docker runtime',
          builder: (_) => const SandboxManagementPage(),
        ),
      ]),
      _SettingsGroup('Appearance', [
        _SettingsDest(
          id: 'theme',
          icon: Icons.palette_outlined,
          label: l.themeSettings,
          keywords: 'theme color colour colors farbe farben accent background '
              'dark mode light mode contrast palette dynamic color preset '
              'interface font chat font typeface appearance look design hell '
              'dunkel kontrast schrift schriftart aussehen',
          builder: (_) => ThemePage(config: widget.config),
        ),
        _SettingsDest(
          id: 'customization',
          icon: Icons.tune,
          label: l.customization,
          keywords: 'customization language sprache font size ui scale zoom '
              'reasoning tokens model info tps images in context downloads '
              'auto titles title generation typography anpassung schriftgröße '
              'skalierung',
          builder: (_) => CustomizationPage(config: widget.config),
        ),
      ]),
      _SettingsGroup('System', [
        if (_developerOptions)
          _SettingsDest(
            id: 'export',
            icon: Icons.file_download_outlined,
            label: l.exportChats,
            keywords: 'export chats backup download exportieren sicherung',
            onAction: _exportChats,
          ),
        _SettingsDest(
          id: 'onboarding',
          icon: Icons.school_outlined,
          label: l.onboardingReplayTile,
          keywords: 'onboarding tutorial intro replay walkthrough einführung',
          onAction: _replayOnboarding,
        ),
        _SettingsDest(
          id: 'about',
          icon: Icons.info_outline,
          label: l.about,
          keywords: 'about version license credits info legal über lizenz',
          builder: (_) => const AboutPage(),
        ),
        if (_developerOptions)
          _SettingsDest(
            id: 'developer',
            icon: Icons.code,
            label: l.developerOptions,
            keywords: 'developer debug diagnostics logs advanced experimental '
                'entwickler fehlersuche',
            builder: (_) => const DeveloperOptionsPage(),
            tone: Theme.of(context).colorScheme.tertiary,
          ),
      ]),
    ];
  }

  _SettingsDest? _findPage(List<_SettingsGroup> groups, String id) {
    for (final g in groups) {
      for (final item in g.items) {
        if (item.id == id && item.isPage) return item;
      }
    }
    return null;
  }

  void _onSelect(_SettingsDest dest) {
    if (dest.onAction != null) {
      // Fire-and-forget; the action handles its own context/lifecycle.
      unawaited(dest.onAction!(context));
      return;
    }
    if (_compact) {
      setState(() => _compactPageId = dest.id);
      return;
    }
    if (dest.id == _selectedId) return;
    setState(() => _selectedId = dest.id);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final m3 = theme.m3;
    final size = MediaQuery.of(context).size;

    final groups = _groups(l);
    // If the current selection vanished (dev options toggled off), fall back.
    if (_findPage(groups, _selectedId) == null) {
      _selectedId = 'account';
    }
    final selectedPage = _findPage(groups, _selectedId);

    // Fit the modal to the window. On small windows go (near) full-bleed and
    // switch to a single-column drill-down instead of the rail + content split.
    final double margin = size.width < 560 || size.height < 560 ? 8 : 24;
    final double panelWidth = math.min(1080.0, size.width - margin * 2);
    final double panelHeight = math.min(760.0, size.height - margin * 2);
    _compact = panelWidth < 720;
    final double radius = _compact ? 20 : kRadiusDialog;

    // If the selection vanished, drop the compact drill-down too.
    if (_compactPageId != null && _findPage(groups, _compactPageId!) == null) {
      _compactPageId = null;
    }

    // One Material draws the rounded border AND clips its children to the same
    // shape, so the corners stay clean. (A ClipRRect wrapping a Container whose
    // own border used the same radius clipped the border unevenly at the
    // corners — that was the "weird corners".)
    return Center(
      child: Padding(
        padding: EdgeInsets.all(margin),
        child: Material(
          color: theme.scaffoldBackgroundColor,
          elevation: 12,
          shadowColor: Colors.black.withValues(alpha: 0.4),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
            side: BorderSide(color: m3.outlineVariant),
          ),
          child: SizedBox(
            width: panelWidth,
            height: panelHeight,
            child: _compact
                ? _buildCompact(context, l, groups)
                : _buildWide(context, l, groups, selectedPage),
          ),
        ),
      ),
    );
  }

  Widget _buildWide(
    BuildContext context,
    AppLocalizations l,
    List<_SettingsGroup> groups,
    _SettingsDest? selectedPage,
  ) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildNavRail(context, l, groups, compact: false),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: selectedPage == null
                    ? const SizedBox.shrink()
                    // A fresh Navigator per section: switching the rail resets
                    // any drill-down, while pushes from the page (detail views,
                    // editors) stay local to the modal.
                    : Navigator(
                        key: ValueKey<String>(_selectedId),
                        onGenerateRoute: (_) => MaterialPageRoute(
                          builder: selectedPage.builder!,
                        ),
                      ),
              ),
              // Floating close button, top-right of the content pane.
              Positioned(
                top: 10,
                right: 10,
                child: Material(
                  color: m3.surfaceContainerHigh,
                  shape: const CircleBorder(),
                  child: IconButton(
                    icon: Icon(Icons.close, color: theme.resolvedIconColor),
                    tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCompact(
    BuildContext context,
    AppLocalizations l,
    List<_SettingsGroup> groups,
  ) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    final page = _compactPageId == null
        ? null
        : _findPage(groups, _compactPageId!);

    if (page == null) {
      // The nav list occupies the whole modal.
      return _buildNavRail(context, l, groups, compact: true);
    }

    // A selected page fills the modal, with a slim back bar above it.
    return Column(
      children: [
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: m3.surfaceContainerLow,
            border: Border(bottom: BorderSide(color: m3.outlineVariant)),
          ),
          child: Row(
            children: [
              IconButton(
                icon: Icon(Icons.arrow_back, color: theme.resolvedIconColor),
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: () => setState(() => _compactPageId = null),
              ),
              Expanded(
                child: Text(
                  page.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
              IconButton(
                icon: Icon(Icons.close, color: theme.resolvedIconColor),
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Expanded(
          child: Navigator(
            key: ValueKey<String>('compact:${page.id}'),
            onGenerateRoute: (_) =>
                MaterialPageRoute(builder: page.builder!),
          ),
        ),
      ],
    );
  }

  Widget _buildNavRail(
    BuildContext context,
    AppLocalizations l,
    List<_SettingsGroup> groups, {
    required bool compact,
  }) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    final cs = theme.colorScheme;
    final query = _query.trim().toLowerCase();

    final List<Widget> navChildren = [];
    for (final group in groups) {
      final matches = group.items
          .where(
            (i) =>
                query.isEmpty ||
                i.label.toLowerCase().contains(query) ||
                i.keywords.toLowerCase().contains(query),
          )
          .toList();
      if (matches.isEmpty) continue;
      navChildren.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 6),
          child: Text(
            group.title,
            style: theme.textTheme.labelMedium?.copyWith(
              color: m3.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ),
      );
      for (final dest in matches) {
        navChildren.add(_navItem(context, dest));
      }
    }

    return Container(
      width: compact ? null : 268,
      decoration: BoxDecoration(
        color: m3.surfaceContainerLow,
        border: compact
            ? null
            : Border(right: BorderSide(color: m3.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Title (with a close button when compact — no content pane to host
          // the floating close in single-column layout).
          Padding(
            padding: EdgeInsets.fromLTRB(20, compact ? 14 : 22, compact ? 6 : 20, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l.settings,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                if (compact)
                  IconButton(
                    icon: Icon(Icons.close, color: theme.resolvedIconColor),
                    tooltip:
                        MaterialLocalizations.of(context).closeButtonTooltip,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
              ],
            ),
          ),
          // Search.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _query = v),
              style: TextStyle(color: cs.onSurface, fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                hintText: '${l.settings}…',
                hintStyle: TextStyle(color: m3.onSurfaceVariant, fontSize: 14),
                prefixIcon: Icon(
                  Icons.search,
                  size: 18,
                  color: m3.onSurfaceVariant,
                ),
                filled: true,
                fillColor: m3.surfaceContainerHigh,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(kRadiusField),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: SettingsListView(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              children: navChildren,
            ),
          ),
          Divider(height: 1, color: m3.outlineVariant),
          _buildRailFooter(context, l),
        ],
      ),
    );
  }

  Widget _navItem(BuildContext context, _SettingsDest dest) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    final cs = theme.colorScheme;
    final bool selected = dest.isPage && dest.id == _selectedId;
    final Color fg = selected ? cs.onSecondaryContainer : cs.onSurface;
    final Color iconColor = dest.tone ?? (selected ? cs.onSecondaryContainer : m3.onSurfaceVariant);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: Material(
        color: selected ? cs.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(kRadiusRow),
        child: InkWell(
          borderRadius: BorderRadius.circular(kRadiusRow),
          onTap: () => _onSelect(dest),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(dest.icon, size: 20, color: iconColor),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    dest.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fg,
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
                if (dest.onAction != null)
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: m3.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRailFooter(BuildContext context, AppLocalizations l) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    final cs = theme.colorScheme;

    // A single quiet log-out row. Account details live on the Account page —
    // no avatar/email chip cluttering the rail foot.
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(kRadiusRow),
        child: InkWell(
          borderRadius: BorderRadius.circular(kRadiusRow),
          onTap: _logout,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.logout, size: 18, color: m3.onSurfaceVariant),
                const SizedBox(width: 14),
                Text(
                  l.logout,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ------- Actions -------

  Future<void> _logout() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await const AuthService().signOut();
      if (navigator.mounted && navigator.canPop()) navigator.pop();
    } on AuthServiceException catch (error) {
      messenger.showSnackBar(_snack(error.message));
    } catch (error) {
      // Never surface the raw exception to the user; log it in debug only.
      if (kDebugMode) debugPrint('Logout failed: $error');
      messenger.showSnackBar(_snack('Could not sign out. Please try again.'));
    }
  }

  Future<void> _replayOnboarding(BuildContext modalContext) async {
    final navigator = Navigator.of(modalContext);
    // Close the modal so the tour starts on the chat root.
    if (navigator.canPop()) navigator.pop();
    await AppThemeService.instance.setOnboardingCompleted(false);
    if (!mounted) return;
    await OnboardingTourController.instance.start(
      navigator.context,
      shellConfig: widget.config,
    );
  }

  Future<void> _exportChats(BuildContext modalContext) async {
    final l = AppLocalizations.of(modalContext)!;
    final messenger = ScaffoldMessenger.of(modalContext);
    try {
      await ChatStorageService.loadSavedChatsForSidebar();
      if (ChatStorageService.savedChats.isEmpty) {
        messenger.showSnackBar(_snack(l.noChatsToExport));
        return;
      }
      final jsonPayload = await ChatStorageService.exportChatsAsJson();
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final fileName = 'chuk_chat_export_$timestamp.json';
      final data = Uint8List.fromList(utf8.encode(jsonPayload));

      if (kIsWeb) {
        await Clipboard.setData(ClipboardData(text: jsonPayload));
        messenger.showSnackBar(_snack(l.copiedToClipboard));
        return;
      }

      if (Platform.isLinux) {
        final Uri? savedUri = await FilePicker.saveFile(
          dialogTitle: l.saveChatExport,
          fileName: fileName,
          bytes: data,
          mimeType: 'application/json',
          type: FileType.custom,
          allowedExtensions: const ['json'],
        );
        if (savedUri != null && savedUri.scheme == 'file') {
          messenger.showSnackBar(_snack(l.savedToPath(savedUri.toFilePath())));
        } else {
          messenger.showSnackBar(_snack(l.exportCancelled));
        }
        return;
      }

      try {
        final xFile = XFile.fromData(
          data,
          mimeType: 'application/json',
          name: fileName,
        );
        await SharePlus.instance.share(
          ShareParams(
            files: [xFile],
            subject: 'Chuk Chat chat export',
            text: 'Backup of your Chuk Chat conversations.',
          ),
        );
        messenger.showSnackBar(_snack(l.shareOpened));
      } on Exception {
        await Clipboard.setData(ClipboardData(text: jsonPayload));
        messenger.showSnackBar(_snack(l.copiedToClipboard));
      }
    } on StateError catch (error) {
      messenger.showSnackBar(_snack(error.message));
    } catch (error) {
      messenger.showSnackBar(_snack(l.exportFailed(error.toString())));
    }
  }

  SnackBar _snack(String text) => SnackBar(
    content: Text(
      text,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
    ),
    behavior: SnackBarBehavior.floating,
    margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    duration: const Duration(seconds: 2),
    dismissDirection: DismissDirection.horizontal,
  );
}
