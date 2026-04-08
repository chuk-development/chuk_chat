// lib/pages/assistant_editor_page.dart
import 'package:chuk_chat/models/assistant_model.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

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

  // Avatar image state
  Uint8List? _pickedImageBytes; // Newly picked image (not yet saved)
  String? _existingImagePath; // Already uploaded image path
  bool _removeImage = false; // User wants to remove existing image
  Future<Uint8List>? _existingImageFuture;

  // Public sharing
  bool _isPublic = false;

  bool get _isEditing => widget.assistant != null;

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
      _existingImagePath = widget.assistant!.avatarImagePath;
      _isPublic = widget.assistant!.isPublic;
      if (_existingImagePath != null) {
        _existingImageFuture =
            ImageStorageService.downloadAndDecryptImage(_existingImagePath!);
      }
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
      'pickedImageBytes': _pickedImageBytes,
      'removeImage': _removeImage,
      'isPublic': _isPublic,
    };

    Navigator.pop(context, result);
  }

  Future<void> _pickImage() async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );
      if (picked == null) return;

      final bytes = await picked.readAsBytes();
      setState(() {
        _pickedImageBytes = bytes;
        _removeImage = false;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to pick image: $e')));
      }
    }
  }

  Future<void> _togglePublic(bool value) async {
    if (value) {
      // First confirmation
      final first = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Make Public?'),
          content: const Text(
            'Making this assistant public will allow anyone to see '
            'your system prompt and use this assistant.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (first != true || !mounted) return;

      // Second confirmation
      final second = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Are you sure?'),
          content: const Text(
            'Your system prompt will be visible to all users. '
            'You can make it private again later from this page.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Make Public'),
            ),
          ],
        ),
      );
      if (second != true || !mounted) return;
    }
    setState(() => _isPublic = value);
  }

  void _removeCurrentImage() {
    setState(() {
      _pickedImageBytes = null;
      _existingImageFuture = null;
      _removeImage = true;
    });
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
      final index =
          _nameController.text.hashCode.abs() % Assistant.kAssistantColors.length;
      return Assistant.kAssistantColors[index];
    }
    return Assistant.kAssistantColors[0];
  }

  IconData _getCurrentIcon() {
    if (_selectedAvatarIcon != null &&
        Assistant.availableIcons.containsKey(_selectedAvatarIcon)) {
      return Assistant.availableIcons[_selectedAvatarIcon]!;
    }
    if (_nameController.text.isNotEmpty) {
      final index = (_nameController.text.hashCode.abs() ~/ 7) %
          Assistant.availableIcons.length;
      return Assistant.availableIcons.values.toList()[index];
    }
    return Assistant.availableIcons.values.first;
  }

  /// Whether we have an image to show (either picked or existing)
  bool get _hasImage =>
      (_pickedImageBytes != null) ||
      (_existingImageFuture != null && !_removeImage);

  /// Build the avatar widget — show image if available, otherwise icon
  Widget _buildAvatarPreview(Color currentColor, bool isDark) {
    if (_pickedImageBytes != null) {
      // Show newly picked image
      return ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Image.memory(
          _pickedImageBytes!,
          width: 80,
          height: 80,
          fit: BoxFit.cover,
        ),
      );
    }

    if (_existingImageFuture != null && !_removeImage) {
      // Show existing uploaded image
      return ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: FutureBuilder<Uint8List>(
          future: _existingImageFuture,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: currentColor.withValues(alpha: isDark ? 0.25 : 0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Icon(
                  Icons.error_outline,
                  color: Colors.red.withValues(alpha: 0.6),
                  size: 32,
                ),
              );
            }
            if (snapshot.hasData) {
              return Image.memory(
                snapshot.data!,
                width: 80,
                height: 80,
                fit: BoxFit.cover,
              );
            }
            return Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: currentColor.withValues(alpha: isDark ? 0.25 : 0.15),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          },
        ),
      );
    }

    // Default: icon avatar
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        color: currentColor.withValues(alpha: isDark ? 0.25 : 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Icon(_getCurrentIcon(), color: currentColor, size: 40),
    );
  }

  @override
  Widget build(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth > 600;

    final currentColor = _getCurrentColor();

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
                          // Avatar with upload overlay
                          Stack(
                            children: [
                              _buildAvatarPreview(currentColor, isDark),
                              Positioned(
                                right: -4,
                                bottom: -4,
                                child: Material(
                                  color: Theme.of(context).colorScheme.primary,
                                  borderRadius: BorderRadius.circular(12),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(12),
                                    onTap: _pickImage,
                                    child: const Padding(
                                      padding: EdgeInsets.all(4),
                                      child: Icon(
                                        Icons.camera_alt,
                                        size: 16,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (_hasImage) ...[
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: _removeCurrentImage,
                              icon: const Icon(Icons.close, size: 16),
                              label: const Text('Remove image'),
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.red.withValues(
                                  alpha: 0.8,
                                ),
                                textStyle: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
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
                    'When memory is enabled, the assistant can access your Soul, User info, and Memory notes. '
                    'When disabled, the assistant operates with only its own system prompt.',
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
                          ? 'Assistant can access Soul, User, and Memory'
                          : 'Assistant uses only its own system prompt',
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

                  // Sharing settings
                  _SectionTitle(
                    icon: Icons.public,
                    title: 'Sharing',
                    iconFg: iconFg,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Public assistants can be seen and used by all users. '
                    'Your system prompt will be visible to everyone.',
                    style: TextStyle(
                      fontSize: 13,
                      color: iconFg.withValues(alpha: 0.5),
                    ),
                  ),
                  const SizedBox(height: 16),

                  SwitchListTile(
                    title: const Text('Make Public'),
                    subtitle: Text(
                      _isPublic
                          ? 'Anyone can see and use this assistant'
                          : 'Only you can see this assistant',
                    ),
                    value: _isPublic,
                    onChanged: _togglePublic,
                    secondary: Icon(
                      _isPublic ? Icons.public : Icons.lock_outline,
                      color: _isPublic ? Colors.blue : iconFg.withValues(alpha: 0.5),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: _isPublic
                            ? Colors.blue.withValues(alpha: 0.3)
                            : iconFg.withValues(alpha: 0.1),
                      ),
                    ),
                  ),

                  if (_isPublic) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Colors.orange.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 18,
                            color: Colors.orange.withValues(alpha: 0.8),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Your system prompt is visible to all users.',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.orange.withValues(alpha: 0.9),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

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
                    children: Assistant.kAssistantColors.map((color) {
                      final hexColor = Assistant.colorToHex(color);
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
                    children: Assistant.availableIcons.entries.map((entry) {
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
