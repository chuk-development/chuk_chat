import 'package:flutter/material.dart';

import 'package:cowork/services/supabase_service.dart';
import 'package:cowork/widgets/auth_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SupabaseService.initialize();
  runApp(const CoworkApp());
}

class CoworkApp extends StatelessWidget {
  const CoworkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CoWork',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4C6EF5)),
        useMaterial3: true,
      ),
      home: const AuthGate(),
    );
  }
}
