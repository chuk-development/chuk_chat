// lib/widgets/workspace_panel.dart
import 'dart:async';

import 'package:chuk_chat/utils/io_helper.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:chuk_chat/constants/file_constants.dart';
import 'package:chuk_chat/models/workspace_model.dart';
import 'package:chuk_chat/services/workspace_storage_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/workspace_file_viewer.dart';

/// Right-side panel for workspace settings (Instructions + Files)
class WorkspacePanel extends StatefulWidget {
  final String workspaceId;
  final VoidCallback? onClose;

  const WorkspacePanel({super.key, required this.workspaceId, this.onClose});

  @override
  State<WorkspacePanel> createState() => _WorkspacePanelState();
}

class _WorkspacePanelState extends State<WorkspacePanel> {
  Workspace? _project;
  StreamSubscription<void>? _projectSub;
  bool _isInstructionsExpanded = false;
  bool _isFilesExpanded = true;
  bool _isEditingInstructions = false;
  final TextEditingController _instructionsController = TextEditingController();

  // Upload state
  bool _isUploadingFile = false;
  String? _uploadFileName;
  String _uploadStatus = ''; // 'uploading', 'converting', ''
  double _uploadProgress = 0.0;

  @override
  void initState() {
    super.initState();
    _loadProject();
    _projectSub = WorkspaceStorageService.changes.listen((_) {
      if (mounted) _loadProject();
    });
  }

  @override
  void dispose() {
    _projectSub?.cancel();
    _instructionsController.dispose();
    super.dispose();
  }

  void _loadProject() {
    final workspace = WorkspaceStorageService.getWorkspace(widget.workspaceId);
    if (mounted) {
      setState(() {
        _project = workspace;
        _instructionsController.text = workspace?.customSystemPrompt ?? '';
      });
    }
  }

  Future<void> _saveInstructions() async {
    if (_project == null) return;

    try {
      await WorkspaceStorageService.updateProject(
        widget.workspaceId,
        customSystemPrompt: _instructionsController.text.trim(),
      );
      if (mounted) {
        setState(() => _isEditingInstructions = false);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to save: $e')));
      }
    }
  }

  Future<void> _pickAndUploadFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: FileConstants.allowedExtensions,
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      if (file.path == null) return;

      final filePath = file.path!;
      final fileName = file.name;
      final fileType = fileName.split('.').last;

      // Start upload with progress tracking
      setState(() {
        _isUploadingFile = true;
        _uploadFileName = fileName;
        _uploadStatus = 'uploading';
        _uploadProgress = 0.0;
      });

      final fileBytes = await File(filePath).readAsBytes();

      // Upload with progress callback
      await WorkspaceStorageService.uploadFile(
        widget.workspaceId,
        fileName,
        fileBytes,
        fileType,
        filePath: filePath,
        generateMarkdown: true,
        onUploadProgress: (progress) {
          if (mounted) {
            setState(() => _uploadProgress = progress);
          }
        },
        onConversionStart: () {
          if (mounted) {
            setState(() => _uploadStatus = 'converting');
          }
        },
      );

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Uploaded: $fileName')));
      }
    } catch (e) {
      if (mounted) {
        // Extract clean error message from StateError
        String errorMessage;
        if (e is StateError) {
          errorMessage = e.message;
        } else {
          errorMessage = e.toString();
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: Colors.red[700],
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUploadingFile = false;
          _uploadFileName = null;
          _uploadStatus = '';
          _uploadProgress = 0.0;
        });
      }
    }
  }

  Future<void> _deleteFile(WorkspaceFile file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete File'),
        content: Text('Delete "${file.fileName}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await WorkspaceStorageService.deleteFile(widget.workspaceId, file.id);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;
    final borderColor = iconFg.withAlpha(30);
    final bgColor = Theme.of(context).scaffoldBackgroundColor;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_project == null) {
      return Container(
        width: 300,
        decoration: BoxDecoration(
          color: bgColor,
          border: Border(left: BorderSide(color: borderColor)),
        ),
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    final displayColor = _project!.displayColor;

    return Container(
      width: 300,
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(left: BorderSide(color: borderColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with workspace color accent
          Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: displayColor, width: 3)),
            ),
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // Workspace avatar
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: displayColor.withValues(alpha: isDark ? 0.2 : 0.12),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(
                    _project!.displayIcon,
                    color: displayColor,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _project!.name,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: iconFg,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.onClose != null)
                  IconButton(
                    icon: Icon(Icons.close, color: iconFg, size: 20),
                    onPressed: widget.onClose,
                    tooltip: 'Close workspace panel',
                  ),
              ],
            ),
          ),

          Divider(height: 1, color: borderColor),

          // Scrollable content
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Instructions Section
                  _buildSection(
                    title: 'Instructions',
                    subtitle: 'Add instructions to tailor AI responses',
                    isExpanded: _isInstructionsExpanded,
                    onToggle: () => setState(
                      () => _isInstructionsExpanded = !_isInstructionsExpanded,
                    ),
                    onAdd: () => setState(() {
                      _isInstructionsExpanded = true;
                      _isEditingInstructions = true;
                    }),
                    hasContent: _project!.hasCustomPrompt,
                    child: _buildInstructionsContent(),
                    accentColor: displayColor,
                  ),

                  const SizedBox(height: 16),

                  // Files Section
                  _buildSection(
                    title: 'Files',
                    subtitle: 'Add documents to reference in this workspace',
                    isExpanded: _isFilesExpanded,
                    onToggle: () =>
                        setState(() => _isFilesExpanded = !_isFilesExpanded),
                    onAdd: _isUploadingFile ? null : _pickAndUploadFile,
                    hasContent: _project!.files.isNotEmpty,
                    child: _buildFilesContent(),
                    accentColor: displayColor,
                    badge: _project!.fileCount > 0
                        ? '${_project!.fileCount}'
                        : null,
                  ),
                ],
              ),
            ),
          ),

          // Footer with encryption indicator
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: borderColor)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.lock_outlined,
                  size: 12,
                  color: iconFg.withAlpha(80),
                ),
                const SizedBox(width: 4),
                Text(
                  'End-to-end encrypted',
                  style: TextStyle(fontSize: 11, color: iconFg.withAlpha(80)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required String subtitle,
    required bool isExpanded,
    required VoidCallback onToggle,
    required VoidCallback? onAdd,
    required bool hasContent,
    required Widget child,
    required Color accentColor,
    String? badge,
  }) {
    final iconFg = Theme.of(context).resolvedIconColor;
    final borderColor = iconFg.withAlpha(30);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section header
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                title,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: iconFg,
                                ),
                              ),
                              if (badge != null) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: accentColor.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    badge,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: accentColor,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          if (!hasContent && !isExpanded)
                            Text(
                              subtitle,
                              style: TextStyle(
                                fontSize: 12,
                                color: iconFg.withAlpha(150),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (onAdd != null)
                  IconButton(
                    icon: Icon(Icons.add, color: accentColor, size: 20),
                    onPressed: onAdd,
                    tooltip: 'Add',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                  ),
              ],
            ),
          ),
        ),

        // Section content
        if (isExpanded || hasContent)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: iconFg.withAlpha(10),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: borderColor),
            ),
            child: child,
          ),
      ],
    );
  }

  Widget _buildInstructionsContent() {
    final iconFg = Theme.of(context).resolvedIconColor;

    if (_isEditingInstructions) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _instructionsController,
            maxLines: 6,
            decoration: InputDecoration(
              hintText: 'Enter custom instructions for the AI...',
              hintStyle: TextStyle(color: iconFg.withValues(alpha: 0.4)),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(
                  color: iconFg.withValues(alpha: 0.15),
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(
                  color: iconFg.withValues(alpha: 0.15),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(
                  color: iconFg.withValues(alpha: 0.3),
                ),
              ),
              contentPadding: const EdgeInsets.all(12),
            ),
            style: TextStyle(fontSize: 13, color: iconFg, height: 1.5),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () {
                  _instructionsController.text =
                      _project?.customSystemPrompt ?? '';
                  setState(() => _isEditingInstructions = false);
                },
                child: Text(
                  'Cancel',
                  style: TextStyle(color: iconFg.withValues(alpha: 0.6)),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _saveInstructions,
                child: const Text('Save'),
              ),
            ],
          ),
        ],
      );
    }

    if (!_project!.hasCustomPrompt) {
      return InkWell(
        onTap: () => setState(() => _isEditingInstructions = true),
        child: Text(
          'Click to add instructions...',
          style: TextStyle(
            fontSize: 13,
            color: iconFg.withAlpha(150),
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }

    return InkWell(
      onTap: () => setState(() => _isEditingInstructions = true),
      child: Text(
        _project!.customSystemPrompt!,
        style: TextStyle(fontSize: 13, color: iconFg),
        maxLines: 6,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildFilesContent() {
    final iconFg = Theme.of(context).resolvedIconColor;
    final accentColor = _project!.displayColor;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_isUploadingFile) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // File name
            Row(
              children: [
                Icon(Icons.insert_drive_file, size: 16, color: accentColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _uploadFileName ?? 'File',
                    style: TextStyle(fontSize: 12, color: iconFg),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Status text
            Text(
              _uploadStatus == 'uploading'
                  ? 'Encrypting and uploading...'
                  : _uploadStatus == 'converting'
                  ? 'Converting to markdown...'
                  : 'Processing...',
              style: TextStyle(fontSize: 11, color: iconFg.withAlpha(150)),
            ),
            const SizedBox(height: 8),

            // Progress indicator
            if (_uploadStatus == 'uploading')
              Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _uploadProgress,
                      backgroundColor: iconFg.withAlpha(30),
                      valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                      minHeight: 6,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${(_uploadProgress * 100).toStringAsFixed(0)}%',
                    style: TextStyle(
                      fontSize: 10,
                      color: iconFg.withAlpha(150),
                    ),
                  ),
                ],
              )
            else
              Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'This may take a moment...',
                    style: TextStyle(
                      fontSize: 10,
                      color: iconFg.withAlpha(120),
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
          ],
        ),
      );
    }

    if (_project!.files.isEmpty) {
      return InkWell(
        onTap: _pickAndUploadFile,
        child: Column(
          children: [
            Icon(Icons.upload_file, size: 40, color: iconFg.withAlpha(100)),
            const SizedBox(height: 8),
            Text(
              'Add PDFs, documents, or other text\nto reference in this workspace.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: iconFg.withAlpha(150)),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        ..._project!.files.map((file) => _buildFileItem(file, isDark)),
        const SizedBox(height: 8),
        InkWell(
          onTap: _pickAndUploadFile,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add, size: 16, color: accentColor.withAlpha(180)),
                const SizedBox(width: 4),
                Text(
                  'Add more files',
                  style: TextStyle(
                    fontSize: 12,
                    color: accentColor.withAlpha(180),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _openFileViewer(WorkspaceFile file) {
    WorkspaceFileViewer.show(context, file, widget.workspaceId);
  }

  Widget _buildFileItem(WorkspaceFile file, bool isDark) {
    final iconFg = Theme.of(context).resolvedIconColor;
    final accentColor = _project!.displayColor;

    return InkWell(
      onTap: () => _openFileViewer(file),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: accentColor.withValues(alpha: isDark ? 0.15 : 0.1),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Icon(file.fileIcon, size: 16, color: accentColor),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.fileName,
                    style: TextStyle(fontSize: 13, color: iconFg),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Row(
                    children: [
                      Text(
                        file.fileSizeFormatted,
                        style: TextStyle(
                          fontSize: 11,
                          color: iconFg.withAlpha(150),
                        ),
                      ),
                      if (file.hasMarkdownSummary) ...[
                        const SizedBox(width: 8),
                        Icon(
                          Icons.check_circle,
                          size: 12,
                          color: Colors.green[600],
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.close, size: 16, color: iconFg.withAlpha(150)),
              onPressed: () => _deleteFile(file),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              tooltip: 'Remove file',
            ),
          ],
        ),
      ),
    );
  }
}
