// OpenUI gallery: a dev entrypoint for visual checks of the OpenUI
// components. Desktop only (it reads files with dart:io).
//
// All canonical samples (test/openui/fixtures/*.oui), each in a
// chat-bubble-wide column:
//   flutter run -d linux -t lib/openui/dev/gallery_main.dart
//
// One program from a file, reloaded when the file changes:
//   flutter run -d linux -t lib/openui/dev/gallery_main.dart \
//     --dart-define=OPENUI_FILE=_scratch/my_view.oui
//
// Run it from the repository root (the paths are relative to it).
// See docs/OPENUI.md, "Gallery".

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/openui/openui.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';

const String _kFile = String.fromEnvironment('OPENUI_FILE');
const String _kDir = String.fromEnvironment(
  'OPENUI_DIR',
  defaultValue: 'test/openui/fixtures',
);

void main() => runApp(const OpenUiGalleryApp());

/// The gallery app.
class OpenUiGalleryApp extends StatefulWidget {
  /// Creates the gallery app.
  const OpenUiGalleryApp({super.key});

  @override
  State<OpenUiGalleryApp> createState() => _OpenUiGalleryAppState();
}

class _OpenUiGalleryAppState extends State<OpenUiGalleryApp> {
  Brightness _brightness = Brightness.dark;

  ThemeData _theme(Brightness b) => buildAppTheme(
    accent: kDefaultAccentColor,
    iconFg: b == Brightness.dark
        ? kDefaultIconFgColor
        : const Color(0xFF1A1C20),
    bg: b == Brightness.dark ? kDefaultBgColor : const Color(0xFFF8F9FF),
    brightness: b,
  );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenUI gallery',
      debugShowCheckedModeBanner: false,
      theme: _theme(_brightness),
      home: _GalleryPage(
        brightness: _brightness,
        onToggleBrightness: () => setState(() {
          _brightness = _brightness == Brightness.dark
              ? Brightness.light
              : Brightness.dark;
        }),
      ),
    );
  }
}

class _GalleryPage extends StatefulWidget {
  const _GalleryPage({
    required this.brightness,
    required this.onToggleBrightness,
  });

  final Brightness brightness;
  final VoidCallback onToggleBrightness;

  @override
  State<_GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<_GalleryPage> {
  Map<String, String> _programs = const <String, String>{};
  String? _error;
  Timer? _watch;
  DateTime? _modified;

  @override
  void initState() {
    super.initState();
    _load();
    if (_kFile.isNotEmpty) {
      _watch = Timer.periodic(const Duration(milliseconds: 700), (_) {
        final file = File(_kFile);
        if (!file.existsSync()) return;
        final m = file.lastModifiedSync();
        if (m != _modified) _load();
      });
    }
  }

  @override
  void dispose() {
    _watch?.cancel();
    super.dispose();
  }

  void _load() {
    try {
      if (_kFile.isNotEmpty) {
        final file = File(_kFile);
        _modified = file.lastModifiedSync();
        setState(() {
          _programs = <String, String>{_kFile: file.readAsStringSync()};
          _error = null;
        });
        return;
      }
      final files =
          Directory(_kDir)
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.oui'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      setState(() {
        _programs = <String, String>{
          for (final f in files) f.uri.pathSegments.last: f.readAsStringSync(),
        };
        _error = files.isEmpty ? 'No .oui files in $_kDir' : null;
      });
    } on Object catch (e) {
      setState(() => _error = 'Cannot read the samples: $e');
    }
  }

  void _show(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final handler = CallbackOpenUiActionHandler(
      onSendToAssistant: (text, ctx, form) => _show(
        'To assistant: ${OpenUiActionHandler.composeMessage(text, context: ctx, formValues: form)}',
      ),
      onOpenUrl: (url) => _show('Open URL: $url'),
    );
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _kFile.isNotEmpty
                          ? 'OpenUI: $_kFile'
                          : 'OpenUI gallery (${_programs.length} samples)',
                      style: t.titleStyle,
                    ),
                  ),
                  _Pill(
                    label: widget.brightness == Brightness.dark
                        ? 'Light'
                        : 'Dark',
                    onTap: widget.onToggleBrightness,
                  ),
                  const SizedBox(width: 8),
                  _Pill(label: 'Reload', onTap: _load),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!, style: t.captionStyle),
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: <Widget>[
                  for (final e in _programs.entries)
                    _Sample(
                      key: ValueKey<String>(e.key),
                      name: e.key,
                      source: e.value,
                      handler: handler,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One sample: its name, the rendered view in a chat-wide column, and
/// a pill that replays the source as a stream.
class _Sample extends StatefulWidget {
  const _Sample({
    required this.name,
    required this.source,
    required this.handler,
    super.key,
  });

  final String name;
  final String source;
  final OpenUiActionHandler handler;

  @override
  State<_Sample> createState() => _SampleState();
}

class _SampleState extends State<_Sample> {
  Timer? _stream;
  int? _shown;
  bool _showSource = false;

  @override
  void dispose() {
    _stream?.cancel();
    super.dispose();
  }

  void _replay() {
    _stream?.cancel();
    setState(() => _shown = 0);
    _stream = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      final next = (_shown ?? 0) + 12;
      if (next >= widget.source.length) {
        timer.cancel();
        setState(() => _shown = null);
      } else {
        setState(() => _shown = next);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    final shown = _shown;
    final streaming = shown != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(widget.name, style: t.titleStyle),
              const SizedBox(width: 12),
              _Pill(label: 'Stream', onTap: _replay),
              const SizedBox(width: 8),
              _Pill(
                label: _showSource ? 'Hide source' : 'Source',
                onTap: () => setState(() => _showSource = !_showSource),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 32,
            runSpacing: 16,
            crossAxisAlignment: WrapCrossAlignment.start,
            children: <Widget>[
              SizedBox(
                width: OpenUiTokens.chatColumnWidth,
                child: OpenUiView(
                  source: streaming
                      ? widget.source.substring(0, shown)
                      : widget.source,
                  isStreaming: streaming,
                  actionHandler: widget.handler,
                ),
              ),
              if (_showSource)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: SelectableText(
                    widget.source,
                    style: t.captionStyle.copyWith(fontFamily: 'monospace'),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = OpenUiTheme.of(context);
    return MorphTap(
      onTap: onTap,
      color: t.scheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      child: Text(
        label,
        style: TextStyle(
          color: t.scheme.onSecondaryContainer,
          fontWeight: FontWeight.w700,
          fontSize: 13,
        ),
      ),
    );
  }
}
