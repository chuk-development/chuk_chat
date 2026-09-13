import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/pdf_attachment_service.dart';
import 'package:chuk_chat/services/storage/agents_chat_store.dart';
import 'package:chuk_chat/ui/expressive/connected_group.dart';
import 'package:chuk_chat/ui/expressive/expressive_screen.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/chat_document_view.dart';
import 'package:chuk_chat/widgets/sandbox_artifact_block.dart';

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
  final AgentsRelayController? controller;

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
  StreamSubscription<AgentsRelayInbound>? _subscription;

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
  AgentsRelayPhase? _phase;

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
    if (phase == AgentsRelayPhase.paired && _phase != phase) {
      unawaited(_request());
      unawaited(_requestCoworkerName());
      if (_selectedId != null) unawaited(_request(id: _selectedId));
    }
    _phase = phase;
  }

  Future<void> _load() async {
    try {
      final chat = await AgentsChatStore.loadThread(widget.sessionKey);
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
        control is! AgentsDocumentsControl ||
        control.state.value.phase != AgentsRelayPhase.paired) {
      if (mounted && id != null && id == _selectedId) {
        setState(() => _reading = false);
      }
      return;
    }
    try {
      await (control as AgentsDocumentsControl).requestDocuments(
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
        control.state.value.phase != AgentsRelayPhase.paired) {
      return;
    }
    try {
      await control.requestAgentList();
    } catch (_) {
      /* No roster: the panel says "this coworker" and moves on. */
    }
  }

  void _receive(AgentsRelayInbound event) {
    if (!mounted) return;
    if (event is AgentsRelayAgentList) {
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
    if (event is AgentsRelayFile &&
        event.document?['session_key'] == widget.sessionKey) {
      setState(() {
        if (_adopt(event.document!)) _persist(event.document!);
      });
    }
    if (event is! AgentsRelayDocuments ||
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
      unawaited(AgentsChatStore.saveDocumentSnapshot(widget.sessionKey, doc));
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
    final rows = _rows;
    if (widget.fullPage) return _buildScreen(context, rows);
    final theme = Theme.of(context);
    final media = MediaQuery.sizeOf(context);
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
        _buildScopeFooter(context),
      ],
    );
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

  // --- the phone screen ------------------------------------------------------

  /// The full-screen form: the app's own frame ([ExpressiveScreen]), so the
  /// title, the one back target and the veil are the same ones every other
  /// screen wears. The list and the reader are the same screen, one behind the
  /// other: back leaves the reader first and the route second.
  Widget _buildScreen(BuildContext context, List<Map<String, dynamic>> rows) {
    final bool reading = _selectedId != null;
    final Map<String, dynamic>? open = _selected;
    final bool readable = open != null && open['kind'] != 'file';
    final String name = '${_documents[_selectedId]?['title'] ?? 'Document'}';
    return PopScope(
      canPop: !reading,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && reading) _deselect();
      },
      child: ExpressiveScreen(
        title: reading ? null : 'Files',
        titleWidget: reading ? _MiddleEllipsis(text: name) : null,
        onBack: reading ? _deselect : null,
        actions: reading
            ? <Widget>[
                if (readable)
                  ExpressiveIconButton(
                    hugeIcon: HugeIcons.share01,
                    tooltip: 'Share',
                    semanticsId: 'files_share',
                    onTap: () => ChatDocumentView.share(open),
                  ),
                if (readable)
                  ExpressiveIconButton(
                    hugeIcon: HugeIcons.download01,
                    tooltip: 'Save',
                    semanticsId: 'files_save',
                    onTap: () => ChatDocumentView.save(open),
                  ),
              ]
            : <Widget>[
                ExpressiveIconButton(
                  hugeIcon: _explorerOptions.grid
                      ? HugeIcons.listView
                      : HugeIcons.gridView,
                  tooltip: _explorerOptions.grid ? 'List view' : 'Grid view',
                  semanticsId: 'files_view_mode',
                  onTap: () => setState(
                    () => _explorerOptions.grid = !_explorerOptions.grid,
                  ),
                ),
                ExpressiveIconButton(
                  hugeIcon: HugeIcons.refresh,
                  tooltip: 'Refresh files',
                  semanticsId: 'files_refresh',
                  onTap: _request,
                ),
              ],
        builder: (BuildContext context) => reading
            ? _buildScreenReader(context)
            : _buildScreenList(context, rows),
      ),
    );
  }

  Widget _buildScreenList(
    BuildContext context,
    List<Map<String, dynamic>> rows,
  ) {
    final double top = MediaQuery.paddingOf(context).top;
    if (_loading) {
      return Padding(
        padding: EdgeInsets.only(top: top),
        child: const Center(child: ExpressiveLoader()),
      );
    }
    if (rows.isEmpty) {
      return _EmptyBlock(
        topInset: top,
        icon: HugeIcons.folder01,
        title: 'No files yet',
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
      phone: true,
      topInset: top + 8,
      banner: _error == null ? null : _buildErrorCard(context, _error!),
    );
  }

  Widget _buildScreenReader(BuildContext context) {
    final double top = MediaQuery.paddingOf(context).top;
    final double bottom = MediaQuery.paddingOf(context).bottom;
    if (_reading) {
      return Padding(
        padding: EdgeInsets.only(top: top),
        child: const Center(child: ExpressiveLoader()),
      );
    }
    if (_error != null) {
      return _EmptyBlock(
        topInset: top,
        icon: HugeIcons.alertCircle,
        title: 'This document could not be opened',
        detail: _error!,
        action: _PillAction(
          icon: HugeIcons.refresh,
          label: 'Try again',
          onTap: () => _request(id: _selectedId),
        ),
      );
    }
    if (_selected == null) {
      return _EmptyBlock(
        topInset: top,
        icon: HugeIcons.laptop,
        title: 'This document is not on the device yet',
        detail:
            'It is in $_owner’s container. Reading it needs the laptop to '
            'be connected.',
        action: _PillAction(
          icon: HugeIcons.refresh,
          label: 'Try again',
          onTap: () => _request(id: _selectedId),
        ),
      );
    }
    if (_file != null) {
      return ListView(
        padding: EdgeInsets.fromLTRB(16, top + 8, 16, bottom + 24),
        children: <Widget>[SandboxArtifactBlock(payload: _file!)],
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ChatDocumentView(
        document: _selected!,
        showActions: false,
        // The document starts below the bar and then travels up behind it,
        // which is the only way the veil has anything to veil.
        topInset: top + 8,
      ),
    );
  }

  // --- the dialog form -------------------------------------------------------

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
      if (AgentsChatStore.isDirty(widget.sessionKey)) 'Sync pending',
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
            child: HugeIcon(
              HugeIcons.folder01,
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
                  '$_owner · Documents',
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
          ExpressiveIconButton(
            hugeIcon: HugeIcons.refresh,
            tooltip: 'Refresh documents',
            onTap: _request,
          ),
          const SizedBox(width: 8),
          ExpressiveIconButton(
            hugeIcon: HugeIcons.cancel01,
            tooltip: 'Close',
            onTap: () => Navigator.pop(context),
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
          HugeIcon(HugeIcons.layers01, size: 12, color: color),
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
          HugeIcon(
            HugeIcons.alertCircle,
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

  /// The same message on the phone, where a band across the top would cut the
  /// veil in two: a card that scrolls with the list it belongs to.
  Widget _buildErrorCard(BuildContext context, String message) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: kBorderRadiusRow,
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: <Widget>[
          HugeIcon(
            HugeIcons.alertCircle,
            size: 18,
            color: scheme.onErrorContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
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

  /// On a narrow dialog the two panes become two views: the list, and the
  /// document with a way back to it.
  Widget _buildOnePane(BuildContext context, List<Map<String, dynamic>> rows) {
    if (_selectedId == null) return _buildList(context, rows);
    final theme = Theme.of(context);
    final title = _documents[_selectedId]?['title'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 16, 6),
          child: Row(
            children: [
              ExpressiveIconButton(
                hugeIcon: HugeIcons.arrowLeft02,
                tooltip: 'Back to the list',
                onTap: _deselect,
              ),
              const SizedBox(width: 10),
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
        icon: HugeIcons.folder01,
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
        icon: HugeIcons.laptop,
        title: 'This document is not on the device yet',
        detail:
            'It is in $_owner’s container. Reading it needs the laptop to '
            'be connected.',
        action: _PillAction(
          icon: HugeIcons.refresh,
          label: 'Try again',
          onTap: () => _request(id: _selectedId),
        ),
      );
    }
    if (_selected == null) {
      // Nothing selected is a normal state, not a hole: it says what the list
      // is for, explains the freshness marks next to each name, and offers the
      // row the agent touched last.
      final recent = rows.isEmpty ? null : rows.first;
      return _EmptyBlock(
        icon: HugeIcons.file01,
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
            : _PillAction(
                icon: _documentIcon(recent),
                label: 'Open ${recent['title']}',
                onTap: () => _select(recent),
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
      padding: EdgeInsets.fromLTRB(10, topInset, 10, 10),
      child: Row(
        children: [
          Flexible(
            child: Text(
              title,
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.m3.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.15),
              borderRadius: kBorderRadiusPill,
            ),
            child: Text(
              '$count',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One list row, in the shape every other list in the app uses (the roster, the
/// media tab): a springing surface with no border, a typed tile on the left,
/// the name on the first line, and the facts a reader cannot get anywhere else
/// on the second — where the file sits, how big it is, and how current it is.
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
    return Semantics(
      selected: selected,
      button: true,
      child: MorphTap(
        onTap: onTap,
        color: selected
            ? scheme.primary.withValues(alpha: 0.12)
            : Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: kBorderRadiusRow),
        pressedShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            _KindTile(document: document, selected: selected),
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
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: selected
                            ? FontWeight.w800
                            : FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (detail.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      style: theme.textTheme.bodyMedium?.copyWith(
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
    );
  }
}

/// The square that carries a row's type glyph: the corner of the icon targets
/// in the chrome, so a list of files and the buttons above it read as one set.
class _KindTile extends StatelessWidget {
  const _KindTile({required this.document, this.selected = false});

  final Map<String, dynamic> document;
  final bool selected;

  static const double size = 48;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected
            ? scheme.primary.withValues(alpha: 0.18)
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(size * 0.34),
      ),
      child: HugeIcon(
        _documentIcon(document),
        size: size * 0.46,
        color: selected ? scheme.primary : scheme.onSurfaceVariant,
      ),
    );
  }
}

/// The app's labelled button, with an icon from the app's own set.
class _PillAction extends StatelessWidget {
  const _PillAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final HugeIconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return MorphTap(
      onTap: onTap,
      color: scheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          HugeIcon(icon, size: 20, color: scheme.onSecondaryContainer),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.onSecondaryContainer,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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

/// The glyph for a row, from the app's own set: the kind first, then the file
/// extension (docs/DESIGN.md §5 — sheet for tables, text for markdown, braces
/// for JSON, source code for markup, and so on down the list).
HugeIconData _documentIcon(Map<String, dynamic> document) {
  if (document['kind'] == 'table') return HugeIcons.sheet;
  if (document['kind'] == 'bar_chart') return HugeIcons.presentation01;
  if (document['kind'] != 'file') return HugeIcons.fileText;
  final name = '${document['path'] ?? document['title'] ?? ''}'.toLowerCase();
  final suffix = name.contains('.') ? name.split('.').last : '';
  return switch (suffix) {
    'pdf' => HugeIcons.pdf01,
    'csv' || 'tsv' || 'xlsx' || 'xls' || 'ods' => HugeIcons.sheet,
    'pptx' || 'ppt' || 'key' => HugeIcons.presentation01,
    'md' || 'markdown' || 'rst' => HugeIcons.fileText,
    'json' || 'yaml' || 'yml' || 'toml' => HugeIcons.braces,
    'html' ||
    'htm' ||
    'xml' ||
    'css' ||
    'js' ||
    'ts' ||
    'dart' ||
    'py' ||
    'c' ||
    'cpp' ||
    'go' ||
    'rs' => HugeIcons.sourceCode,
    'sh' || 'bash' || 'zsh' || 'fish' => HugeIcons.terminal,
    'png' ||
    'jpg' ||
    'jpeg' ||
    'gif' ||
    'webp' ||
    'bmp' ||
    'svg' => HugeIcons.image01,
    'mp4' || 'mov' || 'webm' || 'mkv' => HugeIcons.video01,
    'zip' || 'tar' || 'gz' || 'tgz' || 'rar' || '7z' => HugeIcons.zip01,
    'db' || 'sqlite' || 'sql' => HugeIcons.database01,
    'epub' => HugeIcons.bookOpen01,
    _ => HugeIcons.file01,
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
    this.topInset = 0,
  });

  final HugeIconData icon;
  final String title;
  final String detail;
  final Widget? action;

  /// Room the floating bar needs above the block, so a short empty state is
  /// centred in what the reader can actually see.
  final double topInset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(24, 24 + topInset, 24, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              HugeIcon(
                icon,
                size: 56,
                color: m3.onSurfaceVariant.withValues(alpha: 0.4),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
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

/// A screen title that loses its middle, not its end.
///
/// A file name ends with the part that says what it is — `.md`, `.xlsx` — and
/// ellipsising from the right throws exactly that away. Cut from the middle and
/// both ends survive (docs/DESIGN.md §2).
class _MiddleEllipsis extends StatelessWidget {
  const _MiddleEllipsis({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final TextStyle? style = Theme.of(context).textTheme.headlineSmall
        ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.5);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double scale = MediaQuery.textScalerOf(context).scale(1);
        double width(String candidate) {
          final TextPainter painter = TextPainter(
            text: TextSpan(text: candidate, style: style),
            maxLines: 1,
            textDirection: Directionality.of(context),
            textScaler: TextScaler.linear(scale),
          )..layout();
          return painter.width;
        }

        String shown = text;
        if (width(shown) > constraints.maxWidth) {
          int head = text.length ~/ 2;
          int tail = text.length - head;
          while (head + tail > 4) {
            if (head > tail) {
              head--;
            } else {
              tail--;
            }
            shown =
                '${text.substring(0, head)}…${text.substring(text.length - tail)}';
            if (width(shown) <= constraints.maxWidth) break;
          }
        }
        return Text(shown, style: style, maxLines: 1, softWrap: false);
      },
    );
  }
}
