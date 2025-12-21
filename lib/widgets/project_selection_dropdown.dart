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

  const ProjectSelectionDropdown({
    super.key,
    required this.selectedProjectId,
    required this.onProjectSelected,
    required this.textFieldFocusNode,
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
    if (widget.selectedProjectId == null) return '';
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

  bool get _hasProject => widget.selectedProjectId != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconFgColor = theme.resolvedIconColor;
    final bgColor = theme.scaffoldBackgroundColor;

    final ValueNotifier<bool> isHovered = ValueNotifier<bool>(false);

    final buttonContent = MouseRegion(
      onEnter: (_) => isHovered.value = true,
      onExit: (_) => isHovered.value = false,
      child: ValueListenableBuilder<bool>(
        valueListenable: isHovered,
        builder: (context, hovered, child) {
          return AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
            height: 36,
            padding: EdgeInsets.symmetric(horizontal: _hasProject ? 8 : 0),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _hasProject
                    ? iconFgColor
                    : hovered
                        ? iconFgColor
                        : iconFgColor.withValues(alpha: 0.3),
                width: _hasProject ? 1.5 : (hovered ? 1.2 : 0.8),
              ),
            ),
            child: _hasProject
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.folder, color: iconFgColor, size: 18),
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 80),
                        child: Text(
                          _selectedProjectName,
                          style: TextStyle(color: iconFgColor, fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.keyboard_arrow_down,
                        color: iconFgColor.withValues(alpha: 0.7),
                        size: 16,
                      ),
                    ],
                  )
                : SizedBox(
                    width: 36,
                    child: Icon(
                      Icons.folder_outlined,
                      color: iconFgColor,
                      size: 18,
                    ),
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
        side: BorderSide(color: iconFgColor.withValues(alpha: 0.3)),
      ),
      onCanceled: () => widget.textFieldFocusNode.requestFocus(),
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
