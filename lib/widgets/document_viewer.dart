// lib/widgets/document_viewer.dart
import 'package:flutter/material.dart';

import 'package:chuk_chat/widgets/app_notification.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/expressive_screen.dart';
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
    AppNotifications.show(
      context,
      'Content copied to clipboard',
      duration: const Duration(seconds: 2),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = Theme.of(context).scaffoldBackgroundColor;

    return ExpressiveScreen(
      backgroundColor: bgColor,
      title: widget.fileName,
      actions: <Widget>[
        if (!_isEditing)
          ExpressiveIconButton(
            hugeIcon: HugeIcons.copy01,
            onTap: _copyToClipboard,
            tooltip: 'Copy to clipboard',
          ),
        ExpressiveIconButton(
          hugeIcon: _isEditing ? HugeIcons.view : HugeIcons.edit02,
          onTap: () {
            setState(() {
              _isEditing = !_isEditing;
            });
          },
          tooltip: _isEditing ? 'View mode' : 'Edit mode',
        ),
      ],
      builder: (BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.paddingOf(context).top + 16,
          16,
          MediaQuery.paddingOf(context).bottom + 16,
        ),
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
