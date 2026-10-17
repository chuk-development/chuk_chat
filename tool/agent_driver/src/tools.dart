// The tools of the agent driver. The MCP server (mcp_server.dart) and the
// script runner (bin/agent_driver.dart --script) both call [AgentTools.call].

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_session.dart';

/// Content of a tool result, in MCP form.
class ToolResult {
  ToolResult(this.content, {this.isError = false});

  ToolResult.text(String text, {bool isError = false})
    : this(<Map<String, Object?>>[
        <String, Object?>{'type': 'text', 'text': text},
      ], isError: isError);

  ToolResult.json(Object? value)
    : this.text(const JsonEncoder.withIndent('  ').convert(value));

  final List<Map<String, Object?>> content;
  final bool isError;

  Map<String, Object?> toJson() => <String, Object?>{
    'content': content,
    'isError': isError,
  };

  /// The text parts, joined. For logs and tests.
  String get text => content
      .where((Map<String, Object?> c) => c['type'] == 'text')
      .map((Map<String, Object?> c) => c['text'])
      .join('\n');
}

/// Names of the finder kinds. Same list as `agentFinderKinds` in
/// test_driver/agent_extensions.dart.
const List<String> finderKinds = <String>[
  'text',
  'text_contains',
  'tooltip',
  'semantics_id',
  'semantics_label',
  'key',
  'type',
  'icon',
];

final Map<String, Object?> _finderProps = <String, Object?>{
  'by': <String, Object?>{
    'type': 'string',
    'enum': finderKinds,
    'description':
        'How to find the widget. text: exact text. text_contains: part of a '
        'text. tooltip: tooltip message. semantics_id: Semantics identifier '
        '(for example login_email_field). semantics_label: Semantics label. '
        'key: ValueKey<String>. type: widget class name. icon: icon code '
        'point such as 0xe5d2 (read_state lists them).',
  },
  'value': <String, Object?>{
    'type': 'string',
    'description': 'The text, identifier, key, type name or code point.',
  },
  'index': <String, Object?>{
    'type': 'integer',
    'minimum': 0,
    'description': 'Which match to use when more widgets match. Default 0.',
  },
};

Map<String, Object?> _schema(
  Map<String, Object?> props, [
  List<String> required = const <String>[],
]) => <String, Object?>{
  'type': 'object',
  'properties': props,
  if (required.isNotEmpty) 'required': required,
  'additionalProperties': false,
};

/// The tool definitions, in MCP `tools/list` form.
final List<Map<String, Object?>> toolDefinitions = <Map<String, Object?>>[
  <String, Object?>{
    'name': 'app_start',
    'description':
        'Build and start the chuk_chat app (Linux debug, entry '
        'test_driver/main_agent.dart) against the local E2E stack. The app '
        'gets its own data folders under _scratch/agent_home. The first build '
        'takes some minutes. Returns when the app is ready for commands.',
    'inputSchema': _schema(<String, Object?>{
      'headless': <String, Object?>{
        'type': 'boolean',
        'description': 'Run under xvfb-run, without a window on the desktop. Default true.',
      },
      'fresh': <String, Object?>{
        'type': 'boolean',
        'description':
            'Delete the data folders first, so the app starts signed out. '
            'Default true. false keeps the session of the last run.',
      },
      'defines_file': <String, Object?>{
        'type': 'string',
        'description':
            'Dart defines JSON. Default _scratch/e2e.defines.json. '
            'API_BASE_URL and SUPABASE_URL must be loopback addresses.',
      },
    }),
  },
  <String, Object?>{
    'name': 'app_stop',
    'description': 'Stop the app and its xvfb server.',
    'inputSchema': _schema(<String, Object?>{}),
  },
  <String, Object?>{
    'name': 'app_status',
    'description': 'Tell if the app runs, and give its folders and log file.',
    'inputSchema': _schema(<String, Object?>{}),
  },
  <String, Object?>{
    'name': 'screenshot',
    'description':
        'Capture the whole app window (all routes and dialogs) as PNG. Writes '
        '_scratch/agent_shots/<name>.png and returns the image. One image '
        'pixel is one logical pixel, so tap_at can use its coordinates.',
    'inputSchema': _schema(<String, Object?>{
      'name': <String, Object?>{
        'type': 'string',
        'description': 'File name without .png. Letters, digits, - and _.',
      },
      'inline': <String, Object?>{
        'type': 'boolean',
        'description': 'Return the image in the result. Default true.',
      },
    }),
  },
  <String, Object?>{
    'name': 'read_state',
    'description':
        'List what is on the screen now: texts, tooltips, Semantics '
        'identifiers, icons (code points) and text fields (value, focus), '
        'each with its rectangle in logical pixels. By default only items '
        'that a tap at their centre reaches.',
    'inputSchema': _schema(<String, Object?>{
      'include_hidden': <String, Object?>{
        'type': 'boolean',
        'description': 'Also list covered and off-screen items. Default false.',
      },
    }),
  },
  <String, Object?>{
    'name': 'tap',
    'description':
        'Tap a widget. Waits up to timeout_ms until a match can receive the '
        'tap.',
    'inputSchema': _schema(
      <String, Object?>{
        ..._finderProps,
        'timeout_ms': <String, Object?>{'type': 'integer', 'minimum': 1},
      },
      <String>['by', 'value'],
    ),
  },
  <String, Object?>{
    'name': 'tap_at',
    'description':
        'Tap at a point in logical pixels (the pixels of a screenshot).',
    'inputSchema': _schema(
      <String, Object?>{
        'x': <String, Object?>{'type': 'number'},
        'y': <String, Object?>{'type': 'number'},
      },
      <String>['x', 'y'],
    ),
  },
  <String, Object?>{
    'name': 'enter_text',
    'description':
        'Type text into a text field. The text replaces the value of the '
        'field. With by/value, focuses the text field in or around that '
        'widget first (a Semantics identifier, a hint text, a label). '
        'Without them, types into the field that has the focus.',
    'inputSchema': _schema(
      <String, Object?>{
        'text': <String, Object?>{'type': 'string'},
        ..._finderProps,
      },
      <String>['text'],
    ),
  },
  <String, Object?>{
    'name': 'wait_for',
    'description':
        'Wait until a widget is on the screen (or, with absent, until it is '
        'gone).',
    'inputSchema': _schema(
      <String, Object?>{
        ..._finderProps,
        'absent': <String, Object?>{'type': 'boolean'},
        'timeout_ms': <String, Object?>{
          'type': 'integer',
          'minimum': 1,
          'description': 'Default 30000.',
        },
      },
      <String>['by', 'value'],
    ),
  },
  <String, Object?>{
    'name': 'scroll',
    'description':
        'Drag from the centre of a widget by dx, dy logical pixels. A '
        'negative dy scrolls a list down.',
    'inputSchema': _schema(
      <String, Object?>{
        ..._finderProps,
        'dx': <String, Object?>{'type': 'number'},
        'dy': <String, Object?>{'type': 'number'},
        'duration_ms': <String, Object?>{'type': 'integer', 'minimum': 1},
      },
      <String>['by', 'value', 'dx', 'dy'],
    ),
  },
  <String, Object?>{
    'name': 'wait',
    'description': 'Wait some milliseconds, for example for an animation.',
    'inputSchema': _schema(
      <String, Object?>{
        'ms': <String, Object?>{
          'type': 'integer',
          'minimum': 0,
          'maximum': 60000,
        },
      },
      <String>['ms'],
    ),
  },
  <String, Object?>{
    'name': 'hot_reload',
    'description':
        'Hot reload the app after a code change. full_restart: hot restart.',
    'inputSchema': _schema(<String, Object?>{
      'full_restart': <String, Object?>{'type': 'boolean'},
    }),
  },
  <String, Object?>{
    'name': 'logs',
    'description': 'The last lines of the app and flutter run output.',
    'inputSchema': _schema(<String, Object?>{
      'lines': <String, Object?>{'type': 'integer', 'minimum': 1},
    }),
  },
];

/// Valid screenshot names.
final RegExp _shotName = RegExp(r'^[A-Za-z0-9_-]{1,80}$');

class AgentTools {
  AgentTools(this.app, {required this.shotsDir});

  final AppControl app;
  final String shotsDir;
  int _shotCounter = 0;

  /// Runs tool [name]. Errors become a result with `isError: true`, so the
  /// agent can read them and try again.
  Future<ToolResult> call(String name, Map<String, Object?> args) async {
    try {
      return await _call(name, args);
    } on ArgumentError catch (e) {
      return ToolResult.text('Bad arguments: ${e.message}', isError: true);
    } on Exception catch (e) {
      return ToolResult.text('$e', isError: true);
    } on StateError catch (e) {
      return ToolResult.text(e.message, isError: true);
    } on Error catch (e) {
      // For example a TypeError from an argument of the wrong type.
      return ToolResult.text('Bad arguments or internal error: $e',
          isError: true);
    }
  }

  Future<ToolResult> _call(String name, Map<String, Object?> a) async {
    switch (name) {
      case 'app_start':
        return ToolResult.json(
          await app.start(
            headless: _bool(a, 'headless', true),
            fresh: _bool(a, 'fresh', true),
            definesFile: a['defines_file'] as String?,
          ),
        );
      case 'app_stop':
        return ToolResult.json(await app.stop());
      case 'app_status':
        return ToolResult.json(<String, Object?>{
          ...app.status(),
          'shots': shotsDir,
        });
      case 'logs':
        return ToolResult.text(app.logs(_int(a, 'lines', 100)).join('\n'));
      case 'screenshot':
        return _screenshot(a);
      case 'read_state':
        return ToolResult.json(
          await app.extension('ext.chuk.agent.state', <String, String>{
            'includeHidden': '${_bool(a, 'include_hidden', false)}',
          }),
        );
      case 'tap':
        await app.driver(<String, String>{
          'command': 'tap',
          ..._timeout(a, 10000),
          ...finderParams(a, hittable: true),
        });
        return ToolResult.text('tapped ${_describe(a)}');
      case 'tap_at':
        final num x = _num(a, 'x');
        final num y = _num(a, 'y');
        await app.extension('ext.chuk.agent.tapAt', <String, String>{
          'x': '$x',
          'y': '$y',
        });
        return ToolResult.text('tapped at ($x, $y)');
      case 'enter_text':
        final Object? text = a['text'];
        if (text is! String) throw ArgumentError('text must be a string');
        if (a['by'] != null) {
          // Wait for the widget, then focus its text field. A tap is not
          // enough: a hint text, for example, does not receive taps.
          final Map<String, String> finder = finderParams(a);
          await app.driver(<String, String>{
            'command': 'waitFor',
            ..._timeout(a, 10000),
            ...finder,
          });
          await app.extension('ext.chuk.agent.focus', finder);
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        await app.driver(<String, String>{
          'command': 'enter_text',
          'text': text,
          ..._timeout(a, 10000),
        });
        return ToolResult.text('entered ${text.length} characters');
      case 'wait_for':
        final bool absent = _bool(a, 'absent', false);
        await app.driver(<String, String>{
          'command': absent ? 'waitForAbsent' : 'waitFor',
          ..._timeout(a, 30000),
          ...finderParams(a),
        });
        return ToolResult.text(
          absent ? '${_describe(a)} is gone' : 'found ${_describe(a)}',
        );
      case 'scroll':
        final int ms = _int(a, 'duration_ms', 300);
        await app.driver(<String, String>{
          'command': 'scroll',
          ...finderParams(a),
          'dx': '${_num(a, 'dx').toDouble()}',
          'dy': '${_num(a, 'dy').toDouble()}',
          'duration': '${ms * 1000}',
          'frequency': '60',
          ..._timeout(a, 15000),
        });
        return ToolResult.text('scrolled ${_describe(a)}');
      case 'wait':
        await Future<void>.delayed(Duration(milliseconds: _int(a, 'ms', 0)));
        return ToolResult.text('waited ${_int(a, 'ms', 0)} ms');
      case 'hot_reload':
        return ToolResult.json(
          await app.hotReload(fullRestart: _bool(a, 'full_restart', false)),
        );
      default:
        return ToolResult.text('Unknown tool "$name"', isError: true);
    }
  }

  Future<ToolResult> _screenshot(Map<String, Object?> a) async {
    final String name = (a['name'] as String?) ?? _defaultShotName();
    if (!_shotName.hasMatch(name)) {
      throw ArgumentError('name "$name": use 1-80 letters, digits, - or _');
    }
    final Map<String, Object?> r = await app.extension(
      'ext.chuk.agent.screenshot',
    );
    final String b64 = r['png']! as String;
    final Directory dir = Directory(shotsDir)..createSync(recursive: true);
    final File out = File(p.join(dir.path, '$name.png'));
    out.writeAsBytesSync(base64Decode(b64), flush: true);
    final String text = 'wrote ${out.path} (${r['width']}x${r['height']} px)';
    if (!_bool(a, 'inline', true)) return ToolResult.text(text);
    return ToolResult(<Map<String, Object?>>[
      <String, Object?>{'type': 'text', 'text': text},
      <String, Object?>{'type': 'image', 'data': b64, 'mimeType': 'image/png'},
    ]);
  }

  String _defaultShotName() {
    _shotCounter++;
    final String n = '$_shotCounter'.padLeft(2, '0');
    return 'shot_$n';
  }
}

/// The driver parameters of the `Agent` finder for tool arguments [a].
Map<String, String> finderParams(
  Map<String, Object?> a, {
  bool hittable = false,
}) {
  final Object? by = a['by'];
  final Object? value = a['value'];
  if (by is! String || !finderKinds.contains(by)) {
    throw ArgumentError('by must be one of ${finderKinds.join(', ')}');
  }
  if (value is! String || value.isEmpty) {
    throw ArgumentError('value must be a non-empty string');
  }
  final int index = _int(a, 'index', 0);
  if (index < 0) throw ArgumentError('index must be 0 or more');
  return <String, String>{
    'finderType': 'Agent',
    'by': by,
    'value': value,
    'index': '$index',
    'hittable': '$hittable',
  };
}

String _describe(Map<String, Object?> a) {
  final Object? i = a['index'];
  return '${a['by']}="${a['value']}"${i == null ? '' : ' #$i'}';
}

Map<String, String> _timeout(Map<String, Object?> a, int fallback) =>
    <String, String>{'timeout': '${_int(a, 'timeout_ms', fallback)}'};

bool _bool(Map<String, Object?> a, String key, bool fallback) {
  final Object? v = a[key];
  if (v == null) return fallback;
  if (v is bool) return v;
  throw ArgumentError('$key must be true or false');
}

int _int(Map<String, Object?> a, String key, int fallback) {
  final Object? v = a[key];
  if (v == null) return fallback;
  if (v is num && v == v.roundToDouble()) return v.toInt();
  throw ArgumentError('$key must be an integer');
}

num _num(Map<String, Object?> a, String key) {
  final Object? v = a[key];
  if (v is num) return v;
  throw ArgumentError('$key must be a number');
}
