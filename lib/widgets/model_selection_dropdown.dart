// lib/widgets/model_selection_dropdown.dart
import 'package:flutter/material.dart';
import 'package:ui_elements_flutter/constants.dart'; // For bg, iconFg, accent
import 'package:ui_elements_flutter/models/chat_model.dart'; // For ModelItem

class ModelSelectionDropdown extends StatefulWidget {
  final String initialSelectedModel;
  final ValueChanged<String> onModelSelected;
  final FocusNode textFieldFocusNode; // To request focus back after selection

  const ModelSelectionDropdown({
    Key? key,
    required this.initialSelectedModel,
    required this.onModelSelected,
    required this.textFieldFocusNode,
  }) : super(key: key);

  @override
  State<ModelSelectionDropdown> createState() => _ModelSelectionDropdownState();
}

class _ModelSelectionDropdownState extends State<ModelSelectionDropdown> {
  late String _selectedModel;

  // Die Liste der Modelle, wie sie im letzten Code bereitgestellt wurde.
  // Wenn du eine andere Liste möchtest, musst du diese hier anpassen.
  final List<ModelItem> _allModels = <ModelItem>[
    ModelItem(name: 'Qwen3 235B Thinking', value: 'qwen/qwen3-235b-a22b-thinking-2507'),
    ModelItem(name: 'Qwen3 Coder 480B', value: 'qwen/qwen3-coder'),
    ModelItem(name: 'Qwen3 235B', value: 'qwen/qwen3-235b-a22b-2507'),
    ModelItem(name: 'Qwen3 32B', value: 'qwen/qwen3-32b'),
    ModelItem(name: 'Kimi K2', value: 'moonshotai/kimi-k2-0905'),
    ModelItem(name: 'DeepSeek: R1 0528', value: 'deepseek/deepseek-r1-0528'),
    ModelItem(name: 'DeepSeek V3.1', value: 'deepseek/deepseek-chat-v3.1'),

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
    return MouseRegion(
      onEnter: (_) => isHovered.value = true,
      onExit: (_) => isHovered.value = false,
      child: ValueListenableBuilder<bool>(
        valueListenable: isHovered,
        builder: (context, hovered, child) {
          return AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 10), // Padding innerhalb des Buttons
            height: 36, // Höhe an die anderen Buttons anpassen
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: hovered ? iconFg : iconFg.withOpacity(.3),
                width: hovered ? 1.2 : 0.8,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min, // Damit die Zeile so klein wie möglich ist
              children: [
                Icon(Icons.grid_3x3, color: iconFg, size: 20), // Das 3x3-Gitter-Icon
                const SizedBox(width: 8),
                Flexible( // Flexible, um Überlauf bei langen Modellnamen zu verhindern
                  child: Text(
                    _selectedModel, // Zeigt den aktuell ausgewählten Modellnamen an
                    style: TextStyle(color: iconFg, fontSize: 14),
                    softWrap: false,
                    overflow: TextOverflow.ellipsis, // Zeigt "..." an, wenn der Text zu lang ist
                    maxLines: 1, // Stellt sicher, dass der Text in einer Zeile bleibt
                  ),
                ),
                Icon(Icons.keyboard_arrow_down, color: iconFg.withOpacity(0.8), size: 16),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      // Das "child" des PopupMenuButton verwendet unsere Hilfsfunktion für das Aussehen
      child: _buildDropdownButtonContent(),
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: iconFg.withOpacity(.3)),
      ),
      onSelected: (value) {
        setState(() {
          // Setze das intern ausgewählte Modell basierend auf der Auswahl
          _selectedModel = _allModels.firstWhere((m) => m.value == value).name;
        });
        widget.onModelSelected(_selectedModel); // Benachrichtige den Parent-Widget über die Auswahl
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
                    Switch(value: selected, onChanged: (_) {}, activeColor: iconFg),
                    const SizedBox(width: 6),
                    Text('Best', style: TextStyle(color: iconFg)),
                  ],
                )
              else
                Text(m.name, style: TextStyle(color: selected ? iconFg : iconFg.withOpacity(.8))),
              const Spacer(),
              if (!m.isToggle && selected) Icon(Icons.check, color: iconFg, size: 18),
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