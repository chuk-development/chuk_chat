// lib/widgets/message_bubble/rich_blocks.dart
//
// Part of message_bubble.dart — the inline rich output blocks the AI can emit
// in its text: <chart>, <map>, <email>, <weather>, <news>, <image>, <diff>.
// Parses the interleaved markdown + tag stream and renders each block, with
// the plain-text paragraph fallbacks.

// ignore_for_file: invalid_use_of_protected_member

part of '../message_bubble.dart';

extension _MessageBubbleRichBlocks on _MessageBubbleState {
  bool _hasVisualBlocks(String content) {
    return _visualBlockStartRegex.hasMatch(content);
  }

  dynamic _tryParseJson(String raw) {
    var s = raw.trim();
    try {
      return jsonDecode(s);
    } catch (_) {}

    if (s.startsWith('{') && s.endsWith(']')) {
      s = s.substring(0, s.length - 1).trim();
      if (s.endsWith('}')) {
        try {
          return jsonDecode(s);
        } catch (_) {}
      }
    }

    s = raw.trim().replaceAll(RegExp(r',\s*([}\]])'), r'$1');
    try {
      return jsonDecode(s);
    } catch (_) {}

    return jsonDecode(raw.trim());
  }

  /// Renders interleaved markdown + rich `<chart>` / `<map>` / `<email>`
  /// / `<weather>` / `<news>` / `<image>` blocks. Returns ONE Column —
  /// no external margin. The `Padding(symmetric(vertical: 4))` on each
  /// inner MarkdownMessage is internal breathing room, not a layout
  /// gap (see `_buildBlockText`). Callers control gaps to neighbouring
  /// blocks via `_kBlockGap`.
  Widget _buildVisualContent({
    required String content,
    required Color textColor,
    required Color bgColor,
  }) {
    final widgets = <Widget>[];
    var lastEnd = 0;

    for (final match in _richBlockRegex.allMatches(content)) {
      final textBefore = content.substring(lastEnd, match.start).trim();
      if (textBefore.isNotEmpty) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: MarkdownMessage(
              text: textBefore,
              textColor: textColor,
              backgroundColor: bgColor,
              wrapWithSelectionArea: !widget.useSharedSelectionArea,
              fontFamily: _chatFontFamily,
              paragraphFontSize: AppThemeService.instance.chatFontSize,
            ),
          ),
        );
      }

      final blockType = match.group(1)!.toLowerCase();
      final blockJson = match.group(2)!.trim();

      try {
        if (blockType == 'diff') {
          final parsed = _tryParseJson(blockJson);
          if (parsed is! Map<String, dynamic>) {
            throw const FormatException('Expected JSON object');
          }
          widgets.add(_buildDiffBlock(parsed));
        } else if (blockType == 'map') {
          widgets.add(MapBlockWidget(jsonString: blockJson));
        } else if (blockType == 'email') {
          final parsed = _tryParseJson(blockJson);
          if (parsed is! Map<String, dynamic>) {
            throw const FormatException('Expected JSON object');
          }
          widgets.add(_buildEmailBlock(parsed));
        } else if (blockType == 'weather') {
          final parsed = _tryParseJson(blockJson);
          if (parsed is! Map<String, dynamic>) {
            throw const FormatException('Expected JSON object');
          }
          widgets.add(WeatherBlockWidget(data: parsed));
        } else if (blockType == 'news') {
          final parsed = _tryParseJson(blockJson);
          if (parsed is! Map<String, dynamic>) {
            throw const FormatException('Expected JSON object');
          }
          widgets.add(_buildNewsBlock(parsed));
        } else if (blockType == 'image') {
          final parsed = _tryParseJson(blockJson);
          if (parsed is! Map<String, dynamic>) {
            throw const FormatException('Expected JSON object');
          }
          widgets.add(_buildImageBlock(parsed));
        } else {
          final parsed = _tryParseJson(blockJson);
          if (parsed is! Map<String, dynamic>) {
            throw const FormatException('Expected JSON object');
          }
          widgets.add(ChartRenderer(data: parsed));
        }
      } catch (e) {
        widgets.add(
          Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.errorContainer.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$blockType parse error: $e',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        );
      }

      lastEnd = match.end;
    }

    final textAfter = content.substring(lastEnd).trim();
    if (textAfter.isNotEmpty) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: MarkdownMessage(
            text: textAfter,
            textColor: textColor,
            backgroundColor: bgColor,
            wrapWithSelectionArea: !widget.useSharedSelectionArea,
            fontFamily: _chatFontFamily,
            paragraphFontSize: AppThemeService.instance.chatFontSize,
          ),
        ),
      );
    }

    if (widgets.isEmpty) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: MarkdownMessage(
            text: content,
            textColor: textColor,
            backgroundColor: bgColor,
            wrapWithSelectionArea: !widget.useSharedSelectionArea,
            fontFamily: _chatFontFamily,
            paragraphFontSize: AppThemeService.instance.chatFontSize,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  Widget _buildDiffBlock(Map<String, dynamic> data) {
    return DiffWidget(
      before: data['before'] as String? ?? '',
      after: data['after'] as String? ?? '',
      title: data['title'] as String?,
      type: data['type'] as String?,
    );
  }

  /// Renders an `<email>` block as a card with subject, recipients, body
  /// preview, and an "Open in Mail App" button that launches a mailto: URI.
  Widget _buildEmailBlock(Map<String, dynamic> data) {
    final to = data['to'] as String? ?? '';
    final subject = data['subject'] as String? ?? '';
    final body = data['body'] as String? ?? '';
    final cc = data['cc'] as String?;
    final bcc = data['bcc'] as String?;

    final colorScheme = Theme.of(context).colorScheme;
    final bgColor = Theme.of(context).scaffoldBackgroundColor;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: bgColor.lighten(0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.primary.withValues(alpha: 0.25),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: colorScheme.primary.withValues(alpha: 0.08),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(11),
                topRight: Radius.circular(11),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.email_outlined,
                  size: 18,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    subject.isNotEmpty ? subject : 'No Subject',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: colorScheme.onSurface,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          // Recipients
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (to.isNotEmpty) _emailField('To', to, colorScheme),
                if (cc != null && cc.isNotEmpty)
                  _emailField('CC', cc, colorScheme),
                if (bcc != null && bcc.isNotEmpty)
                  _emailField('BCC', bcc, colorScheme),
              ],
            ),
          ),
          // Body preview
          if (body.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
              child: Text(
                body.length > 300 ? '${body.substring(0, 300)}...' : body,
                style: TextStyle(
                  fontSize: 13,
                  color: colorScheme.onSurface.withValues(alpha: 0.75),
                  height: 1.4,
                ),
                maxLines: 8,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          // Open button
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _openMailto(to, subject, body, cc, bcc),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: Text(AppLocalizations.of(context)!.openInMailApp),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  textStyle: const TextStyle(fontSize: 13),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emailField(String label, String value, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 32,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontSize: 13, color: colorScheme.onSurface),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openMailto(
    String to,
    String subject,
    String body,
    String? cc,
    String? bcc,
  ) async {
    final params = <String, String>{};
    if (subject.isNotEmpty) params['subject'] = subject;
    if (body.isNotEmpty) params['body'] = body;
    if (cc != null && cc.isNotEmpty) params['cc'] = cc;
    if (bcc != null && bcc.isNotEmpty) params['bcc'] = bcc;

    // Build the query by hand with Uri.encodeComponent: Uri's
    // queryParameters uses form encoding, which turns spaces into `+`. RFC
    // 6068 treats `+` in a mailto as a literal, so a subject/body space would
    // surface as a plus sign in the composed mail. encodeComponent uses %20.
    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    final uri = Uri(
      scheme: 'mailto',
      path: to,
      query: query.isEmpty ? null : query,
    );

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  /// Renders a `<news>` block as a list of news cards (thumbnail, title,
  /// publisher · age, description, tap-to-open).
  Widget _buildNewsBlock(Map<String, dynamic> data) {
    final rawItems = data['items'];
    final items = <Map<String, dynamic>>[];
    if (rawItems is List) {
      for (final entry in rawItems) {
        if (entry is Map) {
          items.add(Map<String, dynamic>.from(entry));
        }
      }
    }
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    final colorScheme = Theme.of(context).colorScheme;
    final cards = <Widget>[];
    for (int i = 0; i < items.length; i++) {
      cards.add(_NewsCard(item: items[i], colorScheme: colorScheme));
      if (i < items.length - 1) {
        cards.add(const SizedBox(height: 10));
      }
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: cards,
      ),
    );
  }

  /// Renders an `<image>` block as a display-only image card.
  ///
  /// This is intentionally separate from the `fetch_image` tool path:
  /// - `<image>` = render-only output tag (no fetch/persist side effects)
  /// - `fetch_image` = tool pipeline for fetch/store/vision workflows
  Widget _buildImageBlock(Map<String, dynamic> data) {
    final rawUrl = (data['url'] ?? data['image_url'] ?? data['src'] ?? '')
        .toString()
        .trim();
    final caption = (data['caption'] ?? '').toString().trim();
    final source = (data['source'] ?? data['credit'] ?? '').toString().trim();

    final uri = Uri.tryParse(rawUrl);
    final validHttp =
        uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
    if (!validHttp) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).colorScheme.errorContainer.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          'image parse error: invalid or missing http(s) url',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.error,
          ),
        ),
      );
    }

    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: kBorderRadiusRow,
                onTap: () => _openImagePreview(
                  imageSource: rawUrl,
                  images: [rawUrl],
                  index: 0,
                  // This is a standalone web image, not aligned with
                  // widget.imageMetas — don't label it with that metadata.
                  resolveModels: false,
                ),
                child: Image.network(
                  rawUrl,
                  width: double.infinity,
                  fit: BoxFit.fitWidth,
                  frameBuilder: (context, child, frame, wasSync) {
                    if (frame == null) {
                      return Container(
                        height: 180,
                        color: colorScheme.surfaceContainerHighest,
                        alignment: Alignment.center,
                        child: const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      );
                    }
                    return child;
                  },
                  errorBuilder: (context, error, stackTrace) => Container(
                    height: 120,
                    color: colorScheme.surfaceContainerHighest,
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (caption.isNotEmpty || source.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (caption.isNotEmpty)
                    Text(
                      caption,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  if (source.isNotEmpty) ...[
                    if (caption.isNotEmpty) const SizedBox(height: 2),
                    Text(
                      source,
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurface.withValues(alpha: 0.65),
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Renders a text content block as a MarkdownMessage.
  ///
  /// The `Padding(symmetric(vertical: 4))` is intentional internal
  /// padding around the markdown — it gives text blocks breathing room
  /// against the bubble background and acts as part of the block's own
  /// presentation, NOT as a between-blocks layout gap. Callers still
  /// add `_kBlockGap` between text and other blocks.
  Widget _buildBlockText(String text, Color textColor, Color bgColor) {
    // Check for embedded visual blocks (<chart>/<map>/<email>/<weather>/<news>/<image>)
    if (_hasVisualBlocks(text)) {
      return _buildVisualContent(
        content: text,
        textColor: textColor,
        bgColor: bgColor,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: MarkdownMessage(
        text: text,
        textColor: textColor,
        backgroundColor: bgColor,
        wrapWithSelectionArea: !widget.useSharedSelectionArea,
        fontFamily: _chatFontFamily,
        paragraphFontSize: AppThemeService.instance.chatFontSize,
      ),
    );
  }

  List<Widget> _buildTextParagraphs({
    required String text,
    required Color textColor,
    required Color bgColor,
  }) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) {
      return const <Widget>[];
    }

    if (_hasVisualBlocks(trimmed)) {
      return <Widget>[
        _buildVisualContent(
          content: trimmed,
          textColor: textColor,
          bgColor: bgColor,
        ),
      ];
    }

    return <Widget>[_buildBlockText(trimmed, textColor, bgColor)];
  }
}
