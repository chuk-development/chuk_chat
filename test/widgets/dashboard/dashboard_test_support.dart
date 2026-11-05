// Shared harness for the Home tests: a controller on fakes, a realistic
// dashboard, and one call that pumps the page on a phone column.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/dashboard/dashboard_controller.dart';
import 'package:chuk_chat/services/dashboard/dashboard_model.dart';
import 'package:chuk_chat/widgets/dashboard/dashboard_page.dart';

import '../charts/chart_test_support.dart';

export '../charts/chart_test_support.dart' show loadChartFonts;

/// Monday evening, 2 November 2026, 19:30 local.
final DateTime kDashNow = DateTime(2026, 11, 2, 19, 30);

String _at(DateTime t) => isoWithOffset(t);

/// What a fake host has been sent.
class FakeDashboardHost {
  FakeDashboardHost({bool attached = true})
    : host = ValueNotifier<String?>(attached ? 'host1' : null);

  final ValueNotifier<String?> host;
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  final Map<String, String> kv = <String, String>{};

  late final DashboardController controller = DashboardController(
    send: (Map<String, dynamic> f) async => sent.add(f),
    attachedHost: host,
    userId: () => 'user1',
    readKv: (String k) async => kv[k],
    writeKv: (String k, String v) async => kv[k] = v,
    clock: () => kDashNow,
  );

  List<Map<String, dynamic>> get ops => <Map<String, dynamic>>[
    for (final Map<String, dynamic> f in sent)
      if (f['type'] == 'dashboard_op') f,
  ];

  void show(List<Map<String, dynamic>> widgets, {int version = 7}) {
    controller.init();
    controller.handleFrame(<String, dynamic>{
      'type': 'dashboard_state',
      'dashboard': <String, dynamic>{'version': version, 'widgets': widgets},
    });
  }
}

Map<String, dynamic> pushupsWidget() => <String, dynamic>{
  'id': 'pushups',
  'type': 'tracker',
  'title': 'Push-ups',
  'size': 'half',
  'by': 'Chuk',
  'updated_at': _at(kDashNow.subtract(const Duration(minutes: 12))),
  'unit': 'reps',
  'goal': 100,
  'period': 'day',
  'steps': <int>[1, 10, 25],
  'icon': 'dumbbell',
  'entries': <Map<String, dynamic>>[
    for (int d = 1; d <= 6; d++)
      <String, dynamic>{
        'at': _at(DateTime(2026, 11, 2 - d, 8)),
        'value': d == 4 ? 60 : 100 + (d % 3) * 10,
      },
    <String, dynamic>{'at': _at(DateTime(2026, 11, 2, 8, 10)), 'value': 30},
    <String, dynamic>{'at': _at(DateTime(2026, 11, 2, 18, 40)), 'value': 25},
  ],
};

Map<String, dynamic> waterWidget() => <String, dynamic>{
  'id': 'water',
  'type': 'tracker',
  'title': 'Water',
  'size': 'half',
  'by': 'Chuk',
  'updated_at': _at(kDashNow.subtract(const Duration(hours: 2))),
  'unit': 'ml',
  'goal': 2000,
  'steps': <int>[250, 500],
  'icon': 'water',
  'entries': <Map<String, dynamic>>[
    <String, dynamic>{'at': _at(DateTime(2026, 11, 1, 9)), 'value': 2000},
    <String, dynamic>{'at': _at(DateTime(2026, 11, 2, 9)), 'value': 1500},
    <String, dynamic>{'at': _at(DateTime(2026, 11, 2, 15)), 'value': 500},
  ],
};

Map<String, dynamic> metricWidget() => <String, dynamic>{
  'id': 'weight',
  'type': 'metric',
  'title': 'Weight',
  'by': 'Coach',
  'updated_at': _at(DateTime(2026, 11, 2, 7, 5)),
  'value': 78.4,
  'unit': 'kg',
  'delta': '-0.6 kg',
  'tone': 'good',
  'trend': <double>[80.1, 79.8, 79.9, 79.4, 79.2, 79.0, 78.9, 78.4],
};

Map<String, dynamic> revenueWidget() => <String, dynamic>{
  'id': 'mrr',
  'type': 'metric',
  'title': 'MRR',
  'by': 'Finance',
  'updated_at': _at(DateTime(2026, 11, 1, 22)),
  'value': '€4,280',
  'delta': '+4 %',
  'tone': 'neutral',
  'trend': <double>[3600, 3700, 3650, 3900, 4010, 4120, 4280],
  'caption': 'Stripe, last 7 days',
};

Map<String, dynamic> checklistWidget() => <String, dynamic>{
  'id': 'groceries',
  'type': 'checklist',
  'title': 'Groceries',
  'by': 'Chuk',
  'updated_at': _at(DateTime(2026, 11, 2, 17)),
  'items': <Map<String, dynamic>>[
    <String, dynamic>{'id': 'milk', 'text': 'Oat milk', 'done': true},
    <String, dynamic>{'id': 'eggs', 'text': 'Eggs, 10', 'done': false},
    <String, dynamic>{'id': 'bread', 'text': 'Sourdough bread', 'done': false},
  ],
};

Map<String, dynamic> agendaWidget() => <String, dynamic>{
  'id': 'today',
  'type': 'agenda',
  'title': 'Today',
  'by': 'Calendar',
  'updated_at': _at(DateTime(2026, 11, 2, 6)),
  'date': '2026-11-02',
  'items': <Map<String, dynamic>>[
    <String, dynamic>{'time': '09:30', 'title': 'Standup', 'place': 'Zoom'},
    <String, dynamic>{
      'time': '14:00',
      'title': 'Dentist',
      'place': 'Holtenauer Str. 12',
    },
    <String, dynamic>{'time': '20:00', 'title': 'Call with Mia'},
  ],
};

Map<String, dynamic> weatherWidget() => <String, dynamic>{
  'id': 'kiel',
  'type': 'weather',
  'title': 'Kiel',
  'size': 'full',
  'by': 'Chuk',
  'updated_at': _at(DateTime(2026, 11, 2, 7)),
  'place': 'Kiel',
  'unit': 'C',
  'current': <String, dynamic>{
    'temp': 8,
    'condition': 'Partly cloudy',
    'code': 2,
  },
  'daily': <Map<String, dynamic>>[
    for (int i = 0; i < 7; i++)
      <String, dynamic>{
        'date': '2026-11-0${2 + i}',
        'code': <int>[2, 61, 3, 0, 80, 3, 2][i],
        'max': 9 + i % 3,
        'min': 3 + i % 2,
      },
  ],
};

Map<String, dynamic> promptsWidget() => <String, dynamic>{
  'id': 'ask',
  'type': 'prompts',
  'title': 'Quick asks',
  'by': 'Chuk',
  'updated_at': _at(DateTime(2026, 10, 30, 10)),
  'items': <Map<String, dynamic>>[
    <String, dynamic>{'label': 'Plan my evening', 'prompt': 'Plan my evening.'},
    <String, dynamic>{
      'label': 'Summarise my mail',
      'prompt': 'Summarise my unread mail.',
    },
    <String, dynamic>{'label': 'Log a run', 'prompt': 'Log a 5 km run.'},
  ],
};

Map<String, dynamic> noteWidget() => <String, dynamic>{
  'id': 'focus',
  'type': 'note',
  'title': 'This week',
  'by': 'Chuk',
  'updated_at': _at(DateTime(2026, 11, 2, 8)),
  'text': '**Ship the dashboard.** Then:\n\n- reply to Jonas\n- book the train to Hamburg',
};

Map<String, dynamic> chartWidget() => <String, dynamic>{
  'id': 'sleep',
  'type': 'chart',
  'title': 'Sleep',
  'by': 'Coach',
  'updated_at': _at(DateTime(2026, 11, 2, 7)),
  'spec': <String, dynamic>{
    'kind': 'bar',
    'unit': 'h',
    'decimals': 1,
    'reference_line': <String, dynamic>{'value': 7.5, 'label': 'Goal'},
    'points': <Map<String, dynamic>>[
      for (final (String d, double v) in <(String, double)>[
        ('Tu', 6.8),
        ('We', 7.4),
        ('Th', 8.1),
        ('Fr', 6.2),
        ('Sa', 8.6),
        ('Su', 7.9),
        ('Mo', 7.1),
      ])
        <String, dynamic>{'label': d, 'value': v},
    ],
  },
};

List<Map<String, dynamic>> realisticDashboard() => <Map<String, dynamic>>[
  pushupsWidget(),
  waterWidget(),
  agendaWidget(),
  metricWidget(),
  revenueWidget(),
  checklistWidget(),
  weatherWidget(),
  promptsWidget(),
];

/// Pumps [DashboardPage] on a phone column (or [width]) and settles.
Future<void> pumpDashboard(
  WidgetTester tester,
  FakeDashboardHost host, {
  double width = 360,
  double height = 2000,
  Brightness brightness = Brightness.light,
  double textScale = 1,
  Key shotKey = const ValueKey<String>('dash-shot'),
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final ThemeData theme = chartTheme(brightness);
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: Size(width, height),
        padding: const EdgeInsets.only(top: 24),
        textScaler: TextScaler.linear(textScale),
        disableAnimations: true,
      ),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: Scaffold(
          backgroundColor: theme.colorScheme.surface,
          body: RepaintBoundary(
            key: shotKey,
            child: ColoredBox(
              color: theme.colorScheme.surface,
              child: DashboardPage(
                controller: host.controller,
                clock: () => kDashNow,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
