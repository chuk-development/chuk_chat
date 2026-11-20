// Real pages on the shared header: the agent's Model page, on a desktop
// window (in the settings modal, with the close chip) and on a phone, light
// and dark, at the top and scrolled under the header.
//
// UI_LIB_PNG=1 writes PNGs into _scratch/ui_lib/<UI_LIB_TAG>/ (real fonts).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/pages/agent_model_page.dart';
import 'package:chuk_chat/services/agents/agent_control_source.dart';
import 'package:chuk_chat/services/agents/agent_model.dart';
import 'package:chuk_chat/services/chat_model_selection_service.dart';
import 'package:chuk_chat/services/model_capabilities_service.dart';
import 'package:chuk_chat/theme/theme_presets.dart';
import 'package:chuk_chat/ui/components/components.dart';
import 'package:chuk_chat/widgets/settings_surface.dart';

import '../platform_specific/mobile/mobile_support.dart';
import '../support/kv_cache_test_env.dart';
import '../support/test_app.dart';

final bool _write = Platform.environment['UI_LIB_PNG'] == '1';
final String _tag = Platform.environment['UI_LIB_TAG'] ?? 'pages';

const String _chat = 'host:alex';

const List<AgentCatalogueModel> _catalogue = <AgentCatalogueModel>[
  AgentCatalogueModel(
    id: 'deepseek/deepseek-v4.1-flash-1017',
    name: 'DeepSeek: V4.1 Flash 1017',
    providers: <AgentProvider>[
      AgentProvider(
        slug: 'fireworks/serverless',
        name: 'Fireworks',
        promptPrice: 0.0000002,
        completionPrice: 0.0000008,
      ),
    ],
  ),
  AgentCatalogueModel(
    id: 'z-ai/glm-5.3-flash',
    name: 'Z.ai: GLM 5.3 Flash',
    providers: <AgentProvider>[
      AgentProvider(
        slug: 'fireworks/serverless',
        name: 'Fireworks',
        promptPrice: 0.0000002,
        completionPrice: 0.0000008,
      ),
    ],
  ),
];

ThemeData _theme(Brightness b) => b == Brightness.dark
    ? buildAppTheme(
        accent: kDefaultAccentColor,
        iconFg: kDefaultIconFgColor,
        bg: kDefaultBgColor,
        brightness: Brightness.dark,
        palette: kPlaneDarkPalette,
      )
    : buildAppTheme(
        accent: const Color(0xFF45484A),
        iconFg: const Color(0xFF0F0F10),
        bg: const Color(0xFFFFFFFF),
        brightness: Brightness.light,
      );

Future<void> _png(WidgetTester tester, String name) async {
  if (!_write) return;
  final RenderRepaintBoundary rb = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey<String>('shot')),
  );
  await tester.runAsync(() async {
    final ui.Image image = await rb.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final File out = File('_scratch/ui_lib/$_tag/$name.png');
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(data!.buffer.asUint8List());
  });
}

void main() {
  late Directory kv;

  setUpAll(loadRealFonts);
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ChatModelSelectionService.instance.clearMemoryForTesting();
    AgentModel.debugCatalogue = () async => _catalogue;
    kv = await useTempKvCache();
    await ModelCapabilitiesService.initialize();
  });
  tearDown(() async {
    AgentModel.debugCatalogue = null;
    await disposeTempKvCache(kv);
  });

  for (final Brightness b in Brightness.values) {
    for (final bool desktop in <bool>[true, false]) {
      final String n = '${desktop ? 'desktop' : 'mobile'}_${b.name}';
      testWidgets('model page header $n', (tester) async {
        final Size size = desktop
            ? const Size(1440, 900)
            : const Size(412, 915);
        const EdgeInsets phoneInset = EdgeInsets.only(top: 24, bottom: 16);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        // An agent on Auto routing whose last run named no provider: the
        // case that read "via provider not reported".
        final FakeAgentControlSource source = FakeAgentControlSource(
          initial: const AgentControlSnapshot(
            model: ControlAvailable<AgentModelChoice>(
              AgentModelChoice(id: 'deepseek/deepseek-v4.1-flash-1017'),
            ),
          ),
        );
        addTearDown(source.dispose);
        Widget page(BuildContext _) => AgentModelPage(
          chatId: _chat,
          agentName: 'Alex',
          controlSource: source,
        );
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(
              size: size,
              padding: desktop ? EdgeInsets.zero : phoneInset,
              viewPadding: desktop ? EdgeInsets.zero : phoneInset,
            ),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: _theme(b),
              localizationsDelegates: kTestLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: RepaintBoundary(
                key: const ValueKey<String>('shot'),
                child: desktop
                    ? Scaffold(
                        body: SettingsModalFrame(
                          builder: (context, panel) => SettingsSurfaceNavigator(
                            builder: page,
                            onClose: () {},
                          ),
                        ),
                      )
                    : Builder(builder: page),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // One header: the frosted material, the title pill, and in the
        // settings modal the close chip.
        expect(find.byType(PageHeaderBackdrop), findsOneWidget);
        expect(find.text('Model'), findsWidgets);
        expect(
          find.byKey(const ValueKey<String>('settings-surface-close')),
          desktop ? findsOneWidget : findsNothing,
        );
        // The Auto run reads "via Automatic", never "not reported".
        expect(find.textContaining('not reported'), findsNothing);
        expect(
          find.textContaining('V4.1 Flash 1017 via Automatic'),
          findsWidgets,
        );

        await _png(tester, 'model_${n}_top');
        final ScrollableState scroll = tester.state<ScrollableState>(
          find.byType(Scrollable).first,
        );
        for (final double off in <double>[30, 70]) {
          scroll.position.jumpTo(off);
          await tester.pump();
          await _png(tester, 'model_${n}_scroll${off.toInt()}');
        }
      });
    }
  }
}
