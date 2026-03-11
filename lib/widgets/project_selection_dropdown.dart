// lib/widgets/project_selection_dropdown.dart
import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
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
  State<ProjectSelectionDropdown> createState() =>
      _ProjectSelectionDropdownState();
}

class _ProjectSelectionDropdownState extends State<ProjectSelectionDropdown> {
  List<Project> _projects = [];
  StreamSubscription<void>? _projectChangesSubscription;
  final ValueNotifier<bool> _isHovered = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    // Use cached data immediately - don't trigger network on every chat switch
    _loadProjects();
    _projectChangesSubscription = ProjectStorageService.changes.listen((_) {
      _loadProjects();
    });
  }

  @override
  void dispose() {
    _projectChangesSubscription?.cancel();
    _isHovered.dispose();
    super.dispose();
  }

  void _loadProjects() {
    if (mounted) {
      setState(() {
        _projects = ProjectStorageService.activeProjects;
      });
    }
  }

  Project? get _selectedProject {
    if (widget.selectedProjectId == null) return null;
    try {
      return _projects.firstWhere((p) => p.id == widget.selectedProjectId);
    } catch (_) {
      return null;
    }
  }

  bool get _hasProject => _selectedProject != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconFgColor = theme.resolvedIconColor;
    final bgColor = theme.scaffoldBackgroundColor;
    final selectedProject = _selectedProject;
    final projectColor = selectedProject?.projectColor;

    // When project is active: use project color for styling
    final Color effectiveBgColor = _hasProject
        ? (projectColor ?? iconFgColor)
        : bgColor;
    final Color effectiveIconColor = _hasProject ? Colors.white : iconFgColor;

    final buttonContent = MouseRegion(
      onEnter: (_) => _isHovered.value = true,
      onExit: (_) => _isHovered.value = false,
      child: ValueListenableBuilder<bool>(
        valueListenable: _isHovered,
        builder: (context, hovered, child) {
          final Color borderColor = _hasProject
              ? (projectColor ?? iconFgColor).withValues(alpha: 0.8)
              : hovered
              ? iconFgColor
              : iconFgColor.withValues(alpha: 0.3);
          final double borderWidth = _hasProject ? 2.0 : (hovered ? 2.2 : 1.8);

          return AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
            height: 36,
            padding: EdgeInsets.symmetric(horizontal: _hasProject ? 8 : 0),
            decoration: BoxDecoration(
              color: effectiveBgColor,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: borderColor, width: borderWidth),
            ),
            child: _hasProject
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        selectedProject?.projectIcon ?? Icons.folder,
                        color: effectiveIconColor,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 80),
                        child: Text(
                          selectedProject?.name ?? '?',
                          style: TextStyle(
                            color: effectiveIconColor,
                            fontSize: 13,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.keyboard_arrow_down,
                        color: effectiveIconColor.withValues(alpha: 0.7),
                        size: 16,
                      ),
                    ],
                  )
                // Same size as other icon buttons: 44x36
                : SizedBox(
                    width: 44,
                    height: 36,
                    child: Icon(
                      Icons.folder_outlined,
                      color: effectiveIconColor,
                      size: 20,
                    ),
                  ),
          );
        },
      ),
    );

    return PopupMenuButton<String?>(
      color: bgColor,
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 280),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: iconFgColor.withValues(alpha: 0.2), width: 1.5),
      ),
      onCanceled: () => widget.textFieldFocusNode.requestFocus(),
      onSelected: (value) {
        if (kDebugMode) {
          debugPrint('[ProjectDropdown] Selected: $value');
        }
        widget.textFieldFocusNode.requestFocus();
        // Convert empty string back to null for "No Project"
        final projectId = (value == null || value.isEmpty) ? null : value;
        widget.onProjectSelected(projectId);
      },
      itemBuilder: (context) {
        final items = <PopupMenuEntry<String?>>[];

        // "No Project" option - use empty string instead of null
        items.add(
          PopupMenuItem<String?>(
            value: '',
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(
                  Icons.folder_off_outlined,
                  color: iconFgColor.withValues(alpha: 0.5),
                  size: 18,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'No Project',
                    style: TextStyle(
                      color: !_hasProject
                          ? iconFgColor
                          : iconFgColor.withValues(alpha: 0.7),
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
                if (!_hasProject)
                  Icon(Icons.check, color: iconFgColor, size: 18),
              ],
            ),
          ),
        );

        if (_projects.isNotEmpty) {
          items.add(const PopupMenuDivider(height: 8));

          // Project options
          for (final project in _projects) {
            final isSelected = widget.selectedProjectId == project.id;
            final pColor = project.projectColor;
            items.add(
              PopupMenuItem<String?>(
                value: project.id,
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    // Color dot
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: pColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Icon(project.projectIcon, size: 14, color: pColor),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            project.name,
                            style: TextStyle(
                              color: isSelected
                                  ? iconFgColor
                                  : iconFgColor.withValues(alpha: 0.8),
                              fontSize: 14,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            '${project.fileCount} files, ${project.chatCount} chats',
                            style: TextStyle(
                              fontSize: 11,
                              color: iconFgColor.withValues(alpha: 0.4),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (isSelected) Icon(Icons.check, color: pColor, size: 18),
                  ],
                ),
              ),
            );
          }
        } else {
          // No projects yet
          items.add(
            PopupMenuItem<String?>(
              enabled: false,
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'No projects yet',
                style: TextStyle(
                  color: iconFgColor.withValues(alpha: 0.5),
                  fontStyle: FontStyle.italic,
                ),
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
