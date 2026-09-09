// The scenes the store screenshots are made of.
//
// Every scene is built from the app's own widgets and the app's own theme
// builder, so what the listing shows is what the app draws. Only the data is
// staged: no Supabase, no network, no device storage.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/pages/theme_page.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';

/// The font the app chrome falls back to on Android when the user keeps the
/// system UI font. The theme leaves `fontFamily` null for that case, which a
/// real device resolves to Roboto and the test engine resolves to its
/// box-drawing placeholder — so name it explicitly for screenshots.
const String _platformUiFont = 'Roboto';

/// The default dark palette, i.e. what a new install looks like.
ThemeData screenshotTheme({Brightness brightness = Brightness.dark}) {
  final ThemeData base = buildAppTheme(
    accent: kDefaultAccentColor,
    iconFg: kDefaultIconFgColor,
    bg: brightness == Brightness.dark
        ? kDefaultBgColor
        : const Color(0xFFF7F8FA),
    brightness: brightness,
    contrast: kDefaultContrast,
  );

  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: _platformUiFont),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: _platformUiFont),
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: (base.appBarTheme.titleTextStyle ?? const TextStyle())
          .copyWith(fontFamily: _platformUiFont),
      toolbarTextStyle:
          (base.appBarTheme.toolbarTextStyle ?? const TextStyle())
              .copyWith(fontFamily: _platformUiFont),
    ),
  );
}

/// Wraps a scene in the same app shell the real binary uses: theme,
/// localisation delegates and a fixed locale.
Widget appShell({
  required Widget child,
  required String locale,
  Brightness brightness = Brightness.dark,
}) =>
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: screenshotTheme(brightness: brightness),
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      locale: Locale(locale),
      home: child,
    );

/// Chat chrome around a list of turns: title bar, scroll area, composer.
/// Built here rather than pulled from `ChukChatUIMobile`, which needs a live
/// Supabase session and the local cache to even reach its first frame.
class _ChatFrame extends StatelessWidget {
  const _ChatFrame({
    required this.title,
    required this.modelLabel,
    required this.children,
    this.composerHint = 'Ask anything…',
  });

  final String title;
  final String modelLabel;
  final List<Widget> children;
  final String composerHint;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: const Icon(Icons.menu_rounded),
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium,
            ),
            Text(
              modelLabel,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: const <Widget>[
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: Icon(Icons.edit_square),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                physics: const NeverScrollableScrollPhysics(),
                children: children,
              ),
            ),
            _Composer(hint: composerHint),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({required this.hint});

  final String hint;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: kBorderRadiusField,
          border: Border.all(color: scheme.outlineVariant),
        ),
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                hint,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            Icon(Icons.attach_file_rounded, color: scheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.arrow_upward_rounded,
                  size: 20, color: scheme.onPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

MessageBubble _user(String text) => MessageBubble(
      message: text,
      isUser: true,
    );

MessageBubble _assistant({
  required List<ContentBlock> blocks,
  String? modelLabel,
  String? reasoning,
  double? tps,
  Duration? workedFor,
}) =>
    MessageBubble(
      message: '',
      isUser: false,
      contentBlocks: blocks,
      modelLabel: modelLabel,
      reasoning: reasoning,
      workedFor: workedFor,
      showModelInfo: modelLabel != null,
      showTps: tps != null,
      showReasoningTokens: reasoning != null,
      tps: tps,
    );

/// Scene 1 — an ordinary conversation with formatted output.
Widget chatScene({required String locale}) {
  final bool de = locale.startsWith('de');
  return appShell(
    locale: locale,
    child: _ChatFrame(
      title: 'Rust vs. Go',
      modelLabel: 'DeepSeek V4 Pro',
      composerHint: de ? 'Frag irgendwas…' : 'Ask anything…',
      children: <Widget>[
        _user(de
            ? 'Erklär mir kurz, wann ich Rust statt Go nehmen sollte.'
            : 'In two lines: when should I pick Rust over Go?'),
        const SizedBox(height: 8),
        _assistant(
          modelLabel: 'DeepSeek V4 Pro',
          tps: 84.2,
          blocks: <ContentBlock>[
            ContentBlock.text(
              de
                  ? '**Rust**, wenn du harte Latenzgrenzen hast oder ohne '
                      'Garbage Collector auskommen musst — Kernel-Module, '
                      'Audio, Spiele-Engines.\n\n'
                      '**Go**, wenn Durchsatz und Entwicklungstempo zählen: '
                      'Netzwerkdienste, CLIs, alles mit vielen Goroutines.\n\n'
                      '```rust\n'
                      'let total: u64 = items\n'
                      '    .par_iter()\n'
                      '    .map(|i| i.weight)\n'
                      '    .sum();\n'
                      '```'
                  : '**Rust** when you have hard latency limits or cannot '
                      'afford a garbage collector — kernel modules, audio, '
                      'game engines.\n\n'
                      '**Go** when throughput and shipping speed matter: '
                      'network services, CLIs, anything with many '
                      'goroutines.\n\n'
                      '```rust\n'
                      'let total: u64 = items\n'
                      '    .par_iter()\n'
                      '    .map(|i| i.weight)\n'
                      '    .sum();\n'
                      '```',
            ),
          ],
        ),
        const SizedBox(height: 8),
        _user(de ? 'Und für eine REST-API?' : 'And for a REST API?'),
        const SizedBox(height: 8),
        _assistant(
          modelLabel: 'DeepSeek V4 Pro',
          blocks: <ContentBlock>[
            ContentBlock.text(
              de
                  ? 'Go. Weniger Code, schnellerer Build, und die '
                      'Standardbibliothek deckt fast alles ab.'
                  : 'Go. Less code, faster builds, and the standard library '
                      'covers almost all of it.',
            ),
          ],
        ),
      ],
    ),
  );
}

/// Scene 2 — a turn that used tools, with the sources pill.
Widget toolsScene({required String locale}) {
  final bool de = locale.startsWith('de');
  return appShell(
    locale: locale,
    child: _ChatFrame(
      title: de ? 'Web-Recherche' : 'Web research',
      modelLabel: 'GLM 5.3 Flash',
      composerHint: de ? 'Frag irgendwas…' : 'Ask anything…',
      children: <Widget>[
        _user(de
            ? 'Was hat sich diese Woche bei WebGPU getan?'
            : 'What changed in WebGPU this week?'),
        const SizedBox(height: 8),
        _assistant(
          modelLabel: 'GLM 5.3 Flash',
          workedFor: const Duration(seconds: 7),
          blocks: <ContentBlock>[
            ContentBlock.toolCalls(<ToolCall>[
              ToolCall(
                id: 'call_1',
                name: 'web_search',
                arguments: const <String, dynamic>{
                  'query': 'WebGPU changes this week',
                },
                status: ToolCallStatus.completed,
                result: '1. WebGPU compute pipeline caching lands\n'
                    '   https://developer.chrome.com/webgpu\n'
                    '2. Firefox ships WebGPU on Linux\n'
                    '   https://hacks.mozilla.org/webgpu\n'
                    '3. wgpu 24 release notes\n'
                    '   https://wgpu.rs/releases\n',
              ),
            ]),
            ContentBlock.text(
              de
                  ? 'Drei Dinge diese Woche:\n\n'
                      '- Chrome cached jetzt kompilierte Compute-Pipelines, '
                      'der zweite Start einer Shader-Pipeline entfällt damit.\n'
                      '- Firefox liefert WebGPU auf Linux aus, hinter dem '
                      'Vulkan-Backend.\n'
                      '- wgpu 24 bringt die neue Bind-Group-API und bricht '
                      'dabei die alte Layout-Signatur.'
                  : 'Three things this week:\n\n'
                      '- Chrome now caches compiled compute pipelines, so the '
                      'second start of a shader pipeline is free.\n'
                      '- Firefox ships WebGPU on Linux, on the Vulkan '
                      'backend.\n'
                      '- wgpu 24 brings the new bind group API and breaks the '
                      'old layout signature.',
            ),
          ],
        ),
      ],
    ),
  );
}

/// Scene 3 — visible reasoning, the feature the model info row advertises.
Widget reasoningScene({required String locale}) {
  final bool de = locale.startsWith('de');
  return appShell(
    locale: locale,
    child: _ChatFrame(
      title: de ? 'Denkschritte' : 'Reasoning',
      modelLabel: 'DeepSeek V4 Pro',
      composerHint: de ? 'Frag irgendwas…' : 'Ask anything…',
      children: <Widget>[
        _user(de
            ? 'Ein Zug fährt 90 Minuten mit 120 km/h. Wie weit kommt er?'
            : 'A train runs 90 minutes at 120 km/h. How far does it get?'),
        const SizedBox(height: 8),
        _assistant(
          modelLabel: 'DeepSeek V4 Pro',
          tps: 71.9,
          reasoning: de
              ? '90 Minuten sind 1,5 Stunden. Strecke ist Geschwindigkeit '
                  'mal Zeit, also 120 * 1,5.'
              : '90 minutes is 1.5 hours. Distance is speed times time, so '
                  '120 * 1.5.',
          blocks: <ContentBlock>[
            const ContentBlock.text('**180 km.**'),
          ],
        ),
      ],
    ),
  );
}

/// Scene 4 — the real theme page, i.e. the customisation the app sells.
Widget themeScene({required String locale}) {
  return appShell(
    locale: locale,
    child: ThemePage(config: _screenshotShellConfig(locale)),
  );
}

AppShellConfig _screenshotShellConfig(String locale) => AppShellConfig(
      currentThemeMode: Brightness.dark,
      currentAccentColor: kDefaultAccentColor,
      currentIconFgColor: kDefaultIconFgColor,
      currentBgColor: kDefaultBgColor,
      setThemeMode: (_) {},
      setAccentColor: (_) {},
      setIconFgColor: (_) {},
      setBgColor: (_) {},
      dynamicColorEnabled: false,
      setDynamicColorEnabled: (_) async {},
      contrast: kDefaultContrast,
      setContrast: (_) async {},
      uiFontFamily: kDefaultUiFontFamily,
      setUiFontFamily: (_) async {},
      showReasoningTokens: true,
      setShowReasoningTokens: (_) {},
      showModelInfo: true,
      setShowModelInfo: (_) {},
      showTps: true,
      setShowTps: (_) {},
      autoSendVoiceTranscription: false,
      setAutoSendVoiceTranscription: (_) {},
      imageGenEnabled: true,
      setImageGenEnabled: (_) {},
      imageGenDefaultSize: 'landscape_4_3',
      setImageGenDefaultSize: (_) {},
      imageGenCustomWidth: 1024,
      setImageGenCustomWidth: (_) {},
      imageGenCustomHeight: 768,
      setImageGenCustomHeight: (_) {},
      imageGenUseCustomSize: false,
      setImageGenUseCustomSize: (_) {},
      includeRecentImagesInHistory: true,
      setIncludeRecentImagesInHistory: (_) {},
      includeAllImagesInHistory: false,
      setIncludeAllImagesInHistory: (_) {},
      includeReasoningInHistory: false,
      setIncludeReasoningInHistory: (_) {},
      includeToolResultsInHistory: true,
      setIncludeToolResultsInHistory: (_) {},
      toolCallingEnabled: true,
      setToolCallingEnabled: (_) {},
      toolDiscoveryMode: true,
      setToolDiscoveryMode: (_) {},
      showToolCalls: true,
      setShowToolCalls: (_) {},
      uiLocale: locale,
      setUiLocale: (_) {},
      chatFontSize: kDefaultChatFontSize,
      setChatFontSize: (_) {},
      chatFontFamily: kDefaultChatFontFamily,
      setChatFontFamily: (_) {},
      uiScale: kDefaultUiScale,
      setUiScale: (_) async {},
    );

/// The 1024x500 banner at the top of the store listing.
Widget featureGraphicScene({required String locale}) {
  final bool de = locale.startsWith('de');
  return appShell(
    locale: locale,
    child: Builder(
      builder: (BuildContext context) {
        final ThemeData theme = Theme.of(context);
        final ColorScheme scheme = theme.colorScheme;

        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[
                kDefaultBgColor,
                Color.lerp(kDefaultBgColor, scheme.primary, 0.28)!,
              ],
            ),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  'Chuk Chat',
                  style: theme.textTheme.displaySmall?.copyWith(
                    color: scheme.onSurface,
                    fontSize: 76,
                    height: 1.05,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1.5,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  de
                      ? 'Privat und sicher. Immer.'
                      : 'Private and Secure. Always.',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: scheme.primary,
                    fontSize: 30,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  de
                      ? 'Verschlüsselter KI-Chat mit offenen Modellen'
                      : 'Encrypted AI chat on open-weight models',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontSize: 21,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
