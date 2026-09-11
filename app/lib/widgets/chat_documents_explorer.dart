part of 'chat_documents_panel.dart';

class _ExplorerOptions {
  String query = '';
  String scope = 'All';
  List<String> folder = [];
  bool grid = false;
}

/// A view of the real catalog, never a second filesystem or fabricated tree.
class _DocumentExplorer extends StatefulWidget {
  const _DocumentExplorer({
    required this.documents,
    required this.owner,
    required this.selectedId,
    required this.onSelect,
    required this.options,
  });
  final List<Map<String, dynamic>> documents;
  final String owner;
  final String? selectedId;
  final ValueChanged<Map<String, dynamic>> onSelect;
  final _ExplorerOptions options;

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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
                    prefixIcon: const AppIcon(Icons.search_rounded),
                    suffixIcon: query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            onPressed: () => setState(() {
                              _search.clear();
                              options.query = '';
                            }),
                            icon: const AppIcon(Icons.close_rounded),
                          ),
                    filled: true,
                    fillColor: scheme.surfaceContainerLow,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              IconButton(
                tooltip: options.grid ? 'List view' : 'Grid view',
                onPressed: () => setState(() => options.grid = !options.grid),
                icon: AppIcon(
                  options.grid
                      ? Icons.view_list_outlined
                      : Icons.grid_view_rounded,
                ),
              ),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              for (final scope in ['All', 'Saved', 'Workspace'])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(scope),
                    selected: options.scope == scope,
                    onSelected: (_) => setState(() {
                      options.scope = scope;
                      options.folder = [];
                    }),
                  ),
                ),
            ],
          ),
        ),
        if (options.scope == 'Workspace' && query.isEmpty)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: () => setState(() => options.folder = []),
                  icon: const AppIcon(Icons.folder_open_outlined, size: 18),
                  label: const Text('Workspace'),
                ),
                for (var i = 0; i < options.folder.length; i++) ...[
                  const AppIcon(Icons.chevron_right, size: 16),
                  TextButton(
                    onPressed: () => setState(
                      () =>
                          options.folder = options.folder.take(i + 1).toList(),
                    ),
                    child: Text(options.folder[i]),
                  ),
                ],
              ],
            ),
          ),
        Expanded(
          child: files.isEmpty && folderNames.isEmpty
              ? _EmptyBlock(
                  icon: query.isEmpty
                      ? Icons.folder_open_outlined
                      : Icons.search_off_rounded,
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
                          172 *
                          MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
                    ),
                    itemCount: folderNames.length + files.length,
                    itemBuilder: (context, index) => index < folderNames.length
                        ? _folder(
                            folderNames[index],
                            folders[folderNames[index]]!,
                            grid: true,
                          )
                        : _FileGridTile(
                            document: files[index - folderNames.length],
                            onTap: () => widget.onSelect(
                              files[index - folderNames.length],
                            ),
                          ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  itemCount: folderNames.length + files.length,
                  itemBuilder: (context, index) {
                    if (index < folderNames.length) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _folder(
                          folderNames[index],
                          folders[folderNames[index]]!,
                        ),
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
                                .where(
                                  (row) => (row['kind'] == 'file') == isFile,
                                )
                                .length,
                            topInset: i == 0 ? 4 : 20,
                          ),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _DocumentRow(
                            document: doc,
                            selected: widget.selectedId == doc['id'],
                            onTap: () => widget.onSelect(doc),
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _folder(String name, int count, {bool grid = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => setState(() => options.folder = [...options.folder, name]),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: grid
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppIcon(
                      Icons.folder_rounded,
                      color: scheme.primary,
                      size: 40,
                    ),
                    const Spacer(),
                    Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
                    Text(
                      '$count files',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                )
              : Row(
                  children: [
                    AppIcon(
                      Icons.folder_rounded,
                      color: scheme.primary,
                      size: 32,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text('$count'),
                    const SizedBox(width: 8),
                    const AppIcon(Icons.chevron_right, size: 20),
                  ],
                ),
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
    final scheme = Theme.of(context).colorScheme;
    final title = '${document['title'] ?? document['path'] ?? ''}';
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppIcon(_documentIcon(document), color: scheme.primary, size: 38),
              const Spacer(),
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                _sizeLabel(document) ?? _kindLabel(document),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
