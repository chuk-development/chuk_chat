// lib/widgets/project_selection_dropdown.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:chuk_chat/models/project_model.dart';
import 'package:chuk_chat/services/project_storage_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

class ProjectSelectionDropdown extends StatefulWidget {
  final String? selectedProjectId;
  final ValueChanged<String?> onProjectSelected;
  final FocusNode textFieldFocusNode;
  final bool isCompactMode;

  const ProjectSelectionDropdown({
    super.key,
    required this.selectedProjectId,
    required this.onProjectSelected,
    required this.textFieldFocusNode,
    this.isCompactMode = false,
  });

  @override
  State<ProjectSelectionDropdown> createState() => _ProjectSelectionDropdownState();
}

class _ProjectSelectionDropdownState extends State<ProjectSelectionDropdown> {
  List<Project> _projects = [];
  StreamSubscription<void>? _projectChangesSubscription;

  @override
  void initState() {
    super.initState();
    _loadProjects();
    _projectChangesSubscription = ProjectStorageService.changes.listen((_) {
      _loadProjects();
    });
  }

  @override
  void dispose() {
    _projectChangesSubscription?.cancel();
    super.dispose();
  }

  void _loadProjects() {
    if (mounted) {
      setState(() {
        _projects = ProjectStorageService.activeProjects;
      });
    }
  }

  String get _selectedProjectName {
    if (widget.selectedProjectId == null) {
      return '';
    }
    final project = _projects.firstWhere(
      (p) => p.id == widget.selectedProjectId,
      orElse: () => Project(
        id: '',
        name: '?',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
    return project.name;
  }

  // Show as icon-only when no project selected or in compact mode
  bool get _showIconOnly => widget.isCompactMode || widget.selectedProjectId == null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconFgColor = theme.resolvedIconColor;
    final bgColor = theme.scaffoldBackgroundColor;

    final ValueNotifier<bool> isHovered = ValueNotifier<bool>(false);
    final hasProject = widget.selectedProjectId != null;

    final buttonContent = MouseRegion(
      onEnter: (_) => isHovered.value = true,
      onExit: (_) => isHovered.value = false,
      child: ValueListenableBuilder<bool>(
        valueListenable: isHovered,
        builder: (context, hovered, child) {
          return AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
            padding: _showIconOnly
                ? const EdgeInsets.symmetric(horizontal: 8)
                : const EdgeInsets.symmetric(horizontal: 8),
            height: 36,
            constraints: _showIconOnly
                ? const BoxConstraints(minWidth: 36, maxWidth: 36)
                : const BoxConstraints(minWidth: 36, maxWidth: 140),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: hasProject
                    ? iconFgColor
                    : hovered
                        ? iconFgColor
                        : iconFgColor.withValues(alpha: 0.3),
                width: hasProject ? 1.5 : (hovered ? 1.2 : 0.8),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  hasProject ? Icons.folder : Icons.folder_outlined,
                  color: iconFgColor,
                  size: 18,
                ),
                if (!_showIconOnly) ...[
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      _selectedProjectName,
                      style: TextStyle(color: iconFgColor, fontSize: 13),
                      softWrap: false,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );

    if (_projects.isEmpty && widget.selectedProjectId == null) {
      return buttonContent;
    }

    return PopupMenuButton<String?>(
      color: bgColor,
      constraints: const BoxConstraints(minWidth: 180, maxWidth: 260),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: iconFgColor.withValues(alpha: 0.3),
        ),
      ),
      onCanceled: () {
        widget.textFieldFocusNode.requestFocus();
      },
      onSelected: (value) {
        widget.textFieldFocusNode.requestFocus();
        widget.onProjectSelected(value);
      },
      itemBuilder: (context) {
        final items = <PopupMenuEntry<String?>>[];

        // "No Project" option
        items.add(
          PopupMenuItem<String?>(
            value: null,
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(
                  Icons.folder_off_outlined,
                  color: iconFgColor.withValues(alpha: 0.6),
                  size: 18,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'No Project',
                    style: TextStyle(
                      color: widget.selectedProjectId == null
                          ? iconFgColor
                          : iconFgColor.withValues(alpha: 0.8),
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
                if (widget.selectedProjectId == null)
                  Icon(Icons.check, color: iconFgColor, size: 18),
              ],
            ),
          ),
        );

        if (_projects.isNotEmpty) {
          items.add(const PopupMenuDivider(height: 8));
        }

        // Project options
        for (final project in _projects) {
          final isSelected = widget.selectedProjectId == project.id;
          items.add(
            PopupMenuItem<String?>(
              value: project.id,
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Icon(
                    Icons.folder,
                    color: isSelected ? iconFgColor : iconFgColor.withValues(alpha: 0.6),
                    size: 18,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      project.name,
                      style: TextStyle(
                        color: isSelected ? iconFgColor : iconFgColor.withValues(alpha: 0.8),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (isSelected) Icon(Icons.check, color: iconFgColor, size: 18),
                ],
              ),
            ),
          );
        }

        return items;
      },
      child: buttonContent,
    );
  }
}
