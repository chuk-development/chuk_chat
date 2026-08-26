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
import 'package:chuk_chat/widgets/expressive_settings.dart';

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
  late bool _selectedIncludeToolResultsInHistory;
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
    _selectedIncludeToolResultsInHistory =
        widget.config.includeToolResultsInHistory;
    // Fall back to English if a previously stored locale is no longer offered.
    _selectedLocale = AppLocalizations.supportedLocales.any(
      (l) => l.languageCode == widget.config.uiLocale,
    )
        ? widget.config.uiLocale
        : 'en';
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
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          // Language.
          ExpressiveSectionHeader(l.language),
          ExpressiveGroup(
            children: [
              ExpressiveRow(
                icon: Icons.language,
                title: l.language,
                subtitle: l.languageSubtitle,
                trailing: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedLocale,
                    dropdownColor: m3.surfaceContainerHigh,
                    borderRadius: kBorderRadiusMenu,
                    focusColor: Colors.transparent,
                    items: const [
                      DropdownMenuItem(value: 'en', child: Text('English')),
                      DropdownMenuItem(value: 'de', child: Text('Deutsch')),
                      DropdownMenuItem(value: 'es', child: Text('Español')),
                      DropdownMenuItem(value: 'fr', child: Text('Français')),
                      DropdownMenuItem(value: 'pt', child: Text('Português')),
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
                ),
              ),
            ],
          ),

          // Voice transcription.
          ExpressiveSectionHeader(l.voiceTranscription),
          ExpressiveGroup(
            children: [
              ExpressiveSwitchRow(
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
          ExpressiveInfoCard(text: l.autoSendVoiceInfo),

          // Message display (toggles only; typography is its own section).
          ExpressiveSectionHeader(l.messageDisplay),
          ExpressiveGroup(
            children: [
              ExpressiveSwitchRow(
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
              ExpressiveSwitchRow(
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
              ExpressiveSwitchRow(
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

          // Typography.
          const ExpressiveSectionHeader('Typography'),
          ExpressiveGroup(
            children: [
              ExpressiveCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _CardLabel(
                      title: l.chatFontSize,
                      subtitle: l.chatFontSizeSubtitle,
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
                            label:
                                '${_selectedChatFontSize.toStringAsFixed(0)} pt',
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
                  ],
                ),
              ),
              ExpressiveCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _CardLabel(
                      title: l.chatFontFamily,
                      subtitle: l.chatFontFamilySubtitle,
                    ),
                    const SizedBox(height: 10),
                    ExpressiveField(
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _selectedChatFontFamily,
                          isExpanded: true,
                          dropdownColor: m3.surfaceContainerHigh,
                          borderRadius: kBorderRadiusMenu,
                          // The default focus tint is a full-bleed rectangle
                          // drawn behind the rounded container — it is what
                          // makes a focused dropdown look square. The
                          // container already carries the shape.
                          focusColor: Colors.transparent,
                          items: kSupportedChatFontFamilies
                              .map((id) => DropdownMenuItem<String>(
                                    value: id,
                                    child: Text(_fontFamilyLabel(id, l)),
                                  ))
                              .toList(),
                          onChanged: (String? value) {
                            if (value == null ||
                                value == _selectedChatFontFamily) {
                              return;
                            }
                            setState(() {
                              _selectedChatFontFamily = value;
                            });
                            widget.config.setChatFontFamily(value);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ExpressiveField(
                      padding: const EdgeInsets.all(14),
                      child: SizedBox(
                        width: double.infinity,
                        child: Text(
                          l.fontSizePreview,
                          style: TextStyle(
                            color: cs.onSurface,
                            fontSize: _selectedChatFontSize,
                            fontFamily:
                                resolveChatFontFamily(_selectedChatFontFamily),
                            height: 1.38,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          // UI scale.
          ExpressiveSectionHeader(l.uiScale),
          ExpressiveGroup(
            children: [
              ExpressiveCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _CardLabel(
                      title: l.uiScalePercentage(
                        (_selectedUiScale * 100).round().toString(),
                      ),
                      subtitle: l.uiScaleSubtitle,
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
                            label: '${(_selectedUiScale * 100).round()}%',
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
            ],
          ),

          // AI context.
          ExpressiveSectionHeader(l.aiContext),
          ExpressiveInfoCard(text: l.aiContextInfo),
          const SizedBox(height: 8),
          ExpressiveGroup(
            children: [
              ExpressiveSwitchRow(
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
              ExpressiveSwitchRow(
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
              ExpressiveSwitchRow(
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
              ExpressiveSwitchRow(
                icon: Icons.build_outlined,
                title: l.toolResultsInContext,
                subtitle: l.toolResultsInContextSubtitle,
                value: _selectedIncludeToolResultsInHistory,
                onChanged: (bool value) {
                  setState(() {
                    _selectedIncludeToolResultsInHistory = value;
                  });
                  widget.config.setIncludeToolResultsInHistory(value);
                },
              ),
            ],
          ),

          // Downloads: nav row into DownloadSettingsPage.
          ExpressiveSectionHeader(l.downloads),
          ExpressiveGroup(
            children: [
              ExpressiveRow(
                icon: Icons.folder_outlined,
                title: l.downloads,
                subtitle: l.downloadsSubtitle,
                trailing: Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: m3.onSurfaceVariant,
                ),
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

          // Auto chat titles.
          ExpressiveSectionHeader(l.chatTitles),
          ExpressiveGroup(
            children: [
              ExpressiveSwitchRow(
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
              if (_autoGenerateTitles && !_isLoadingTitleSetting)
                ..._systemPromptEditor(l),
            ],
          ),
          const SizedBox(height: 8),
          ExpressiveInfoCard(text: l.titleGenInfo),

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

  /// The prompt editor is two tiles of the same group: the row that opens it,
  /// and the editor itself once it is open.
  List<Widget> _systemPromptEditor(AppLocalizations l) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;

    return [
      ExpressiveRow(
        icon: Icons.edit_note,
        title: l.titleGenerationPrompt,
        subtitle: _hasCustomPrompt ? l.usingCustomPrompt : l.usingDefaultPrompt,
        trailing: Icon(
          _isPromptExpanded ? Icons.expand_less : Icons.expand_more,
          color: m3.onSurfaceVariant,
        ),
        onTap: () {
          setState(() {
            _isPromptExpanded = !_isPromptExpanded;
          });
        },
      ),
      if (_isPromptExpanded)
        ExpressiveCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'System prompt used to generate titles:',
                style: theme.textTheme.bodySmall?.copyWith(
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
    ];
  }
}

/// Title and explanation at the top of a card that is not a row.
class _CardLabel extends StatelessWidget {
  const _CardLabel({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurface,
          ),
        ),
        if (subtitle?.isNotEmpty ?? false) ...[
          const SizedBox(height: 2),
          Text(
            subtitle!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.m3.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}
