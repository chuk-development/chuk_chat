// lib/widgets/document_viewer.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:chuk_chat/widgets/markdown_message.dart';

/// Document viewer for markdown-converted files
class DocumentViewer extends StatefulWidget {
  const DocumentViewer({
    super.key,
    required this.fileName,
    required this.markdownContent,
  });

  final String fileName;
  final String markdownContent;

  @override
  State<DocumentViewer> createState() => _DocumentViewerState();
}

class _DocumentViewerState extends State<DocumentViewer> {
  bool _isEditing = false;
  late TextEditingController _controller;
  late ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.markdownContent);
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _copyToClipboard() {
    Clipboard.setData(ClipboardData(text: widget.markdownContent));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Content copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final iconColor = Theme.of(context).colorScheme.onSurface;
    final bgColor = Theme.of(context).scaffoldBackgroundColor;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        title: Text(
          widget.fileName,
          style: TextStyle(color: iconColor),
        ),
        leading: IconButton(
          icon: Icon(Icons.close, color: iconColor),
          onPressed: () => Navigator.of(context).pop(),
          tooltip: 'Close',
        ),
        actions: [
          if (!_isEditing)
            IconButton(
              icon: Icon(Icons.copy, color: iconColor),
              onPressed: _copyToClipboard,
              tooltip: 'Copy to clipboard',
            ),
          IconButton(
            icon: Icon(
              _isEditing ? Icons.visibility : Icons.edit,
              color: iconColor,
            ),
            onPressed: () {
              setState(() {
                _isEditing = !_isEditing;
              });
            },
            tooltip: _isEditing ? 'View mode' : 'Edit mode',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: _isEditing ? _buildEditView() : _buildMarkdownView(),
      ),
    );
  }

  Widget _buildMarkdownView() {
    return SingleChildScrollView(
      controller: _scrollController,
      child: MarkdownMessage(
        text: widget.markdownContent,
        textColor: Theme.of(context).colorScheme.onSurface,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      ),
    );
  }

  Widget _buildEditView() {
    return TextField(
      controller: _controller,
      maxLines: null,
      expands: true,
      style: TextStyle(
        color: Theme.of(context).colorScheme.onSurface,
        fontFamily: 'monospace',
        fontSize: 14,
      ),
      decoration: InputDecoration(
        border: InputBorder.none,
        filled: true,
        fillColor: Theme.of(context).colorScheme.surface.withValues(alpha: 0.3),
        contentPadding: const EdgeInsets.all(16),
      ),
    );
  }
}
