// Answer replay: a dev entrypoint for visual checks of real answers. It draws
// each message of a JSON file through the real MessageBubble and writes one
// PNG per message, at full height. No login, no Supabase, no chat storage.
//
//   scripts/answer_replay.sh [--light] [--width 430] <messages.json> <out dir>
//
// The JSON is a list of {"id", "text", "toolCalls"?}. Text comes from a local
// file and is not sent anywhere; card images load from their shops over the
// network, as in the app. Desktop only (dart:io). See docs/ANSWER_BLOCKS.md.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';

const String _kFile = String.fromEnvironment('REPLAY_FILE');
const String _kOut = String.fromEnvironment('REPLAY_OUT');
const double _kWidth = 0.0 + int.fromEnvironment('REPLAY_WIDTH', defaultValue: 430);
const bool _kLight = bool.fromEnvironment('REPLAY_LIGHT');
const int _kSettleMs = int.fromEnvironment('REPLAY_SETTLE_MS', defaultValue: 3500);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _ReplayApp());
}

class _ReplayApp extends StatefulWidget {
  const _ReplayApp();

  @override
  State<_ReplayApp> createState() => _ReplayAppState();
}

class _ReplayAppState extends State<_ReplayApp> {
  final GlobalKey _boundary = GlobalKey();
  late final List<Map<String, dynamic>> _items =
      (jsonDecode(File(_kFile).readAsStringSync()) as List<dynamic>)
          .cast<Map<String, dynamic>>();
  int _index = 0;

  @override
  void initState() {
    super.initState();
    if (_items.isEmpty) {
      stderr.writeln('REPLAY no messages in $_kFile');
      exit(2);
    }
    Directory(_kOut).createSync(recursive: true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
  }

  Future<void> _capture() async {
    await Future<void>.delayed(const Duration(milliseconds: _kSettleMs));
    try {
      await _writePng();
    } catch (e) {
      // The script waits for this process: a failure must end it.
      stderr.writeln('REPLAY failed: $e');
      exit(1);
    }
    if (_index + 1 >= _items.length) exit(0);
    setState(() => _index++);
    WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
  }

  Future<void> _writePng() async {
    final String id = _items[_index]['id'].toString();
    final RenderRepaintBoundary box =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final ui.Image image = await box.toImage(pixelRatio: 1.5);
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    File('$_kOut/$id.png').writeAsBytesSync(data!.buffer.asUint8List());
    image.dispose();
    stdout.writeln('REPLAY $id ${box.size.height.round()}');
  }

  @override
  Widget build(BuildContext context) {
    final Brightness b = _kLight ? Brightness.light : Brightness.dark;
    final ThemeData theme = buildAppTheme(
      accent: kDefaultAccentColor,
      iconFg: _kLight ? const Color(0xFF1A1C20) : kDefaultIconFgColor,
      bg: _kLight ? const Color(0xFFF8F9FF) : kDefaultBgColor,
      brightness: b,
    );
    final Map<String, dynamic> item = _items[_index];
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      locale: const Locale('de'),
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: SingleChildScrollView(
          child: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: _boundary,
              child: Container(
                width: _kWidth,
                color: theme.scaffoldBackgroundColor,
                padding: const EdgeInsets.all(12),
                child: MessageBubble(
                  key: ValueKey<int>(_index),
                  message: item['text'] as String,
                  isUser: false,
                  messageId: item['id'].toString(),
                  maxWidth: _kWidth - 24,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
