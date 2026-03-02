import 'dart:math' as math;

/// Calculator tool with full expression parsing.
///
/// Supports:
/// - Complex expressions: "2 + 3 * 4", "(5 + 3) * 2", "2^10"
/// - Functions: sqrt, sin, cos, tan, log, ln, abs, exp, ceil, floor
/// - Constants: pi, e
/// - Percentages: "15% of 200"
/// - Format 1: {"expression": "5 + 3 * 2"}
/// - Format 2: {"operation": "add", "num1": 5, "num2": 3} (legacy)
String executeCalculate(Map<String, dynamic> args) {
  try {
    // Format 1: expression string (preferred)
    if (args.containsKey('expression')) {
      final expr = args['expression'].toString().trim();
      return _evalExpression(expr);
    }

    // Format 2: legacy {"operation": "add", "num1": 5, "num2": 3}
    if (args.containsKey('operation')) {
      final opRaw = args['operation'];
      if (opRaw is! String || opRaw.trim().isEmpty) {
        return 'Error: operation must be a non-empty string';
      }

      final rawNum1 = args['num1'] ?? args['a'];
      final rawNum2 = args['num2'] ?? args['b'];
      if (rawNum1 == null || rawNum2 == null) {
        return 'Error: num1 and num2 are required for operation mode';
      }

      late final num num1;
      late final num num2;
      try {
        num1 = _toNum(rawNum1);
        num2 = _toNum(rawNum2);
      } catch (_) {
        return 'Error: num1 and num2 must be numeric values';
      }

      final op = opRaw.trim();

      switch (op.toLowerCase()) {
        case 'add' || 'plus' || '+':
          return 'Result: ${_formatNum(num1 + num2)}';
        case 'subtract' || 'minus' || '-':
          return 'Result: ${_formatNum(num1 - num2)}';
        case 'multiply' || 'times' || '*' || 'x':
          return 'Result: ${_formatNum(num1 * num2)}';
        case 'divide' || '/':
          if (num2 == 0) return 'Error: Division by zero';
          return 'Result: ${_formatNum(num1 / num2)}';
        case 'power' || 'pow' || '^':
          return 'Result: ${_formatNum(math.pow(num1, num2))}';
        case 'modulo' || 'mod' || '%':
          if (num2 == 0) return 'Error: Division by zero';
          return 'Result: ${_formatNum(num1 % num2)}';
        default:
          return 'Unknown operation: $op';
      }
    }

    return 'Error: Provide {"expression": "5 + 3 * 2"} or '
        '{"operation": "add", "num1": 5, "num2": 3}';
  } catch (e) {
    return 'Calculation error: $e';
  }
}

/// Evaluate a math expression using a simple recursive descent parser.
/// Avoids the math_expressions dependency for now -- supports basic arithmetic,
/// parentheses, functions, and constants.
String _evalExpression(String raw) {
  if (raw.isEmpty) return 'Error: Empty expression';

  // Normalise common symbols
  var expr = raw
      .replaceAll('\u00D7', '*') // ×
      .replaceAll('\u00F7', '/'); // ÷

  // Handle commas: strip thousand separators (digit,digit{3}) then convert
  // remaining commas to dots for European decimal notation.
  expr = expr.replaceAll(RegExp(r'(?<=\d),(?=\d{3}\b)'), '');
  expr = expr.replaceAll(',', '.');

  // Replace constants (use negative lookbehind/lookahead to avoid matching
  // the 'e' in scientific notation like 3e5 or 1.5e-10).
  expr = expr.replaceAll(RegExp(r'\bpi\b', caseSensitive: false), '${math.pi}');
  expr = expr.replaceAll(
    RegExp(r'(?<!\d\.?)(?<!\d)\be\b(?![+-]?\d)', caseSensitive: false),
    '${math.e}',
  );

  // Handle percentage: "50% of 200" -> "0.50 * 200"
  expr = expr.replaceAllMapped(
    RegExp(
      r'(\d+(?:\.\d+)?)\s*%\s*(?:of|von)\s*(\d+(?:\.\d+)?)',
      caseSensitive: false,
    ),
    (m) {
      final pctRaw = double.tryParse(m.group(1) ?? '');
      if (pctRaw == null) {
        return m.group(0) ?? '';
      }
      final pct = pctRaw / 100;
      final base = m.group(2)!;
      return '($pct * $base)';
    },
  );

  // Handle simple percentage: "15%" -> "0.15"
  expr = expr.replaceAllMapped(RegExp(r'(\d+(?:\.\d+)?)\s*%(?!\s*\d)'), (m) {
    final value = double.tryParse(m.group(1) ?? '');
    if (value == null) {
      return m.group(0) ?? '';
    }
    return '${value / 100}';
  });

  try {
    final parser = _ExprParser(expr);
    final result = parser.parseExpression();
    if (parser.pos < parser.input.length) {
      return 'Error parsing "$raw": unexpected character at position '
          '${parser.pos}';
    }
    return 'Expression: $raw\nResult: ${_formatNum(result)}';
  } catch (e) {
    return 'Error parsing "$raw": $e';
  }
}

/// Simple recursive descent parser for math expressions.
/// Supports: +, -, *, /, ^, parentheses, sqrt, sin, cos, tan, log, abs, exp
class _ExprParser {
  final String input;
  int pos = 0;

  _ExprParser(String raw) : input = raw.replaceAll(' ', '');

  double parseExpression() {
    var result = parseTerm();
    while (pos < input.length) {
      if (_match('+')) {
        result += parseTerm();
      } else if (_match('-')) {
        result -= parseTerm();
      } else {
        break;
      }
    }
    return result;
  }

  double parseTerm() {
    var result = parsePower();
    while (pos < input.length) {
      if (_match('*')) {
        result *= parsePower();
      } else if (_match('/')) {
        final divisor = parsePower();
        if (divisor == 0) throw FormatException('Division by zero');
        result /= divisor;
      } else {
        break;
      }
    }
    return result;
  }

  double parsePower() {
    final base = parseUnary();
    if (_match('^')) {
      final exponent = parsePower();
      return math.pow(base, exponent).toDouble();
    }
    return base;
  }

  double parseUnary() {
    if (_match('-')) return -parseUnary();
    if (_match('+')) return parseUnary();
    return parsePrimary();
  }

  double parsePrimary() {
    // Parentheses
    if (_match('(')) {
      final result = parseExpression();
      if (!_match(')')) throw FormatException('Missing closing parenthesis');
      return result;
    }

    // Functions
    for (final fn in [
      'sqrt',
      'sin',
      'cos',
      'tan',
      'log',
      'ln',
      'abs',
      'exp',
      'ceil',
      'floor',
    ]) {
      if (_matchWord(fn)) {
        if (!_match('(')) throw FormatException('Expected ( after $fn');
        final arg = parseExpression();
        if (!_match(')')) throw FormatException('Missing ) after $fn');
        return _evalFunction(fn, arg);
      }
    }

    // Number
    return parseNumber();
  }

  double parseNumber() {
    final start = pos;
    // Consume digits and decimal point
    while (pos < input.length &&
        (input[pos].codeUnitAt(0) >= 48 && input[pos].codeUnitAt(0) <= 57 ||
            input[pos] == '.')) {
      pos++;
    }
    if (pos == start) {
      throw FormatException(
        'Expected number at position $pos: '
        '"${input.substring(pos, (pos + 10).clamp(0, input.length))}"',
      );
    }
    // Handle scientific notation: e.g. 3e5, 1.5e-10, 2E+3
    if (pos < input.length && (input[pos] == 'e' || input[pos] == 'E')) {
      pos++;
      if (pos < input.length && (input[pos] == '+' || input[pos] == '-')) {
        pos++;
      }
      while (pos < input.length &&
          input[pos].codeUnitAt(0) >= 48 &&
          input[pos].codeUnitAt(0) <= 57) {
        pos++;
      }
    }
    return double.parse(input.substring(start, pos));
  }

  bool _match(String char) {
    if (pos < input.length && input[pos] == char) {
      pos++;
      return true;
    }
    return false;
  }

  bool _matchWord(String word) {
    if (pos + word.length <= input.length &&
        input.substring(pos, pos + word.length).toLowerCase() == word) {
      // Ensure it's not part of a longer word
      if (pos + word.length < input.length) {
        final next = input[pos + word.length];
        if (RegExp(r'[a-zA-Z_]').hasMatch(next)) return false;
      }
      pos += word.length;
      return true;
    }
    return false;
  }

  double _evalFunction(String name, double arg) {
    switch (name) {
      case 'sqrt':
        return math.sqrt(arg);
      case 'sin':
        return math.sin(arg);
      case 'cos':
        return math.cos(arg);
      case 'tan':
        return math.tan(arg);
      case 'log':
        return math.log(arg) / math.ln10;
      case 'ln':
        return math.log(arg);
      case 'abs':
        return arg.abs();
      case 'exp':
        return math.exp(arg);
      case 'ceil':
        return arg.ceilToDouble();
      case 'floor':
        return arg.floorToDouble();
      default:
        throw FormatException('Unknown function: $name');
    }
  }
}

/// Format a number: strip trailing .0 for integers.
String _formatNum(num value) {
  if (value is double &&
      value == value.roundToDouble() &&
      !value.isInfinite &&
      !value.isNaN) {
    if (value.abs() < 1e15) {
      return value.toInt().toString();
    }
  }
  return value.toString();
}

/// Safely convert dynamic to num.
num _toNum(dynamic v) {
  if (v is num) return v;
  return num.parse(v.toString());
}
