// lib/widgets/model_selection_dropdown.dart
import 'package:flutter/material.dart';
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class ModelSelectionDropdown extends StatefulWidget {
  final String initialSelectedModelId; // Now expects model ID
  final ValueChanged<String> onModelSelected; // Callback returns model ID
  final FocusNode textFieldFocusNode;
  final bool isCompactMode; // Indicates if it should show only the icon
  final String? compactLabel; // Optional label for compact mode (e.g., "#")

  const ModelSelectionDropdown({
    super.key,
    required this.initialSelectedModelId,
    required this.onModelSelected,
    required this.textFieldFocusNode,
    this.isCompactMode = false,
    this.compactLabel,
  });

  @override
  State<ModelSelectionDropdown> createState() => _ModelSelectionDropdownState();
}

class _ModelSelectionDropdownState extends State<ModelSelectionDropdown> {
  String _selectedModelId = ''; // Stores the model ID
  String _selectedModelName = 'Loading Models...'; // Stores the display name
  List<ModelItem> _allModels = [];
  bool _isLoadingModels = true;
  String _errorMessage = '';

  // NEW: Base URL for your FastAPI server
  static const String _apiBaseUrl =
      'http://127.0.0.1:8000'; // Adjust if your server is elsewhere

  @override
  void initState() {
    super.initState();
    _selectedModelId = widget.initialSelectedModelId;
    _initializeModelSelection();
  }

  @override
  void didUpdateWidget(covariant ModelSelectionDropdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialSelectedModelId != oldWidget.initialSelectedModelId ||
        widget.isCompactMode != oldWidget.isCompactMode) {
      // React to compact mode changes
      _selectedModelId = widget.initialSelectedModelId;
      _updateSelectedModelName(); // Update display name if ID changes
    }
  }

  // Initialize model selection by loading saved preference and fetching models
  Future<void> _initializeModelSelection() async {
    setState(() {
      _isLoadingModels = true;
      _errorMessage = '';
    });

    try {
      // First, try to load the saved model preference
      final savedModelId = await UserPreferencesService.loadSelectedModel();
      if (savedModelId != null && savedModelId.isNotEmpty) {
        _selectedModelId = savedModelId;
        // Don't notify parent yet - wait until models are fetched and validated
      }

      // Then fetch the available models
      await _fetchModels();
    } catch (e) {
      _errorMessage = 'Error initializing model selection: $e';
      _selectedModelName = 'Error Loading';
      debugPrint('Error initializing model selection: $e');
    } finally {
      setState(() {
        _isLoadingModels = false;
      });
    }
  }

  // NEW: Fetch models from FastAPI backend
  Future<void> _fetchModels() async {
    try {
      final response = await http.get(Uri.parse('$_apiBaseUrl/models_info'));

      if (response.statusCode == 200) {
        final List<dynamic> jsonList = json.decode(response.body);
        _allModels = jsonList.map((json) => ModelItem.fromJson(json)).toList();

        // Sort models alphabetically by name
        _allModels.sort((a, b) => a.name.compareTo(b.name));

        // Validate the selected model against the fetched list
        if (!_allModels.any((m) => m.value == _selectedModelId)) {
          // If selected model is not in the fetched list,
          // default to the first available model or a placeholder.
          if (_allModels.isNotEmpty) {
            _selectedModelId = _allModels.first.value;
            // Save the new default selection
            await UserPreferencesService.saveSelectedModel(_selectedModelId);
          } else {
            _selectedModelId = ''; // No models available
          }
        }

        // Now notify parent with the validated selection (exactly once)
        widget.onModelSelected(_selectedModelId);
        _updateSelectedModelName();
      } else {
        _errorMessage = 'Failed to load models: ${response.statusCode}';
        _selectedModelName = 'Error Loading';
        debugPrint('API Error: $_errorMessage');
      }
    } catch (e) {
      _errorMessage = 'Network error: $e';
      _selectedModelName = 'Network Error';
      debugPrint('Network Error fetching models: $e');
    }
  }

  // Helper to update the displayed model name based on the selected ID
  void _updateSelectedModelName() {
    final selectedItem = _allModels.firstWhere(
      (m) => m.value == _selectedModelId,
      orElse: () => ModelItem(name: 'Select Model', value: ''), // Fallback
    );
    setState(() {
      _selectedModelName = selectedItem.name;
    });
  }

  // Hilfsfunktion für den visuellen Inhalt des Dropdown-Buttons, einschließlich Text und Hover-Effekt.
  Widget _buildDropdownButtonContent() {
    final ValueNotifier<bool> isHovered = ValueNotifier<bool>(false);
    final Color bgColor = Theme.of(context).scaffoldBackgroundColor;
    final Color iconFgColor = Theme.of(context).iconTheme.color!;

    return MouseRegion(
      onEnter: (_) => isHovered.value = true,
      onExit: (_) => isHovered.value = false,
      child: ValueListenableBuilder<bool>(
        valueListenable: isHovered,
        builder: (context, hovered, child) {
          return AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
            padding: widget.isCompactMode
                ? EdgeInsets.zero
                : const EdgeInsets.symmetric(horizontal: 10),
            width: widget.isCompactMode
                ? 44
                : null, // Fixed width for compact mode
            height: 36,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: hovered
                    ? iconFgColor
                    : iconFgColor.withValues(alpha: 0.3),
                width: hovered ? 1.2 : 0.8,
              ),
            ),
            alignment: widget.isCompactMode ? Alignment.center : null,
            child: Row(
              mainAxisSize: widget.isCompactMode
                  ? MainAxisSize.max
                  : MainAxisSize.min,
              mainAxisAlignment: widget.isCompactMode
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                if (widget.isCompactMode) ...[
                  widget.compactLabel != null
                      ? Text(
                          widget.compactLabel!,
                          style: TextStyle(
                            color: iconFgColor,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        )
                      : Icon(Icons.grid_3x3, color: iconFgColor, size: 20),
                ] else ...[
                  Icon(Icons.grid_3x3, color: iconFgColor, size: 20),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _selectedModelName, // Displays the currently selected model name
                      style: TextStyle(color: iconFgColor, fontSize: 14),
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                  Icon(
                    Icons.keyboard_arrow_down,
                    color: iconFgColor.withValues(alpha: 0.8),
                    size: 16,
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Color bgColor = Theme.of(context).scaffoldBackgroundColor;
    final Color iconFgColor = Theme.of(context).iconTheme.color!;

    if (_isLoadingModels) {
      return _buildDropdownButtonContent(); // Show "Loading Models..."
    }

    if (_errorMessage.isNotEmpty) {
      return _buildDropdownButtonContent(); // Show "Error Loading"
    }

    return PopupMenuButton<String>(
      color: bgColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: iconFgColor.withValues(alpha: 0.3)),
      ),
      onSelected: (value) async {
        // Store the previous state for potential rollback
        final previousModelId = _selectedModelId;

        setState(() {
          _selectedModelId = value;
          _updateSelectedModelName(); // Update name after ID changes
        });
        widget.onModelSelected(value); // Notify parent with the model ID

        // Save the selection to Supabase with error handling
        try {
          await UserPreferencesService.saveSelectedModel(value);
        } catch (e) {
          // Log the error
          debugPrint('Failed to save selected model: $e');

          // Show user-facing error
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Failed to save model selection. Please try again.',
                ),
                backgroundColor: Colors.red,
                duration: Duration(seconds: 3),
              ),
            );
          }

          // Revert the in-memory selection if persistence fails
          setState(() {
            _selectedModelId = previousModelId;
            _updateSelectedModelName(); // Update name after reverting ID
          });

          // Notify parent with the reverted model ID
          widget.onModelSelected(previousModelId);
        }

        // Request focus regardless of save success/failure
        Future.delayed(
          Duration.zero,
          () => widget.textFieldFocusNode.requestFocus(),
        );
      },
      itemBuilder: (BuildContext context) => _allModels.map((m) {
        final selected = _selectedModelId == m.value;
        return PopupMenuItem<String>(
          value: m.value,
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              if (m.isToggle)
                Row(
                  children: [
                    Switch(
                      value: selected,
                      onChanged: (_) {},
                      activeThumbColor: iconFgColor,
                      activeTrackColor: iconFgColor.withValues(alpha: 0.5),
                    ),
                    const SizedBox(width: 6),
                    Text('Best', style: TextStyle(color: iconFgColor)),
                  ],
                )
              else
                Expanded(
                  child: Text(
                    m.name,
                    style: TextStyle(
                      color: selected
                          ? iconFgColor
                          : iconFgColor.withValues(alpha: 0.8),
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              const Spacer(),
              if (!m.isToggle && selected)
                Icon(Icons.check, color: iconFgColor, size: 18),
              if (m.badge != null)
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: m.badge == 'new' ? Colors.teal : Colors.orange,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    m.badge!,
                    style: const TextStyle(color: Colors.white, fontSize: 10),
                  ),
                ),
            ],
          ),
        );
      }).toList(),
      child: _buildDropdownButtonContent(),
    );
  }
}
