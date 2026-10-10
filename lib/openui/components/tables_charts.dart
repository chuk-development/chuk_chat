// OpenUI components, group B2: tables and charts.
//
// Owner: agent B2. Add each component as one OpenUiComponentDef to
// [tablesChartsComponents]. Do not edit the registry
// (lib/openui/openui_library.dart). Rules: docs/OPENUI.md.
//
// Components of this file (upstream chat library):
//   Table                  (data_table.dart)
//   Col                    (data-only: Table reads it)
//   EditableTable          (editable_table.dart)
//   BarChart               (cartesian_charts.dart)
//   LineChart
//   AreaChart
//   RadarChart             (round_charts.dart)
//   HorizontalBarChart     (cartesian_charts.dart)
//   Series                 (data-only: the 2D charts read it)
//   PieChart               (round_charts.dart)
//   RadialChart
//   SingleStackedBarChart
//   Slice                  (data-only: legacy 1D form)
//   ScatterChart           (scatter_chart.dart)
//   ScatterSeries          (data-only: ScatterChart reads it)
//   Point                  (data-only: ScatterSeries reads it)
//
// Design: every chart and table sits on the inner card surface of the
// OpenUI family (OpenUiTheme.cardDecoration). Series colours: the
// user's accent first, then the app chart palette (ChartPalette). Axis
// text and number format follow the app's `<chart>` renderer. No
// reader throws on bad, empty, mismatched or streaming data; a chart
// draws what is valid (helpers in tables_charts/chart_common.dart).
//
// The exact signatures are in
// test/openui/fixtures/upstream/components-chat.json.

import 'package:chuk_chat/openui/components/tables_charts/cartesian_charts.dart';
import 'package:chuk_chat/openui/components/tables_charts/data_table.dart';
import 'package:chuk_chat/openui/components/tables_charts/editable_table.dart';
import 'package:chuk_chat/openui/components/tables_charts/round_charts.dart';
import 'package:chuk_chat/openui/components/tables_charts/scatter_chart.dart';
import 'package:chuk_chat/openui/openui_component.dart';

const String _tables = 'Tables';
const String _charts2d = 'Charts (2D)';
const String _charts1d = 'Charts (1D)';
const String _scatter = 'Charts (Scatter)';

const List<OpenUiParam> _params2d = <OpenUiParam>[
  OpenUiParam('labels', 'string[]'),
  OpenUiParam('series', 'Series[]'),
];

const List<OpenUiParam> _params1d = <OpenUiParam>[
  OpenUiParam('labels', 'string[]'),
  OpenUiParam('values', 'number[]'),
];

/// The B2 components: tables and charts.
final List<OpenUiComponentDef> tablesChartsComponents = <OpenUiComponentDef>[
  // -------------------------------------------------------------- Tables
  const OpenUiComponentDef(
    name: 'Table',
    group: _tables,
    description:
        'Data table — column-oriented. Each Col holds its own data array.',
    params: <OpenUiParam>[OpenUiParam('columns', 'Col[]')],
    builder: buildTable,
  ),
  const OpenUiComponentDef.data(
    name: 'Col',
    group: _tables,
    description: 'Column definition — holds label + data array',
    params: <OpenUiParam>[
      OpenUiParam('label', 'string'),
      OpenUiParam('data', 'any'),
      OpenUiParam.opt('type', '"string" | "number" | "action"'),
    ],
  ),
  const OpenUiComponentDef(
    name: 'EditableTable',
    group: _tables,
    description:
        'Spreadsheet-like table whose cells the user can edit inline '
        '(text, number, url, date, select columns); edits are saved back '
        'as a form field',
    params: <OpenUiParam>[
      OpenUiParam.opt('name', 'string'),
      OpenUiParam.opt(
        'columns',
        '{type: "text" | "number" | "date-single" | "select" | "url", '
            'key?: string, header?: string, width?: number, '
            'options?: {value: string, label: string}[]}[]',
      ),
      OpenUiParam.opt('data', '{id: string, values: (string | number)[]}[]'),
    ],
    builder: buildEditableTable,
  ),

  // ---------------------------------------------------------- Charts (2D)
  const OpenUiComponentDef(
    name: 'BarChart',
    group: _charts2d,
    description:
        'Vertical bars; use for comparing values across categories with '
        'one or more series',
    params: <OpenUiParam>[
      ..._params2d,
      OpenUiParam.opt('variant', '"grouped" | "stacked"'),
      OpenUiParam.opt('xLabel', 'string'),
      OpenUiParam.opt('yLabel', 'string'),
      OpenUiParam.opt('height', 'number'),
    ],
    builder: buildBarChart,
  ),
  const OpenUiComponentDef(
    name: 'LineChart',
    group: _charts2d,
    description:
        'Lines over categories; use for trends and continuous data over time',
    params: <OpenUiParam>[
      ..._params2d,
      OpenUiParam.opt('variant', '"linear" | "natural" | "step"'),
      OpenUiParam.opt('xLabel', 'string'),
      OpenUiParam.opt('yLabel', 'string'),
      OpenUiParam.opt('height', 'number'),
    ],
    builder: buildLineChart,
  ),
  const OpenUiComponentDef(
    name: 'AreaChart',
    group: _charts2d,
    description:
        'Filled area under lines; use for cumulative totals or volume '
        'trends over time',
    params: <OpenUiParam>[
      ..._params2d,
      OpenUiParam.opt('variant', '"linear" | "natural" | "step"'),
      OpenUiParam.opt('xLabel', 'string'),
      OpenUiParam.opt('yLabel', 'string'),
      OpenUiParam.opt('height', 'number'),
    ],
    builder: buildAreaChart,
  ),
  const OpenUiComponentDef(
    name: 'RadarChart',
    group: _charts2d,
    description:
        'Spider/web chart; use for comparing multiple variables across one '
        'or more entities',
    params: _params2d,
    builder: buildRadarChart,
  ),
  const OpenUiComponentDef(
    name: 'HorizontalBarChart',
    group: _charts2d,
    description:
        'Horizontal bars; prefer when category labels are long or for '
        'ranked lists',
    params: <OpenUiParam>[
      ..._params2d,
      OpenUiParam.opt('variant', '"grouped" | "stacked"'),
      OpenUiParam.opt('xLabel', 'string'),
      OpenUiParam.opt('yLabel', 'string'),
    ],
    builder: buildHorizontalBarChart,
  ),
  const OpenUiComponentDef.data(
    name: 'Series',
    group: _charts2d,
    description: 'One data series',
    params: <OpenUiParam>[
      OpenUiParam('category', 'string'),
      OpenUiParam('values', 'number[]'),
    ],
  ),

  // ---------------------------------------------------------- Charts (1D)
  const OpenUiComponentDef(
    name: 'PieChart',
    group: _charts1d,
    description:
        'Circular slices; use plucked arrays: '
        'PieChart(data.categories, data.values)',
    params: <OpenUiParam>[
      ..._params1d,
      OpenUiParam.opt('variant', '"pie" | "donut"'),
      OpenUiParam.opt('appearance', '"circular" | "semiCircular"'),
    ],
    builder: buildPieChart,
  ),
  const OpenUiComponentDef(
    name: 'RadialChart',
    group: _charts1d,
    description:
        'Radial bars; use plucked arrays: '
        'RadialChart(data.categories, data.values)',
    params: _params1d,
    builder: buildRadialChart,
  ),
  const OpenUiComponentDef(
    name: 'SingleStackedBarChart',
    group: _charts1d,
    description:
        'Single horizontal stacked bar; use plucked arrays: '
        'SingleStackedBarChart(data.categories, data.values)',
    params: _params1d,
    builder: buildSingleStackedBarChart,
  ),
  const OpenUiComponentDef.data(
    name: 'Slice',
    group: _charts1d,
    description: 'One slice with label and numeric value',
    params: <OpenUiParam>[
      OpenUiParam('category', 'string'),
      OpenUiParam('value', 'number'),
    ],
  ),

  // ----------------------------------------------------- Charts (Scatter)
  const OpenUiComponentDef(
    name: 'ScatterChart',
    group: _scatter,
    description:
        'X/Y scatter plot; use for correlations, distributions, and '
        'clustering',
    params: <OpenUiParam>[
      OpenUiParam('datasets', 'ScatterSeries[]'),
      OpenUiParam.opt('xLabel', 'string'),
      OpenUiParam.opt('yLabel', 'string'),
    ],
    builder: buildScatterChart,
  ),
  const OpenUiComponentDef.data(
    name: 'ScatterSeries',
    group: _scatter,
    description: 'Named dataset',
    params: <OpenUiParam>[
      OpenUiParam('name', 'string'),
      OpenUiParam('points', 'Point[]'),
    ],
  ),
  const OpenUiComponentDef.data(
    name: 'Point',
    group: _scatter,
    description: 'Data point with numeric coordinates',
    params: <OpenUiParam>[
      OpenUiParam('x', 'number'),
      OpenUiParam('y', 'number'),
      OpenUiParam.opt('z', 'number'),
    ],
  ),
];
