// lib/pages/system_prompt_page.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/tool_handlers/notes_tools.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/nice_snackbar.dart';
import 'package:chuk_chat/widgets/settings_kit.dart';

class SystemPromptPage extends StatefulWidget {
  const SystemPromptPage({super.key});

  @override
  State<SystemPromptPage> createState() => _SystemPromptPageState();
}

class _SystemPromptPageState extends State<SystemPromptPage> {
  final TextEditingController _systemPromptCtrl = TextEditingController();
  final TextEditingController _soulCtrl = TextEditingController();
  final TextEditingController _userInfoCtrl = TextEditingController();
  final TextEditingController _memoryCtrl = TextEditingController();

  bool _isSaving = false;
  bool _isLoading = true;
  String? _errorMessage;

  // Master toggle for the identity system (Soul / User / Memory).
  bool _identityEnabled = true;

  // Original values to detect changes.
  String? _originalPrompt;
  String _originalSoul = '';
  String _originalUserInfo = '';
  String _originalMemory = '';
  bool _originalIdentityEnabled = true;

  bool get _isDesktopPlatform {
    if (kIsWeb) return false;
    return switch (defaultTargetPlatform) {
      TargetPlatform.linux => true,
      TargetPlatform.windows => true,
      TargetPlatform.macOS => true,
      _ => false,
    };
  }

  String _selectedTextOrAll(TextEditingValue value) {
    final selection = value.selection;
    if (selection.isValid && !selection.isCollapsed) {
      return selection.textInside(value.text);
    }
    return value.text;
  }

  Widget _buildDesktopTextContextMenu(
    BuildContext context,
    EditableTextState editableTextState,
  ) {
    final buttonItems = List<ContextMenuButtonItem>.from(
      editableTextState.contextMenuButtonItems,
    );

    final hasCopy = buttonItems.any(
      (item) => item.type == ContextMenuButtonType.copy,
    );

    if (!hasCopy) {
      buttonItems.insert(
        0,
        ContextMenuButtonItem(
          type: ContextMenuButtonType.copy,
          onPressed: () {
            final text = _selectedTextOrAll(editableTextState.textEditingValue);
            if (text.isNotEmpty) {
              Clipboard.setData(ClipboardData(text: text));
            }
            ContextMenuController.removeAny();
          },
        ),
      );
    }

    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editableTextState.contextMenuAnchors,
      buttonItems: buttonItems,
    );
  }

  @override
  void initState() {
    super.initState();
    _loadAll();
    _systemPromptCtrl.addListener(_onTextChanged);
    _soulCtrl.addListener(_onTextChanged);
    _userInfoCtrl.addListener(_onTextChanged);
    _memoryCtrl.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _systemPromptCtrl.removeListener(_onTextChanged);
    _soulCtrl.removeListener(_onTextChanged);
    _userInfoCtrl.removeListener(_onTextChanged);
    _memoryCtrl.removeListener(_onTextChanged);
    _systemPromptCtrl.dispose();
    _soulCtrl.dispose();
    _userInfoCtrl.dispose();
    _memoryCtrl.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    setState(() {});
  }

  // ─── Loading ──────────────────────────────────────────────────────────

  Future<void> _loadAll() async {
    final stopwatch = Stopwatch()..start();
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Phase 1: Load from local SharedPreferences (instant, no network).
      final prefs = await SharedPreferences.getInstance();
      final localSystemPrompt =
          await UserPreferencesService.loadSystemPromptLocal();
      final localSoul = prefs.getString('identity_soul') ?? '';
      final localUserInfo = prefs.getString('identity_user') ?? '';
      final localMemory = prefs.getString('identity_memory') ?? '';
      final localIdentityOn = prefs.getBool('identity_enabled') ?? true;

      if (!mounted) return;
      setState(() {
        _originalPrompt = localSystemPrompt;
        _systemPromptCtrl.text = localSystemPrompt ?? '';
        _originalSoul = localSoul;
        _soulCtrl.text = localSoul;
        _originalUserInfo = localUserInfo;
        _userInfoCtrl.text = localUserInfo;
        _originalMemory = localMemory;
        _memoryCtrl.text = localMemory;
        _identityEnabled = localIdentityOn;
        _originalIdentityEnabled = localIdentityOn;
        _isLoading = false;
      });

      unawaited(
        DiagnosticsLogService.timing(
          'settings',
          'load_ai_identity_page',
          stopwatch.elapsedMilliseconds,
          data: {
            'platform': defaultTargetPlatform.name,
            'soul_len': localSoul.length,
            'user_len': localUserInfo.length,
            'memory_len': localMemory.length,
            'identity_enabled': localIdentityOn,
          },
        ),
      );

      // Phase 2: Sync from Supabase in background. If anything changed,
      // update the UI silently — only if the user hasn't started editing.
      unawaited(_backgroundSyncIdentity());
    } on StateError catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Encryption error: ${error.message}. '
            'You may need to sign out and sign in again.';
        _isLoading = false;
      });
      unawaited(
        DiagnosticsLogService.error(
          'settings',
          'AI identity load failed with state error',
          error: error,
          data: {
            'elapsed_ms': stopwatch.elapsedMilliseconds,
            'platform': defaultTargetPlatform.name,
          },
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to load: $error';
        _isLoading = false;
      });
      unawaited(
        DiagnosticsLogService.error(
          'settings',
          'AI identity load failed',
          error: error,
          data: {
            'elapsed_ms': stopwatch.elapsedMilliseconds,
            'platform': defaultTargetPlatform.name,
          },
        ),
      );
    }
  }

  // Refresh identity fields from Supabase in the background.
  // Updates the UI only if the user hasn't started editing.
  Future<void> _backgroundSyncIdentity() async {
    try {
      await syncIdentityFromSupabase(forceRefresh: true);
      final results = await Future.wait([
        UserPreferencesService.loadSystemPrompt(),
        loadSoulText(),
        loadUserInfoText(),
        loadMemoryText(),
        isIdentityEnabled(),
      ]);
      if (!mounted) return;
      final remoteSysPrompt = results[0] as String?;
      final remoteSoul = results[1] as String;
      final remoteUserInfo = results[2] as String;
      final remoteMemory = results[3] as String;
      final remoteIdentityOn = results[4] as bool;

      // Only overwrite fields the user hasn't touched yet.
      final bool userHasEdited = _hasAnyChanges;
      if (userHasEdited) return;

      final bool changed =
          remoteSysPrompt != _originalPrompt ||
          remoteSoul != _originalSoul ||
          remoteUserInfo != _originalUserInfo ||
          remoteMemory != _originalMemory ||
          remoteIdentityOn != _originalIdentityEnabled;
      if (!changed) return;

      if (!mounted) return;
      setState(() {
        _originalPrompt = remoteSysPrompt;
        _systemPromptCtrl.text = remoteSysPrompt ?? '';
        _originalSoul = remoteSoul;
        _soulCtrl.text = remoteSoul;
        _originalUserInfo = remoteUserInfo;
        _userInfoCtrl.text = remoteUserInfo;
        _originalMemory = remoteMemory;
        _memoryCtrl.text = remoteMemory;
        _identityEnabled = remoteIdentityOn;
        _originalIdentityEnabled = remoteIdentityOn;
      });
    } catch (error) {
      // Background sync failure is non-critical — local data is displayed.
      if (kDebugMode) {
        debugPrint('Background identity sync failed: $error');
      }
    }
  }

  // ─── Save all ─────────────────────────────────────────────────────────

  Future<void> _saveAll() async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      final prompt = _systemPromptCtrl.text.trim();
      final soul = _soulCtrl.text.trim();
      final userInfo = _userInfoCtrl.text.trim();
      final memory = _memoryCtrl.text.trim();

      await Future.wait([
        // System prompt (encrypted in Supabase).
        if (_hasPromptChanges)
          prompt.isEmpty
              ? UserPreferencesService.clearSystemPrompt()
              : UserPreferencesService.saveSystemPrompt(prompt),
        // Soul + User + Memory (local cache + Supabase sync).
        if (_hasSoulChanges) saveSoulText(soul),
        if (_hasUserInfoChanges) saveUserInfoText(userInfo),
        if (_hasMemoryChanges) saveMemoryText(memory),
      ]);

      if (!mounted) return;
      setState(() {
        _originalPrompt = prompt.isEmpty ? null : prompt;
        _originalSoul = soul;
        _originalUserInfo = userInfo;
        _originalMemory = memory;
        _isSaving = false;
      });

      _showSnackBar('Saved');
    } on StateError catch (error) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _errorMessage =
            'Encryption error: ${error.message}. '
            'You may need to sign out and sign in again.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _errorMessage = 'Failed to save: $error';
      });
    }
  }

  // ─── Change detection ─────────────────────────────────────────────────

  bool get _hasPromptChanges =>
      _systemPromptCtrl.text.trim() != (_originalPrompt ?? '');

  bool get _hasSoulChanges => _soulCtrl.text.trim() != _originalSoul;

  bool get _hasUserInfoChanges =>
      _userInfoCtrl.text.trim() != _originalUserInfo;

  bool get _hasMemoryChanges => _memoryCtrl.text.trim() != _originalMemory;

  bool get _hasIdentityToggleChanged =>
      _identityEnabled != _originalIdentityEnabled;

  bool get _hasAnyChanges =>
      _hasPromptChanges ||
      _hasSoulChanges ||
      _hasUserInfoChanges ||
      _hasMemoryChanges ||
      _hasIdentityToggleChanged;

  // ─── Import memory from another AI ────────────────────────────────────

  static const String _importPrompt =
      "I'm moving to another service and need to export my data. "
      'List every memory you have stored about me, as well as any context '
      "you've learned about me from past conversations. Output everything "
      'in a single code block so I can easily copy it. Format each entry '
      'as: [date saved, if available] - memory content.\n\n'
      'Make sure to cover all of the following — preserve my words verbatim '
      'where possible:\n'
      '- Instructions I\'ve given you about how to respond (tone, format, '
      "style, 'always do X', 'never do Y').\n"
      '- Personal details: name, location, job, family, interests.\n'
      '- Projects, goals, and recurring topics.\n'
      '- Tools, languages, and frameworks I use.\n'
      '- Preferences and corrections I\'ve made to your behavior.\n'
      '- Any other stored context not covered above.\n\n'
      'Do not summarize, group, or omit any entries. After the code block, '
      'confirm whether that is the complete set or if any remain.';

  Future<void> _importMemory() async {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final m3 = theme.m3;

    // Step 1: Show the prompt the user should paste into their old AI.
    final goToStep2 = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import from another AI'),
        content: SizedBox(
          width: 500,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Step 1: Copy this prompt and paste it into your '
                'other AI chat (ChatGPT, Claude, etc.):',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: m3.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: m3.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(
                  _importPrompt,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: colorScheme.onSurface,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy & continue'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _importPrompt));
              Navigator.pop(ctx, true);
            },
          ),
        ],
      ),
    );

    if (goToStep2 != true || !mounted) return;

    _showSnackBar('Prompt copied');

    // Step 2: Let the user paste the AI's response.
    final pasteCtrl = TextEditingController();

    final pastedText = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import from another AI'),
        content: SizedBox(
          width: 500,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Step 2: Paste the response from your other AI below:',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: m3.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: pasteCtrl,
                maxLines: 12,
                contextMenuBuilder: _isDesktopPlatform
                    ? _buildDesktopTextContextMenu
                    : null,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  height: 1.4,
                ),
                decoration: InputDecoration(
                  hintText: 'Paste the AI\'s response here...',
                  hintStyle: TextStyle(color: m3.onSurfaceVariant),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  filled: true,
                  fillColor: m3.surfaceContainerLow,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.download, size: 16),
            label: const Text('Import'),
            onPressed: () {
              final text = pasteCtrl.text.trim();
              if (text.isNotEmpty) {
                Navigator.pop(ctx, text);
              }
            },
          ),
        ],
      ),
    );

    pasteCtrl.dispose();
    if (pastedText == null || pastedText.isEmpty || !mounted) return;

    // Append the imported text to existing memory (or replace if empty).
    final existing = _memoryCtrl.text.trim();
    if (existing.isEmpty) {
      _memoryCtrl.text = pastedText;
    } else {
      _memoryCtrl.text = '$existing\n\n--- Imported ---\n$pastedText';
    }

    // Auto-save immediately so it persists.
    await saveMemoryText(_memoryCtrl.text.trim());
    if (!mounted) return;
    setState(() => _originalMemory = _memoryCtrl.text.trim());
    _showSnackBar('Imported to memory');
  }

  void _showSnackBar(String text) {
    if (!mounted) return;
    NiceSnackBar.show(
      context,
      text,
      duration: const Duration(seconds: 1),
      backgroundColor: Theme.of(context).colorScheme.primary,
    );
  }

  // ─── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final m3 = theme.m3;
    final l = AppLocalizations.of(context)!;

    Widget bodyContent;

    if (_isLoading) {
      bodyContent = const Center(child: CircularProgressIndicator());
    } else {
      bodyContent = ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_errorMessage != null) ...[
            SettingsInfoCard(_errorMessage!, tone: SettingsInfoTone.danger),
            const SizedBox(height: 16),
          ],

          // ── Identity System (master toggle) ─────────────────────
          const SettingsSectionHeader(
            'IDENTITY SYSTEM',
            padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
          ),
          SettingsGroupedCard(
            children: [
              SettingsRow(
                leading: SettingsLeadingIcon(
                  icon: Icons.psychology,
                  tint: _identityEnabled
                      ? colorScheme.primary
                      : m3.onSurfaceVariant,
                ),
                title: l.identitySystem,
                subtitle: _identityEnabled
                    ? l.identityActive
                    : l.identityDisabled,
                trailing: Switch(
                  value: _identityEnabled,
                  onChanged: (value) async {
                    setState(() => _identityEnabled = value);
                    await setIdentityEnabled(value);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // ── Soul / User / Memory — dimmed when identity is off ──
          IgnorePointer(
            ignoring: !_identityEnabled,
            child: AnimatedOpacity(
              opacity: _identityEnabled ? 1.0 : 0.35,
              duration: const Duration(milliseconds: 200),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── Soul ─────────────────────────────────────────
                  const SettingsSectionHeader(
                    'SOUL',
                    padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
                  ),
                  SettingsInfoCard(l.soulHint),
                  const SizedBox(height: 12),
                  _MaterialTextField(
                    controller: _soulCtrl,
                    hintText: l.soulExample,
                    minLines: 3,
                    maxLines: 10,
                    contextMenuBuilder: _isDesktopPlatform
                        ? _buildDesktopTextContextMenu
                        : null,
                  ),
                  const SizedBox(height: 24),

                  // ── User ─────────────────────────────────────────
                  const SettingsSectionHeader(
                    'USER',
                    padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
                  ),
                  SettingsInfoCard(l.userHint),
                  const SizedBox(height: 12),
                  _MaterialTextField(
                    controller: _userInfoCtrl,
                    hintText: l.userExample,
                    minLines: 3,
                    maxLines: 10,
                    contextMenuBuilder: _isDesktopPlatform
                        ? _buildDesktopTextContextMenu
                        : null,
                  ),
                  const SizedBox(height: 24),

                  // ── Memory ───────────────────────────────────────
                  const SettingsSectionHeader(
                    'MEMORY',
                    padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
                  ),
                  SettingsInfoCard(l.memoryHint),
                  const SizedBox(height: 12),
                  _MaterialTextField(
                    controller: _memoryCtrl,
                    hintText: l.memoryExample,
                    minLines: 3,
                    maxLines: 10,
                    contextMenuBuilder: _isDesktopPlatform
                        ? _buildDesktopTextContextMenu
                        : null,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.download_outlined, size: 18),
                        label: Text(l.importFromAnotherAi),
                        onPressed: _importMemory,
                        style: OutlinedButton.styleFrom(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 12,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${_memoryCtrl.text.length} ${l.characters}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: m3.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // ── Raw System Prompt ───────────────────────────────────
          const SettingsSectionHeader(
            'RAW SYSTEM PROMPT',
            padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
          ),
          SettingsInfoCard(l.systemPromptHint),
          const SizedBox(height: 12),
          _MaterialTextField(
            controller: _systemPromptCtrl,
            hintText: l.systemPromptExample,
            minLines: 3,
            maxLines: 16,
            contextMenuBuilder: _isDesktopPlatform
                ? _buildDesktopTextContextMenu
                : null,
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '${_systemPromptCtrl.text.length} ${l.characters}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: m3.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 24),

          // ── Save button ─────────────────────────────────────────
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton.icon(
              icon: _isSaving
                  ? SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(
                          colorScheme.onPrimary,
                        ),
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.check, size: 20),
              label: Text(_isSaving ? l.saving : l.saveChanges),
              onPressed: _isSaving || !_hasAnyChanges ? null : _saveAll,
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
                textStyle: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(height: 32),
        ],
      );
    }

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: Text(l.aiIdentityMemory),
        centerTitle: false,
        backgroundColor: colorScheme.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: bodyContent,
    );
  }
}

// ─── Reusable private pieces ─────────────────────────────────────────────

class _MaterialTextField extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;
  final int minLines;
  final int maxLines;
  final EditableTextContextMenuBuilder? contextMenuBuilder;

  const _MaterialTextField({
    required this.controller,
    required this.hintText,
    this.minLines = 4,
    this.maxLines = 8,
    this.contextMenuBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final m3 = theme.m3;
    return TextField(
      controller: controller,
      minLines: minLines,
      maxLines: maxLines,
      contextMenuBuilder: contextMenuBuilder,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: colorScheme.onSurface,
      ),
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: theme.textTheme.bodyMedium?.copyWith(
          color: m3.onSurfaceVariant,
        ),
        filled: true,
        fillColor: m3.surfaceContainer,
        contentPadding: const EdgeInsets.all(16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colorScheme.primary, width: 2),
        ),
      ),
    );
  }
}
