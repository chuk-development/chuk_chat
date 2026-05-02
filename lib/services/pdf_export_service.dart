// lib/services/pdf_export_service.dart
import 'package:flutter/foundation.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// Renders an assistant markdown response as a PDF and triggers the
/// platform's native share/save flow via the `printing` package.
class PdfExportService {
  static const PdfPageFormat _pageFormat = PdfPageFormat.a4;

  /// Build the PDF and hand it to the share sheet (web triggers a download).
  /// Returns true on success, false on failure.
  static Future<bool> exportMarkdownAndShare(
    String markdownText, {
    String? title,
  }) async {
    if (markdownText.trim().isEmpty) return false;
    try {
      final Uint8List bytes = await buildPdfBytes(markdownText, title: title);
      final String filename = _safeFilename(title);
      await Printing.sharePdf(bytes: bytes, filename: filename);
      return true;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('PdfExportService.exportMarkdownAndShare failed: $e\n$st');
      }
      return false;
    }
  }

  /// Build the PDF and open the native print dialog (Linux/macOS/Windows
  /// system print, Android/iOS print sheet, web browser print). Returns
  /// true if the dialog was shown.
  static Future<bool> printMarkdown(
    String markdownText, {
    String? title,
  }) async {
    if (markdownText.trim().isEmpty) return false;
    try {
      final Uint8List bytes = await buildPdfBytes(markdownText, title: title);
      return await Printing.layoutPdf(
        onLayout: (PdfPageFormat _) async => bytes,
        name: _safeFilename(title),
      );
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('PdfExportService.printMarkdown failed: $e\n$st');
      }
      return false;
    }
  }

  static Future<Uint8List> buildPdfBytes(
    String markdownText, {
    String? title,
  }) async {
    // Use Noto fonts for broad Unicode coverage (bullets, em-dashes, CJK,
    // arrows, etc.). Fall back to built-in Helvetica/Courier when font assets
    // aren't reachable (e.g. offline test runs).
    final pw.Font baseFont = await _safeLoadFont(PdfGoogleFonts.notoSansRegular)
        ?? pw.Font.helvetica();
    final pw.Font boldFont = await _safeLoadFont(PdfGoogleFonts.notoSansBold)
        ?? pw.Font.helveticaBold();
    final pw.Font italicFont = await _safeLoadFont(PdfGoogleFonts.notoSansItalic)
        ?? pw.Font.helveticaOblique();
    final pw.Font monoFont = await _safeLoadFont(PdfGoogleFonts.robotoMonoRegular)
        ?? pw.Font.courier();
    final pw.Font emojiFont = await _safeLoadFont(PdfGoogleFonts.notoColorEmoji)
        ?? baseFont;

    final pw.ThemeData theme = pw.ThemeData.withFont(
      base: baseFont,
      bold: boldFont,
      italic: italicFont,
      boldItalic: boldFont,
      icons: emojiFont,
      fontFallback: <pw.Font>[emojiFont, monoFont],
    );

    final pw.Document doc = pw.Document(
      title: title ?? 'Chat response',
      theme: theme,
    );

    final List<md.Node> nodes = md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
    ).parse(markdownText);

    final List<pw.Widget> widgets = _renderNodes(nodes, monoFont: monoFont);

    if (title != null && title.trim().isNotEmpty) {
      widgets.insert(
        0,
        pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 12),
          child: pw.Text(
            title.trim(),
            style: pw.TextStyle(
              fontSize: 18,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
        ),
      );
    }

    doc.addPage(
      pw.MultiPage(
        pageFormat: _pageFormat,
        margin: const pw.EdgeInsets.all(36),
        build: (pw.Context context) => widgets.isEmpty
            ? <pw.Widget>[pw.SizedBox()]
            : widgets,
        footer: (pw.Context context) => pw.Container(
          alignment: pw.Alignment.centerRight,
          margin: const pw.EdgeInsets.only(top: 8),
          child: pw.Text(
            '${context.pageNumber} / ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey),
          ),
        ),
      ),
    );

    return doc.save();
  }

  static List<pw.Widget> _renderNodes(
    List<md.Node> nodes, {
    required pw.Font monoFont,
  }) {
    final List<pw.Widget> out = <pw.Widget>[];
    for (final md.Node node in nodes) {
      final pw.Widget? widget = _renderBlock(node, monoFont: monoFont);
      if (widget != null) out.add(widget);
    }
    return out;
  }

  static pw.Widget? _renderBlock(md.Node node, {required pw.Font monoFont}) {
    if (node is md.Text) {
      return _paragraph([pw.TextSpan(text: node.text)]);
    }
    if (node is! md.Element) return null;

    final String tag = node.tag;

    switch (tag) {
      case 'h1':
        return _heading(node, 22, monoFont: monoFont);
      case 'h2':
        return _heading(node, 18, monoFont: monoFont);
      case 'h3':
        return _heading(node, 15, monoFont: monoFont);
      case 'h4':
        return _heading(node, 13, monoFont: monoFont);
      case 'h5':
      case 'h6':
        return _heading(node, 12, monoFont: monoFont);
      case 'p':
        return _paragraph(_renderInlines(node.children, monoFont: monoFont));
      case 'hr':
        return pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 8),
          child: pw.Divider(thickness: 0.5, color: PdfColors.grey400),
        );
      case 'pre':
        return _codeBlock(node, monoFont: monoFont);
      case 'blockquote':
        return _blockquote(node, monoFont: monoFont);
      case 'ul':
        return _list(node, ordered: false, monoFont: monoFont);
      case 'ol':
        return _list(node, ordered: true, monoFont: monoFont);
      case 'table':
        return _renderTable(node, monoFont: monoFont);
      default:
        // Fallback: render any inline content
        final inlines = _renderInlines(node.children, monoFont: monoFont);
        if (inlines.isEmpty) return null;
        return _paragraph(inlines);
    }
  }

  static pw.Widget _heading(
    md.Element node,
    double size, {
    required pw.Font monoFont,
  }) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(top: 8, bottom: 4),
      child: pw.RichText(
        text: pw.TextSpan(
          children: _renderInlines(node.children, monoFont: monoFont),
          style: pw.TextStyle(
            fontSize: size,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
      ),
    );
  }

  static pw.Widget _paragraph(List<pw.InlineSpan> spans) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 3),
      child: pw.RichText(
        text: pw.TextSpan(
          children: spans,
          style: const pw.TextStyle(fontSize: 11, lineSpacing: 2),
        ),
      ),
    );
  }

  static pw.Widget _codeBlock(md.Element pre, {required pw.Font monoFont}) {
    final String code = _collectText(pre);
    return pw.Container(
      width: double.infinity,
      margin: const pw.EdgeInsets.symmetric(vertical: 6),
      padding: const pw.EdgeInsets.all(8),
      decoration: pw.BoxDecoration(
        color: PdfColors.grey200,
        borderRadius: pw.BorderRadius.circular(4),
      ),
      child: pw.Text(
        code,
        style: pw.TextStyle(
          fontSize: 9.5,
          font: monoFont,
          color: PdfColors.grey900,
        ),
      ),
    );
  }

  static pw.Widget _blockquote(md.Element node, {required pw.Font monoFont}) {
    return pw.Container(
      margin: const pw.EdgeInsets.symmetric(vertical: 4),
      padding: const pw.EdgeInsets.only(left: 10, top: 2, bottom: 2),
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          left: pw.BorderSide(color: PdfColors.grey400, width: 3),
        ),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: _renderNodes(node.children ?? <md.Node>[], monoFont: monoFont),
      ),
    );
  }

  static pw.Widget _list(
    md.Element node, {
    required bool ordered,
    required pw.Font monoFont,
  }) {
    final List<pw.Widget> items = <pw.Widget>[];
    int idx = 1;
    for (final md.Node child in node.children ?? <md.Node>[]) {
      if (child is md.Element && child.tag == 'li') {
        final String marker = ordered ? '$idx.' : '•';
        items.add(_listItem(child, marker, monoFont: monoFont));
        idx++;
      }
    }
    return pw.Padding(
      padding: const pw.EdgeInsets.only(left: 6, top: 2, bottom: 2),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: items,
      ),
    );
  }

  static pw.Widget _listItem(
    md.Element li,
    String marker, {
    required pw.Font monoFont,
  }) {
    final List<pw.Widget> blockChildren = <pw.Widget>[];
    final List<pw.InlineSpan> inlineBuffer = <pw.InlineSpan>[];

    void flushInline() {
      if (inlineBuffer.isEmpty) return;
      blockChildren.add(
        pw.RichText(
          text: pw.TextSpan(
            children: List<pw.InlineSpan>.from(inlineBuffer),
            style: const pw.TextStyle(fontSize: 11, lineSpacing: 2),
          ),
        ),
      );
      inlineBuffer.clear();
    }

    for (final md.Node child in li.children ?? <md.Node>[]) {
      if (child is md.Text) {
        inlineBuffer.add(pw.TextSpan(text: child.text));
      } else if (child is md.Element) {
        // Inline elements stay in line; block elements break.
        if (_isBlockTag(child.tag)) {
          flushInline();
          final pw.Widget? w = _renderBlock(child, monoFont: monoFont);
          if (w != null) blockChildren.add(w);
        } else {
          inlineBuffer.addAll(_renderInlines([child], monoFont: monoFont));
        }
      }
    }
    flushInline();

    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: <pw.Widget>[
          pw.SizedBox(
            width: 16,
            child: pw.Text(
              marker,
              style: const pw.TextStyle(fontSize: 11),
            ),
          ),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: blockChildren.isEmpty
                  ? <pw.Widget>[pw.SizedBox()]
                  : blockChildren,
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _renderTable(md.Element table, {required pw.Font monoFont}) {
    final List<List<List<pw.InlineSpan>>> rows =
        <List<List<pw.InlineSpan>>>[];
    final List<List<pw.InlineSpan>> headerCells = <List<pw.InlineSpan>>[];

    for (final md.Node section in table.children ?? <md.Node>[]) {
      if (section is! md.Element) continue;
      final bool isHeader = section.tag == 'thead';
      for (final md.Node tr in section.children ?? <md.Node>[]) {
        if (tr is! md.Element || tr.tag != 'tr') continue;
        final List<List<pw.InlineSpan>> cells = <List<pw.InlineSpan>>[];
        for (final md.Node cell in tr.children ?? <md.Node>[]) {
          if (cell is md.Element &&
              (cell.tag == 'th' || cell.tag == 'td')) {
            cells.add(_renderInlines(cell.children, monoFont: monoFont));
          }
        }
        if (isHeader && headerCells.isEmpty) {
          headerCells.addAll(cells);
        } else {
          rows.add(cells);
        }
      }
    }

    pw.Widget cellWidget(List<pw.InlineSpan> spans, {bool bold = false}) {
      return pw.Padding(
        padding: const pw.EdgeInsets.all(4),
        child: pw.RichText(
          text: pw.TextSpan(
            children: spans,
            style: pw.TextStyle(
              fontSize: 10,
              fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
            ),
          ),
        ),
      );
    }

    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 6),
      child: pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
        children: <pw.TableRow>[
          if (headerCells.isNotEmpty)
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: PdfColors.grey200),
              children: headerCells
                  .map((c) => cellWidget(c, bold: true))
                  .toList(),
            ),
          ...rows.map(
            (r) => pw.TableRow(
              children: r.map((c) => cellWidget(c)).toList(),
            ),
          ),
        ],
      ),
    );
  }

  static bool _isBlockTag(String tag) {
    return tag == 'p' ||
        tag == 'pre' ||
        tag == 'blockquote' ||
        tag == 'ul' ||
        tag == 'ol' ||
        tag == 'hr' ||
        tag == 'table' ||
        (tag.length == 2 && tag.startsWith('h'));
  }

  static List<pw.InlineSpan> _renderInlines(
    List<md.Node>? nodes, {
    required pw.Font monoFont,
    pw.TextStyle? inherited,
  }) {
    final List<pw.InlineSpan> out = <pw.InlineSpan>[];
    if (nodes == null) return out;
    for (final md.Node n in nodes) {
      if (n is md.Text) {
        out.add(
          pw.TextSpan(
            text: _decodeEntities(n.textContent),
            style: inherited,
          ),
        );
      } else if (n is md.Element) {
        out.addAll(_renderInlineElement(n, inherited, monoFont));
      }
    }
    return out;
  }

  static List<pw.InlineSpan> _renderInlineElement(
    md.Element el,
    pw.TextStyle? inherited,
    pw.Font monoFont,
  ) {
    final pw.TextStyle base = inherited ?? const pw.TextStyle();
    switch (el.tag) {
      case 'strong':
      case 'b':
        return _renderInlines(
          el.children,
          monoFont: monoFont,
          inherited: base.copyWith(fontWeight: pw.FontWeight.bold),
        );
      case 'em':
      case 'i':
        return _renderInlines(
          el.children,
          monoFont: monoFont,
          inherited: base.copyWith(fontStyle: pw.FontStyle.italic),
        );
      case 'del':
      case 's':
        return _renderInlines(
          el.children,
          monoFont: monoFont,
          inherited: base.copyWith(decoration: pw.TextDecoration.lineThrough),
        );
      case 'code':
        return <pw.InlineSpan>[
          pw.TextSpan(
            text: el.textContent,
            style: base.copyWith(
              font: monoFont,
              fontSize: (base.fontSize ?? 11) - 0.5,
              color: PdfColors.grey900,
              background: const pw.BoxDecoration(color: PdfColors.grey200),
            ),
          ),
        ];
      case 'a':
        final String href = el.attributes['href'] ?? '';
        final String label = el.textContent.isEmpty ? href : el.textContent;
        return <pw.InlineSpan>[
          pw.TextSpan(
            text: label,
            style: base.copyWith(
              color: PdfColors.blue700,
              decoration: pw.TextDecoration.underline,
            ),
            annotation: href.isEmpty
                ? null
                : pw.AnnotationUrl(href),
          ),
        ];
      case 'br':
        return <pw.InlineSpan>[const pw.TextSpan(text: '\n')];
      case 'img':
        final String alt = el.attributes['alt'] ?? 'image';
        return <pw.InlineSpan>[
          pw.TextSpan(text: '[image: $alt]', style: base),
        ];
      default:
        return _renderInlines(
          el.children,
          monoFont: monoFont,
          inherited: inherited,
        );
    }
  }

  static String _collectText(md.Node node) {
    if (node is md.Text) return node.text;
    if (node is md.Element) {
      final List<md.Node> children = node.children ?? <md.Node>[];
      return children.map(_collectText).join();
    }
    return '';
  }

  static String _decodeEntities(String s) {
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAllMapped(
          RegExp(r'&#(\d+);'),
          (m) => String.fromCharCode(int.parse(m.group(1)!)),
        )
        .replaceAllMapped(
          RegExp(r'&#x([0-9a-fA-F]+);'),
          (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
        );
  }

  /// Try to load a font, return null on failure (e.g. offline test runs).
  static Future<pw.Font?> _safeLoadFont(
    Future<pw.Font> Function() loader,
  ) async {
    try {
      return await loader();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PdfExportService: font load failed, using fallback: $e');
      }
      return null;
    }
  }

  static String _safeFilename(String? title) {
    final String base = (title == null || title.trim().isEmpty)
        ? 'chat-response'
        : title.trim();
    final String sanitized = base
        .replaceAll(RegExp(r'[^A-Za-z0-9._\- ]+'), '')
        .replaceAll(RegExp(r'\s+'), '-')
        .toLowerCase();
    final String trimmed = sanitized.isEmpty ? 'chat-response' : sanitized;
    return '$trimmed.pdf';
  }
}
