import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:cowork/ui/expressive/icon_map.dart';
import 'package:cowork/constants.dart';
import 'package:cowork/models/content_block.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/services/pdf_attachment_service.dart';
import 'package:cowork/services/storage/cowork_chat_store.dart';
import 'package:cowork/utils/theme_extensions.dart';
import 'package:cowork/widgets/chat_document_view.dart';
import 'package:cowork/widgets/sandbox_artifact_block.dart';

part 'chat_documents_explorer.dart';

/// Below this width a list column and a reading pane would each be too narrow
/// to read, so the panel shows one at a time instead — the phone layout.
const double _kTwoPaneWidth = 720;

/// The list column on the two-pane layout. Wide enough for a file name plus
/// its folder without the name truncating on the first segment.
const double _kListWidth = 320;

class ChatDocumentsPanel extends StatefulWidget {
  const ChatDocumentsPanel({
    super.key,
    required this.sessionKey,
    this.controller,
    this.coworkerName,
    this.fullPage = false,
  });
  final String sessionKey;
  final CoworkRelayController? controller;

  /// Use inside a normal Navigator route on mobile. Dialog callers are unchanged.
  final bool fullPage;

  /// The coworker whose container these documents live in, when the caller
  /// already knows it. Null lets the panel ask the host for the roster and fill
  /// the name in itself; until an answer arrives the panel says "this coworker"
  /// rather than inventing a name.
  final String? coworkerName;

  @override
  State<ChatDocumentsPanel> createState() => _ChatDocumentsPanelState();
}

class _ChatDocumentsPanelState extends State<ChatDocumentsPanel> {
  final Map<String, Map<String, dynamic>> _documents = {};
  Map<String, dynamic>? _selected;
  SandboxArtifactPayload? _file;
  String? _error;
  String? _coworker;
  bool _loading = true;
  final _explorerOptions = _ExplorerOptions();
  StreamSubscription<CoworkRelayInbound>? _subscription;

  @override
  void initState() {
    super.initState();
    _coworker = _clean(widget.coworkerName);
    _subscription = widget.controller?.inbound.listen(_receive);
    widget.controller?.state.addListener(_connectionChanged);
    unawaited(_load());
  }

  bool _reading = false;
  String? _selectedId;
  int _selectionEpoch = 0;
  CoworkRelayPhase? _phase;

  static String? _clean(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  /// The coworker's name, or the honest stand-in. Never a guess: the roster is
  /// the only source, and until it answers the panel says what it does know —
  /// that one coworker owns this chat.
  String get _owner => _coworker ?? 'this coworker';

  void _connectionChanged() {
    final phase = widget.controller?.state.value.phase;
    if (phase == CoworkRelayPhase.paired && _phase != phase) {
      unawaited(_request());
      unawaited(_requestCoworkerName());
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
      if (mounted && id != null && id == _selectedId) {
        setState(() => _reading = false);
      }
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

  /// Asks the host who this thread belongs to. The thread key *is* the agent
  /// id, so the roster answer names the coworker whose container holds these
  /// documents. A host that cannot answer costs nothing: the panel keeps the
  /// stand-in wording.
  Future<void> _requestCoworkerName() async {
    if (_coworker != null) return;
    final control = widget.controller;
    if (control == null ||
        control.state.value.phase != CoworkRelayPhase.paired) {
      return;
    }
    try {
      await control.requestAgentList();
    } catch (_) {
      /* No roster: the panel says "this coworker" and moves on. */
    }
  }

  void _receive(CoworkRelayInbound event) {
    if (!mounted) return;
    if (event is CoworkRelayAgentList) {
      for (final agent in event.agents) {
        if (agent.agentId != widget.sessionKey) continue;
        final name = _clean(agent.name);
        if (name != null && name != _coworker) {
          setState(() => _coworker = name);
        }
        break;
      }
      return;
    }
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
    final contents = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(context, rows),
        Divider(height: 1, color: theme.m3.outlineVariant),
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
        if (!widget.fullPage) _buildScopeFooter(context),
      ],
    );
    if (widget.fullPage) {
      return PopScope(
        canPop: _selectedId == null,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && _selectedId != null) _deselect();
        },
        child: Scaffold(
          backgroundColor: theme.colorScheme.surface,
          body: SafeArea(child: contents),
        ),
      );
    }
    return Dialog(
      clipBehavior: Clip.antiAlias,
      insetPadding: EdgeInsets.all(margin),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusDialog),
        side: BorderSide(color: theme.m3.outlineVariant),
      ),
      child: SizedBox(width: width, height: height, child: contents),
    );
  }

  /// The house header: an accent rule on top, the owning coworker in an avatar
  /// tile, and one status line. The status is what the panel actually knows —
  /// whose chat this is, how much it holds and whether the copy on this device
  /// has reached the cloud — never a description of what the feature is for.
  Widget _buildHeader(BuildContext context, List<Map<String, dynamic>> rows) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final m3 = theme.m3;
    final isDark = theme.brightness == Brightness.dark;
    final saved = rows.where((d) => d['kind'] != 'file').length;
    final files = rows.length - saved;
    final parts = <String>[
      'This chat only',
      if (_loading)
        'Loading…'
      else if (rows.isEmpty)
        'Nothing saved yet'
      else ...[
        '$saved saved',
        if (files > 0) '$files ${files == 1 ? 'file' : 'files'}',
      ],
      if (CoworkChatStore.isDirty(widget.sessionKey)) 'Sync pending',
    ];
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.primary, width: 3)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: isDark ? 0.2 : 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: AppIcon(
              Icons.folder_shared_outlined,
              size: 20,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.fullPage ? 'Files · $_owner' : '$_owner · Documents',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  parts.join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: m3.onSurfaceVariant,
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
            icon: const AppIcon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Close',
            onPressed: () => Navigator.pop(context),
            icon: const AppIcon(Icons.close),
          ),
        ],
      ),
    );
  }

  /// The one sentence that answers "whose files am I looking at". It is a
  /// footer, in the same shape as the house's encryption line, because it is a
  /// standing fact about the panel and not a message about the current state.
  Widget _buildScopeFooter(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.m3.onSurfaceVariant;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.m3.outlineVariant)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AppIcon(Icons.inventory_2_outlined, size: 12, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '$_owner runs in its own container. '
              'These documents belong to this chat alone.',
              style: TextStyle(fontSize: 11, color: color),
              maxLines: 2,
              textAlign: TextAlign.center,
            ),
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
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          AppIcon(
            Icons.error_outline,
            size: 18,
            color: scheme.onErrorContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer),
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
          SizedBox(width: _kListWidth, child: _buildList(context, rows)),
          VerticalDivider(width: 1, color: Theme.of(context).m3.outlineVariant),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
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
          padding: const EdgeInsets.fromLTRB(4, 6, 16, 6),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Back to the list',
                onPressed: _deselect,
                icon: const AppIcon(Icons.arrow_back),
              ),
              Expanded(
                child: Text(
                  '${title ?? 'Document'}',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: theme.m3.outlineVariant),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: _buildReader(context, rows),
          ),
        ),
      ],
    );
  }

  /// One scrolling list, two named groups. The group headings carry the counts,
  /// so the reader never has to work out which rows came from the chat and
  /// which came off the coworker's own disk.
  Widget _buildList(BuildContext context, List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) {
      return _EmptyBlock(
        icon: Icons.folder_open_outlined,
        title: 'No documents yet',
        detail:
            'Ask $_owner for a table, a chart or a note. It is kept in this '
            'chat across restarts, and files it writes in its container show '
            'up here too.',
      );
    }
    return _DocumentExplorer(
      options: _explorerOptions,
      documents: rows,
      owner: _owner,
      selectedId: _selectedId,
      onSelect: _select,
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
            'It is in $_owner’s container. Reading it needs the laptop to '
            'be connected.',
        action: FilledButton.tonalIcon(
          style: _pillButton,
          onPressed: () => _request(id: _selectedId),
          icon: const AppIcon(Icons.refresh, size: 18),
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
            ? 'Ask $_owner for a table, a chart or a note. It is kept in this '
                  'chat across restarts.'
            : '$_owner rewrites these while it works. The version and time '
                  'beside each name say how current it is.',
        action: recent == null
            ? null
            : FilledButton.tonalIcon(
                style: _pillButton,
                onPressed: () => _select(recent),
                icon: AppIcon(_documentIcon(recent), size: 18),
                label: Text(
                  'Open ${recent['title']}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
      );
    }
    if (_file != null) {
      return SingleChildScrollView(
        child: SandboxArtifactBlock(payload: _file!),
      );
    }
    return ChatDocumentView(document: _selected!);
  }
}

/// A group heading with its count, in the shape the house uses for the sections
/// of the workspace panel: a plain title and a tinted count pill.
class _GroupHeading extends StatelessWidget {
  const _GroupHeading({
    required this.title,
    required this.count,
    required this.topInset,
  });

  final String title;
  final int count;
  final double topInset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Padding(
      padding: EdgeInsets.fromLTRB(4, topInset, 4, 10),
      child: Row(
        children: [
          Flexible(
            child: Text(
              title,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One list row, in the house file-tile shape: a tinted type icon, the name on
/// the first line, and the facts a reader cannot get anywhere else on the
/// second — where the file sits, how big it is, and how current it is.
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
    final m3 = theme.m3;
    final isDark = theme.brightness == Brightness.dark;
    final isFile = document['kind'] == 'file';
    final path = '${document['path'] ?? ''}';
    final title = '${document['title']}';
    final detail = <String>[
      if (isFile) ...[
        ?_folderLabel(path),
        ?_sizeLabel(document),
      ] else
        _kindLabel(document),
      ?documentFreshness(document),
    ].join(' · ');
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: isDark ? 0.22 : 0.14)
          : m3.surfaceContainer,
      borderRadius: kBorderRadiusCard,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: kBorderRadiusCard,
        onTap: onTap,
        child: Semantics(
          selected: selected,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(
                      alpha: isDark ? 0.18 : 0.12,
                    ),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: AppIcon(
                    _documentIcon(document),
                    size: 22,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Tooltip(
                        message: isFile && path.isNotEmpty ? path : title,
                        child: Text(
                          title,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: selected ? scheme.primary : null,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (detail.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          detail,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: m3.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
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

/// Where a workspace file sits, short enough for one line. Twenty skills all
/// carry a `SKILL.md`, so the folder is what tells the rows apart — and the
/// last segments are the specific ones, so truncation eats the head, never the
/// tail. Null for a file at the root of the container's workspace.
String? _folderLabel(String path) {
  if (path.isEmpty) return null;
  final parts = path.split('/')..removeLast();
  if (parts.isEmpty) return null;
  if (parts.length <= 2) return parts.join('/');
  return '…/${parts.sublist(parts.length - 2).join('/')}';
}

/// The house file-size wording, byte for byte the one the workspace file tiles
/// use. Null when the catalog carries no size, because a made-up `0 B` reads as
/// an empty file.
String? _sizeLabel(Map<String, dynamic> document) {
  final raw = document['size'];
  if (raw is! num || raw < 0 || !raw.isFinite) return null;
  final bytes = raw.toInt();
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
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
    'md' || 'markdown' || 'txt' => Icons.description_outlined,
    _ => Icons.insert_drive_file_outlined,
  };
}

/// The panel's one empty state, in the house shape: a large quiet icon, the
/// headline under it, then the sentence that says what would fill the list.
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
    final m3 = theme.m3;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(
                icon,
                size: 64,
                color: m3.onSurfaceVariant.withValues(alpha: 0.4),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: m3.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: m3.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
              if (action != null) ...[const SizedBox(height: 20), action!],
            ],
          ),
        ),
      ),
    );
  }
}
