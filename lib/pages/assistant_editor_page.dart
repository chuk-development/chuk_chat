// lib/pages/assistant_editor_page.dart
import 'package:chuk_chat/models/assistant_model.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:flutter/material.dart';

/// Page for creating or editing an AI assistant
class AssistantEditorPage extends StatefulWidget {
  final Assistant? assistant;

  const AssistantEditorPage({super.key, this.assistant});

  @override
  State<AssistantEditorPage> createState() => _AssistantEditorPageState();
}

class _AssistantEditorPageState extends State<AssistantEditorPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _systemPromptController = TextEditingController();
  final _modelIdController = TextEditingController();

  bool _memoryEnabled = true;
  String? _selectedAvatarColor;
  String? _selectedAvatarIcon;

  bool get _isEditing => widget.assistant != null;

  // Predefined colors for selection
  final List<Color> _colorOptions = const [
    Color(0xFF6366F1), // Indigo
    Color(0xFF8B5CF6), // Violet
    Color(0xFFEC4899), // Pink
    Color(0xFFEF4444), // Red
    Color(0xFFF97316), // Orange
    Color(0xFFEAB308), // Yellow
    Color(0xFF22C55E), // Green
    Color(0xFF14B8A6), // Teal
    Color(0xFF06B6D4), // Cyan
    Color(0xFF3B82F6), // Blue
    Color(0xFF8B5E3C), // Brown
    Color(0xFF64748B), // Slate
  ];

  // Predefined icon options
  final Map<String, IconData> _iconOptions = const {
    'smart_toy': Icons.smart_toy_outlined,
    'psychology': Icons.psychology_outlined,
    'lightbulb': Icons.lightbulb_outline,
    'auto_awesome': Icons.auto_awesome_outlined,
    'chat': Icons.chat_bubble_outline,
    'support': Icons.support_agent_outlined,
    'person': Icons.person_outline,
    'face': Icons.face_outlined,
    'mood': Icons.mood_outlined,
    'star': Icons.star_outline,
    'favorite': Icons.favorite_outline,
    'code': Icons.code,
    'school': Icons.school_outlined,
    'work': Icons.work_outline,
    'science': Icons.science_outlined,
    'book': Icons.auto_stories_outlined,
    'palette': Icons.palette_outlined,
    'terminal': Icons.terminal,
    'rocket': Icons.rocket_launch_outlined,
    'cloud': Icons.cloud_outlined,
    'robot': Icons.smart_toy,
    'brain': Icons.psychology,
    'idea': Icons.lightbulb,
    'assistant': Icons.support_agent,
    'bot': Icons.smart_toy_outlined,
    'ai': Icons.auto_awesome,
  };

  @override
  void initState() {
    super.initState();
    if (_isEditing) {
      _nameController.text = widget.assistant!.name;
      _descriptionController.text = widget.assistant!.description ?? '';
      _systemPromptController.text = widget.assistant!.systemPrompt;
      _memoryEnabled = widget.assistant!.memoryEnabled;
      _modelIdController.text = widget.assistant!.modelId ?? '';
      _selectedAvatarColor = widget.assistant!.avatarColor;
      _selectedAvatarIcon = widget.assistant!.avatarIcon;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _systemPromptController.dispose();
    _modelIdController.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;

    final result = {
      'name': _nameController.text.trim(),
      'description': _descriptionController.text.trim().isNotEmpty
          ? _descriptionController.text.trim()
          : null,
      'systemPrompt': _systemPromptController.text.trim(),
      'memoryEnabled': _memoryEnabled,
      'modelId': _modelIdController.text.trim().isNotEmpty
          ? _modelIdController.text.trim()
          : null,
      'avatarColor': _selectedAvatarColor,
      'avatarIcon': _selectedAvatarIcon,
    };

    Navigator.pop(context, result);
  }

  Color _getCurrentColor() {
    if (_selectedAvatarColor != null) {
      try {
        return Color(
          int.parse(_selectedAvatarColor!.replaceFirst('#', ''), radix: 16) |
              0xFF000000,
        );
      } catch (_) {
        // Fall through
      }
    }
    if (_nameController.text.isNotEmpty) {
      final index = _nameController.text.hashCode.abs() % _colorOptions.length;
      return _colorOptions[index];
    }
    return _colorOptions[0];
  }

  IconData _getCurrentIcon() {
    if (_selectedAvatarIcon != null &&
        _iconOptions.containsKey(_selectedAvatarIcon)) {
      return _iconOptions[_selectedAvatarIcon]!;
    }
    if (_nameController.text.isNotEmpty) {
      final index =
          (_nameController.text.hashCode.abs() ~/ 7) % _iconOptions.length;
      return _iconOptions.values.toList()[index];
    }
    return _iconOptions.values.first;
  }

  String _colorToHex(Color color) {
    return '#${color.value.toRadixString(16).substring(2).toUpperCase()}';
  }

  @override
  Widget build(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth > 600;

    final currentColor = _getCurrentColor();
    final currentIcon = _getCurrentIcon();

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit Assistant' : 'New Assistant'),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: iconFg),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          TextButton(onPressed: _save, child: const Text('Save')),
          const SizedBox(width: 8),
        ],
      ),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: isWide ? 700 : 600),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Avatar preview section
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: currentColor.withValues(
                          alpha: isDark ? 0.15 : 0.08,
                        ),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Column(
                        children: [
                          // Avatar
                          Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              color: currentColor.withValues(
                                alpha: isDark ? 0.25 : 0.15,
                              ),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Icon(
                              currentIcon,
                              color: currentColor,
                              size: 40,
                            ),
                          ),
                          const SizedBox(height: 16),
                          // Preview name
                          Text(
                            _nameController.text.isEmpty
                                ? 'Assistant Name'
                                : _nameController.text,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: iconFg.withValues(alpha: 0.9),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _memoryEnabled
                                ? 'Memory enabled'
                                : 'Memory disabled',
                            style: TextStyle(
                              fontSize: 13,
                              color: _memoryEnabled
                                  ? Colors.green.withValues(alpha: 0.8)
                                  : Colors.orange.withValues(alpha: 0.8),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Basic info section
                  _SectionTitle(
                    icon: Icons.person_outline,
                    title: 'Basic Information',
                    iconFg: iconFg,
                  ),
                  const SizedBox(height: 16),

                  // Name field
                  TextFormField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      labelText: 'Name *',
                      hintText: 'e.g., Code Expert, Creative Writer',
                      prefixIcon: const Icon(Icons.badge_outlined),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    autofocus: !_isEditing,
                    textInputAction: TextInputAction.next,
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Assistant name is required';
                      }
                      return null;
                    },
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 16),

                  // Description field
                  TextFormField(
                    controller: _descriptionController,
                    decoration: InputDecoration(
                      labelText: 'Description (optional)',
                      hintText: 'Brief description of what this assistant does',
                      prefixIcon: const Icon(Icons.notes_outlined),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    maxLines: 2,
                    textInputAction: TextInputAction.next,
                  ),

                  const SizedBox(height: 32),

                  // System Prompt section
                  _SectionTitle(
                    icon: Icons.psychology_outlined,
                    title: 'System Prompt',
                    iconFg: iconFg,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Define how the assistant behaves, its personality, and capabilities.',
                    style: TextStyle(
                      fontSize: 13,
                      color: iconFg.withValues(alpha: 0.5),
                    ),
                  ),
                  const SizedBox(height: 16),

                  TextFormField(
                    controller: _systemPromptController,
                    decoration: InputDecoration(
                      labelText: 'System Prompt *',
                      hintText:
                          'You are a helpful coding assistant. You provide clear, concise code explanations...',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    maxLines: 8,
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'System prompt is required';
                      }
                      return null;
                    },
                  ),

                  const SizedBox(height: 32),

                  // Memory settings
                  _SectionTitle(
                    icon: Icons.memory_outlined,
                    title: 'Memory Settings',
                    iconFg: iconFg,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'When memory is enabled, the assistant can see previous messages in the conversation. When disabled, each message is processed independently.',
                    style: TextStyle(
                      fontSize: 13,
                      color: iconFg.withValues(alpha: 0.5),
                    ),
                  ),
                  const SizedBox(height: 16),

                  SwitchListTile(
                    title: const Text('Enable Memory'),
                    subtitle: Text(
                      _memoryEnabled
                          ? 'Assistant remembers conversation history'
                          : 'Assistant treats each message independently',
                    ),
                    value: _memoryEnabled,
                    onChanged: (value) =>
                        setState(() => _memoryEnabled = value),
                    secondary: Icon(
                      _memoryEnabled
                          ? Icons.check_circle_outline
                          : Icons.do_not_disturb_on_outlined,
                      color: _memoryEnabled ? Colors.green : Colors.orange,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: iconFg.withValues(alpha: 0.1)),
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Advanced settings
                  _SectionTitle(
                    icon: Icons.tune_outlined,
                    title: 'Advanced Settings',
                    iconFg: iconFg,
                  ),
                  const SizedBox(height: 16),

                  // Model preference
                  TextFormField(
                    controller: _modelIdController,
                    decoration: InputDecoration(
                      labelText: 'Preferred Model (optional)',
                      hintText: 'e.g., gpt-4o, claude-3-opus',
                      prefixIcon: const Icon(Icons.model_training_outlined),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      helperText:
                          'Leave empty to use the user\'s default model selection',
                    ),
                    textInputAction: TextInputAction.done,
                  ),

                  const SizedBox(height: 24),

                  // Avatar color selection
                  Text(
                    'Avatar Color',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: iconFg.withValues(alpha: 0.8),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: _colorOptions.map((color) {
                      final hexColor = _colorToHex(color);
                      final isSelected = _selectedAvatarColor == hexColor;
                      return InkWell(
                        onTap: () =>
                            setState(() => _selectedAvatarColor = hexColor),
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: BorderRadius.circular(10),
                            border: isSelected
                                ? Border.all(
                                    color: iconFg.withValues(alpha: 0.8),
                                    width: 3,
                                  )
                                : null,
                          ),
                          child: isSelected
                              ? Icon(
                                  Icons.check,
                                  color: Colors.white.withValues(alpha: 0.9),
                                  size: 24,
                                )
                              : null,
                        ),
                      );
                    }).toList(),
                  ),

                  const SizedBox(height: 24),

                  // Avatar icon selection
                  Text(
                    'Avatar Icon',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: iconFg.withValues(alpha: 0.8),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _iconOptions.entries.map((entry) {
                      final isSelected = _selectedAvatarIcon == entry.key;
                      return InkWell(
                        onTap: () =>
                            setState(() => _selectedAvatarIcon = entry.key),
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: isSelected
                                ? currentColor.withValues(alpha: 0.2)
                                : iconFg.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(10),
                            border: isSelected
                                ? Border.all(color: currentColor, width: 2)
                                : null,
                          ),
                          child: Icon(
                            entry.value,
                            color: isSelected
                                ? currentColor
                                : iconFg.withValues(alpha: 0.6),
                            size: 24,
                          ),
                        ),
                      );
                    }).toList(),
                  ),

                  const SizedBox(height: 40),

                  // Save button
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _save,
                      icon: Icon(_isEditing ? Icons.save_outlined : Icons.add),
                      label: Text(
                        _isEditing ? 'Save Changes' : 'Create Assistant',
                      ),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color iconFg;

  const _SectionTitle({
    required this.icon,
    required this.title,
    required this.iconFg,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: iconFg.withValues(alpha: 0.7)),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: iconFg.withValues(alpha: 0.9),
          ),
        ),
      ],
    );
  }
}
