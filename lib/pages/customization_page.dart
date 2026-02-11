// lib/pages/customization_page.dart
import 'package:flutter/material.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/services/title_generation_service.dart';

class CustomizationPage extends StatefulWidget {
  final bool autoSendVoiceTranscription;
  final Function(bool) setAutoSendVoiceTranscription;
  final bool showReasoningTokens;
  final Function(bool) setShowReasoningTokens;
  final bool showModelInfo;
  final Function(bool) setShowModelInfo;
  final bool showTps;
  final Function(bool) setShowTps;
  // Image generation settings
  final bool imageGenEnabled;
  final Function(bool) setImageGenEnabled;
  final String imageGenDefaultSize;
  final Function(String) setImageGenDefaultSize;
  final int imageGenCustomWidth;
  final Function(int) setImageGenCustomWidth;
  final int imageGenCustomHeight;
  final Function(int) setImageGenCustomHeight;
  final bool imageGenUseCustomSize;
  final Function(bool) setImageGenUseCustomSize;
  // AI context settings
  final bool includeRecentImagesInHistory;
  final Function(bool) setIncludeRecentImagesInHistory;
  final bool includeAllImagesInHistory;
  final Function(bool) setIncludeAllImagesInHistory;
  final bool includeReasoningInHistory;
  final Function(bool) setIncludeReasoningInHistory;

  const CustomizationPage({
    super.key,
    required this.autoSendVoiceTranscription,
    required this.setAutoSendVoiceTranscription,
    required this.showReasoningTokens,
    required this.setShowReasoningTokens,
    required this.showModelInfo,
    required this.setShowModelInfo,
    required this.showTps,
    required this.setShowTps,
    required this.imageGenEnabled,
    required this.setImageGenEnabled,
    required this.imageGenDefaultSize,
    required this.setImageGenDefaultSize,
    required this.imageGenCustomWidth,
    required this.setImageGenCustomWidth,
    required this.imageGenCustomHeight,
    required this.setImageGenCustomHeight,
    required this.imageGenUseCustomSize,
    required this.setImageGenUseCustomSize,
    required this.includeRecentImagesInHistory,
    required this.setIncludeRecentImagesInHistory,
    required this.includeAllImagesInHistory,
    required this.setIncludeAllImagesInHistory,
    required this.includeReasoningInHistory,
    required this.setIncludeReasoningInHistory,
  });

  @override
  State<CustomizationPage> createState() => _CustomizationPageState();
}

class _CustomizationPageState extends State<CustomizationPage> {
  late bool _selectedAutoSendVoiceTranscription;
  late bool _selectedShowReasoningTokens;
  late bool _selectedShowModelInfo;
  late bool _selectedShowTps;
  // Image generation state
  late bool _selectedImageGenEnabled;
  late String _selectedImageGenDefaultSize;
  late int _selectedImageGenCustomWidth;
  late int _selectedImageGenCustomHeight;
  late bool _selectedImageGenUseCustomSize;
  // AI context state
  late bool _selectedIncludeRecentImagesInHistory;
  late bool _selectedIncludeAllImagesInHistory;
  late bool _selectedIncludeReasoningInHistory;
  // Auto title generation state
  bool _autoGenerateTitles = false;
  bool _isLoadingTitleSetting = true;
  bool _hasCustomPrompt = false;
  final TextEditingController _promptController = TextEditingController();
  bool _isPromptExpanded = false;

  // Size preset options with their dimensions
  static const Map<String, Map<String, dynamic>> _sizePresets = {
    'square_hd': {'label': 'Square HD (1024×1024)', 'width': 1024, 'height': 1024},
    'square': {'label': 'Square (512×512)', 'width': 512, 'height': 512},
    'portrait_4_3': {'label': 'Portrait 4:3 (768×1024)', 'width': 768, 'height': 1024},
    'portrait_16_9': {'label': 'Portrait 16:9 (576×1024)', 'width': 576, 'height': 1024},
    'landscape_4_3': {'label': 'Landscape 4:3 (1024×768)', 'width': 1024, 'height': 768},
    'landscape_16_9': {'label': 'Landscape 16:9 (1024×576)', 'width': 1024, 'height': 576},
  };

  @override
  void initState() {
    super.initState();
    _selectedAutoSendVoiceTranscription = widget.autoSendVoiceTranscription;
    _selectedShowReasoningTokens = widget.showReasoningTokens;
    _selectedShowModelInfo = widget.showModelInfo;
    _selectedShowTps = widget.showTps;
    _selectedImageGenEnabled = widget.imageGenEnabled;
    _selectedImageGenDefaultSize = widget.imageGenDefaultSize;
    _selectedImageGenCustomWidth = widget.imageGenCustomWidth;
    _selectedImageGenCustomHeight = widget.imageGenCustomHeight;
    _selectedImageGenUseCustomSize = widget.imageGenUseCustomSize;
    _selectedIncludeRecentImagesInHistory = widget.includeRecentImagesInHistory;
    _selectedIncludeAllImagesInHistory = widget.includeAllImagesInHistory;
    _selectedIncludeReasoningInHistory = widget.includeReasoningInHistory;
    _loadAutoTitleSetting();
  }

  Future<void> _loadAutoTitleSetting() async {
    final enabled = await TitleGenerationService.isEnabled();
    final prompt = await TitleGenerationService.getSystemPrompt();
    final hasCustom = await TitleGenerationService.hasCustomSystemPrompt();
    if (mounted) {
      setState(() {
        _autoGenerateTitles = enabled;
        _hasCustomPrompt = hasCustom;
        _promptController.text = prompt;
        _isLoadingTitleSetting = false;
      });
    }
  }

  Future<void> _saveSystemPrompt() async {
    await TitleGenerationService.setSystemPrompt(_promptController.text);
    final hasCustom = await TitleGenerationService.hasCustomSystemPrompt();
    if (mounted) {
      setState(() {
        _hasCustomPrompt = hasCustom;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('System prompt saved'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _resetSystemPrompt() async {
    await TitleGenerationService.resetSystemPrompt();
    if (mounted) {
      setState(() {
        _hasCustomPrompt = false;
        _promptController.text = TitleGenerationService.defaultSystemPrompt;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('System prompt reset to default'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color scaffoldBg = theme.scaffoldBackgroundColor;
    final Color iconFg = theme.resolvedIconColor;
    final TextStyle? titleTextStyle = theme.appBarTheme.titleTextStyle;

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        title: Text('Customization', style: titleTextStyle),
        backgroundColor: scaffoldBg,
        elevation: 0,
        iconTheme: IconThemeData(color: iconFg),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // Voice Transcription Section
          _buildSectionHeader(
            context,
            'Voice Transcription',
            Icons.mic,
            iconFg,
          ),
          const SizedBox(height: 12),
          _buildToggleCard(
            context,
            title: 'Auto-send voice messages',
            subtitle: 'Automatically send transcribed voice messages without confirmation',
            value: _selectedAutoSendVoiceTranscription,
            onChanged: (bool value) {
              setState(() {
                _selectedAutoSendVoiceTranscription = value;
              });
              widget.setAutoSendVoiceTranscription(value);
            },
            scaffoldBg: scaffoldBg,
            iconFg: iconFg,
          ),
          const SizedBox(height: 8),
          _buildInfoCard(
            context,
            'When enabled, voice transcriptions are sent immediately. When disabled (default), transcriptions appear in the text field for review before sending.',
            scaffoldBg,
            iconFg,
          ),
          const SizedBox(height: 24),

          // Message Display Section
          _buildSectionHeader(
            context,
            'Message Display',
            Icons.chat_bubble_outline,
            iconFg,
          ),
          const SizedBox(height: 12),
          _buildToggleCard(
            context,
            title: 'Show reasoning tokens',
            subtitle: 'Display reasoning process tokens in AI responses',
            value: _selectedShowReasoningTokens,
            onChanged: (bool value) {
              setState(() {
                _selectedShowReasoningTokens = value;
              });
              widget.setShowReasoningTokens(value);
            },
            scaffoldBg: scaffoldBg,
            iconFg: iconFg,
          ),
          const SizedBox(height: 12),
          _buildToggleCard(
            context,
            title: 'Show model info',
            subtitle: 'Display model name and information in chat messages',
            value: _selectedShowModelInfo,
            onChanged: (bool value) {
              setState(() {
                _selectedShowModelInfo = value;
              });
              widget.setShowModelInfo(value);
            },
            scaffoldBg: scaffoldBg,
            iconFg: iconFg,
          ),
          const SizedBox(height: 12),
          _buildToggleCard(
            context,
            title: 'Show tokens per second',
            subtitle: 'Display AI response generation speed (TPS)',
            value: _selectedShowTps,
            onChanged: (bool value) {
              setState(() {
                _selectedShowTps = value;
              });
              widget.setShowTps(value);
            },
            scaffoldBg: scaffoldBg,
            iconFg: iconFg,
          ),
          const SizedBox(height: 24),

          // AI Context Section
          _buildSectionHeader(
            context,
            'AI Context',
            Icons.psychology,
            iconFg,
          ),
          const SizedBox(height: 12),
          _buildToggleCard(
            context,
            title: 'Recent images in context',
            subtitle: 'Send images from recent messages to the AI model',
            value: _selectedIncludeRecentImagesInHistory,
            onChanged: (bool value) {
              setState(() {
                _selectedIncludeRecentImagesInHistory = value;
              });
              widget.setIncludeRecentImagesInHistory(value);
            },
            scaffoldBg: scaffoldBg,
            iconFg: iconFg,
          ),
          const SizedBox(height: 12),
          _buildToggleCard(
            context,
            title: 'All images in context',
            subtitle: 'Send all conversation images to the AI (uses more tokens)',
            value: _selectedIncludeAllImagesInHistory,
            onChanged: (bool value) {
              setState(() {
                _selectedIncludeAllImagesInHistory = value;
              });
              widget.setIncludeAllImagesInHistory(value);
            },
            scaffoldBg: scaffoldBg,
            iconFg: iconFg,
          ),
          const SizedBox(height: 12),
          _buildToggleCard(
            context,
            title: 'Reasoning in context',
            subtitle: 'Include AI thinking process in conversation history',
            value: _selectedIncludeReasoningInHistory,
            onChanged: (bool value) {
              setState(() {
                _selectedIncludeReasoningInHistory = value;
              });
              widget.setIncludeReasoningInHistory(value);
            },
            scaffoldBg: scaffoldBg,
            iconFg: iconFg,
          ),
          const SizedBox(height: 8),
          _buildInfoCard(
            context,
            'Recent images sends the last 6 messages\' images. All images sends every image in the conversation. Reasoning includes the AI\'s thinking process as context for follow-up messages.',
            scaffoldBg,
            iconFg,
          ),
          const SizedBox(height: 24),

          // Auto Chat Titles Section
          _buildSectionHeader(
            context,
            'Chat Titles',
            Icons.title,
            iconFg,
          ),
          const SizedBox(height: 12),
          _buildToggleCard(
            context,
            title: 'Auto-generate chat titles',
            subtitle: 'Use AI to generate titles for new chats',
            value: _isLoadingTitleSetting ? false : _autoGenerateTitles,
            onChanged: _isLoadingTitleSetting
                ? null
                : (bool value) async {
                    setState(() {
                      _autoGenerateTitles = value;
                    });
                    await TitleGenerationService.setEnabled(value);
                  },
            scaffoldBg: scaffoldBg,
            iconFg: iconFg,
          ),
          // System prompt editor (only shown when auto-generate is enabled)
          if (_autoGenerateTitles && !_isLoadingTitleSetting) ...[
            const SizedBox(height: 12),
            _buildSystemPromptEditor(scaffoldBg, iconFg),
          ],
          const SizedBox(height: 8),
          _buildInfoCard(
            context,
            'When enabled, a short title will be automatically generated for new chats based on your first message. Uses a fast, lightweight AI model (qwen3-8b).',
            scaffoldBg,
            iconFg,
          ),

          // Image Generation Section
          ...[
            const SizedBox(height: 24),
            _buildSectionHeader(
              context,
              'Image Generation',
              Icons.auto_awesome,
              iconFg,
            ),
            const SizedBox(height: 12),
            _buildToggleCard(
              context,
              title: 'Enable AI image generation',
              subtitle: 'Generate images from text prompts in chat',
              value: _selectedImageGenEnabled,
              onChanged: (bool value) {
                setState(() {
                  _selectedImageGenEnabled = value;
                });
                widget.setImageGenEnabled(value);
              },
              scaffoldBg: scaffoldBg,
              iconFg: iconFg,
            ),
            if (_selectedImageGenEnabled) ...[
              const SizedBox(height: 12),
              _buildSizePresetDropdown(scaffoldBg, iconFg),
              const SizedBox(height: 12),
              _buildToggleCard(
                context,
                title: 'Use custom dimensions',
                subtitle: 'Set custom width and height instead of presets',
                value: _selectedImageGenUseCustomSize,
                onChanged: (bool value) {
                  setState(() {
                    _selectedImageGenUseCustomSize = value;
                  });
                  widget.setImageGenUseCustomSize(value);
                },
                scaffoldBg: scaffoldBg,
                iconFg: iconFg,
              ),
              if (_selectedImageGenUseCustomSize) ...[
                const SizedBox(height: 12),
                _buildCustomSizeInputs(scaffoldBg, iconFg),
              ],
            ],
            const SizedBox(height: 8),
            _buildInfoCard(
              context,
              'Image generation costs approximately 0.01 EUR per image (1 megapixel). Cost scales with image resolution.',
              scaffoldBg,
              iconFg,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSystemPromptEditor(Color scaffoldBg, Color iconFg) {
    final theme = Theme.of(context);
    return Card(
      color: scaffoldBg.lighten(0.05),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: iconFg.withValues(alpha: 0.3), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with expand/collapse
          InkWell(
            onTap: () {
              setState(() {
                _isPromptExpanded = !_isPromptExpanded;
              });
            },
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(Icons.edit_note, color: iconFg, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Title Generation Prompt',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _hasCustomPrompt ? 'Using custom prompt' : 'Using default prompt',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: iconFg.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    _isPromptExpanded ? Icons.expand_less : Icons.expand_more,
                    color: iconFg,
                  ),
                ],
              ),
            ),
          ),
          // Expandable content
          if (_isPromptExpanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'System prompt used to generate titles:',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: iconFg.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _promptController,
                    maxLines: 6,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: scaffoldBg,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: iconFg.withValues(alpha: 0.3)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: iconFg.withValues(alpha: 0.3)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: theme.colorScheme.primary),
                      ),
                      contentPadding: const EdgeInsets.all(12),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton.icon(
                        onPressed: _resetSystemPrompt,
                        icon: Icon(Icons.restore, size: 18),
                        label: const Text('Reset'),
                        style: TextButton.styleFrom(
                          foregroundColor: iconFg.withValues(alpha: 0.7),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: _saveSystemPrompt,
                        icon: Icon(Icons.save, size: 18),
                        label: const Text('Save'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSizePresetDropdown(Color scaffoldBg, Color iconFg) {
    return Card(
      color: scaffoldBg.lighten(0.05),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: iconFg.withValues(alpha: 0.3), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Default image size',
              style: TextStyle(
                color: Theme.of(context).textTheme.titleMedium?.color,
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _selectedImageGenDefaultSize,
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: iconFg.withValues(alpha: 0.3)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: iconFg.withValues(alpha: 0.3)),
                ),
              ),
              dropdownColor: scaffoldBg.lighten(0.08),
              items: _sizePresets.entries.map((entry) {
                return DropdownMenuItem<String>(
                  value: entry.key,
                  child: Text(
                    entry.value['label'] as String,
                    style: TextStyle(
                      color: Theme.of(context).textTheme.bodyMedium?.color,
                      fontSize: 14,
                    ),
                  ),
                );
              }).toList(),
              onChanged: (String? value) {
                if (value != null) {
                  setState(() {
                    _selectedImageGenDefaultSize = value;
                  });
                  widget.setImageGenDefaultSize(value);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCustomSizeInputs(Color scaffoldBg, Color iconFg) {
    return Card(
      color: scaffoldBg.lighten(0.05),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: iconFg.withValues(alpha: 0.3), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Custom dimensions (256-2048 pixels)',
              style: TextStyle(
                color: Theme.of(context).textTheme.titleMedium?.color,
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: _selectedImageGenCustomWidth.toString(),
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Width',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: iconFg.withValues(alpha: 0.3)),
                      ),
                    ),
                    onChanged: (value) {
                      final width = int.tryParse(value);
                      if (width != null && width >= 256 && width <= 2048) {
                        setState(() {
                          _selectedImageGenCustomWidth = width;
                        });
                        widget.setImageGenCustomWidth(width);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 16),
                Text('×', style: TextStyle(color: iconFg, fontSize: 20)),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    initialValue: _selectedImageGenCustomHeight.toString(),
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Height',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: iconFg.withValues(alpha: 0.3)),
                      ),
                    ),
                    onChanged: (value) {
                      final height = int.tryParse(value);
                      if (height != null && height >= 256 && height <= 2048) {
                        setState(() {
                          _selectedImageGenCustomHeight = height;
                        });
                        widget.setImageGenCustomHeight(height);
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Estimated cost: ${_calculateCostEstimate()} EUR',
              style: TextStyle(
                color: iconFg.withValues(alpha: 0.7),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _calculateCostEstimate() {
    int width, height;
    if (_selectedImageGenUseCustomSize) {
      width = _selectedImageGenCustomWidth;
      height = _selectedImageGenCustomHeight;
    } else {
      final preset = _sizePresets[_selectedImageGenDefaultSize];
      width = preset?['width'] as int? ?? 1024;
      height = preset?['height'] as int? ?? 768;
    }
    final megapixels = (width * height) / 1000000;
    final costUsd = megapixels * 0.005;
    // Round up to nearest cent
    final costEur = (costUsd * 100).ceil() / 100;
    return costEur.toStringAsFixed(2);
  }

  Widget _buildSectionHeader(
    BuildContext context,
    String title,
    IconData icon,
    Color iconFg,
  ) {
    return Row(
      children: [
        Icon(icon, color: iconFg, size: 20),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).textTheme.titleMedium?.color,
          ),
        ),
      ],
    );
  }

  Widget _buildToggleCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required bool value,
    ValueChanged<bool>? onChanged,
    required Color scaffoldBg,
    required Color iconFg,
  }) {
    return Card(
      color: scaffoldBg.lighten(0.05),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: iconFg.withValues(alpha: 0.3), width: 1),
      ),
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        title: Text(
          title,
          style: TextStyle(
            color: Theme.of(context).textTheme.titleMedium?.color,
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(color: iconFg.lighten(0.3), fontSize: 13),
        ),
        value: value,
        onChanged: onChanged,
        activeTrackColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
        activeThumbColor: Theme.of(context).colorScheme.primary,
      ),
    );
  }

  Widget _buildInfoCard(
    BuildContext context,
    String text,
    Color scaffoldBg,
    Color iconFg,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scaffoldBg.lighten(0.03),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: iconFg.withValues(alpha: 0.2), width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 18,
            color: iconFg.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                color: iconFg.withValues(alpha: 0.8),
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
