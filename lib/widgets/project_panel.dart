// lib/widgets/project_panel.dart
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:chuk_chat/models/project_model.dart';
import 'package:chuk_chat/services/project_storage_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

/// Right-side panel for project settings (Instructions + Files)
class ProjectPanel extends StatefulWidget {
  final String projectId;
  final VoidCallback? onClose;

  const ProjectPanel({
    super.key,
    required this.projectId,
    this.onClose,
  });

  @override
  State<ProjectPanel> createState() => _ProjectPanelState();
}

class _ProjectPanelState extends State<ProjectPanel> {
  Project? _project;
  StreamSubscription<void>? _projectSub;
  bool _isInstructionsExpanded = false;
  bool _isFilesExpanded = true;
  bool _isEditingInstructions = false;
  final TextEditingController _instructionsController = TextEditingController();
  bool _isUploadingFile = false;

  @override
  void initState() {
    super.initState();
    _loadProject();
    _projectSub = ProjectStorageService.changes.listen((_) {
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
    final project = ProjectStorageService.getProject(widget.projectId);
    if (mounted) {
      setState(() {
        _project = project;
        _instructionsController.text = project?.customSystemPrompt ?? '';
      });
    }
  }

  Future<void> _saveInstructions() async {
    if (_project == null) return;

    try {
      await ProjectStorageService.updateProject(
        widget.projectId,
        customSystemPrompt: _instructionsController.text.trim(),
      );
      if (mounted) {
        setState(() => _isEditingInstructions = false);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
      }
    }
  }

  Future<void> _pickAndUploadFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'txt', 'md', 'json', 'yaml', 'yml', 'csv', 'xml',
          'dart', 'js', 'ts', 'py', 'java', 'cpp', 'c', 'h',
          'rs', 'go', 'rb', 'php', 'swift', 'kt',
          'html', 'htm', 'css', 'scss',
        ],
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      if (file.path == null) return;

      setState(() => _isUploadingFile = true);

      final fileBytes = await File(file.path!).readAsBytes();
      final fileName = file.name;
      final fileType = fileName.split('.').last;

      await ProjectStorageService.uploadFile(
        widget.projectId,
        fileName,
        fileBytes,
        fileType,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Uploaded: $fileName')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploadingFile = false);
    }
  }

  Future<void> _deleteFile(ProjectFile file) async {
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
        await ProjectStorageService.deleteFile(widget.projectId, file.id);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Delete failed: $e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;
    final borderColor = iconFg.withAlpha(30);
    final bgColor = Theme.of(context).scaffoldBackgroundColor;

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

    return Container(
      width: 300,
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(left: BorderSide(color: borderColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _project!.name,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
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
                    tooltip: 'Close project panel',
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
                    onToggle: () => setState(() =>
                      _isInstructionsExpanded = !_isInstructionsExpanded),
                    onAdd: () => setState(() {
                      _isInstructionsExpanded = true;
                      _isEditingInstructions = true;
                    }),
                    hasContent: _project!.hasCustomPrompt,
                    child: _buildInstructionsContent(),
                  ),

                  const SizedBox(height: 16),

                  // Files Section
                  _buildSection(
                    title: 'Files',
                    subtitle: 'Add documents to reference in this project',
                    isExpanded: _isFilesExpanded,
                    onToggle: () => setState(() =>
                      _isFilesExpanded = !_isFilesExpanded),
                    onAdd: _isUploadingFile ? null : _pickAndUploadFile,
                    hasContent: _project!.files.isNotEmpty,
                    child: _buildFilesContent(),
                  ),
                ],
              ),
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: iconFg,
                        ),
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
                ),
                if (onAdd != null)
                  IconButton(
                    icon: Icon(Icons.add, color: iconFg, size: 20),
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
              borderRadius: BorderRadius.circular(8),
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
              hintStyle: TextStyle(color: iconFg.withAlpha(100)),
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
            style: TextStyle(fontSize: 13, color: iconFg),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () {
                  _instructionsController.text = _project?.customSystemPrompt ?? '';
                  setState(() => _isEditingInstructions = false);
                },
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
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

    if (_isUploadingFile) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (_project!.files.isEmpty) {
      return InkWell(
        onTap: _pickAndUploadFile,
        child: Column(
          children: [
            Icon(
              Icons.upload_file,
              size: 40,
              color: iconFg.withAlpha(100),
            ),
            const SizedBox(height: 8),
            Text(
              'Add PDFs, documents, or other text\nto reference in this project.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: iconFg.withAlpha(150),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        ..._project!.files.map((file) => _buildFileItem(file)),
        const SizedBox(height: 8),
        InkWell(
          onTap: _pickAndUploadFile,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add, size: 16, color: iconFg.withAlpha(150)),
                const SizedBox(width: 4),
                Text(
                  'Add more files',
                  style: TextStyle(
                    fontSize: 12,
                    color: iconFg.withAlpha(150),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFileItem(ProjectFile file) {
    final iconFg = Theme.of(context).resolvedIconColor;
    final accentColor = Theme.of(context).colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(file.fileIcon, size: 20, color: accentColor),
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
                Text(
                  file.fileSizeFormatted,
                  style: TextStyle(
                    fontSize: 11,
                    color: iconFg.withAlpha(150),
                  ),
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
    );
  }
}
