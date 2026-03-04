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

    // When project is active: invert colors (like other active buttons)
    final Color effectiveBgColor = _hasProject ? iconFgColor : bgColor;
    final Color effectiveIconColor = _hasProject ? bgColor : iconFgColor;

    final buttonContent = MouseRegion(
      onEnter: (_) => isHovered.value = true,
      onExit: (_) => isHovered.value = false,
      child: ValueListenableBuilder<bool>(
        valueListenable: isHovered,
        builder: (context, hovered, child) {
          final Color borderColor = _hasProject
              ? iconFgColor.withValues(alpha: 0.6)
              : hovered
              ? iconFgColor
              : iconFgColor.withValues(alpha: 0.3);
          final double borderWidth = _hasProject ? 2.0 : (hovered ? 2.2 : 1.8);

          return AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
            height: 42,
            padding: EdgeInsets.symmetric(horizontal: _hasProject ? 10 : 0),
            decoration: BoxDecoration(
              color: effectiveBgColor,
              borderRadius: BorderRadius.circular(21),
              border: Border.all(color: borderColor, width: borderWidth),
            ),
            child: _hasProject
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.folder, color: effectiveIconColor, size: 20),
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 80),
                        child: Text(
                          _selectedProjectName,
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
                // Same size as other icon buttons: 50x42
                : SizedBox(
                    width: 50,
                    height: 42,
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
      constraints: const BoxConstraints(minWidth: 180, maxWidth: 260),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: iconFgColor.withValues(alpha: 0.3)),
      ),
      onCanceled: () => widget.textFieldFocusNode.requestFocus(),
      onSelected: (value) {
        if (kDebugMode) {
          debugPrint('📁 Project dropdown selected: $value');
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
                      color: !_hasProject
                          ? iconFgColor
                          : iconFgColor.withValues(alpha: 0.8),
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
            items.add(
              PopupMenuItem<String?>(
                value: project.id,
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Icon(
                      Icons.folder,
                      color: isSelected
                          ? iconFgColor
                          : iconFgColor.withValues(alpha: 0.6),
                      size: 18,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        project.name,
                        style: TextStyle(
                          color: isSelected
                              ? iconFgColor
                              : iconFgColor.withValues(alpha: 0.8),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isSelected)
                      Icon(Icons.check, color: iconFgColor, size: 18),
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
              height: 40,
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
