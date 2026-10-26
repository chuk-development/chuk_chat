// ignore_for_file: invalid_use_of_visible_for_testing_member
// Renders the REAL app widgets (Clawed dark theme) to PNG, as the reference half of the
// fidelity sheets for episode 12. Not part of the app's test suite.
// Run from the repo root:
//   flutter test marketing/videos/chuk-12-memory/_work/fidelity_test/real_widgets_test.dart
//
// Both pages are State-heavy (WorkspaceStorageService, Supabase), so their build bodies
// are copied here verbatim, with the controllers filled the way the video shows them:
// * workspace_detail_page.dart  _WorkspaceDetailPageState.build (header + tabs) and
//   _buildSettingsTab (identity card, Custom System Prompt card, Save Changes)
// * system_prompt_page.dart     the Memory section of build() and _MaterialTextField
// Every widget they use (FloatingAppBar, ExpressiveSectionHeader, ExpressiveInfoCard,
// AppIcon, Card, TextFormField, FilledButton ...) is the real one from lib/.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/workspace_model.dart';
import 'package:chuk_chat/services/app_theme_service.dart';
import 'package:chuk_chat/utils/chat_font_resolver.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';
import 'package:chuk_chat/widgets/workspace/workspace_common_widgets.dart';

const String work = 'marketing/videos/chuk-12-memory/_work';
const double ratio = 2.0;

const String wsName = 'Tax helper';
const String wsDescription = 'My German tax return: receipts, deadlines, deductions.';
const String wsPrompt =
    'Help me with my German tax return. Ask before you assume. Keep answers short.';
const String memoryText =
    '- Lives in Hamburg\n- Files taxes with ELSTER\n- Self-employed since 2024';

Future<void> _font(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    loader.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
  }
  await loader.load();
}

ThemeData _theme() {
  final t = buildAppTheme(
    accent: const Color(0xFFD97757),
    iconFg: const Color(0xFFE8E4D8),
    bg: const Color(0xFF262624),
    brightness: Brightness.dark,
    contrast: 0.55,
  );
  // The app leaves ThemeData.fontFamily unset (system font = Ubuntu on the owner's
  // desktop). Styles without a family render as boxes in a test, so every family-less
  // style the theme hands out gets Ubuntu here; sizes and weights stay the app's.
  WidgetStateProperty<TextStyle?>? fam(WidgetStateProperty<TextStyle?>? p) => p == null
      ? null
      : WidgetStateProperty.resolveWith((s) => p.resolve(s)?.copyWith(fontFamily: 'Ubuntu'));
  return t.copyWith(
    textTheme: t.textTheme.apply(fontFamily: 'Ubuntu'),
    primaryTextTheme: t.primaryTextTheme.apply(fontFamily: 'Ubuntu'),
    appBarTheme: t.appBarTheme.copyWith(
      titleTextStyle: t.appBarTheme.titleTextStyle?.copyWith(fontFamily: 'Ubuntu'),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: t.filledButtonTheme.style?.copyWith(textStyle: fam(t.filledButtonTheme.style?.textStyle)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: t.outlinedButtonTheme.style?.copyWith(textStyle: fam(t.outlinedButtonTheme.style?.textStyle)),
    ),
  );
}

String _hex(Color c) =>
    '#${c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

Future<void> _shoot(WidgetTester tester, Widget child, Size size, String name) async {
  final key = GlobalKey();
  tester.view.physicalSize = size * ratio;
  tester.view.devicePixelRatio = ratio;
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: _theme(),
    localizationsDelegates: const <LocalizationsDelegate<Object>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: DefaultTextStyle(
      style: const TextStyle(fontFamily: 'Ubuntu'),
      child: RepaintBoundary(key: key, child: child),
    ),
  ));
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final png = await tester.runAsync(() async {
    final ui.Image img = await boundary.toImage(pixelRatio: ratio);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  });
  File('$work/fidelity/real-$name.png').writeAsBytesSync(png!);
}

/// Prints the theme values the HTML rebuild needs (sizes and colours).
void _dumpTheme(BuildContext context, Workspace ws) {
  final theme = Theme.of(context);
  final m3 = theme.m3;
  final cs = theme.colorScheme;
  final idt = theme.inputDecorationTheme;
  final lines = <String>[
    'displayColor ${_hex(ws.displayColor)} displayIcon ${ws.displayIcon.codePoint.toRadixString(16)}',
    'iconFg ${_hex(theme.resolvedIconColor)} scaffold ${_hex(theme.scaffoldBackgroundColor)}',
    'card color ${theme.cardTheme.color == null ? 'null' : _hex(theme.cardTheme.color!)} '
        'surfaceContainerLow ${_hex(cs.surfaceContainerLow)} elevation ${theme.cardTheme.elevation} '
        'margin ${theme.cardTheme.margin} shape ${theme.cardTheme.shape}',
    'm3.surfaceContainerLow ${_hex(m3.surfaceContainerLow)} m3.surfaceContainer ${_hex(m3.surfaceContainer)} '
        'm3.surfaceContainerHigh ${_hex(m3.surfaceContainerHigh)} m3.onSurfaceVariant ${_hex(m3.onSurfaceVariant)} '
        'm3.outlineVariant ${_hex(m3.outlineVariant)}',
    'primary ${_hex(cs.primary)} onSurface ${_hex(cs.onSurface)} surfaceTint ${_hex(cs.surfaceTint)}',
    'input filled ${idt.filled} fill ${idt.fillColor == null ? 'null' : _hex(idt.fillColor!)} '
        'contentPadding ${idt.contentPadding} border ${idt.border} enabled ${idt.enabledBorder} '
        'hintStyle ${idt.hintStyle}',
    'bodyMedium ${theme.textTheme.bodyMedium} ',
    'bodySmall ${theme.textTheme.bodySmall}',
    'titleMedium ${theme.textTheme.titleMedium}',
    'bodyLarge ${theme.textTheme.bodyLarge}',
    'titleSmall ${theme.textTheme.titleSmall}',
    'labelLarge ${theme.textTheme.labelLarge}',
    'inputBorder ${(idt.border as OutlineInputBorder?)?.borderRadius} ${(idt.border as OutlineInputBorder?)?.borderSide} '
        'enabled ${(idt.enabledBorder as OutlineInputBorder?)?.borderSide} focused ${idt.focusedBorder is OutlineInputBorder ? (idt.focusedBorder as OutlineInputBorder).borderSide : idt.focusedBorder}',
    'outline ${_hex(cs.outline)} divider ${_hex(theme.dividerColor)} onPrimary ${_hex(cs.onPrimary)}',
    'tabTheme divider ${theme.tabBarTheme.dividerColor} ${theme.tabBarTheme.labelStyle} indicatorSize ${theme.tabBarTheme.indicatorSize}',
    'tabBar ${theme.tabBarTheme.labelStyle} ${theme.tabBarTheme.unselectedLabelColor}',
    'chatFont ${resolveChatFontFamily(AppThemeService.instance.chatFontFamily)}',
    'kRadiusField $kRadiusField kRadiusPill $kRadiusPill',
  ];
  File('$work/fidelity/theme-values.txt').writeAsStringSync('${lines.join('\n')}\n');
}

Workspace _workspace() => Workspace(
      id: '00000000-0000-4000-8000-000000000012',
      name: wsName,
      description: wsDescription,
      customSystemPrompt: wsPrompt,
      createdAt: DateTime.now().subtract(const Duration(days: 30)),
      updatedAt: DateTime.now().subtract(const Duration(minutes: 3)),
      chatIds: const ['a', 'b', 'c', 'd'],
      files: [
        for (final n in ['receipts-2025.pdf', 'invoice-template.docx'])
          WorkspaceFile(
            id: n,
            workspaceId: 'w',
            fileName: n,
            storagePath: n,
            fileType: 'pdf',
            fileSize: 120000,
            uploadedAt: DateTime.now(),
          ),
      ],
    );

// ---------------------------------------------------------------- workspace settings
class _WorkspaceSettings extends StatefulWidget {
  const _WorkspaceSettings({required this.typedPrompt});
  final String typedPrompt;
  @override
  State<_WorkspaceSettings> createState() => _WorkspaceSettingsState();
}

class _WorkspaceSettingsState extends State<_WorkspaceSettings> {
  final _project = _workspace();
  final _nameController = TextEditingController(text: wsName);
  final _descriptionController = TextEditingController(text: wsDescription);
  late final _systemPromptController = TextEditingController(text: widget.typedPrompt);
  final bool _hasSettingsChanges = true;

  @override
  Widget build(BuildContext context) {
    _dumpTheme(context, _project);
    final displayColor = _project.displayColor;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // _WorkspaceDetailPageState.build, verbatim (FAB omitted: onStartNewChat is null
    // when the page is opened from the sidebar's workspace menu)
    return DefaultTabController(
      length: 3,
      initialIndex: 2,
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: FloatingAppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: displayColor.withValues(alpha: isDark ? 0.2 : 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: AppIcon(_project.displayIcon, color: displayColor, size: 16),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(_project.name, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          leading: FloatingHeaderButton(
            icon: Icons.arrow_back_rounded,
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: () {},
          ),
          bottom: TabBar(
            indicatorColor: displayColor,
            labelColor: displayColor,
            tabs: [
              Tab(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const AppIcon(Icons.description_outlined, size: 18),
                    const SizedBox(width: 6),
                    const Text('Files'),
                    if (_project.fileCount > 0)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: WorkspaceCountBadge(count: _project.fileCount, color: displayColor),
                      ),
                  ],
                ),
              ),
              Tab(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const AppIcon(Icons.chat_bubble_outline, size: 18),
                    const SizedBox(width: 6),
                    const Text('Chats'),
                    if (_project.chatCount > 0)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: WorkspaceCountBadge(count: _project.chatCount, color: displayColor),
                      ),
                  ],
                ),
              ),
              const Tab(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppIcon(Icons.settings_outlined, size: 18),
                    SizedBox(width: 6),
                    Text('Settings'),
                  ],
                ),
              ),
            ],
          ),
        ),
        body: TabBarView(
          children: [const SizedBox(), const SizedBox(), _buildSettingsTab()],
        ),
      ),
    );
  }

  // _buildSettingsTab, verbatim up to the danger zone
  Widget _buildSettingsTab() {
    final theme = Theme.of(context);
    final iconFg = theme.resolvedIconColor;
    final displayColor = _project.displayColor;
    final isDark = theme.brightness == Brightness.dark;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16).add(floatingHeaderInset(context)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: displayColor.withValues(alpha: isDark ? 0.2 : 0.12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: AppIcon(_project.displayIcon, color: displayColor, size: 24),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_project.chatCount} chats, ${_project.fileCount} files',
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: iconFg),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Updated ${_project.updatedAgo}',
                              style: TextStyle(fontSize: 12, color: iconFg.withValues(alpha: 0.5)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Workspace Name',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: iconFg.withValues(alpha: 0.7)),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _nameController,
                    decoration: const InputDecoration(hintText: 'Workspace name'),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Description',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: iconFg.withValues(alpha: 0.7)),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _descriptionController,
                    decoration: const InputDecoration(hintText: 'What is this workspace about?'),
                    maxLines: 3,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      AppIcon(Icons.tune, color: displayColor, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        'Custom System Prompt',
                        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: iconFg),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'These instructions are sent to the AI at the start of '
                    'every chat in this workspace.',
                    style: TextStyle(fontSize: 12, color: iconFg.withValues(alpha: 0.5)),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _systemPromptController,
                    decoration: const InputDecoration(
                      hintText: 'e.g., You are a senior developer helping with a '
                          'Flutter workspace. Use Dart best practices...',
                      hintMaxLines: 3,
                    ),
                    maxLines: 6,
                  ),
                ],
              ),
            ),
          ),
          if (_hasSettingsChanges) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {},
                icon: const AppIcon(Icons.save, size: 18),
                label: const Text('Save Changes'),
                style: FilledButton.styleFrom(
                  backgroundColor: displayColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: kBorderRadiusPill),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- memory section
// system_prompt_page.dart _MaterialTextField, verbatim (no full-screen route here)
class _MaterialTextField extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;
  final int minLines;
  final int maxLines;
  final String? fullscreenTitle;
  final String? fontFamily;

  const _MaterialTextField({
    required this.controller,
    required this.hintText,
    this.minLines = 6,
    this.maxLines = 18,
    this.fontFamily,
    this.fullscreenTitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final m3 = theme.m3;
    final Widget field = TextField(
      controller: controller,
      minLines: minLines,
      maxLines: maxLines,
      cursorColor: colorScheme.primary,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: colorScheme.onSurface,
        height: 1.5,
        fontFamily: fontFamily,
      ),
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: theme.textTheme.bodyMedium?.copyWith(
          color: m3.onSurfaceVariant,
          height: 1.5,
          fontFamily: fontFamily,
        ),
        filled: true,
        fillColor: m3.surfaceContainerLow,
        contentPadding: const EdgeInsets.all(16),
        border: OutlineInputBorder(
          borderRadius: kBorderRadiusField,
          borderSide: BorderSide(color: m3.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: kBorderRadiusField,
          borderSide: BorderSide(color: m3.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: kBorderRadiusField,
          borderSide: BorderSide(color: colorScheme.primary, width: 2),
        ),
      ),
    );
    if (fullscreenTitle == null) return field;
    return Stack(
      children: [
        field,
        Positioned(
          top: 6,
          right: 6,
          child: Material(
            color: m3.surfaceContainerHigh,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: 32,
              height: 32,
              child: AppIcon(Icons.open_in_full_rounded, size: 16, color: m3.onSurfaceVariant),
            ),
          ),
        ),
      ],
    );
  }
}

class _MemoryPage extends StatelessWidget {
  const _MemoryPage({required this.memory});
  final String memory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    final l = AppLocalizations.of(context)!;
    final String? chatFont = resolveChatFontFamily(AppThemeService.instance.chatFontFamily);
    final ctrl = TextEditingController(text: memory);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: FloatingAppBar(
        title: Text(l.aiIdentityMemory),
        leading: FloatingHeaderButton(
          icon: Icons.arrow_back_rounded,
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () {},
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24).add(floatingHeaderInset(context)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Memory ─────────── (system_prompt_page.dart build(), verbatim)
            const ExpressiveSectionHeader('Memory'),
            ExpressiveInfoCard(text: l.memoryHint),
            const SizedBox(height: 12),
            _MaterialTextField(
              controller: ctrl,
              fullscreenTitle: 'Memory',
              hintText: l.memoryExample,
              fontFamily: chatFont,
              minLines: 6,
              maxLines: 18,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Flexible(
                  child: OutlinedButton.icon(
                    icon: const AppIcon(Icons.download_outlined, size: 18),
                    label: Text(l.importFromAnotherAi, maxLines: 1, overflow: TextOverflow.ellipsis),
                    onPressed: () {},
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '${ctrl.text.length} ${l.characters}',
                  style: theme.textTheme.bodySmall?.copyWith(color: m3.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 24),
            // the page's Save button (build(), verbatim, enabled: _hasAnyChanges)
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                icon: const AppIcon(Icons.check, size: 20),
                label: Text(l.saveChanges),
                onPressed: () {},
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                  // + fontFamily: test only, see _theme()
                  textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, fontFamily: 'Ubuntu'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await _font('Ubuntu', ['$work/../../_lib/assets/fonts/Ubuntu-wght.ttf']);
    // Styles that set no family fall back to Roboto in a test; the desktop app draws
    // them in the system UI font, which is Ubuntu on the owner's machine (screenshots).
    await _font('Roboto', ['$work/../../_lib/assets/fonts/Ubuntu-wght.ttf']);
    await _font('FlutterTest', ['$work/../../_lib/assets/fonts/Ubuntu-wght.ttf']);
    await _font('JetBrains Mono', ['assets/fonts/JetBrainsMono-wght.ttf']);
    final sdk = File(Platform.resolvedExecutable).parent.parent.parent.parent.path;
    await _font('MaterialIcons', ['$sdk/artifacts/material_fonts/MaterialIcons-Regular.otf']);
    AppThemeService.instance.setChatFontFamily(kChatFontFamilyJetBrainsMono);
  });

  testWidgets('workspace settings tab', (tester) async {
    await _shoot(tester, const _WorkspaceSettings(typedPrompt: wsPrompt), const Size(760, 700), 'workspace');
  });

  testWidgets('memory section', (tester) async {
    await _shoot(tester, const _MemoryPage(memory: memoryText), const Size(760, 560), 'memory');
  });
}
