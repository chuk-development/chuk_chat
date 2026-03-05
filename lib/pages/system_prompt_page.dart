// lib/pages/system_prompt_page.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/tool_handlers/notes_tools.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

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

  /// Master toggle for the identity system (Soul / User / Memory).
  bool _identityEnabled = true;

  // Original values to detect changes.
  String? _originalPrompt;
  String _originalSoul = '';
  String _originalUserInfo = '';
  String _originalMemory = '';

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
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final results = await Future.wait([
        UserPreferencesService.loadSystemPrompt(),
        loadSoulText(),
        loadUserInfoText(),
        loadMemoryText(),
        isIdentityEnabled(),
      ]);
      if (!mounted) return;
      final systemPrompt = results[0] as String?;
      final soul = results[1] as String;
      final userInfo = results[2] as String;
      final memory = results[3] as String;
      final identityOn = results[4] as bool;
      setState(() {
        _originalPrompt = systemPrompt;
        _systemPromptCtrl.text = systemPrompt ?? '';
        _originalSoul = soul;
        _soulCtrl.text = soul;
        _originalUserInfo = userInfo;
        _userInfoCtrl.text = userInfo;
        _originalMemory = memory;
        _memoryCtrl.text = memory;
        _identityEnabled = identityOn;
        _isLoading = false;
      });
    } on StateError catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Encryption error: ${error.message}. '
            'You may need to sign out and sign in again.';
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to load: $error';
        _isLoading = false;
      });
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

  bool get _hasAnyChanges =>
      _hasPromptChanges ||
      _hasSoulChanges ||
      _hasUserInfoChanges ||
      _hasMemoryChanges;

  // ─── Memory helpers ────────────────────────────────────────────────────

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
    final Color scaffoldBg = theme.scaffoldBackgroundColor;
    final Color iconFg = theme.resolvedIconColor;

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
                  color: iconFg.lighten(0.2),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scaffoldBg.lighten(0.03),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: iconFg.withValues(alpha: 0.2)),
                ),
                child: SelectableText(
                  _importPrompt,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: iconFg,
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
                  color: iconFg.lighten(0.2),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: pasteCtrl,
                maxLines: 12,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  height: 1.4,
                ),
                decoration: InputDecoration(
                  hintText: 'Paste the AI\'s response here...',
                  hintStyle: TextStyle(color: iconFg.withValues(alpha: 0.4)),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  filled: true,
                  fillColor: scaffoldBg.lighten(0.03),
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          text,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        backgroundColor: Theme.of(context).colorScheme.primary,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        duration: const Duration(seconds: 1),
        dismissDirection: DismissDirection.horizontal,
      ),
    );
  }

  // ─── Build ────────────────────────────────────────────────────────────

  InputDecoration _fieldDecoration({
    required String hintText,
    required Color iconFg,
    required Color scaffoldBg,
    required ThemeData theme,
  }) {
    return InputDecoration(
      hintText: hintText,
      hintStyle: TextStyle(color: iconFg.withValues(alpha: 0.5), fontSize: 14),
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
        borderSide: BorderSide(color: theme.colorScheme.primary, width: 2),
      ),
      filled: true,
      fillColor: scaffoldBg.lighten(0.03),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color scaffoldBg = theme.scaffoldBackgroundColor;
    final Color iconFg = theme.resolvedIconColor;
    final TextStyle? titleTextStyle = theme.appBarTheme.titleTextStyle;

    Widget bodyContent;

    if (_isLoading) {
      bodyContent = const Center(child: CircularProgressIndicator());
    } else {
      bodyContent = ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_errorMessage != null)
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.1),
                border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _errorMessage!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.redAccent,
                ),
              ),
            ),

          // ── Identity toggle ──────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: scaffoldBg.lighten(0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: iconFg.withValues(alpha: 0.3),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.psychology,
                  color: _identityEnabled
                      ? theme.colorScheme.primary
                      : iconFg.withValues(alpha: 0.4),
                  size: 22,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Identity System',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: iconFg,
                        ),
                      ),
                      Text(
                        _identityEnabled
                            ? 'Soul, User, and Memory are active'
                            : 'Disabled — AI has no persistent identity',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: iconFg.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(
                  value: _identityEnabled,
                  onChanged: (value) async {
                    setState(() => _identityEnabled = value);
                    await setIdentityEnabled(value);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // ── Soul / User / Memory — dimmed when identity is off ──
          IgnorePointer(
            ignoring: !_identityEnabled,
            child: AnimatedOpacity(
              opacity: _identityEnabled ? 1.0 : 0.35,
              duration: const Duration(milliseconds: 200),
              child: Column(
                children: [
                  // ── Soul ──────────────────────────────────────────
                  _SectionCard(
                    title: 'Soul',
                    scaffoldBg: scaffoldBg,
                    iconFg: iconFg,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Define the AI\'s personality, tone, and '
                          'boundaries. This shapes how it communicates '
                          'across all conversations.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: iconFg.lighten(0.2),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _soulCtrl,
                          maxLines: 8,
                          style: theme.textTheme.bodyMedium,
                          decoration: _fieldDecoration(
                            hintText:
                                'Example:\n'
                                '- Be direct and concise\n'
                                '- Match the user\'s language and energy\n'
                                '- Have opinions, don\'t hedge everything\n'
                                '- Privacy first: ask before external actions',
                            iconFg: iconFg,
                            scaffoldBg: scaffoldBg,
                            theme: theme,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── User ──────────────────────────────────────────
                  _SectionCard(
                    title: 'User',
                    scaffoldBg: scaffoldBg,
                    iconFg: iconFg,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Facts about you. The AI reads this every message '
                          'and can also update it when it learns new things '
                          'about you.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: iconFg.lighten(0.2),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _userInfoCtrl,
                          maxLines: 8,
                          style: theme.textTheme.bodyMedium,
                          decoration: _fieldDecoration(
                            hintText:
                                'Example:\n'
                                '- Name: Alex\n'
                                '- Timezone: Europe/Berlin\n'
                                '- Language: German/English mix\n'
                                '- Prefers concise, technical answers',
                            iconFg: iconFg,
                            scaffoldBg: scaffoldBg,
                            theme: theme,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── Memory ─────────────────────────────────────────
                  _SectionCard(
                    title: 'Memory',
                    scaffoldBg: scaffoldBg,
                    iconFg: iconFg,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Long-term knowledge the AI remembers across '
                          'conversations. The AI can also update this '
                          'when it learns important facts or decisions.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: iconFg.lighten(0.2),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _memoryCtrl,
                          maxLines: 8,
                          style: theme.textTheme.bodyMedium,
                          decoration: _fieldDecoration(
                            hintText:
                                'Example:\n'
                                '- Prefers Dart/Flutter for mobile\n'
                                '- License: BSL for all projects\n'
                                '- Current project: chuk_chat\n'
                                '- Dark mode enthusiast',
                            iconFg: iconFg,
                            scaffoldBg: scaffoldBg,
                            theme: theme,
                          ),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.upload, size: 18),
                          label: const Text('Import from another AI'),
                          onPressed: _importMemory,
                          style: OutlinedButton.styleFrom(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── System Prompt ─────────────────────────────────────────
          _SectionCard(
            title: 'System Prompt',
            scaffoldBg: scaffoldBg,
            iconFg: iconFg,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Custom instructions sent with every conversation. '
                  'Encrypted with your chat encryption key.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: iconFg.lighten(0.2),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _systemPromptCtrl,
                  maxLines: 10,
                  style: theme.textTheme.bodyMedium,
                  decoration: _fieldDecoration(
                    hintText:
                        'Example: You are a helpful assistant. Provide '
                        'concise, accurate responses.',
                    iconFg: iconFg,
                    scaffoldBg: scaffoldBg,
                    theme: theme,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${_systemPromptCtrl.text.length} characters',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: iconFg.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ── Save button ───────────────────────────────────────────
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              icon: _isSaving
                  ? SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(
                          theme.colorScheme.onPrimary,
                        ),
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.check),
              label: Text(_isSaving ? 'Saving...' : 'Save changes'),
              onPressed: _isSaving || !_hasAnyChanges ? null : _saveAll,
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.onPrimary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
          const SizedBox(height: 32),
        ],
      );
    }

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        title: Text('AI Identity & Memory', style: titleTextStyle),
        backgroundColor: scaffoldBg,
        elevation: 0,
        iconTheme: IconThemeData(color: iconFg),
      ),
      body: bodyContent,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared card widget
// ─────────────────────────────────────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  final Color scaffoldBg;
  final Color iconFg;

  const _SectionCard({
    required this.title,
    required this.child,
    required this.scaffoldBg,
    required this.iconFg,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scaffoldBg.lighten(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: iconFg.withValues(alpha: 0.3), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: iconFg,
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}
