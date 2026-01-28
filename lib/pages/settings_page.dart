// lib/pages/settings_page.dart
import 'dart:convert';
import 'package:chuk_chat/utils/io_helper.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:chuk_chat/model_selector_page.dart';
import 'package:chuk_chat/pages/theme_page.dart';
import 'package:chuk_chat/pages/customization_page.dart';
import 'package:chuk_chat/pages/account_settings_page.dart';
import 'package:chuk_chat/pages/about_page.dart';
import 'package:chuk_chat/pages/pricing_page.dart';
import 'package:chuk_chat/pages/system_prompt_page.dart';
import 'package:chuk_chat/services/auth_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:share_plus/share_plus.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

class SettingsPage extends StatelessWidget {
  final Brightness currentThemeMode;
  final Color currentAccentColor;
  final Color currentIconFgColor;
  final Color currentBgColor;

  final Function(Brightness) setThemeMode;
  final Function(Color) setAccentColor;
  final Function(Color) setIconFgColor;
  final Function(Color) setBgColor;

  // Film grain
  final bool grainEnabled;
  final Function(bool) setGrainEnabled;

  // Message display preferences
  final bool showReasoningTokens;
  final Function(bool) setShowReasoningTokens;
  final bool showModelInfo;
  final Function(bool) setShowModelInfo;
  final bool showTps;
  final Function(bool) setShowTps;

  // Customization preferences
  final bool autoSendVoiceTranscription;
  final Function(bool) setAutoSendVoiceTranscription;

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

  const SettingsPage({
    super.key,
    required this.currentThemeMode,
    required this.currentAccentColor,
    required this.currentIconFgColor,
    required this.currentBgColor,
    required this.setThemeMode,
    required this.setAccentColor,
    required this.setIconFgColor,
    required this.setBgColor,
    required this.grainEnabled,
    required this.setGrainEnabled,
    required this.showReasoningTokens,
    required this.setShowReasoningTokens,
    required this.showModelInfo,
    required this.setShowModelInfo,
    required this.showTps,
    required this.setShowTps,
    required this.autoSendVoiceTranscription,
    required this.setAutoSendVoiceTranscription,
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
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color scaffoldBg = theme.scaffoldBackgroundColor;
    final Color accent = theme.colorScheme.primary;
    final Color iconFg = theme.resolvedIconColor;
    final TextStyle? titleTextStyle = theme.appBarTheme.titleTextStyle;

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        title: Text('Settings', style: titleTextStyle),
        backgroundColor: scaffoldBg,
        elevation: 0,
        iconTheme: IconThemeData(color: iconFg),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // Theme Settings
          _buildSettingsCard(
            context,
            title: 'Theme Settings',
            subtitle: 'Adjust app theme, colors, and appearance',
            icon: Icons.palette,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ThemePage(
                    currentThemeMode: currentThemeMode,
                    currentAccentColor: currentAccentColor,
                    currentIconFgColor: currentIconFgColor,
                    currentBgColor: currentBgColor,
                    setThemeMode: setThemeMode,
                    setAccentColor: setAccentColor,
                    setIconFgColor: setIconFgColor,
                    setBgColor: setBgColor,
                    grainEnabled: grainEnabled,
                    setGrainEnabled: setGrainEnabled,
                  ),
                ),
              );
            },
            accentColor: accent,
            iconFgColor: iconFg,
            bgColor: scaffoldBg,
          ),
          const SizedBox(height: 16),

          // Customization Settings
          _buildSettingsCard(
            context,
            title: 'Customization',
            subtitle: 'Configure app behavior and preferences',
            icon: Icons.tune,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => CustomizationPage(
                    autoSendVoiceTranscription: autoSendVoiceTranscription,
                    setAutoSendVoiceTranscription: setAutoSendVoiceTranscription,
                    showReasoningTokens: showReasoningTokens,
                    setShowReasoningTokens: setShowReasoningTokens,
                    showModelInfo: showModelInfo,
                    setShowModelInfo: setShowModelInfo,
                    showTps: showTps,
                    setShowTps: setShowTps,
                    imageGenEnabled: imageGenEnabled,
                    setImageGenEnabled: setImageGenEnabled,
                    imageGenDefaultSize: imageGenDefaultSize,
                    setImageGenDefaultSize: setImageGenDefaultSize,
                    imageGenCustomWidth: imageGenCustomWidth,
                    setImageGenCustomWidth: setImageGenCustomWidth,
                    imageGenCustomHeight: imageGenCustomHeight,
                    setImageGenCustomHeight: setImageGenCustomHeight,
                    imageGenUseCustomSize: imageGenUseCustomSize,
                    setImageGenUseCustomSize: setImageGenUseCustomSize,
                  ),
                ),
              );
            },
            accentColor: accent,
            iconFgColor: iconFg,
            bgColor: scaffoldBg,
          ),
          const SizedBox(height: 16),

          // Model Selection
          _buildSettingsCard(
            context,
            title: 'Model Selection',
            subtitle: 'Choose and configure your AI models',
            icon: Icons.psychology_alt,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ModelSelectorPage()),
              );
            },
            accentColor: accent,
            iconFgColor: iconFg,
            bgColor: scaffoldBg,
          ),
          const SizedBox(height: 16),

          // System Prompt
          _buildSettingsCard(
            context,
            title: 'System Prompt',
            subtitle: 'Set a default system prompt for all conversations',
            icon: Icons.code,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SystemPromptPage()),
              );
            },
            accentColor: accent,
            iconFgColor: iconFg,
            bgColor: scaffoldBg,
          ),
          const SizedBox(height: 16),

          // Pricing Plans
          _buildSettingsCard(
            context,
            title: 'Pricing Plans',
            subtitle: 'View our subscription plans and pricing',
            icon: Icons.credit_card,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PricingPage()),
              );
            },
            accentColor: accent,
            iconFgColor: iconFg,
            bgColor: scaffoldBg,
          ),
          const SizedBox(height: 16),

          // Account Settings
          _buildSettingsCard(
            context,
            title: 'Account Settings',
            subtitle: 'Manage your profile and account',
            icon: Icons.person_outline,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AccountSettingsPage()),
              );
            },
            accentColor: accent,
            iconFgColor: iconFg,
            bgColor: scaffoldBg,
          ),
          const SizedBox(height: 32),
          _buildSettingsCard(
            context,
            title: 'Export Chats',
            subtitle: 'Download your conversations as JSON',
            icon: Icons.download_outlined,
            onTap: () => _exportChats(context),
            accentColor: accent,
            iconFgColor: iconFg,
            bgColor: scaffoldBg,
          ),
          const SizedBox(height: 32),
          _buildSettingsCard(
            context,
            title: 'About',
            subtitle: 'Version details and open source licenses',
            icon: Icons.info_outline,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AboutPage()),
              );
            },
            accentColor: accent,
            iconFgColor: iconFg,
            bgColor: scaffoldBg,
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade600,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                final navigator = Navigator.of(context);
                try {
                  await const AuthService().signOut();
                  if (!navigator.mounted) return;
                  if (navigator.canPop()) {
                    navigator.pop();
                  }
                } on AuthServiceException catch (error) {
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(
                        error.message,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      behavior: SnackBarBehavior.floating,
                      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      duration: const Duration(seconds: 2),
                      dismissDirection: DismissDirection.horizontal,
                    ),
                  );
                } catch (error) {
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(
                        'Error: $error',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      behavior: SnackBarBehavior.floating,
                      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      duration: const Duration(seconds: 2),
                      dismissDirection: DismissDirection.horizontal,
                    ),
                  );
                }
              },
              child: const Text(
                'Logout',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _exportChats(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ChatStorageService.loadSavedChatsForSidebar();
      if (ChatStorageService.savedChats.isEmpty) {
        messenger.showSnackBar(
          SnackBar(
            content: const Text(
              'No chats to export',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            duration: const Duration(seconds: 2),
            dismissDirection: DismissDirection.horizontal,
          ),
        );
        return;
      }
      final jsonPayload = await ChatStorageService.exportChatsAsJson();
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final fileName = 'chuk_chat_export_$timestamp.json';
      final data = Uint8List.fromList(utf8.encode(jsonPayload));

      if (kIsWeb) {
        await Clipboard.setData(ClipboardData(text: jsonPayload));
        messenger.showSnackBar(
          SnackBar(
            content: const Text(
              'Copied to clipboard',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            duration: const Duration(seconds: 2),
            dismissDirection: DismissDirection.horizontal,
          ),
        );
        return;
      }

      if (Platform.isLinux) {
        final savedPath = await _saveExportToLinux(data, fileName);
        if (savedPath != null) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                'Saved to $savedPath',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              behavior: SnackBarBehavior.floating,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              duration: const Duration(seconds: 2),
              dismissDirection: DismissDirection.horizontal,
            ),
          );
        } else {
          messenger.showSnackBar(
            SnackBar(
              content: const Text(
                'Export cancelled',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
              behavior: SnackBarBehavior.floating,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              duration: const Duration(seconds: 1),
              dismissDirection: DismissDirection.horizontal,
            ),
          );
        }
        return;
      }

      try {
        final xFile = XFile.fromData(
          data,
          mimeType: 'application/json',
          name: fileName,
        );
        await SharePlus.instance.share(
          ShareParams(
            files: [xFile],
            subject: 'chuk.chat chat export',
            text: 'Backup of your chuk.chat conversations.',
          ),
        );
        messenger.showSnackBar(
          SnackBar(
            content: const Text(
              'Share opened',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            duration: const Duration(seconds: 1),
            dismissDirection: DismissDirection.horizontal,
          ),
        );
      } on Exception {
        await Clipboard.setData(ClipboardData(text: jsonPayload));
        messenger.showSnackBar(
          SnackBar(
            content: const Text(
              'Copied to clipboard',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            duration: const Duration(seconds: 2),
            dismissDirection: DismissDirection.horizontal,
          ),
        );
      }
    } on StateError catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            error.message,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          duration: const Duration(seconds: 2),
          dismissDirection: DismissDirection.horizontal,
        ),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Export failed: $error',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          duration: const Duration(seconds: 2),
          dismissDirection: DismissDirection.horizontal,
        ),
      );
    }
  }

  Future<String?> _saveExportToLinux(Uint8List data, String fileName) async {
    final Directory? initialDirectory = await _linuxInitialDirectory();
    final String? outputPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save chat export',
      fileName: fileName,
      initialDirectory: initialDirectory?.path,
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );

    if (outputPath == null) {
      return null;
    }

    final file = File(outputPath);
    await file.writeAsBytes(data, flush: true);
    return file.path;
  }

  Future<Directory?> _linuxInitialDirectory() async {
    final String? homeDir = Platform.environment['HOME'];
    if (homeDir == null || homeDir.isEmpty) {
      return null;
    }

    final List<String> candidateFolders = <String>[
      '$homeDir/Downloads',
      '$homeDir/Documents',
      homeDir,
    ];

    for (final path in candidateFolders) {
      final directory = Directory(path);
      if (await directory.exists()) {
        return directory;
      }
    }
    return null;
  }

  Widget _buildSettingsCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
    required Color accentColor,
    required Color iconFgColor,
    required Color bgColor,
  }) {
    return Card(
      color: bgColor.lighten(0.05),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: iconFgColor.withValues(alpha: 0.3), width: 1),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Icon(icon, color: accentColor),
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
          style: TextStyle(color: iconFgColor.lighten(0.3), fontSize: 13),
        ),
        trailing: Icon(Icons.arrow_forward_ios, color: iconFgColor),
        onTap: onTap,
      ),
    );
  }
}
