import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:cowork/models/content_block.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/services/pdf_attachment_service.dart';
import 'package:cowork/services/storage/cowork_chat_store.dart';
import 'package:cowork/widgets/chat_document_view.dart';
import 'package:cowork/widgets/sandbox_artifact_block.dart';

/// Below this width a list column and a reading pane would each be too narrow
/// to read, so the panel shows one at a time instead — the phone layout.
const double _kTwoPaneWidth = 720;

class ChatDocumentsPanel extends StatefulWidget {
  const ChatDocumentsPanel({
    super.key,
    required this.sessionKey,
    this.controller,
  });
  final String sessionKey;
  final CoworkRelayController? controller;
  @override
  State<ChatDocumentsPanel> createState() => _ChatDocumentsPanelState();
}

class _ChatDocumentsPanelState extends State<ChatDocumentsPanel> {
  final Map<String, Map<String, dynamic>> _documents = {};
  Map<String, dynamic>? _selected;
  SandboxArtifactPayload? _file;
  String? _error;
  bool _loading = true;
  StreamSubscription<CoworkRelayInbound>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = widget.controller?.inbound.listen(_receive);
    widget.controller?.state.addListener(_connectionChanged);
    unawaited(_load());
  }

  bool _reading = false;
  String? _selectedId;
  int _selectionEpoch = 0;
  CoworkRelayPhase? _phase;

  void _connectionChanged() {
    final phase = widget.controller?.state.value.phase;
    if (phase == CoworkRelayPhase.paired && _phase != phase) {
      unawaited(_request());
      if (_selectedId != null) unawaited(_request(id: _selectedId));
    }
    _phase = phase;
  }

  Future<void> _load() async {
    try {
      final chat = await CoworkChatStore.loadThread(widget.sessionKey);
      if (!mounted) return;
      for (final message in chat?.messages ?? []) {
        try {
          final blocks = jsonDecode(message.contentBlocks ?? '[]');
          for (final block in (blocks as List).whereType<Map>()) {
            final doc = block['sandboxArtifact']?['document'];
            if (doc is Map) _adopt(Map<String, dynamic>.from(doc));
          }
        } catch (_) {
          /* Legacy messages have no document snapshot. */
        }
      }
    } catch (_) {
      if (mounted) {
        _error = 'Saved documents could not be loaded. Try refreshing.';
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        _connectionChanged();
      }
    }
  }

  bool _hasContent(Map<String, dynamic> doc) =>
      doc.containsKey('text') ||
      doc.containsKey('rows') ||
      doc.containsKey('data');

  bool _adopt(Map<String, dynamic> doc) {
    final id = doc['id'];
    if (id is! String || id.isEmpty) return false;
    final previous = _documents[id];
    // A version that arrives as a string would throw inside setState and stop
    // the panel adopting anything further; an unreadable one simply counts as
    // no version.
    final previousVersion = previous?['version'];
    final nextVersion = doc['version'];
    final before = previousVersion is num ? previousVersion : 0;
    final after = nextVersion is num ? nextVersion : 0;
    if (after < before) return false;
    // A newer catalog entry must never relabel old rows with its version.
    _documents[id] = after > before ? {...doc} : {...?previous, ...doc};
    if (_selectedId == id && _hasContent(_documents[id]!)) {
      _selected = _documents[id];
      _reading = doc['kind'] == 'file';
    } else if (_selectedId == id && after > before) {
      _selected = null;
      _reading = true;
      unawaited(_request(id: id));
    }
    return true;
  }

  Future<void> _request({String? id}) async {
    final control = widget.controller;
    if (control == null ||
        control is! CoworkDocumentsControl ||
        control.state.value.phase != CoworkRelayPhase.paired) {
      return;
    }
    try {
      await (control as CoworkDocumentsControl).requestDocuments(
        widget.sessionKey,
        id: id,
      );
    } catch (_) {
      if (mounted && (id == null || id == _selectedId)) {
        setState(() {
          _reading = false;
          _error =
              'Connection unavailable. Your saved documents are still here.';
        });
      }
    }
  }

  void _receive(CoworkRelayInbound event) {
    if (!mounted) return;
    if (event is CoworkRelayFile &&
        event.document?['session_key'] == widget.sessionKey) {
      setState(() {
        if (_adopt(event.document!)) _persist(event.document!);
      });
    }
    if (event is! CoworkRelayDocuments ||
        event.payload['session_key'] != widget.sessionKey) {
      return;
    }
    final data = event.payload;
    if (data['error'] != null &&
        data['id'] != null &&
        data['id'] != _selectedId) {
      return;
    }
    setState(() {
      _error = data['error'] as String?;
      if (_error != null) _reading = false;
      for (final doc in (data['documents'] as List? ?? []).whereType<Map>()) {
        _adopt(Map<String, dynamic>.from(doc));
      }
    });
    if (data['selected'] is Map) {
      final doc = Map<String, dynamic>.from(data['selected'] as Map);
      bool accepted = false;
      setState(() {
        accepted = _adopt(doc);
      });
      if (accepted) _persist(doc);
      if (accepted && doc['id'] == _selectedId && doc['kind'] == 'file') {
        unawaited(_openFile(doc, _selectionEpoch));
      }
    }
  }

  void _persist(Map<String, dynamic> doc) {
    if (doc['kind'] != 'file' && _hasContent(doc)) {
      unawaited(CoworkChatStore.saveDocumentSnapshot(widget.sessionKey, doc));
    }
  }

  void _select(Map<String, dynamic> doc) {
    _selectionEpoch++;
    setState(() {
      _selectedId = doc['id'] as String;
      _selected = _hasContent(doc) && doc['kind'] != 'file' ? doc : null;
      _file = null;
      _reading = _selected == null;
      _error = null;
    });
    if (doc['kind'] == 'file' && _hasContent(doc)) {
      unawaited(_openFile(doc, _selectionEpoch));
    }
    unawaited(_request(id: _selectedId));
  }

  /// Leaving the reader on the one-pane layout. The epoch moves so that a read
  /// still in flight cannot drop its answer onto the list the reader came back
  /// to.
  void _deselect() {
    _selectionEpoch++;
    setState(() {
      _selectedId = null;
      _selected = null;
      _file = null;
      _reading = false;
      _error = null;
    });
  }

  Future<void> _openFile(Map<String, dynamic> doc, int epoch) async {
    try {
      final bytes = base64Decode(doc['data'] as String);
      final path = await PdfAttachmentService.upload(bytes);
      if (!mounted || epoch != _selectionEpoch || doc['id'] != _selectedId) {
        return;
      }
      setState(() {
        _selected = doc;
        _reading = false;
        _file = SandboxArtifactPayload(
          storagePath: path,
          filename: '${doc['title']}',
          mime: '${doc['mime']}',
          sizeBytes: bytes.length,
        );
      });
    } catch (_) {
      if (mounted && epoch == _selectionEpoch) {
        setState(() {
          _reading = false;
          _error = 'Could not open this document.';
        });
      }
    }
  }

  @override
  void dispose() {
    widget.controller?.state.removeListener(_connectionChanged);
    _subscription?.cancel();
    super.dispose();
  }

  /// Chat documents first, then workspace files; each group newest first, so
  /// the row the agent just rewrote is the one at the top.
  List<Map<String, dynamic>> get _rows {
    final rows = _documents.values.toList();
    rows.sort((a, b) {
      final group = (a['kind'] == 'file' ? 1 : 0).compareTo(
        b['kind'] == 'file' ? 1 : 0,
      );
      if (group != 0) return group;
      final at = documentUpdatedAt(a);
      final bt = documentUpdatedAt(b);
      if (at != null && bt != null && at != bt) return bt.compareTo(at);
      if ((at == null) != (bt == null)) return at == null ? 1 : -1;
      return '${a['title']}'.compareTo('${b['title']}');
    });
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.sizeOf(context);
    final rows = _rows;
    // The house shell: margin collapses on a small window, the outer radius
    // drops with it, and one Material both draws the edge and clips it.
    final margin = media.width < 560 || media.height < 560 ? 8.0 : 24.0;
    final width = math.max(280.0, math.min(1040.0, media.width - margin * 2));
    final height = math.max(320.0, math.min(760.0, media.height - margin * 2));
    return Dialog(
      clipBehavior: Clip.antiAlias,
      insetPadding: EdgeInsets.all(margin),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(width < _kTwoPaneWidth ? 20 : 28),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(context, rows),
            Divider(height: 1, color: theme.colorScheme.outlineVariant),
            if (_error != null) _buildErrorBanner(context, _error!),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : LayoutBuilder(
                      builder: (context, constraints) =>
                          constraints.maxWidth >= _kTwoPaneWidth
                          ? _buildTwoPane(context, rows)
                          : _buildOnePane(context, rows),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// One title, one status line. The status is what the panel actually knows —
  /// how much it holds and whether the copy on this device has reached the
  /// cloud — never a description of what the feature is for.
  Widget _buildHeader(BuildContext context, List<Map<String, dynamic>> rows) {
    final theme = Theme.of(context);
    final saved = rows.where((d) => d['kind'] != 'file').length;
    final files = rows.length - saved;
    final parts = <String>[
      if (_loading)
        'Loading…'
      else if (rows.isEmpty)
        'Nothing saved yet'
      else ...[
        '$saved in this chat',
        if (files > 0) '$files workspace ${files == 1 ? 'file' : 'files'}',
      ],
      if (CoworkChatStore.isDirty(widget.sessionKey)) 'Sync pending',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 8, 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Chat documents',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  parts.join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Refresh documents',
            onPressed: _request,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Close',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(BuildContext context, String message) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTwoPane(BuildContext context, List<Map<String, dynamic>> rows) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 300, child: _buildList(context, rows)),
          VerticalDivider(
            width: 1,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: _buildReader(context, rows),
            ),
          ),
        ],
      );

  /// On a phone the two panes become two screens: the list, and the document
  /// with a way back to it.
  Widget _buildOnePane(BuildContext context, List<Map<String, dynamic>> rows) {
    if (_selectedId == null) return _buildList(context, rows);
    final theme = Theme.of(context);
    final title = _documents[_selectedId]?['title'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Back to the list',
                onPressed: _deselect,
                icon: const Icon(Icons.arrow_back),
              ),
              Expanded(
                child: Text(
                  '${title ?? 'Document'}',
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: theme.colorScheme.outlineVariant),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: _buildReader(context, rows),
          ),
        ),
      ],
    );
  }

  Widget _buildList(BuildContext context, List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) {
      return _EmptyBlock(
        icon: Icons.folder_open_outlined,
        title: 'No documents yet',
        detail:
            'Ask the agent for a table, a chart or a note and it is kept here '
            'across restarts.',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final doc = rows[i];
        final isFile = doc['kind'] == 'file';
        final startsGroup = i == 0 || (rows[i - 1]['kind'] == 'file') != isFile;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (startsGroup)
              Padding(
                padding: EdgeInsets.fromLTRB(16, i == 0 ? 14 : 22, 12, 6),
                child: Text(
                  isFile ? 'WORKSPACE FILES' : 'SAVED IN THIS CHAT',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            _DocumentRow(
              document: doc,
              selected: _selectedId == doc['id'],
              onTap: () => _select(doc),
            ),
          ],
        );
      },
    );
  }

  Widget _buildReader(BuildContext context, List<Map<String, dynamic>> rows) {
    if (_reading) return const Center(child: CircularProgressIndicator());
    if (_selected == null && _selectedId != null) {
      // A selected document with no body is a read that did not arrive. Saying
      // "select a document" here would blame the reader for a failed request.
      return _EmptyBlock(
        icon: Icons.cloud_off_outlined,
        title: 'This document is not on the device yet',
        detail:
            'It is saved on the agent. Reading it needs the laptop to be '
            'connected.',
        action: FilledButton.tonalIcon(
          style: _pillButton,
          onPressed: () => _request(id: _selectedId),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Try again'),
        ),
      );
    }
    if (_selected == null) {
      // Nothing selected is a normal state, not a hole: it says what the list
      // is for, explains the freshness marks next to each name, and offers the
      // row the agent touched last.
      final recent = rows.isEmpty ? null : rows.first;
      return _EmptyBlock(
        icon: Icons.article_outlined,
        title: rows.isEmpty
            ? 'No documents yet'
            : 'Select a document to read it',
        detail: rows.isEmpty
            ? 'Ask the agent for a table, a chart or a note and it is kept '
                  'here across restarts.'
            : 'The agent rewrites these while it works. The version and time '
                  'beside each name say how current it is.',
        action: recent == null
            ? null
            : FilledButton.tonalIcon(
                style: _pillButton,
                onPressed: () => _select(recent),
                icon: Icon(_documentIcon(recent), size: 18),
                label: Text(
                  'Open ${recent['title']}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
      );
    }
    if (_file != null) {
      return SingleChildScrollView(child: SandboxArtifactBlock(payload: _file!));
    }
    return ChatDocumentView(document: _selected!);
  }
}

/// One list row. The kind is carried by the icon, which frees the second line
/// for the only thing a reader cannot get anywhere else: how current this
/// document is.
class _DocumentRow extends StatelessWidget {
  const _DocumentRow({
    required this.document,
    required this.selected,
    required this.onTap,
  });

  final Map<String, dynamic> document;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isFile = document['kind'] == 'file';
    final path = '${document['path'] ?? ''}';
    final title = isFile && path.isNotEmpty
        ? _folderLabel(path)
        : '${document['title']}';
    final freshness = documentFreshness(document);
    final detail = isFile
        ? ['${document['title']}', ?freshness].join(' · ')
        : freshness ?? _kindLabel(document);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: .18)
              : scheme.surfaceContainer,
          // The border is reserved whether or not the row is selected:
          // selecting must change colour only. A border that appears on
          // selection resizes the row and nudges the whole list.
          border: Border.all(
            color: selected
                ? scheme.primary.withValues(alpha: .55)
                : Colors.transparent,
            width: 1.5,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Semantics(
              selected: selected,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 9, 12, 9),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        _documentIcon(document),
                        size: 18,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Tooltip(
                            message: isFile && path.isNotEmpty ? path : title,
                            child: Text(
                              title,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: selected ? scheme.primary : null,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            detail,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Every button in the house style is a pill.
final ButtonStyle _pillButton = FilledButton.styleFrom(
  shape: const StadiumBorder(),
  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
);

/// Workspace files repeat their names — twenty skills all carry a `SKILL.md` —
/// so the folder is the identity and it is what the row leads with. The last
/// segments are the specific ones, so truncation eats the head, never the tail.
String _folderLabel(String path) {
  final parts = path.split('/')..removeLast();
  if (parts.isEmpty) return path;
  if (parts.length <= 2) return parts.join('/');
  return '…/${parts.sublist(parts.length - 2).join('/')}';
}

String _kindLabel(Map<String, dynamic> document) => switch (document['kind']) {
  'table' => 'Table',
  'bar_chart' => 'Chart',
  _ => 'Document',
};

IconData _documentIcon(Map<String, dynamic> document) {
  if (document['kind'] == 'table') return Icons.table_chart_outlined;
  if (document['kind'] == 'bar_chart') return Icons.bar_chart;
  if (document['kind'] != 'file') return Icons.description_outlined;
  final name = '${document['path'] ?? document['title'] ?? ''}'.toLowerCase();
  final suffix = name.contains('.') ? name.split('.').last : '';
  return switch (suffix) {
    'pdf' => Icons.picture_as_pdf_outlined,
    'csv' || 'xlsx' => Icons.table_chart_outlined,
    'pptx' => Icons.slideshow_outlined,
    'docx' => Icons.article_outlined,
    'html' || 'svg' => Icons.code_outlined,
    _ => Icons.description_outlined,
  };
}

/// The panel's one empty state. Compact and top-aligned on purpose: a pane
/// that answers 800x600 of emptiness with a centred icon reads as broken, not
/// as calm. It is a card that says what the list holds and offers a way in.
class _EmptyBlock extends StatelessWidget {
  const _EmptyBlock({
    required this.icon,
    required this.title,
    required this.detail,
    this.action,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    icon,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              detail,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: 18),
              Align(alignment: Alignment.centerLeft, child: action!),
            ],
          ],
        ),
      ),
    );
  }
}
