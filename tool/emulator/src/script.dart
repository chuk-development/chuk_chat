// Scripted model for the chuk API emulator.
//
// A "turn" is the answer to one chat request. A turn is a list of steps. The
// emulator plays the steps in order and turns each one into the frames that
// api.chuk.chat sends for the same event. When no scripted turn is queued, the
// emulator plays [defaultTurn], a deterministic echo of the user message.

import 'dart:convert';

/// The step types that a script can use.
const Set<String> knownStepTypes = {
  'text',
  'reasoning',
  'tool_call',
  'usage',
  'error',
  'disconnect',
  'delay',
};

/// One step of a scripted turn. See docs/API_EMULATOR.md for the format.
class ScriptStep {
  ScriptStep(this.type, this.data);

  /// Parses one step. Throws [FormatException] for a step that is not valid.
  factory ScriptStep.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('A step must be a JSON object.');
    }
    final map = raw.map((k, v) => MapEntry(k.toString(), v));
    final type = map['type'];
    if (type is! String || !knownStepTypes.contains(type)) {
      throw FormatException(
        'Unknown step type: $type. Use one of ${knownStepTypes.join(', ')}.',
      );
    }
    switch (type) {
      case 'text':
      case 'reasoning':
        if (map['text'] is! String && map['chunks'] is! List) {
          throw FormatException('A "$type" step needs "text" or "chunks".');
        }
      case 'tool_call':
        if (map['name'] is! String) {
          throw const FormatException('A "tool_call" step needs "name".');
        }
        final chunks = map['arguments_chunks'];
        if (chunks != null && chunks is! List) {
          throw const FormatException('"arguments_chunks" must be a list.');
        }
      case 'error':
        if (map['message'] is! String) {
          throw const FormatException('An "error" step needs "message".');
        }
      case 'delay':
        if (map['ms'] is! num) {
          throw const FormatException('A "delay" step needs "ms".');
        }
    }
    return ScriptStep(type, map);
  }

  final String type;
  final Map<String, Object?> data;

  /// The text pieces of a "text" or "reasoning" step, one frame each.
  List<String> get textChunks {
    final chunks = data['chunks'];
    if (chunks is List) {
      return chunks
          .map((c) => c.toString())
          .where((c) => c.isNotEmpty)
          .toList();
    }
    return splitIntoChunks(data['text'] as String? ?? '');
  }

  /// The complete argument string of a "tool_call" step.
  ///
  /// The real server collects the argument deltas from the upstream model and
  /// sends the finished call in one `tool_calls` frame. The emulator does the
  /// same: "arguments_chunks" are joined here, as the server joins the deltas.
  String get toolArguments {
    final chunks = data['arguments_chunks'];
    if (chunks is List) return chunks.map((c) => c.toString()).join();
    final args = data['arguments'];
    if (args is String) return args;
    if (args == null) return '{}';
    return jsonEncode(args);
  }

  Map<String, Object?> toJson() => data;
}

/// A scripted turn: the steps that answer one chat request.
typedef ScriptTurn = List<ScriptStep>;

/// Parses the body of POST /__emulator/script.
///
/// Accepted forms:
/// - a JSON list of steps: one turn;
/// - `{"steps": [...]}`: one turn;
/// - `{"turns": [[...], [...]]}`: several turns, one per chat request.
List<ScriptTurn> parseScript(Object? body) {
  if (body is List) {
    return [body.map(ScriptStep.fromJson).toList()];
  }
  if (body is Map) {
    final turns = body['turns'];
    if (turns is List) {
      return turns.map((turn) {
        if (turn is! List) {
          throw const FormatException('Each turn must be a list of steps.');
        }
        return turn.map(ScriptStep.fromJson).toList();
      }).toList();
    }
    final steps = body['steps'];
    if (steps is List) {
      return [steps.map(ScriptStep.fromJson).toList()];
    }
  }
  throw const FormatException(
    'Send a list of steps, {"steps": [...]} or {"turns": [[...], ...]}.',
  );
}

/// The answer when no script is queued: a deterministic echo.
ScriptTurn defaultTurn(String message) {
  final text = message.trim().isEmpty
      ? 'Echo: (empty message)'
      : 'Echo: ${message.trim()}';
  return [
    ScriptStep('text', {'type': 'text', 'text': text}),
  ];
}

/// Splits text into word-sized pieces. Joining the pieces gives the input.
List<String> splitIntoChunks(String text) {
  if (text.isEmpty) return const [];
  final pieces = RegExp(r'\s*\S+\s*')
      .allMatches(text)
      .map((m) => m.group(0)!)
      .toList();
  return pieces.isEmpty ? [text] : pieces;
}
