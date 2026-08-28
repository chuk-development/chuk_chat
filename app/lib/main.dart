import 'package:flutter/material.dart';

import 'package:cowork/services/settings/theme_controller.dart';
import 'package:cowork/services/supabase_service.dart';
import 'package:cowork/widgets/auth_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SupabaseService.initialize();
  runApp(const CoworkApp());
}

class CoworkApp extends StatefulWidget {
  const CoworkApp({super.key});

  @override
  State<CoworkApp> createState() => _CoworkAppState();
}

class _CoworkAppState extends State<CoworkApp> {
  /// Owns the theme mode for the app's life. Loaded from storage on startup;
  /// the settings Theme page writes to it and the whole app repaints.
  final ThemeController _theme = ThemeController();

  static const Color _seed = Color(0xFF4C6EF5);

  @override
  void initState() {
    super.initState();
    _theme.load();
  }

  @override
  void dispose() {
    _theme.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: _theme,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'CoWork',
          debugShowCheckedModeBanner: false,
          themeMode: mode,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: _seed),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: _seed,
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
          ),
          home: AuthGate(themeController: _theme),
        );
      },
    );
  }
}
