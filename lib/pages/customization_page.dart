// lib/pages/customization_page.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/pages/download_settings_page.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
import 'package:chuk_chat/utils/chat_font_resolver.dart';
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
  late double _selectedChatFontSize;
  late String _selectedChatFontFamily;
  // AI context state
  late bool _selectedIncludeRecentImagesInHistory;
  late bool _selectedIncludeAllImagesInHistory;
  late bool _selectedIncludeReasoningInHistory;
  // Language selection state
  late String _selectedLocale;
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
    _selectedChatFontSize = widget.config.chatFontSize.clamp(
      kMinChatFontSize,
      kMaxChatFontSize,
    );
    _selectedChatFontFamily =
        kSupportedChatFontFamilies.contains(widget.config.chatFontFamily)
        ? widget.config.chatFontFamily
        : kDefaultChatFontFamily;
    _selectedIncludeRecentImagesInHistory =
        widget.config.includeRecentImagesInHistory;
    _selectedIncludeAllImagesInHistory =
        widget.config.includeAllImagesInHistory;
    _selectedIncludeReasoningInHistory =
        widget.config.includeReasoningInHistory;
    _selectedLocale = widget.config.uiLocale;
    _loadAutoTitleSetting();
  }

  Future<void> _loadAutoTitleSetting() async {
    final stopwatch = Stopwatch()..start();
    try {
      // Load local cache first to keep page transitions smooth.
      final values = await Future.wait<dynamic>([
        TitleGenerationService.isEnabled(),
        TitleGenerationService.getSystemPrompt(),
      ]);
      final enabled = values[0] as bool;
      final prompt = values[1] as String;
      final hasCustom =
          prompt.trim() != TitleGenerationService.defaultSystemPrompt.trim();
      if (!mounted) return;

      setState(() {
        _autoGenerateTitles = enabled;
        _hasCustomPrompt = hasCustom;
        _promptController.text = prompt;
        _isLoadingTitleSetting = false;
      });

      unawaited(
        DiagnosticsLogService.timing(
          'settings',
          'load_customization_page_title_settings_local',
          stopwatch.elapsedMilliseconds,
          data: {
            'platform': Theme.of(context).platform.name,
            'auto_generate_titles': enabled,
            'has_custom_prompt': hasCustom,
          },
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoadingTitleSetting = false;
      });
      unawaited(
        DiagnosticsLogService.warning(
          'settings',
          'Failed to load customization title settings locally',
          data: {'error': error.toString()},
        ),
      );
    }

    // Pull from remote after first paint so navigation remains responsive.
    unawaited(_refreshAutoTitleSettingFromSupabase());
  }

  Future<void> _refreshAutoTitleSettingFromSupabase() async {
    final stopwatch = Stopwatch()..start();
    try {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await TitleGenerationService.syncSettingsFromSupabase(
        forceRefresh: false,
      );
      final values = await Future.wait<dynamic>([
        TitleGenerationService.isEnabled(),
        TitleGenerationService.getSystemPrompt(),
      ]);
      final enabled = values[0] as bool;
      final prompt = values[1] as String;
      final hasCustom =
          prompt.trim() != TitleGenerationService.defaultSystemPrompt.trim();
      if (!mounted) return;

      setState(() {
        _autoGenerateTitles = enabled;
        _hasCustomPrompt = hasCustom;
        // Avoid clobbering in-progress edits while the prompt editor is open.
        if (!_isPromptExpanded) {
          _promptController.text = prompt;
        }
      });

      unawaited(
        DiagnosticsLogService.timing(
          'settings',
          'refresh_customization_page_title_settings_remote',
          stopwatch.elapsedMilliseconds,
          data: {
            'platform': Theme.of(context).platform.name,
            'auto_generate_titles': enabled,
            'has_custom_prompt': hasCustom,
          },
        ),
      );
    } catch (error) {
      unawaited(
        DiagnosticsLogService.warning(
          'settings',
          'Remote customization title settings refresh failed',
          data: {'error': error.toString()},
        ),
      );
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
          content: Text(AppLocalizations.of(context)?.systemPromptSaved ?? 'System prompt saved'),
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
          content: Text(AppLocalizations.of(context)?.systemPromptResetToDefault ?? 'System prompt reset to default'),
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
    final l = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        title: Text(l.customization, style: titleTextStyle),
        backgroundColor: scaffoldBg,
        elevation: 0,
        iconTheme: IconThemeData(color: iconFg),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // Language Section
          _buildSectionHeader(context, l.language, Icons.language, iconFg),
          const SizedBox(height: 12),
          _buildLanguageSelector(scaffoldBg, iconFg, l),
          const SizedBox(height: 24),

          // Voice Transcription Section
          _buildSectionHeader(
            context,
            l.voiceTranscription,
            Icons.mic,
            iconFg,
          ),
          const SizedBox(height: 12),
          _buildToggleCard(
            context,
            title: l.autoSendVoice,
            subtitle: l.autoSendVoiceSubtitle,
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
          _buildInfoCard(context, l.autoSendVoiceInfo, scaffoldBg, iconFg),
          const SizedBox(height: 24),

          // Message Display Section
          _buildSectionHeader(
            context,
            l.messageDisplay,
            Icons.chat_bubble_outline,
            iconFg,
          ),
          const SizedBox(height: 12),
          _buildToggleCard(
            context,
            title: l.showReasoningTokens,
            subtitle: l.showReasoningTokensSubtitle,
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
            title: l.showModelInfo,
            subtitle: l.showModelInfoSubtitle,
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
            title: l.showTps,
            subtitle: l.showTpsSubtitle,
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
          const SizedBox(height: 12),
          _buildChatFontSizeCard(scaffoldBg, iconFg, l),
          const SizedBox(height: 12),
          _buildChatFontFamilyCard(scaffoldBg, iconFg, l),
          const SizedBox(height: 24),

          // AI Context Section
          _buildSectionHeader(context, l.aiContext, Icons.psychology, iconFg),
          const SizedBox(height: 12),
          _buildToggleCard(
            context,
            title: l.recentImagesInContext,
            subtitle: l.recentImagesInContextSubtitle,
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
            title: l.allImagesInContext,
            subtitle: l.allImagesInContextSubtitle,
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
            title: l.reasoningInContext,
            subtitle: l.reasoningInContextSubtitle,
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
          _buildInfoCard(context, l.aiContextInfo, scaffoldBg, iconFg),
          const SizedBox(height: 24),

          // Downloads Section
          _buildSectionHeader(
            context,
            l.downloads,
            Icons.folder_outlined,
            iconFg,
          ),
          const SizedBox(height: 12),
          _buildNavCard(
            context,
            title: l.downloads,
            subtitle: l.downloadsSubtitle,
            icon: Icons.folder_outlined,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const DownloadSettingsPage(),
                ),
              );
            },
            scaffoldBg: scaffoldBg,
            iconFg: iconFg,
          ),
          const SizedBox(height: 24),

          // Auto Chat Titles Section
          _buildSectionHeader(context, l.chatTitles, Icons.title, iconFg),
          const SizedBox(height: 12),
          _buildToggleCard(
            context,
            title: l.autoGenerateTitles,
            subtitle: l.autoGenerateTitlesSubtitle,
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
          _buildInfoCard(context, l.titleGenInfo, scaffoldBg, iconFg),

          // Image generation is now handled via tool calling (generate_image tool)
        ],
      ),
    );
  }

  String _fontFamilyLabel(String id, AppLocalizations l) {
    switch (id) {
      case kChatFontFamilySystem:
        return l.fontFamilySystem;
      case kChatFontFamilyMerriweather:
        return l.fontFamilyMerriweather;
      case kChatFontFamilyJetBrainsMono:
        return l.fontFamilyJetBrainsMono;
      case kChatFontFamilyArimo:
      default:
        return l.fontFamilyArimo;
    }
  }

  Widget _buildChatFontFamilyCard(
    Color scaffoldBg,
    Color iconFg,
    AppLocalizations l,
  ) {
    final theme = Theme.of(context);
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
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l.chatFontFamily,
                        style: TextStyle(
                          color: theme.textTheme.titleMedium?.color,
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        l.chatFontFamilySubtitle,
                        style: TextStyle(
                          color: iconFg.lighten(0.3),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                DropdownButton<String>(
                  value: _selectedChatFontFamily,
                  underline: const SizedBox.shrink(),
                  dropdownColor: scaffoldBg.lighten(0.08),
                  items: kSupportedChatFontFamilies.map((id) {
                    return DropdownMenuItem<String>(
                      value: id,
                      child: Text(_fontFamilyLabel(id, l)),
                    );
                  }).toList(),
                  onChanged: (String? value) {
                    if (value == null || value == _selectedChatFontFamily) {
                      return;
                    }
                    setState(() {
                      _selectedChatFontFamily = value;
                    });
                    widget.config.setChatFontFamily(value);
                  },
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: scaffoldBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: iconFg.withValues(alpha: 0.2),
                  width: 1,
                ),
              ),
              child: Text(
                l.fontSizePreview,
                style: TextStyle(
                  color: iconFg,
                  fontSize: _selectedChatFontSize,
                  fontFamily: resolveChatFontFamily(_selectedChatFontFamily),
                  height: 1.38,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatFontSizeCard(
    Color scaffoldBg,
    Color iconFg,
    AppLocalizations l,
  ) {
    final theme = Theme.of(context);
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
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l.chatFontSize,
                        style: TextStyle(
                          color: theme.textTheme.titleMedium?.color,
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        l.chatFontSizeSubtitle,
                        style: TextStyle(
                          color: iconFg.lighten(0.3),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${_selectedChatFontSize.round()}pt',
                    style: TextStyle(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Slider(
              value: _selectedChatFontSize,
              min: kMinChatFontSize,
              max: kMaxChatFontSize,
              divisions: (kMaxChatFontSize - kMinChatFontSize).round(),
              label: '${_selectedChatFontSize.round()}pt',
              onChanged: (double value) {
                setState(() {
                  _selectedChatFontSize = value;
                });
              },
              onChangeEnd: (double value) {
                widget.config.setChatFontSize(value);
              },
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: scaffoldBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: iconFg.withValues(alpha: 0.2),
                    width: 1,
                  ),
                ),
                child: Text(
                  l.fontSizePreview,
                  style: TextStyle(
                    color: iconFg,
                    fontSize: _selectedChatFontSize,
                    height: 1.38,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLanguageSelector(Color scaffoldBg, Color iconFg, AppLocalizations l) {
    return Card(
      color: scaffoldBg.lighten(0.05),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: iconFg.withValues(alpha: 0.3), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.language,
                    style: TextStyle(
                      color: Theme.of(context).textTheme.titleMedium?.color,
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    l.languageSubtitle,
                    style: TextStyle(color: iconFg.lighten(0.3), fontSize: 13),
                  ),
                ],
              ),
            ),
            DropdownButton<String>(
              value: _selectedLocale,
              underline: const SizedBox.shrink(),
              dropdownColor: scaffoldBg.lighten(0.08),
              items: [
                const DropdownMenuItem(value: 'en', child: Text('English')),
                const DropdownMenuItem(value: 'de', child: Text('Deutsch')),
                const DropdownMenuItem(value: 'zh', child: Text('中文')),
                const DropdownMenuItem(value: 'hi', child: Text('हिन्दी')),
                const DropdownMenuItem(value: 'es', child: Text('Español')),
                const DropdownMenuItem(value: 'fr', child: Text('Français')),
                const DropdownMenuItem(value: 'ar', child: Text('العربية')),
                const DropdownMenuItem(value: 'bn', child: Text('বাংলা')),
                const DropdownMenuItem(value: 'pt', child: Text('Português')),
                const DropdownMenuItem(value: 'ru', child: Text('Русский')),
                const DropdownMenuItem(value: 'ja', child: Text('日本語')),
              ],
              onChanged: (String? value) {
                if (value != null && value != _selectedLocale) {
                  setState(() {
                    _selectedLocale = value;
                  });
                  widget.config.setUiLocale(value);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSystemPromptEditor(Color scaffoldBg, Color iconFg) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context)!;
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
                          l.titleGenerationPrompt,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _hasCustomPrompt
                              ? l.usingCustomPrompt
                              : l.usingDefaultPrompt,
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
                        label: Text(l.reset),
                        style: TextButton.styleFrom(
                          foregroundColor: iconFg.withValues(alpha: 0.7),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: _saveSystemPrompt,
                        icon: Icon(Icons.save, size: 18),
                        label: Text(l.save),
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

  Widget _buildNavCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
    required Color scaffoldBg,
    required Color iconFg,
  }) {
    final theme = Theme.of(context);
    return Card(
      color: scaffoldBg.lighten(0.05),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: iconFg.withValues(alpha: 0.3), width: 1),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(icon, color: iconFg, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: theme.textTheme.titleMedium?.color,
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: iconFg.lighten(0.3),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: iconFg.withValues(alpha: 0.7),
              ),
            ],
          ),
        ),
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
