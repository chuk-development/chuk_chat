// lib/widgets/model_selection_dropdown.dart
import 'package:flutter/material.dart';
import 'package:ui_elements_flutter/models/chat_model.dart'; // For ModelItem

class ModelSelectionDropdown extends StatefulWidget {
  final String initialSelectedModel;
  final ValueChanged<String> onModelSelected;
  final FocusNode textFieldFocusNode; // To request focus back after selection
  final bool isCompactMode;

  const ModelSelectionDropdown({
    Key? key,
    required this.initialSelectedModel,
    required this.onModelSelected,
    required this.textFieldFocusNode,
    this.isCompactMode = false,
  }) : super(key: key);

  @override
  State<ModelSelectionDropdown> createState() => _ModelSelectionDropdownState();
}

class _ModelSelectionDropdownState extends State<ModelSelectionDropdown> {
  late String _selectedModel;

  final List<ModelItem> _allModels = <ModelItem>[
    ModelItem(name: 'Qwen3 235B Thinking', value: 'qwen/qwen3-235b-a22b-thinking-2507'),
    ModelItem(name: 'Qwen3 235B', value: 'qwen/qwen3-235b-a22b-2507'),
    ModelItem(name: 'Qwen3 Coder 480B', value: 'qwen/qwen3-coder'),
    ModelItem(name: 'Qwen3 32B', value: 'qwen/qwen3-32b'),
    ModelItem(name: 'Kimi K2', value: 'moonshotai/kimi-k2-0905'),
    ModelItem(name: 'DeepSeek: R1 0528', value: 'deepseek/deepseek-r1-0528'),
    ModelItem(name: 'DeepSeek V3.1', value: ' '),
  ];

  @override
  void initState() {
    super.initState();
    _selectedModel = widget.initialSelectedModel;
  }

  @override
  void didUpdateWidget(covariant ModelSelectionDropdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Aktualisiere das intern ausgewählte Modell, wenn sich initialSelectedModel vom Parent ändert
    if (widget.initialSelectedModel != oldWidget.initialSelectedModel) {
      _selectedModel = widget.initialSelectedModel;
    }
  }

  // Hilfsfunktion für den visuellen Inhalt des Dropdown-Buttons, einschließlich Text und Hover-Effekt.
  Widget _buildDropdownButtonContent() {
    final ValueNotifier<bool> isHovered = ValueNotifier<bool>(false);
    // Get colors from theme for this widget
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
            // Reduziertes Padding für Kompaktmodus, oder normales Padding
            padding: widget.isCompactMode ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 10),
            // Feste Breite von 44px im Kompaktmodus, ansonsten dynamisch
            width: widget.isCompactMode ? 44 : null,
            height: 36, // Höhe an die anderen Buttons anpassen
            decoration: BoxDecoration(
              color: bgColor, // Use theme's bgColor
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: hovered ? iconFgColor : iconFgColor.withOpacity(.3), // Use theme's iconFgColor
                width: hovered ? 1.2 : 0.8,
              ),
            ),
            // Zentriert den Inhalt im Kompaktmodus
            alignment: widget.isCompactMode ? Alignment.center : null,
            child: Row(
              // Max Größe im Kompaktmodus, um den Container zu füllen, sonst Min
              mainAxisSize: widget.isCompactMode ? MainAxisSize.max : MainAxisSize.min,
              // Zentriert die Icons im Kompaktmodus
              mainAxisAlignment: widget.isCompactMode ? MainAxisAlignment.center : MainAxisAlignment.start,
              children: [
                Icon(Icons.grid_3x3, color: iconFgColor, size: 20), // The 3x3-grid-icon, use theme's iconFgColor
                if (!widget.isCompactMode) ...[ // Only show text and arrow if NOT in compact mode
                  const SizedBox(width: 8),
                  Flexible( // Flexible to prevent overflow with long model names
                    child: Text(
                      _selectedModel, // Displays the currently selected model name
                      style: TextStyle(color: iconFgColor, fontSize: 14), // Use theme's iconFgColor
                      softWrap: false,
                      overflow: TextOverflow.ellipsis, // Shows "..." if text is too long
                      maxLines: 1, // Ensures text stays on one line
                    ),
                  ),
                  Icon(Icons.keyboard_arrow_down, color: iconFgColor.withOpacity(0.8), size: 16), // Use theme's iconFgColor
                ],
                // In compact mode, only the icon is displayed.
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Get colors from theme for this widget
    final Color bgColor = Theme.of(context).scaffoldBackgroundColor;
    final Color iconFgColor = Theme.of(context).iconTheme.color!;

    return PopupMenuButton<String>(
      // The "child" of the PopupMenuButton uses our helper function for its appearance
      child: _buildDropdownButtonContent(),
      color: bgColor, // Use theme's bgColor for dropdown background
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: iconFgColor.withOpacity(.3)), // Use theme's iconFgColor
      ),
      onSelected: (value) {
        setState(() {
          // Set the internally selected model based on the selection
          _selectedModel = _allModels.firstWhere((m) => m.value == value).name;
        });
        widget.onModelSelected(_selectedModel); // Notify the Parent-Widget about the selection
        Future.delayed(Duration.zero, () => widget.textFieldFocusNode.requestFocus());
      },
      itemBuilder: (BuildContext context) => _allModels.map((m) {
        final selected = _selectedModel == m.name;
        return PopupMenuItem<String>(
          value: m.value,
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              if (m.isToggle)
                Row(
                  children: [
                    Switch(value: selected, onChanged: (_) {}, activeColor: iconFgColor), // Use theme's iconFgColor
                    const SizedBox(width: 6),
                    Text('Best', style: TextStyle(color: iconFgColor)), // Use theme's iconFgColor
                  ],
                )
              else
                Text(m.name, style: TextStyle(color: selected ? iconFgColor : iconFgColor.withOpacity(.8))), // Use theme's iconFgColor
              const Spacer(),
              if (!m.isToggle && selected) Icon(Icons.check, color: iconFgColor, size: 18), // Use theme's iconFgColor
              if (m.badge != null)
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: m.badge == 'new' ? Colors.teal : Colors.orange,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(m.badge!, style: const TextStyle(color: Colors.white, fontSize: 10)),
                ),
            ],
          ),
        );
      }).toList(),
    );
  }
}