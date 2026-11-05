import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/dashboard/dashboard_model.dart';

String at(DateTime t) => isoWithOffset(t);

Map<String, dynamic> tracker({
  String period = 'day',
  double goal = 100,
  List<Map<String, dynamic>> entries = const <Map<String, dynamic>>[],
}) => <String, dynamic>{
  'id': 'pushups',
  'type': 'tracker',
  'title': 'Push-ups',
  'unit': 'reps',
  'goal': goal,
  'period': period,
  'entries': entries,
};

TrackerWidget parseTracker(Map<String, dynamic> json) =>
    DashboardWidget.tryParse(json)! as TrackerWidget;

void main() {
  group('parse', () {
    test('never throws and skips what it cannot draw', () {
      expect(DashboardDocument.fromJson(null).isEmpty, isTrue);
      expect(DashboardDocument.fromJson('x').isEmpty, isTrue);
      final DashboardDocument doc = DashboardDocument.fromJson(
        <String, dynamic>{
          'version': 7,
          'widgets': <Object?>[
            'junk',
            <String, dynamic>{'id': 'a', 'type': 'hologram', 'title': 'x'},
            <String, dynamic>{'id': 'BAD ID', 'type': 'note', 'title': 'x'},
            <String, dynamic>{'id': 'n', 'type': 'note', 'title': 5, 'text': 3},
            <String, dynamic>{'id': 'n', 'type': 'note', 'title': 'dup'},
            tracker(goal: -3)..['steps'] = <Object?>['x', -1, 5, 6, 7, 8],
          ],
        },
      );
      expect(doc.version, 7);
      expect(doc.widgets.map((DashboardWidget w) => w.id), <String>[
        'n',
        'pushups',
      ]);
      final NoteWidget note = doc.widgets.first as NoteWidget;
      expect(note.title, '5');
      expect(note.size, DashboardSize.full);
      final TrackerWidget t = doc.widgets.last as TrackerWidget;
      expect(t.goal, 1);
      expect(t.steps, <double>[5, 6, 7]);
      expect(t.icon, TrackerIcon.check);
      expect(t.size, DashboardSize.half);
    });

    test('all eight types parse', () {
      final DashboardDocument doc = DashboardDocument.fromJson(
        <String, dynamic>{
          'widgets': <Object?>[
            tracker(),
            <String, dynamic>{
              'id': 'm',
              'type': 'metric',
              'value': 72.50,
              'tone': 'good',
              'trend': <Object?>[1, 'x', 2],
            },
            <String, dynamic>{
              'id': 'c',
              'type': 'checklist',
              'items': <Object?>[
                <String, dynamic>{'id': 'i', 'text': 'Milk', 'done': true},
                <String, dynamic>{'text': 'no id'},
              ],
            },
            <String, dynamic>{'id': 'n', 'type': 'note', 'text': '**hi**'},
            <String, dynamic>{
              'id': 'ch',
              'type': 'chart',
              'spec': <String, dynamic>{'kind': 'bar'},
            },
            <String, dynamic>{
              'id': 'ag',
              'type': 'agenda',
              'date': '2026-11-02',
              'items': <Object?>[
                <String, dynamic>{'time': '09:30', 'title': 'Standup'},
              ],
            },
            <String, dynamic>{
              'id': 'p',
              'type': 'prompts',
              'items': <Object?>[
                <String, dynamic>{'label': 'Plan', 'prompt': 'Plan my day'},
              ],
            },
            <String, dynamic>{
              'id': 'w',
              'type': 'weather',
              'place': 'Kiel',
              'current': <String, dynamic>{'temp': 8, 'code': 3},
              'daily': <Object?>[],
            },
          ],
        },
      );
      expect(doc.widgets.length, 8);
      final MetricWidget m = doc.widgets[1] as MetricWidget;
      expect(m.value, '72.5');
      expect(m.trend, <double>[1, 2]);
      expect(m.tone, MetricTone.good);
      expect((doc.widgets[2] as ChecklistWidget).items.length, 1);
      expect((doc.widgets[5] as AgendaWidget).items.single.minutes, 570);
      expect((doc.widgets[7] as WeatherWidget).unit, 'C');
    });

    test('round-trips through toJson', () {
      final Map<String, dynamic> json = <String, dynamic>{
        'version': 3,
        'widgets': <Object?>[tracker()..['extra'] = 1],
      };
      final DashboardDocument doc = DashboardDocument.fromJson(json);
      expect(
        DashboardDocument.fromJson(doc.toJson()).widgets.single.raw['extra'],
        1,
      );
    });
  });

  group('tracker maths', () {
    final DateTime now = DateTime(2026, 11, 4, 20); // a Wednesday

    test('today sums the local day only', () {
      final TrackerWidget t = parseTracker(
        tracker(
          entries: <Map<String, dynamic>>[
            <String, dynamic>{
              'at': at(DateTime(2026, 11, 4, 0, 5)),
              'value': 30,
            },
            <String, dynamic>{
              'at': at(DateTime(2026, 11, 4, 23, 50)),
              'value': 10,
            },
            <String, dynamic>{
              'at': at(DateTime(2026, 11, 3, 23, 59)),
              'value': 99,
            },
            <String, dynamic>{'at': at(DateTime(2026, 11, 4, 12)), 'value': -5},
          ],
        ),
      );
      expect(t.current(now), 35);
    });

    test('week is the ISO week, Monday first', () {
      final TrackerWidget t = parseTracker(
        tracker(
          period: 'week',
          entries: <Map<String, dynamic>>[
            <String, dynamic>{
              'at': at(DateTime(2026, 11, 2, 1)),
              'value': 10,
            }, // Monday
            <String, dynamic>{
              'at': at(DateTime(2026, 11, 8, 23)),
              'value': 10,
            }, // Sunday
            <String, dynamic>{
              'at': at(DateTime(2026, 11, 1, 23)),
              'value': 50,
            }, // last Sunday
          ],
        ),
      );
      expect(t.current(now), 20);
      expect(t.periodStart(now), DateTime(2026, 11, 2));
    });

    test('streak ends yesterday, or today when today reached the goal', () {
      List<Map<String, dynamic>> days(List<int> back) => <Map<String, dynamic>>[
        for (final int d in back)
          <String, dynamic>{
            'at': at(DateTime(2026, 11, 4 - d, 9)),
            'value': 100,
          },
      ];
      expect(
        (DashboardWidget.tryParse(tracker(entries: days(<int>[1, 2, 3])))!
                as TrackerWidget)
            .streak(now),
        3,
      );
      expect(
        (DashboardWidget.tryParse(tracker(entries: days(<int>[0, 1, 2, 3])))!
                as TrackerWidget)
            .streak(now),
        4,
      );
      expect(
        (DashboardWidget.tryParse(tracker(entries: days(<int>[2, 3])))!
                as TrackerWidget)
            .streak(now),
        0,
      );
      expect(
        (DashboardWidget.tryParse(tracker(entries: days(<int>[0])))!
                as TrackerWidget)
            .streak(now),
        1,
      );
    });

    test('recent is the last seven periods, oldest first', () {
      final TrackerWidget t = parseTracker(
        tracker(
          entries: <Map<String, dynamic>>[
            <String, dynamic>{'at': at(DateTime(2026, 11, 4, 9)), 'value': 4},
            <String, dynamic>{'at': at(DateTime(2026, 10, 29, 9)), 'value': 1},
          ],
        ),
      );
      expect(t.recent(now), <double>[1, 0, 0, 0, 0, 0, 4]);
    });

    test('undoable skips entries a correction cancelled', () {
      final TrackerWidget t = parseTracker(
        tracker(
          entries: <Map<String, dynamic>>[
            <String, dynamic>{'at': at(DateTime(2026, 11, 4, 9)), 'value': 10},
            <String, dynamic>{'at': at(DateTime(2026, 11, 4, 10)), 'value': 25},
            <String, dynamic>{
              'at': at(DateTime(2026, 11, 4, 11)),
              'value': -25,
            },
          ],
        ),
      );
      expect(t.undoable?.value, 10);
    });
  });

  group('applyDashboardOp', () {
    final DateTime now = DateTime(2026, 11, 4, 20);
    final DashboardDocument doc = DashboardDocument.fromJson(<String, dynamic>{
      'version': 1,
      'widgets': <Object?>[
        tracker(),
        <String, dynamic>{
          'id': 'c',
          'type': 'checklist',
          'items': <Object?>[
            <String, dynamic>{'id': 'i', 'text': 'Milk', 'done': false},
          ],
        },
        <String, dynamic>{'id': 'n', 'type': 'note', 'text': 'x'},
      ],
    });

    test('log adds an entry by You', () {
      final DashboardDocument out = applyDashboardOp(doc, <String, dynamic>{
        'action': 'log',
        'id': 'pushups',
        'value': 10,
      }, now);
      final TrackerWidget t = out.byId('pushups')! as TrackerWidget;
      expect(t.current(now), 10);
      expect(t.by, 'You');
    });

    test('check, move, remove, update', () {
      DashboardDocument out = applyDashboardOp(doc, <String, dynamic>{
        'action': 'check',
        'id': 'c',
        'item': 'i',
        'done': true,
      }, now);
      expect((out.byId('c')! as ChecklistWidget).items.single.done, isTrue);
      out = applyDashboardOp(out, <String, dynamic>{
        'action': 'move',
        'id': 'n',
        'index': 0,
      }, now);
      expect(out.widgets.first.id, 'n');
      out = applyDashboardOp(out, <String, dynamic>{
        'action': 'update',
        'id': 'n',
        'patch': <String, dynamic>{'size': 'half', 'type': 'metric'},
      }, now);
      expect(out.byId('n')!.size, DashboardSize.half);
      expect(out.byId('n')!.type, DashboardWidgetType.note);
      out = applyDashboardOp(out, <String, dynamic>{
        'action': 'remove',
        'id': 'c',
      }, now);
      expect(out.byId('c'), isNull);
    });

    test('an op that does not fit changes nothing', () {
      expect(
        applyDashboardOp(doc, <String, dynamic>{
          'action': 'log',
          'id': 'n',
          'value': 1,
        }, now),
        same(doc),
      );
      expect(
        applyDashboardOp(doc, <String, dynamic>{
          'action': 'log',
          'id': 'zz',
          'value': 1,
        }, now),
        same(doc),
      );
    });
  });

  test('isoWithOffset carries an offset', () {
    expect(
      isoWithOffset(DateTime(2026, 11, 2, 21, 40)),
      matches(RegExp(r'^2026-11-02T21:40:00[+-]\d\d:\d\d$')),
    );
  });
}
