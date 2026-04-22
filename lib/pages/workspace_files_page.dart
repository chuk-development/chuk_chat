// lib/pages/workspace_files_page.dart
//
// Mobile page: all files attached to a workspace ("Projektwissen").
// The "+" FAB opens a bottom sheet with:
//   - Upload from device
//   - Take photo
//   - Pick image
//   - Create new document (inline markdown editor)

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'package:chuk_chat/constants/file_constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/workspace_model.dart';
import 'package:chuk_chat/services/workspace_message_service.dart';
import 'package:chuk_chat/services/workspace_storage_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/utils/io_helper.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/workspace_file_viewer.dart';

class WorkspaceFilesPage extends StatefulWidget {
  final String workspaceId;

  const WorkspaceFilesPage({super.key, required this.workspaceId});

  @override
  State<WorkspaceFilesPage> createState() => _WorkspaceFilesPageState();
}

class _WorkspaceFilesPageState extends State<WorkspaceFilesPage> {
  Workspace? _workspace;
  StreamSubscription<void>? _sub;
  String? _modelId;

  bool _uploading = false;
  String? _uploadName;
  double _uploadProgress = 0.0;
  String _uploadStatus = '';

  @override
  void initState() {
    super.initState();
    _load();
    _loadModel();
    _sub = WorkspaceStorageService.changes.listen((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _load() {
    final ws = WorkspaceStorageService.getWorkspace(widget.workspaceId);
    if (mounted) setState(() => _workspace = ws);
  }

  Future<void> _loadModel() async {
    final id = await UserPreferencesService.loadSelectedModel();
    if (mounted) setState(() => _modelId = id);
  }

  // ─── Upload helpers ────────────────────────────────────────────────────

  Future<void> _uploadBytes(
    String fileName,
    Uint8List bytes,
    String extension, {
    String? filePath,
  }) async {
    if (_workspace == null) return;
    final estimatedTokens = (bytes.length / 4).ceil();
    final remaining = WorkspaceMessageService.remainingFileTokenBudget(
      _workspace!,
      _modelId,
    );
    if (remaining < estimatedTokens && mounted) {
      final l = AppLocalizations.of(context)!;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l.projectContextBudgetTitle),
          content: Text(l.projectContextBudgetBody(estimatedTokens)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l.projectUploadAnyway),
            ),
          ],
        ),
      );
      if (proceed != true) return;
    }

    if (!mounted) return;
    setState(() {
      _uploading = true;
      _uploadName = fileName;
      _uploadStatus = 'uploading';
      _uploadProgress = 0.0;
    });

    try {
      await WorkspaceStorageService.uploadFile(
        widget.workspaceId,
        fileName,
        bytes,
        extension,
        filePath: filePath,
        generateMarkdown: true,
        onUploadProgress: (p) {
          if (mounted) setState(() => _uploadProgress = p);
        },
        onConversionStart: () {
          if (mounted) setState(() => _uploadStatus = 'converting');
        },
      );
      if (mounted) {
        final l = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.projectUploaded(fileName))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e is StateError ? e.message : e.toString()),
            backgroundColor: Colors.red[700],
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _uploading = false;
          _uploadName = null;
          _uploadStatus = '';
          _uploadProgress = 0.0;
        });
      }
    }
  }

  Future<void> _pickFromDevice() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: FileConstants.allowedExtensions,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.path == null) {
      if (mounted) {
        final l = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.projectNotSupportedPlatform)),
        );
      }
      return;
    }
    final bytes = await File(file.path!).readAsBytes();
    await _uploadBytes(
      file.name,
      bytes,
      file.name.contains('.') ? file.name.split('.').last : 'bin',
      filePath: file.path,
    );
  }

  Future<void> _takePhoto() async {
    try {
      final xfile = await ImagePicker().pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
      );
      if (xfile == null) return;
      final bytes = await xfile.readAsBytes();
      final name = _timestampedName('photo', 'jpg');
      await _uploadBytes(name, bytes, 'jpg', filePath: xfile.path);
    } catch (e) {
      if (mounted) {
        final l = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.projectCameraFailed(e.toString()))));
      }
    }
  }

  Future<void> _pickImage() async {
    try {
      final xfile = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
      if (xfile == null) return;
      final bytes = await xfile.readAsBytes();
      final ext =
          xfile.name.contains('.') ? xfile.name.split('.').last : 'jpg';
      await _uploadBytes(xfile.name, bytes, ext, filePath: xfile.path);
    } catch (e) {
      if (mounted) {
        final l = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.projectImagePickFailed(e.toString()))));
      }
    }
  }

  Future<void> _createDocument() async {
    final result = await Navigator.of(context).push<_DocumentDraft>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const _NewDocumentPage(),
      ),
    );
    if (result == null) return;
    final title = result.title.trim().isEmpty ? 'document' : result.title.trim();
    final safeName = title.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_');
    final fileName = safeName.toLowerCase().endsWith('.md')
        ? safeName
        : '$safeName.md';
    final body = '# $title\n\n${result.content}';
    await _uploadBytes(fileName, Uint8List.fromList(utf8.encode(body)), 'md');
  }

  String _timestampedName(String prefix, String ext) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}';
    return '$prefix-$stamp.$ext';
  }

  // ─── Add content sheet ─────────────────────────────────────────────────

  Future<void> _showAddSheet() async {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;
    final l = AppLocalizations.of(context)!;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: m3.outlineVariant,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  l.projectAddContent,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _SheetTile(
                icon: Icons.upload_file_outlined,
                label: l.projectUploadFromDevice,
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _pickFromDevice();
                },
              ),
              _SheetTile(
                icon: Icons.photo_camera_outlined,
                label: l.projectTakePhoto,
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _takePhoto();
                },
              ),
              _SheetTile(
                icon: Icons.photo_library_outlined,
                label: l.projectPickImage,
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _pickImage();
                },
              ),
              _SheetTile(
                icon: Icons.note_add_outlined,
                label: l.projectCreateDocument,
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _createDocument();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── File actions ──────────────────────────────────────────────────────

  Future<void> _deleteFile(WorkspaceFile file) async {
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.projectDeleteFileTitle),
        content: Text(l.projectDeleteFileBody(file.fileName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(l.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await WorkspaceStorageService.deleteFile(widget.workspaceId, file.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.projectDeleteFailed(e.toString()))));
      }
    }
  }

  // ─── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;
    final l = AppLocalizations.of(context)!;

    final ws = _workspace;
    if (ws == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l.projectKnowledge)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: Text(l.projectKnowledge),
        backgroundColor: cs.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: CustomScrollView(
        slivers: [
          if (_uploading)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: _UploadProgress(
                  fileName: _uploadName ?? '',
                  status: _uploadStatus,
                  progress: _uploadProgress,
                  color: ws.displayColor,
                ),
              ),
            ),
          if (ws.files.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.folder_open_outlined,
                        size: 64,
                        color: m3.onSurfaceVariant.withValues(alpha: 0.4),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        l.projectNoFiles,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: m3.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
              sliver: SliverList.separated(
                itemCount: ws.files.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  final file = ws.files[i];
                  return _FileTile(
                    file: file,
                    workspaceId: widget.workspaceId,
                    color: ws.displayColor,
                    onDelete: () => _deleteFile(file),
                  );
                },
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _uploading ? null : _showAddSheet,
        icon: const Icon(Icons.add),
        label: Text(l.projectAddContent),
        backgroundColor: cs.primary,
        foregroundColor: cs.onPrimary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
        ),
      ),
    );
  }
}

// ─── Tile inside add-content bottom sheet ──────────────────────────────────

class _SheetTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _SheetTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: m3.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: cs.primaryContainer.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, size: 22, color: cs.onPrimaryContainer),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Icon(Icons.chevron_right, color: m3.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── File tile ─────────────────────────────────────────────────────────────

class _FileTile extends StatelessWidget {
  final WorkspaceFile file;
  final String workspaceId;
  final Color color;
  final VoidCallback onDelete;

  const _FileTile({
    required this.file,
    required this.workspaceId,
    required this.color,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    final isDark = theme.brightness == Brightness.dark;
    return Material(
      color: m3.surfaceContainer,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => WorkspaceFileViewer.show(context, file, workspaceId),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: isDark ? 0.18 : 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(file.fileIcon, color: color, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${file.fileSizeFormatted} · ${file.estimatedTokensFormatted}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: m3.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(Icons.more_horiz, color: m3.onSurfaceVariant),
                onPressed: () async {
                  final l = AppLocalizations.of(context)!;
                  final choice = await showModalBottomSheet<String>(
                    context: context,
                    backgroundColor: theme.colorScheme.surface,
                    shape: const RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.vertical(top: Radius.circular(24)),
                    ),
                    builder: (ctx) => SafeArea(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(height: 8),
                          ListTile(
                            leading: const Icon(Icons.visibility_outlined),
                            title: Text(l.projectView),
                            onTap: () => Navigator.pop(ctx, 'view'),
                          ),
                          ListTile(
                            leading: const Icon(
                              Icons.delete_outline,
                              color: Colors.red,
                            ),
                            title: Text(
                              l.delete,
                              style: const TextStyle(color: Colors.red),
                            ),
                            onTap: () => Navigator.pop(ctx, 'delete'),
                          ),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
                  );
                  if (choice == 'view' && context.mounted) {
                    WorkspaceFileViewer.show(context, file, workspaceId);
                  } else if (choice == 'delete') {
                    onDelete();
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Upload progress ───────────────────────────────────────────────────────

class _UploadProgress extends StatelessWidget {
  final String fileName;
  final String status;
  final double progress;
  final Color color;

  const _UploadProgress({
    required this.fileName,
    required this.status,
    required this.progress,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: m3.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.upload_file, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  fileName,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: status == 'uploading'
                ? LinearProgressIndicator(
                    value: progress,
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                  )
                : LinearProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                  ),
          ),
          const SizedBox(height: 6),
          Builder(
            builder: (ctx) {
              final l = AppLocalizations.of(ctx)!;
              return Text(
                status == 'uploading'
                    ? l.projectEncryptingUploading
                    : l.projectConvertingMarkdown,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: m3.onSurfaceVariant,
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

// ─── New document page ────────────────────────────────────────────────────

class _DocumentDraft {
  final String title;
  final String content;
  const _DocumentDraft(this.title, this.content);
}

class _NewDocumentPage extends StatefulWidget {
  const _NewDocumentPage();

  @override
  State<_NewDocumentPage> createState() => _NewDocumentPageState();
}

class _NewDocumentPageState extends State<_NewDocumentPage> {
  final _titleCtrl = TextEditingController();
  final _contentCtrl = TextEditingController();

  @override
  void dispose() {
    _titleCtrl.dispose();
    _contentCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;
    final l = AppLocalizations.of(context)!;
    final canSave =
        _titleCtrl.text.trim().isNotEmpty &&
        _contentCtrl.text.trim().isNotEmpty;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: Text(l.projectNewDocument),
        backgroundColor: cs.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          TextButton(
            onPressed: canSave
                ? () => Navigator.pop(
                    context,
                    _DocumentDraft(_titleCtrl.text, _contentCtrl.text),
                  )
                : null,
            child: Text(l.save),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _titleCtrl,
            onChanged: (_) => setState(() {}),
            style: theme.textTheme.titleMedium,
            decoration: InputDecoration(
              hintText: l.projectDocumentTitleHint,
              hintStyle: theme.textTheme.titleMedium?.copyWith(
                color: m3.onSurfaceVariant,
              ),
              filled: true,
              fillColor: m3.surfaceContainer,
              contentPadding: const EdgeInsets.all(16),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: cs.primary, width: 2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _contentCtrl,
            onChanged: (_) => setState(() {}),
            minLines: 12,
            maxLines: 30,
            decoration: InputDecoration(
              hintText: l.projectDocumentContentHint,
              hintStyle: theme.textTheme.bodyMedium?.copyWith(
                color: m3.onSurfaceVariant,
              ),
              filled: true,
              fillColor: m3.surfaceContainer,
              contentPadding: const EdgeInsets.all(16),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: cs.primary, width: 2),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
