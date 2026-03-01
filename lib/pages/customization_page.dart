// lib/pages/customization_page.dart
import 'package:flutter/material.dart';
import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/services/title_generation_service.dart';

class CustomizationPage extends StatefulWidget {
  final AppShellConfig config;

  const CustomizationPage({super.key, required this.config});

  @override
  State<CustomizationPage> createState() => _CustomizationPageState();
}

class _CustomizationPageState extends State<CustomizationPage> {
  late bool _selectedAutoSendVoiceTranscription;
  late bool _selectedShowReasoningTokens;
  late bool _selectedShowModelInfo;
  late bool _selectedShowTps;
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

  @override
  void initState() {
    super.initState();
    _selectedAutoSendVoiceTranscription =
        widget.config.autoSendVoiceTranscription;
    _selectedShowReasoningTokens = widget.config.showReasoningTokens;
    _selectedShowModelInfo = widget.config.showModelInfo;
    _selectedShowTps = widget.config.showTps;
    _selectedIncludeRecentImagesInHistory =
        widget.config.includeRecentImagesInHistory;
    _selectedIncludeAllImagesInHistory =
        widget.config.includeAllImagesInHistory;
    _selectedIncludeReasoningInHistory =
        widget.config.includeReasoningInHistory;
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
            subtitle:
                'Automatically send transcribed voice messages without confirmation',
            value: _selectedAutoSendVoiceTranscription,
            onChanged: (bool value) {
              setState(() {
                _selectedAutoSendVoiceTranscription = value;
              });
              widget.config.setAutoSendVoiceTranscription(value);
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
              widget.config.setShowReasoningTokens(value);
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
              widget.config.setShowModelInfo(value);
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
              widget.config.setShowTps(value);
            },
            scaffoldBg: scaffoldBg,
            iconFg: iconFg,
          ),
          const SizedBox(height: 24),

          // AI Context Section
          _buildSectionHeader(context, 'AI Context', Icons.psychology, iconFg),
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
              widget.config.setIncludeRecentImagesInHistory(value);
            },
            scaffoldBg: scaffoldBg,
            iconFg: iconFg,
          ),
          const SizedBox(height: 12),
          _buildToggleCard(
            context,
            title: 'All images in context',
            subtitle:
                'Send all conversation images to the AI (uses more tokens)',
            value: _selectedIncludeAllImagesInHistory,
            onChanged: (bool value) {
              setState(() {
                _selectedIncludeAllImagesInHistory = value;
              });
              widget.config.setIncludeAllImagesInHistory(value);
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
              widget.config.setIncludeReasoningInHistory(value);
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
          _buildSectionHeader(context, 'Chat Titles', Icons.title, iconFg),
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

          // Image generation is now handled via tool calling (generate_image tool)
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
                          _hasCustomPrompt
                              ? 'Using custom prompt'
                              : 'Using default prompt',
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
                        borderSide: BorderSide(
                          color: iconFg.withValues(alpha: 0.3),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                          color: iconFg.withValues(alpha: 0.3),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                          color: theme.colorScheme.primary,
                        ),
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
        activeTrackColor: Theme.of(
          context,
        ).colorScheme.primary.withValues(alpha: 0.5),
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
