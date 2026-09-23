part of 'chat_documents_panel.dart';

class _ExplorerOptions {
  String query = '';
  String scope = 'All';
  List<String> folder = [];
  bool grid = false;
}

/// The three scopes, and the words the phone puts on the switch. The stored
/// value stays what the panel has always stored; only the label is short
/// enough for a segment at 360 px.
const List<String> _kScopes = <String>['All', 'Saved', 'Workspace'];
const List<String> _kScopeLabels = <String>['All', 'Saved', 'Files'];

/// A view of the real catalog, never a second filesystem or fabricated tree.
class _DocumentExplorer extends StatefulWidget {
  const _DocumentExplorer({
    required this.documents,
    required this.owner,
    required this.selectedId,
    required this.onSelect,
    required this.options,
    this.phone = false,
    this.topInset = 0,
    this.banner,
  });
  final List<Map<String, dynamic>> documents;
  final String owner;
  final String? selectedId;
  final ValueChanged<Map<String, dynamic>> onSelect;
  final _ExplorerOptions options;

  /// The full-screen form: one scroller that carries its own header, so the
  /// search field and the switch travel up behind the veil with the rows
  /// instead of sitting in a band of their own.
  final bool phone;

  /// Room the floating bar takes at the top of that scroller.
  final double topInset;

  /// A message that belongs to the list (a failed read, say), scrolling with
  /// it rather than cutting across the top of the screen.
  final Widget? banner;

  @override
  State<_DocumentExplorer> createState() => _DocumentExplorerState();
}

class _DocumentExplorerState extends State<_DocumentExplorer> {
  _ExplorerOptions get options => widget.options;
  late final _search = TextEditingController(text: options.query);

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<String> _parts(Map<String, dynamic> doc) =>
      '${doc['path'] ?? doc['title'] ?? ''}'
          .split('/')
          .where((part) => part.isNotEmpty && part != '.')
          .toList();

  void _setScope(String scope) => setState(() {
    options.scope = scope;
    options.folder = [];
  });

  @override
  Widget build(BuildContext context) {
    final query = options.query.trim().toLowerCase();
    final scoped = widget.documents.where((doc) {
      final isFile = doc['kind'] == 'file';
      if (options.scope == 'Saved' && isFile) return false;
      if (options.scope == 'Workspace' && !isFile) return false;
      return query.isEmpty ||
          '${doc['title'] ?? ''} ${doc['path'] ?? ''}'.toLowerCase().contains(
            query,
          );
    }).toList();
    final files = <Map<String, dynamic>>[];
    final folders = <String, int>{};
    for (final doc in scoped) {
      if (options.scope != 'Workspace' || query.isNotEmpty) {
        files.add(doc);
        continue;
      }
      final path = _parts(doc);
      if (path.length <= options.folder.length) continue;
      var matches = true;
      for (var i = 0; i < options.folder.length; i++) {
        if (path[i] != options.folder[i]) matches = false;
      }
      if (!matches) continue;
      if (path.length > options.folder.length + 1) {
        final child = path[options.folder.length];
        folders[child] = (folders[child] ?? 0) + 1;
      } else {
        files.add(doc);
      }
    }
    final folderNames = folders.keys.toList()..sort();
    final bool empty = files.isEmpty && folderNames.isEmpty;
    if (widget.phone) {
      return _buildPhone(context, files, folders, folderNames, query, empty);
    }
    return _buildWide(context, files, folders, folderNames, query, empty);
  }

  // --- the full-screen form --------------------------------------------------

  Widget _buildPhone(
    BuildContext context,
    List<Map<String, dynamic>> files,
    Map<String, int> folders,
    List<String> folderNames,
    String query,
    bool empty,
  ) {
    final double bottom = MediaQuery.paddingOf(context).bottom;
    final bool crumbs = options.scope == 'Workspace' && query.isEmpty;
    return CustomScrollView(
      slivers: <Widget>[
        SliverPadding(
          padding: EdgeInsets.fromLTRB(16, widget.topInset, 16, 4),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (widget.banner != null) ...<Widget>[
                  widget.banner!,
                  const SizedBox(height: 12),
                ],
                _SearchField(
                  controller: _search,
                  onChanged: (String value) =>
                      setState(() => options.query = value),
                  onClear: () => setState(() {
                    _search.clear();
                    options.query = '';
                  }),
                ),
                const SizedBox(height: 10),
                ConnectedGroup(
                  labels: _kScopeLabels,
                  selected: _kScopes.indexOf(options.scope),
                  margin: EdgeInsets.zero,
                  onSelected: (int i) => _setScope(_kScopes[i]),
                ),
                if (crumbs) _buildCrumbs(context),
                const SizedBox(height: 6),
              ],
            ),
          ),
        ),
        if (empty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyBlock(
              icon: query.isEmpty ? HugeIcons.folder01 : HugeIcons.search01,
              title: query.isEmpty ? 'No files here' : 'No matching files',
              detail: query.isEmpty
                  ? 'This view contains no catalogued files.'
                  : 'Try another name or path.',
            ),
          )
        else if (options.grid)
          SliverPadding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, bottom + 24),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                mainAxisExtent:
                    150 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
              ),
              delegate: SliverChildBuilderDelegate(
                (BuildContext context, int index) =>
                    _gridItem(index, files, folders, folderNames),
                childCount: folderNames.length + files.length,
              ),
            ),
          )
        else
          SliverPadding(
            padding: EdgeInsets.fromLTRB(6, 0, 6, bottom + 24),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (BuildContext context, int index) =>
                    _listItem(index, files, folders, folderNames),
                childCount: folderNames.length + files.length,
              ),
            ),
          ),
      ],
    );
  }

  /// Where in the container's tree the list is standing. The root crumb is the
  /// workspace itself; every other one is a folder that really exists in the
  /// catalog.
  Widget _buildCrumbs(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: <Widget>[
            _Crumb(
              key: const ValueKey<String>('files_crumb_root'),
              label: 'Workspace',
              icon: HugeIcons.folder01,
              onTap: () => setState(() => options.folder = []),
            ),
            for (int i = 0; i < options.folder.length; i++) ...<Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: HugeIcon(
                  HugeIcons.arrowRight01,
                  size: 14,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              _Crumb(
                key: ValueKey<String>('files_crumb_$i'),
                label: options.folder[i],
                onTap: () => setState(
                  () => options.folder = options.folder.take(i + 1).toList(),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // --- the dialog form -------------------------------------------------------

  Widget _buildWide(
    BuildContext context,
    List<Map<String, dynamic>> files,
    Map<String, int> folders,
    List<String> folderNames,
    String query,
    bool empty,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  onChanged: (value) => setState(() => options.query = value),
                  decoration: InputDecoration(
                    hintText: 'Search files',
                    prefixIcon: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: HugeIcon(HugeIcons.search01, size: 20),
                    ),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    suffixIcon: query.isEmpty
                        ? null
                        : Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ExpressiveIconButton(
                              hugeIcon: HugeIcons.cancel01,
                              tooltip: 'Clear search',
                              size: 36,
                              onTap: () => setState(() {
                                _search.clear();
                                options.query = '';
                              }),
                            ),
                          ),
                    suffixIconConstraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    filled: true,
                    fillColor: scheme.surfaceContainerHighest,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(
                        ConnectedGroup.outerRadius,
                      ),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ExpressiveIconButton(
                hugeIcon: options.grid
                    ? HugeIcons.listView
                    : HugeIcons.gridView,
                tooltip: options.grid ? 'List view' : 'Grid view',
                onTap: () => setState(() => options.grid = !options.grid),
              ),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              for (final scope in _kScopes)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(scope),
                    selected: options.scope == scope,
                    onSelected: (_) => _setScope(scope),
                  ),
                ),
            ],
          ),
        ),
        if (options.scope == 'Workspace' && query.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  _Crumb(
                    label: 'Workspace',
                    icon: HugeIcons.folder01,
                    onTap: () => setState(() => options.folder = []),
                  ),
                  for (var i = 0; i < options.folder.length; i++) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: HugeIcon(HugeIcons.arrowRight01, size: 14),
                    ),
                    _Crumb(
                      label: options.folder[i],
                      onTap: () => setState(
                        () => options.folder = options.folder
                            .take(i + 1)
                            .toList(),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        Expanded(
          child: empty
              ? _EmptyBlock(
                  icon: query.isEmpty ? HugeIcons.folder01 : HugeIcons.search01,
                  title: query.isEmpty ? 'No files here' : 'No matching files',
                  detail: query.isEmpty
                      ? 'This view contains no catalogued files.'
                      : 'Try another name or path.',
                )
              : options.grid
              ? LayoutBuilder(
                  builder: (context, constraints) => GridView.builder(
                    padding: const EdgeInsets.all(16),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: constraints.maxWidth >= 520 ? 3 : 2,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                      mainAxisExtent:
                          150 *
                          MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
                    ),
                    itemCount: folderNames.length + files.length,
                    itemBuilder: (context, index) =>
                        _gridItem(index, files, folders, folderNames),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 16),
                  itemCount: folderNames.length + files.length,
                  itemBuilder: (context, index) =>
                      _listItem(index, files, folders, folderNames),
                ),
        ),
      ],
    );
  }

  // --- the rows themselves, shared by both forms -----------------------------

  Widget _listItem(
    int index,
    List<Map<String, dynamic>> files,
    Map<String, int> folders,
    List<String> folderNames,
  ) {
    if (index < folderNames.length) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: _folder(folderNames[index], folders[folderNames[index]]!),
      );
    }
    final i = index - folderNames.length;
    final doc = files[i];
    final isFile = doc['kind'] == 'file';
    final startsGroup =
        options.scope == 'All' &&
        (i == 0 || (files[i - 1]['kind'] == 'file') != isFile);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (startsGroup)
          _GroupHeading(
            title: isFile
                ? '${widget.owner}’s container'
                : 'Saved in this chat',
            count: files
                .where((row) => (row['kind'] == 'file') == isFile)
                .length,
            topInset: i == 0 ? 4 : 20,
          ),
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: _DocumentRow(
            document: doc,
            selected: widget.selectedId == doc['id'],
            onTap: () => widget.onSelect(doc),
          ),
        ),
      ],
    );
  }

  Widget _gridItem(
    int index,
    List<Map<String, dynamic>> files,
    Map<String, int> folders,
    List<String> folderNames,
  ) => index < folderNames.length
      ? _folder(folderNames[index], folders[folderNames[index]]!, grid: true)
      : _FileGridTile(
          document: files[index - folderNames.length],
          onTap: () => widget.onSelect(files[index - folderNames.length]),
        );

  Widget _folder(String name, int count, {bool grid = false}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final Widget tile = Container(
      width: grid ? 48 : 48,
      height: grid ? 48 : 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(48 * 0.34),
      ),
      child: HugeIcon(
        HugeIcons.folder03,
        size: 22,
        color: scheme.onSurfaceVariant,
      ),
    );
    return MorphTap(
      onTap: () => setState(() => options.folder = [...options.folder, name]),
      color: grid ? scheme.surfaceContainerHigh : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: grid ? kBorderRadiusCard : kBorderRadiusRow,
      ),
      pressedShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
      padding: grid
          ? const EdgeInsets.all(14)
          : const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: grid
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                tile,
                const Spacer(),
                Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$count ${count == 1 ? 'file' : 'files'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            )
          : Row(
              children: [
                tile,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$count ${count == 1 ? 'file' : 'files'}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                HugeIcon(
                  HugeIcons.arrowRight01,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
    );
  }
}

/// One step of the workspace path. It is a target, so it is the app's own
/// target: a springing capsule, never a Material text button.
class _Crumb extends StatelessWidget {
  const _Crumb({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
  });

  final String label;
  final HugeIconData? icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return MorphTap(
      onTap: onTap,
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            HugeIcon(icon!, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// The list's search input, in the shape the roster uses: one rounded filled
/// field, the app's own glyph inside it, and a clear target that appears only
/// when there is something to clear.
class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool hasText = controller.text.isNotEmpty;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(ConnectedGroup.outerRadius),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 5, 7, 5),
        child: Row(
          children: <Widget>[
            HugeIcon(
              HugeIcons.search01,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: controller,
                onChanged: onChanged,
                textInputAction: TextInputAction.search,
                cursorColor: scheme.primary,
                style: theme.textTheme.titleMedium,
                decoration: InputDecoration(
                  isCollapsed: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  hintText: 'Search files',
                  hintStyle: theme.textTheme.titleMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                ),
              ),
            ),
            hasText
                ? ExpressiveIconButton(
                    hugeIcon: HugeIcons.cancel01,
                    onTap: onClear,
                    size: 40,
                    color: scheme.surfaceContainerHigh,
                    tooltip: 'Clear search',
                  )
                : const SizedBox(width: 8, height: 40),
          ],
        ),
      ),
    );
  }
}

class _FileGridTile extends StatelessWidget {
  const _FileGridTile({required this.document, required this.onTap});
  final Map<String, dynamic> document;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = '${document['title'] ?? document['path'] ?? ''}';
    return MorphTap(
      onTap: onTap,
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: kBorderRadiusCard),
      pressedShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _KindTile(document: document),
          const Spacer(),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _sizeLabel(document) ?? _kindLabel(document),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
