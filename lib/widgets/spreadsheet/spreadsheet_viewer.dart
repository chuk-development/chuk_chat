// Read-only preview of a spreadsheet attachment (.xlsx, .csv, .tsv; .xls
// says why it cannot be shown). The parse runs off the UI isolate with caps
// (lib/services/spreadsheet/spreadsheet_parser.dart). The first row of a
// sheet stays pinned while the body scrolls both ways; a banner lists what
// the preview leaves out (charts, images, conditional formatting, ...).
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart'
    show kRadiusLg, kRadiusMd, kRadiusPill;
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/spreadsheet/spreadsheet_parser.dart';
import 'package:chuk_chat/ui/components/components.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

typedef SpreadsheetParseFn = Future<SpreadsheetDocument> Function(
  Uint8List bytes,
  SpreadsheetFormat format,
);

class SpreadsheetViewer extends StatefulWidget {
  const SpreadsheetViewer({
    super.key,
    required this.fileName,
    required this.bytes,
    this.parser,
  }) : document = null;

  /// Shows an already-read [document], e.g. the tables of a sent
  /// attachment, of which only the Markdown is kept.
  SpreadsheetViewer.document({
    super.key,
    required this.fileName,
    required SpreadsheetDocument this.document,
  }) : bytes = Uint8List(0),
       parser = null;

  final String fileName;
  final Uint8List bytes;

  /// Set by [SpreadsheetViewer.document]: nothing is parsed.
  final SpreadsheetDocument? document;

  /// Replaces the isolate parse (tests).
  final SpreadsheetParseFn? parser;

  static const double columnWidth = 132;
  static const double rowHeight = 34;
  static const double gutterWidth = 52;

  /// True for the files this viewer opens.
  static bool handles(String fileName) =>
      SpreadsheetParser.isSpreadsheet(fileName);

  static Future<void> open(
    BuildContext context, {
    required String fileName,
    required Uint8List bytes,
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => SpreadsheetViewer(fileName: fileName, bytes: bytes),
      ),
    );
  }

  /// Opens the tables of a sent attachment's Markdown, for
  /// [sentDocument].
  static Future<void> openSent(
    BuildContext context, {
    required String fileName,
    required SpreadsheetDocument document,
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) =>
            SpreadsheetViewer.document(fileName: fileName, document: document),
      ),
    );
  }

  /// The sheets of a sent attachment, or null when the attachment is not a
  /// spreadsheet or its Markdown holds no table. A sent message keeps only
  /// the server's Markdown of the file, so the cells come from there.
  static SpreadsheetDocument? sentDocument(String fileName, String markdown) {
    if (!isSentSpreadsheetName(fileName)) return null;
    return SpreadsheetParser.fromMarkdownTables(markdown);
  }

  /// The file types the server turns into tables: the parser's formats plus
  /// the ones only the server reads (.xlsb, .ods).
  static bool isSentSpreadsheetName(String fileName) {
    if (SpreadsheetParser.isSpreadsheet(fileName)) return true;
    final String lower = fileName.toLowerCase();
    return lower.endsWith('.xlsb') || lower.endsWith('.ods');
  }

  @override
  State<SpreadsheetViewer> createState() => _SpreadsheetViewerState();
}

class _SpreadsheetViewerState extends State<SpreadsheetViewer> {
  SpreadsheetDocument? _doc;
  SpreadsheetErrorKind? _error;
  int _sheet = 0;
  final ScrollController _horizontal = ScrollController();
  final ScrollController _vertical = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.document case final SpreadsheetDocument ready) {
      _doc = ready;
      return;
    }
    final SpreadsheetFormat? format = SpreadsheetParser.formatFor(
      widget.fileName,
    );
    if (format == null) {
      setState(() => _error = SpreadsheetErrorKind.unsupportedFormat);
      return;
    }
    try {
      final SpreadsheetDocument doc =
          await (widget.parser ?? SpreadsheetParser.parse)(
            widget.bytes,
            format,
          );
      if (mounted) setState(() => _doc = doc);
    } on SpreadsheetParseException catch (e) {
      if (mounted) setState(() => _error = e.kind);
    } catch (_) {
      if (mounted) setState(() => _error = SpreadsheetErrorKind.invalid);
    }
  }

  @override
  void dispose() {
    _horizontal.dispose();
    _vertical.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExpressiveScreen(
      title: widget.fileName,
      builder: (BuildContext context) {
        final EdgeInsets pad = MediaQuery.paddingOf(context);
        return Padding(
          padding: EdgeInsets.only(top: pad.top, bottom: pad.bottom),
          child: _body(context),
        );
      },
    );
  }

  Widget _body(BuildContext context) {
    final AppLocalizations l10n =
        AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (_error case final SpreadsheetErrorKind error) {
      return _Message(
        icon: Icons.error_outline,
        text: switch (error) {
          SpreadsheetErrorKind.tooLarge => l10n.spreadsheetErrorTooLarge,
          SpreadsheetErrorKind.unsupportedFormat => l10n.spreadsheetErrorXls,
          SpreadsheetErrorKind.timeout => l10n.spreadsheetErrorTimeout,
          SpreadsheetErrorKind.invalid => l10n.spreadsheetErrorInvalid,
        },
      );
    }
    final SpreadsheetDocument? doc = _doc;
    if (doc == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CircularProgressIndicator(color: scheme.primary),
            const SizedBox(height: 12),
            Text(
              l10n.spreadsheetLoading,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    final List<String> notes = <String>[
      if (doc.unsupported.isNotEmpty)
        l10n.spreadsheetNotShown(
          SpreadsheetFeature.values
              .where(doc.unsupported.contains)
              .map((f) => _featureName(l10n, f))
              .join(', '),
        ),
      if (doc.truncated)
        l10n.spreadsheetTruncated(_groupThousands(SpreadsheetParser.maxCells)),
    ];
    final SpreadsheetSheet? sheet = doc.sheets.isEmpty
        ? null
        : doc.sheets[_sheet.clamp(0, doc.sheets.length - 1)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (notes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: _Banner(
              key: const ValueKey('spreadsheet-banner'),
              lines: notes,
            ),
          ),
        if (doc.sheets.length > 1)
          _SheetTabs(
            names: <String>[for (final s in doc.sheets) s.name],
            selected: _sheet,
            onSelect: (int i) {
              if (i == _sheet) return;
              setState(() => _sheet = i);
              if (_vertical.hasClients) _vertical.jumpTo(0);
              if (_horizontal.hasClients) _horizontal.jumpTo(0);
            },
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
          child: Text(
            sheet == null || sheet.rows.isEmpty
                ? l10n.spreadsheetReadOnly
                : '${l10n.spreadsheetReadOnly} · '
                      '${sheet.rows.length} × ${sheet.columnCount}',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
        ),
        Expanded(
          child: sheet == null || sheet.rows.isEmpty
              ? _Message(
                  icon: Icons.table_chart_outlined,
                  text: l10n.spreadsheetEmpty,
                )
              : _Grid(
                  key: ValueKey<int>(_sheet),
                  sheet: sheet,
                  horizontal: _horizontal,
                  vertical: _vertical,
                ),
        ),
      ],
    );
  }

  static String _featureName(AppLocalizations l10n, SpreadsheetFeature f) =>
      switch (f) {
        SpreadsheetFeature.charts => l10n.spreadsheetFeatureCharts,
        SpreadsheetFeature.images => l10n.spreadsheetFeatureImages,
        SpreadsheetFeature.conditionalFormatting =>
          l10n.spreadsheetFeatureConditionalFormatting,
        SpreadsheetFeature.pivotTables => l10n.spreadsheetFeaturePivotTables,
        SpreadsheetFeature.macros => l10n.spreadsheetFeatureMacros,
      };

  static String _groupThousands(int n) {
    final String s = n.toString();
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) out.write(' ');
      out.write(s[i]);
    }
    return out.toString();
  }
}

/// The cells. The first row is the header: it sits outside the vertical
/// list, so it stays in place while the body scrolls, and inside the same
/// horizontal scroll, so its columns stay over theirs.
class _Grid extends StatelessWidget {
  const _Grid({
    super.key,
    required this.sheet,
    required this.horizontal,
    required this.vertical,
  });

  final SpreadsheetSheet sheet;
  final ScrollController horizontal;
  final ScrollController vertical;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final double width =
        SpreadsheetViewer.gutterWidth +
        sheet.columnCount * SpreadsheetViewer.columnWidth;
    final List<String> header = sheet.rows.first;
    final int bodyRows = sheet.rows.length - 1;
    return Scrollbar(
      controller: horizontal,
      notificationPredicate: (n) => n.depth == 0,
      child: SingleChildScrollView(
        controller: horizontal,
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Container(
                key: const ValueKey('spreadsheet-header'),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  border: Border(
                    bottom: BorderSide(color: scheme.outlineVariant),
                  ),
                ),
                child: _Row(index: 1, cells: header, header: true),
              ),
              Expanded(
                child: Scrollbar(
                  controller: vertical,
                  child: ListView.builder(
                    controller: vertical,
                    itemExtent: SpreadsheetViewer.rowHeight,
                    itemCount: bodyRows,
                    itemBuilder: (BuildContext context, int i) =>
                        _Row(index: i + 2, cells: sheet.rows[i + 1]),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.index, required this.cells, this.header = false});

  final int index;
  final List<String> cells;
  final bool header;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final BorderSide line = BorderSide(
      color: scheme.outlineVariant.withValues(alpha: 0.6),
      width: 0.5,
    );
    final TextStyle style = TextStyle(
      color: scheme.onSurface,
      fontSize: 13,
      fontWeight: header ? FontWeight.w600 : FontWeight.w400,
    );
    return SizedBox(
      height: SpreadsheetViewer.rowHeight,
      child: Row(
        children: <Widget>[
          Container(
            width: SpreadsheetViewer.gutterWidth,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              border: Border(right: line, bottom: line),
            ),
            child: Text(
              '$index',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 11,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
          for (final String cell in cells)
            Container(
              width: SpreadsheetViewer.columnWidth,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                border: Border(right: line, bottom: line),
              ),
              child: Text(
                cell,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
        ],
      ),
    );
  }
}

class _SheetTabs extends StatelessWidget {
  const _SheetTabs({
    required this.names,
    required this.selected,
    required this.onSelect,
  });

  final List<String> names;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        itemCount: names.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (BuildContext context, int i) {
          final bool on = i == selected;
          return Semantics(
            selected: on,
            button: true,
            child: Material(
              color: on ? scheme.primary : scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(kRadiusPill),
              child: InkWell(
                key: ValueKey<String>('spreadsheet-tab-$i'),
                borderRadius: BorderRadius.circular(kRadiusPill),
                onTap: () => onSelect(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Center(
                    child: Text(
                      names[i],
                      style: TextStyle(
                        color: on ? scheme.onPrimary : scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(kRadiusMd),
        border: Border.all(color: scheme.outlineVariant, width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            height: 20,
            child: Center(
              child: AppIcon(
                Icons.info_outline,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final String line in lines)
                  Text(
                    line,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 13,
                      height: 20 / 13,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(kRadiusLg),
              ),
              alignment: Alignment.center,
              child: AppIcon(icon, size: 28, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
