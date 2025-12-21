// lib/widgets/project_file_viewer.dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:chuk_chat/models/project_model.dart';
import 'package:chuk_chat/services/project_storage_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

/// Dialog to view and edit project files and their markdown summaries
class ProjectFileViewer extends StatefulWidget {
  final ProjectFile file;
  final String projectId;

  const ProjectFileViewer({
    super.key,
    required this.file,
    required this.projectId,
  });

  static Future<void> show(BuildContext context, ProjectFile file, String projectId) {
    return showDialog(
      context: context,
      builder: (context) => ProjectFileViewer(file: file, projectId: projectId),
    );
  }

  @override
  State<ProjectFileViewer> createState() => _ProjectFileViewerState();
}

class _ProjectFileViewerState extends State<ProjectFileViewer>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  bool _isLoading = true;
  String? _error;

  // Original file content
  String? _textContent;
  Uint8List? _imageBytes;

  // Markdown summary
  String? _markdownSummary;

  // Editing state
  bool _isEditingContent = false;
  bool _isEditingMarkdown = false;
  final TextEditingController _contentController = TextEditingController();
  final TextEditingController _markdownController = TextEditingController();

  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _markdownSummary = widget.file.markdownSummary;
    _markdownController.text = _markdownSummary ?? '';
    _loadFileContent();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _contentController.dispose();
    _markdownController.dispose();
    super.dispose();
  }

  Future<void> _loadFileContent() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final bytes = await ProjectStorageService.downloadFile(
        widget.projectId,
        widget.file.id,
      );

      if (widget.file.isImage) {
        _imageBytes = bytes;
      } else {
        _textContent = utf8.decode(bytes, allowMalformed: true);
        _contentController.text = _textContent ?? '';
      }

      setState(() => _isLoading = false);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _saveContent() async {
    if (_isSaving) return;

    setState(() => _isSaving = true);

    try {
      final newContent = _contentController.text;
      final newBytes = Uint8List.fromList(utf8.encode(newContent));

      await ProjectStorageService.updateFileContent(
        widget.projectId,
        widget.file.id,
        newBytes,
      );

      _textContent = newContent;
      setState(() => _isEditingContent = false);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File saved')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
      }
    } finally {
      setState(() => _isSaving = false);
    }
  }

  Future<void> _saveMarkdown() async {
    if (_isSaving) return;

    setState(() => _isSaving = true);

    try {
      final newMarkdown = _markdownController.text.trim();

      await ProjectStorageService.updateFileMarkdown(
        widget.projectId,
        widget.file.id,
        newMarkdown.isEmpty ? null : newMarkdown,
      );

      _markdownSummary = newMarkdown.isEmpty ? null : newMarkdown;
      setState(() => _isEditingMarkdown = false);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Markdown saved')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
      }
    } finally {
      setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;
    final bgColor = Theme.of(context).scaffoldBackgroundColor;
    final accentColor = Theme.of(context).colorScheme.primary;
    final screenSize = MediaQuery.of(context).size;

    final dialogWidth = screenSize.width * 0.8;
    final dialogHeight = screenSize.height * 0.85;

    return Dialog(
      backgroundColor: bgColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: dialogWidth.clamp(400.0, 1000.0),
        height: dialogHeight.clamp(400.0, 800.0),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Icon(widget.file.fileIcon, color: accentColor, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.file.fileName,
                        style: TextStyle(
                          color: iconFg,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        widget.file.fileSizeFormatted,
                        style: TextStyle(
                          color: iconFg.withValues(alpha: 0.6),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close, color: iconFg),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // Tab bar
            TabBar(
              controller: _tabController,
              labelColor: accentColor,
              unselectedLabelColor: iconFg.withValues(alpha: 0.6),
              indicatorColor: accentColor,
              tabs: [
                Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(widget.file.isImage ? Icons.image : Icons.code, size: 18),
                      const SizedBox(width: 8),
                      const Text('Original'),
                    ],
                  ),
                ),
                Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.description, size: 18),
                      const SizedBox(width: 8),
                      const Text('Markdown'),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // Tab content
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildOriginalContent(iconFg, accentColor),
                  _buildMarkdownContent(iconFg, accentColor),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOriginalContent(Color iconFg, Color accentColor) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, color: Colors.red, size: 48),
            const SizedBox(height: 16),
            Text(
              'Failed to load file',
              style: TextStyle(color: iconFg, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: iconFg.withValues(alpha: 0.6), fontSize: 12),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadFileContent,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    // Image content
    if (widget.file.isImage && _imageBytes != null) {
      return InteractiveViewer(
        minScale: 0.5,
        maxScale: 4.0,
        child: Center(
          child: Image.memory(
            _imageBytes!,
            fit: BoxFit.contain,
          ),
        ),
      );
    }

    // Text content
    if (_textContent != null) {
      return Column(
        children: [
          // Edit toggle
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (_isEditingContent) ...[
                TextButton(
                  onPressed: () {
                    _contentController.text = _textContent ?? '';
                    setState(() => _isEditingContent = false);
                  },
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _isSaving ? null : _saveContent,
                  child: _isSaving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save'),
                ),
              ] else
                IconButton(
                  icon: Icon(Icons.edit, color: iconFg),
                  onPressed: () => setState(() => _isEditingContent = true),
                  tooltip: 'Edit',
                ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: iconFg.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: iconFg.withValues(alpha: 0.2)),
              ),
              child: _isEditingContent
                  ? TextField(
                      controller: _contentController,
                      maxLines: null,
                      expands: true,
                      style: TextStyle(
                        color: iconFg,
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.all(12),
                      ),
                    )
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        _textContent!,
                        style: TextStyle(
                          color: iconFg,
                          fontFamily: 'monospace',
                          fontSize: 13,
                        ),
                      ),
                    ),
            ),
          ),
        ],
      );
    }

    return Center(
      child: Text(
        'No content available',
        style: TextStyle(color: iconFg.withValues(alpha: 0.6)),
      ),
    );
  }

  Widget _buildMarkdownContent(Color iconFg, Color accentColor) {
    return Column(
      children: [
        // Edit toggle
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (_isEditingMarkdown) ...[
              TextButton(
                onPressed: () {
                  _markdownController.text = _markdownSummary ?? '';
                  setState(() => _isEditingMarkdown = false);
                },
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _isSaving ? null : _saveMarkdown,
                child: _isSaving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Save'),
              ),
            ] else
              IconButton(
                icon: Icon(Icons.edit, color: iconFg),
                onPressed: () => setState(() => _isEditingMarkdown = true),
                tooltip: 'Edit',
              ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: iconFg.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: iconFg.withValues(alpha: 0.2)),
            ),
            child: _isEditingMarkdown
                ? TextField(
                    controller: _markdownController,
                    maxLines: null,
                    expands: true,
                    style: TextStyle(color: iconFg, fontSize: 14),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.all(12),
                      hintText: 'Enter markdown summary...',
                      hintStyle: TextStyle(color: iconFg.withValues(alpha: 0.4)),
                    ),
                  )
                : _markdownSummary != null && _markdownSummary!.isNotEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(12),
                        child: MarkdownWidget(
                          data: _markdownSummary!,
                          selectable: true,
                          config: MarkdownConfig(
                            configs: [
                              PConfig(textStyle: TextStyle(color: iconFg, fontSize: 14)),
                              H1Config(style: TextStyle(color: iconFg, fontSize: 24, fontWeight: FontWeight.bold)),
                              H2Config(style: TextStyle(color: iconFg, fontSize: 20, fontWeight: FontWeight.bold)),
                              H3Config(style: TextStyle(color: iconFg, fontSize: 18, fontWeight: FontWeight.bold)),
                              CodeConfig(style: TextStyle(color: accentColor, fontFamily: 'monospace')),
                              PreConfig(
                                textStyle: TextStyle(color: accentColor, fontFamily: 'monospace'),
                                decoration: BoxDecoration(
                                  color: iconFg.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    : Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.description_outlined,
                              size: 48,
                              color: iconFg.withValues(alpha: 0.3),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No markdown summary yet',
                              style: TextStyle(color: iconFg.withValues(alpha: 0.6)),
                            ),
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: () => setState(() => _isEditingMarkdown = true),
                              icon: const Icon(Icons.add),
                              label: const Text('Add summary'),
                            ),
                          ],
                        ),
                      ),
          ),
        ),
      ],
    );
  }
}
