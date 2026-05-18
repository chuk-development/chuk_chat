// lib/pages/customization_page.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/models/app_shell_config.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/pages/download_settings_page.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
import 'package:chuk_chat/utils/chat_font_resolver.dart';
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
  late double _selectedUiScale;
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
    _selectedUiScale = widget.config.uiScale.clamp(
      kMinUiScale,
      kMaxUiScale,
    );
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
          content: Text(AppLocalizations.of(context)?.systemPromptSaved ??
              'System prompt saved'),
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
          content: Text(AppLocalizations.of(context)
                  ?.systemPromptResetToDefault ??
              'System prompt reset to default'),
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
    final cs = theme.colorScheme;
    final m3 = theme.m3;
    final l = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: Text(l.customization),
        centerTitle: false,
        backgroundColor: cs.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // Language section.
          _SectionHeader(l.language),
          _FilledCard(
            child: Row(
              children: [
                Icon(Icons.language, size: 24, color: m3.onSurfaceVariant),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l.language,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        l.languageSubtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: m3.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                DropdownButton<String>(
                  value: _selectedLocale,
                  underline: const SizedBox.shrink(),
                  dropdownColor: m3.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                  items: const [
                    DropdownMenuItem(value: 'en', child: Text('English')),
                    DropdownMenuItem(value: 'de', child: Text('Deutsch')),
                    DropdownMenuItem(value: 'zh', child: Text('中文')),
                    DropdownMenuItem(value: 'hi', child: Text('हिन्दी')),
                    DropdownMenuItem(value: 'es', child: Text('Español')),
                    DropdownMenuItem(value: 'fr', child: Text('Français')),
                    DropdownMenuItem(value: 'ar', child: Text('العربية')),
                    DropdownMenuItem(value: 'bn', child: Text('বাংলা')),
                    DropdownMenuItem(value: 'pt', child: Text('Português')),
                    DropdownMenuItem(value: 'ru', child: Text('Русский')),
                    DropdownMenuItem(value: 'ja', child: Text('日本語')),
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
          const SizedBox(height: 24),

          // Voice Transcription section.
          _SectionHeader(l.voiceTranscription),
          _GroupedCard(
            children: [
              _SwitchRow(
                icon: Icons.mic_outlined,
                title: l.autoSendVoice,
                subtitle: l.autoSendVoiceSubtitle,
                value: _selectedAutoSendVoiceTranscription,
                onChanged: (bool value) {
                  setState(() {
                    _selectedAutoSendVoiceTranscription = value;
                  });
                  widget.config.setAutoSendVoiceTranscription(value);
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          _InfoCard(text: l.autoSendVoiceInfo),
          const SizedBox(height: 24),

          // Message Display section (toggles only; typography is its own section).
          _SectionHeader(l.messageDisplay),
          _GroupedCard(
            children: [
              _SwitchRow(
                icon: Icons.psychology_alt_outlined,
                title: l.showReasoningTokens,
                subtitle: l.showReasoningTokensSubtitle,
                value: _selectedShowReasoningTokens,
                onChanged: (bool value) {
                  setState(() {
                    _selectedShowReasoningTokens = value;
                  });
                  widget.config.setShowReasoningTokens(value);
                },
              ),
              _divider(context),
              _SwitchRow(
                icon: Icons.info_outline,
                title: l.showModelInfo,
                subtitle: l.showModelInfoSubtitle,
                value: _selectedShowModelInfo,
                onChanged: (bool value) {
                  setState(() {
                    _selectedShowModelInfo = value;
                  });
                  widget.config.setShowModelInfo(value);
                },
              ),
              _divider(context),
              _SwitchRow(
                icon: Icons.speed_outlined,
                title: l.showTps,
                subtitle: l.showTpsSubtitle,
                value: _selectedShowTps,
                onChanged: (bool value) {
                  setState(() {
                    _selectedShowTps = value;
                  });
                  widget.config.setShowTps(value);
                },
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Typography section.
          const _SectionHeader('Typography'),
          _FilledCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.chatFontSize,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  l.chatFontSizeSubtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: m3.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value: _selectedChatFontSize,
                        min: kMinChatFontSize,
                        max: kMaxChatFontSize,
                        divisions:
                            (kMaxChatFontSize - kMinChatFontSize).round(),
                        label: '${_selectedChatFontSize.toStringAsFixed(0)} pt',
                        onChanged: (double value) {
                          setState(() {
                            _selectedChatFontSize = value;
                          });
                        },
                        onChangeEnd: (double value) {
                          widget.config.setChatFontSize(value);
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 56,
                      child: Text(
                        '${_selectedChatFontSize.toStringAsFixed(0)} pt',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  l.chatFontFamily,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  l.chatFontFamilySubtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: m3.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                _FontFamilyField(
                  value: _selectedChatFontFamily,
                  items: kSupportedChatFontFamilies
                      .map((id) => DropdownMenuItem<String>(
                            value: id,
                            child: Text(_fontFamilyLabel(id, l)),
                          ))
                      .toList(),
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
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: m3.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    l.fontSizePreview,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: _selectedChatFontSize,
                      fontFamily: resolveChatFontFamily(_selectedChatFontFamily),
                      height: 1.38,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // UI Scale section.
          _SectionHeader(l.uiScale),
          _FilledCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.uiScalePercentage(
                    (_selectedUiScale * 100).round().toString(),
                  ),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  l.uiScaleSubtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: m3.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value: _selectedUiScale,
                        min: kMinUiScale,
                        max: kMaxUiScale,
                        // 5% steps across the 80%-150% range => 14 divisions.
                        divisions: 14,
                        label:
                            '${(_selectedUiScale * 100).round()}%',
                        onChanged: (double value) {
                          setState(() {
                            _selectedUiScale = value;
                          });
                        },
                        onChangeEnd: (double value) {
                          widget.config.setUiScale(value);
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 56,
                      child: Text(
                        '${(_selectedUiScale * 100).round()}%',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: <double>[0.8, 1.0, 1.2].map((preset) {
                    final selected =
                        (_selectedUiScale - preset).abs() < 0.001;
                    return ChoiceChip(
                      label: Text('${(preset * 100).round()}%'),
                      selected: selected,
                      onSelected: (_) {
                        setState(() {
                          _selectedUiScale = preset;
                        });
                        widget.config.setUiScale(preset);
                      },
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // AI Context section.
          _SectionHeader(l.aiContext),
          _InfoCard(text: l.aiContextInfo),
          const SizedBox(height: 8),
          _GroupedCard(
            children: [
              _SwitchRow(
                icon: Icons.image_outlined,
                title: l.recentImagesInContext,
                subtitle: l.recentImagesInContextSubtitle,
                value: _selectedIncludeRecentImagesInHistory,
                onChanged: (bool value) {
                  setState(() {
                    _selectedIncludeRecentImagesInHistory = value;
                  });
                  widget.config.setIncludeRecentImagesInHistory(value);
                },
              ),
              _divider(context),
              _SwitchRow(
                icon: Icons.photo_library_outlined,
                title: l.allImagesInContext,
                subtitle: l.allImagesInContextSubtitle,
                value: _selectedIncludeAllImagesInHistory,
                onChanged: (bool value) {
                  setState(() {
                    _selectedIncludeAllImagesInHistory = value;
                  });
                  widget.config.setIncludeAllImagesInHistory(value);
                },
              ),
              _divider(context),
              _SwitchRow(
                icon: Icons.psychology_outlined,
                title: l.reasoningInContext,
                subtitle: l.reasoningInContextSubtitle,
                value: _selectedIncludeReasoningInHistory,
                onChanged: (bool value) {
                  setState(() {
                    _selectedIncludeReasoningInHistory = value;
                  });
                  widget.config.setIncludeReasoningInHistory(value);
                },
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Downloads section: nav row into DownloadSettingsPage.
          _SectionHeader(l.downloads),
          _GroupedCard(
            children: [
              _NavRow(
                icon: Icons.folder_outlined,
                title: l.downloads,
                subtitle: l.downloadsSubtitle,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const DownloadSettingsPage(),
                    ),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Auto Chat Titles section.
          _SectionHeader(l.chatTitles),
          _GroupedCard(
            children: [
              _SwitchRow(
                icon: Icons.auto_awesome_outlined,
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
              ),
            ],
          ),
          if (_autoGenerateTitles && !_isLoadingTitleSetting) ...[
            const SizedBox(height: 12),
            _buildSystemPromptEditor(),
          ],
          const SizedBox(height: 8),
          _InfoCard(text: l.titleGenInfo),
          const SizedBox(height: 16),

          // Image generation is now handled via tool calling (generate_image tool)
        ],
      ),
    );
  }

  Widget _divider(BuildContext context) {
    final m3 = Theme.of(context).m3;
    return Divider(height: 1, color: m3.outlineVariant, indent: 56);
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

  Widget _buildSystemPromptEditor() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;
    final l = AppLocalizations.of(context)!;
    return Container(
      decoration: BoxDecoration(
        color: m3.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () {
              setState(() {
                _isPromptExpanded = !_isPromptExpanded;
              });
            },
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(Icons.edit_note, size: 24, color: m3.onSurfaceVariant),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.titleGenerationPrompt,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _hasCustomPrompt
                              ? l.usingCustomPrompt
                              : l.usingDefaultPrompt,
                          style: TextStyle(
                            fontSize: 12,
                            color: m3.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    _isPromptExpanded ? Icons.expand_less : Icons.expand_more,
                    color: m3.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (_isPromptExpanded) ...[
            Divider(height: 1, color: m3.outlineVariant),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'System prompt used to generate titles:',
                    style: TextStyle(
                      fontSize: 12,
                      color: m3.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _promptController,
                    maxLines: 6,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton.icon(
                        onPressed: _resetSystemPrompt,
                        icon: const Icon(Icons.restore, size: 18),
                        label: Text(l.reset),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: _saveSystemPrompt,
                        icon: const Icon(Icons.save, size: 18),
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
}

// ---- Shared UI primitives (colocated because both pages use them) ----

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.5,
          color: cs.primary,
        ),
      ),
    );
  }
}

class _GroupedCard extends StatelessWidget {
  final List<Widget> children;
  const _GroupedCard({required this.children});

  @override
  Widget build(BuildContext context) {
    final m3 = Theme.of(context).m3;
    return Container(
      decoration: BoxDecoration(
        color: m3.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

class _FilledCard extends StatelessWidget {
  final Widget child;
  const _FilledCard({required this.child});

  @override
  Widget build(BuildContext context) {
    final m3 = Theme.of(context).m3;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: m3.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: child,
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const _SwitchRow({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final m3 = Theme.of(context).m3;
    final enabled = onChanged != null;
    return InkWell(
      onTap: enabled ? () => onChanged!(!value) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 24, color: m3.onSurfaceVariant),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 12,
                        color: m3.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Switch.adaptive(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}

class _NavRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  const _NavRow({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final m3 = Theme.of(context).m3;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 24, color: m3.onSurfaceVariant),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 12,
                        color: m3.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: m3.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final String text;
  const _InfoCard({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
      decoration: BoxDecoration(
        color: m3.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: m3.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                color: m3.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Dropdown styled as a filled TextField to match the rest of the surface.
class _FontFamilyField extends StatelessWidget {
  final String value;
  final List<DropdownMenuItem<String>> items;
  final ValueChanged<String?> onChanged;

  const _FontFamilyField({
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: m3.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          dropdownColor: m3.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}
