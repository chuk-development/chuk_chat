// Every canonical upstream example program (test/openui/fixtures/*.oui)
// must parse with zero syntax errors, render without an exception and
// call only registered components.
// ignore_for_file: experimental_member_use, avoid_print

import 'package:flutter_test/flutter_test.dart';
import 'package:openui_core/openui_core.dart';

import 'package:chuk_chat/openui/openui.dart';

import 'openui_test_helper.dart';

/// The component names a program calls (not `Action` and `Query`).
Set<String> componentNames(String source) {
  final out = <String>{};
  void walk(AstNode node) {
    switch (node) {
      case CompCall(:final type, :final args):
        if (type != 'Action' && type != 'Query') out.add(type);
        for (final a in args) {
          walk(a.value);
        }
      case BuiltinCall(:final args):
      case MutationCall(:final args):
        for (final a in args) {
          walk(a.value);
        }
      case ArrayLit(:final elements):
        elements.forEach(walk);
      case ObjectLit(:final entries):
        for (final e in entries) {
          walk(e.value);
        }
      case BinaryOp(:final left, :final right):
        walk(left);
        walk(right);
      case UnaryOp(:final operand):
        walk(operand);
      case Ternary(:final condition, :final then, :final otherwise):
        walk(condition);
        walk(then);
        walk(otherwise);
      case MemberAccess(:final target):
        walk(target);
      case IndexAccess(:final target, :final index):
        walk(target);
        walk(index);
      case StateAssign(:final value):
        walk(value);
      case Literal():
      case NullLiteral():
      case Reference():
      case StateRef():
        break;
    }
  }

  for (final s in createStreamingParser().set(source).statements) {
    walk(s.expression);
  }
  return out;
}

/// Unknown component names per fixture.
Map<String, List<String>> unknownComponents() {
  return <String, List<String>>{
    for (final e in readOpenUiFixtures().entries)
      e.key: (componentNames(
        e.value,
      ).where((n) => !chukOpenUiLibrary.contains(n)).toList()..sort()),
  };
}

void main() {
  final fixtures = readOpenUiFixtures();

  test('the fixture set is present', () {
    expect(fixtures.length, greaterThanOrEqualTo(14));
  });

  for (final entry in fixtures.entries) {
    test('${entry.key} parses with zero syntax errors', () {
      final result = createStreamingParser().set(entry.value);
      expect(
        result.meta.errors.map((e) => e.message),
        isEmpty,
        reason: entry.key,
      );
      expect(result.root, isNotNull, reason: '${entry.key} has a root');
    });

    testWidgets('${entry.key} renders without an exception', (tester) async {
      await pumpOpenUi(tester, entry.value);
      expect(tester.takeException(), isNull);
    });
  }

  test('report: unknown component names per fixture', () {
    final unknown = unknownComponents();
    final all = <String>{for (final l in unknown.values) ...l};
    print('OpenUI unknown components (${all.length}): ${all.toList()..sort()}');
    for (final e in unknown.entries) {
      if (e.value.isNotEmpty) print('  ${e.key}: ${e.value.join(', ')}');
    }
  });

  test('all fixtures render with no unknown component', () {
    final unknown = unknownComponents()
      ..removeWhere((_, names) => names.isEmpty);
    expect(unknown, isEmpty);
  });
}
