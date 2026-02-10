// lib/pages/system_prompt_page.dart
import 'package:flutter/material.dart';

import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

class SystemPromptPage extends StatefulWidget {
  const SystemPromptPage({super.key});

  @override
  State<SystemPromptPage> createState() => _SystemPromptPageState();
}

class _SystemPromptPageState extends State<SystemPromptPage> {
  final TextEditingController _systemPromptCtrl = TextEditingController();

  bool _isSaving = false;
  bool _isLoading = true;
  String? _errorMessage;
  String? _originalPrompt;

  @override
  void initState() {
    super.initState();
    _loadSystemPrompt();
    // Listen to text changes to update button state
    _systemPromptCtrl.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _systemPromptCtrl.removeListener(_onTextChanged);
    _systemPromptCtrl.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    // Trigger rebuild to update save button enabled state
    setState(() {});
  }

  Future<void> _loadSystemPrompt() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final systemPrompt = await UserPreferencesService.loadSystemPrompt();
      if (!mounted) return;
      setState(() {
        _originalPrompt = systemPrompt;
        _systemPromptCtrl.text = systemPrompt ?? '';
        _isLoading = false;
      });
    } on StateError catch (error) {
      // Handle encryption-related errors
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Encryption error: ${error.message}. '
            'You may need to sign out and sign in again.';
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to load system prompt: $error';
        _isLoading = false;
      });
    }
  }

  Future<void> _saveSystemPrompt() async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      final prompt = _systemPromptCtrl.text.trim();

      if (prompt.isEmpty) {
        await UserPreferencesService.clearSystemPrompt();
      } else {
        await UserPreferencesService.saveSystemPrompt(prompt);
      }

      if (!mounted) return;
      setState(() {
        _originalPrompt = prompt.isEmpty ? null : prompt;
        _isSaving = false;
      });

      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            prompt.isEmpty ? 'Cleared' : 'Saved',
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
    } on StateError catch (error) {
      // Handle encryption-related errors
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _errorMessage = 'Encryption error: ${error.message}. '
            'You may need to sign out and sign in again.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _errorMessage = 'Failed to save system prompt: $error';
      });
    }
  }

  Future<void> _clearSystemPrompt() async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      await UserPreferencesService.clearSystemPrompt();

      if (!mounted) return;
      setState(() {
        _originalPrompt = null;
        _systemPromptCtrl.clear();
        _isSaving = false;
      });

      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(
        SnackBar(
          content: const Text(
            'Cleared',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
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
    } on StateError catch (error) {
      // Handle encryption-related errors
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _errorMessage = 'Error: ${error.message}';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _errorMessage = 'Failed to clear system prompt: $error';
      });
    }
  }

  bool get _hasChanges {
    final currentText = _systemPromptCtrl.text.trim();
    final original = _originalPrompt ?? '';
    return currentText != original;
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

          _SystemPromptSectionCard(
            title: 'System Prompt',
            scaffoldBg: scaffoldBg,
            iconFg: iconFg,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Define a default system prompt that will be sent with every conversation. '
                  'This helps set the behavior and personality of the AI assistant.\n\n'
                  'Your system prompt is encrypted with the same encryption used for your chat messages, '
                  'protecting it with your password.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: iconFg.lighten(0.2),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _systemPromptCtrl,
                  maxLines: 12,
                  style: theme.textTheme.bodyMedium,
                  decoration: InputDecoration(
                    hintText:
                        'Example: You are a helpful and knowledgeable assistant. Provide concise, accurate, and insightful responses. When explaining complex topics, break them down into simple terms.',
                    hintStyle: TextStyle(
                      color: iconFg.withValues(alpha: 0.5),
                      fontSize: 14,
                    ),
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
                        width: 2,
                      ),
                    ),
                    filled: true,
                    fillColor: scaffoldBg.lighten(0.03),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Character count: ${_systemPromptCtrl.text.length}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: iconFg.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          _SystemPromptSectionCard(
            title: 'Tips',
            scaffoldBg: scaffoldBg,
            iconFg: iconFg,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildTipItem(
                  theme,
                  iconFg,
                  'Be specific',
                  'Clearly define the assistant\'s role, tone, and expertise.',
                ),
                const SizedBox(height: 12),
                _buildTipItem(
                  theme,
                  iconFg,
                  'Set boundaries',
                  'Specify what the assistant should or shouldn\'t do.',
                ),
                const SizedBox(height: 12),
                _buildTipItem(
                  theme,
                  iconFg,
                  'Format preferences',
                  'Tell the assistant how to structure responses (e.g., bullet points, step-by-step).',
                ),
                const SizedBox(height: 12),
                _buildTipItem(
                  theme,
                  iconFg,
                  'Keep it concise',
                  'Shorter system prompts often work better than lengthy ones.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),

          // Clear button (only show if there's a saved prompt)
          if (_originalPrompt != null && _originalPrompt!.isNotEmpty)
            SizedBox(
              width: double.infinity,
              height: 48,
              child: OutlinedButton.icon(
                icon: _isSaving
                    ? const SizedBox.shrink()
                    : const Icon(Icons.delete_outline),
                label: Text(_isSaving ? 'Clearing…' : 'Clear system prompt'),
                onPressed: _isSaving ? null : _clearSystemPrompt,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  side: BorderSide(color: Colors.red.withValues(alpha: 0.5)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          if (_originalPrompt != null && _originalPrompt!.isNotEmpty)
            const SizedBox(height: 16),

          // Save button
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
              label: Text(_isSaving ? 'Saving…' : 'Save changes'),
              onPressed: _isSaving || !_hasChanges ? null : _saveSystemPrompt,
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.onPrimary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        title: Text('System Prompt', style: titleTextStyle),
        backgroundColor: scaffoldBg,
        elevation: 0,
        iconTheme: IconThemeData(color: iconFg),
      ),
      body: bodyContent,
    );
  }

  Widget _buildTipItem(
    ThemeData theme,
    Color iconFg,
    String title,
    String description,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.lightbulb_outline,
          size: 20,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: iconFg,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: iconFg.lighten(0.2),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SystemPromptSectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  final Color scaffoldBg;
  final Color iconFg;

  const _SystemPromptSectionCard({
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
        border: Border.all(
          color: iconFg.withValues(alpha: 0.3),
          width: 1,
        ),
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
