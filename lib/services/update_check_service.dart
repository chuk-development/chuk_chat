// lib/services/update_check_service.dart

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:chuk_chat/utils/io_helper.dart';

/// Checks for app updates via the public GitHub Releases API.
/// Compares the installed version against the latest release tag
/// and provides a platform-specific direct download URL.
class UpdateCheckService {
  const UpdateCheckService._();

  static const String _owner = 'chuk-development';
  static const String _repo = 'chuk_chat_releases';
  static const String _apiUrl =
      'https://api.github.com/repos/$_owner/$_repo/releases/latest';
  static const Duration _httpTimeout = Duration(seconds: 5);

  /// Minimum interval between automatic checks (4 hours).
  static const Duration _checkInterval = Duration(hours: 4);

  /// Reactive notifier — widgets listen to this for update availability.
  static final ValueNotifier<UpdateInfo?> updateAvailable =
      ValueNotifier<UpdateInfo?>(null);

  static DateTime? _lastCheckTime;
  static bool _isChecking = false;

  /// Check for updates. Skips if checked recently (< 4 hours).
  /// Call this at app startup and when settings page is opened.
  static Future<void> checkForUpdate({bool force = false}) async {
    if (_isChecking) return;

    // Skip on web — web updates via Dokploy automatically
    if (kIsWeb) return;

    // Respect check interval unless forced
    if (!force && _lastCheckTime != null) {
      final elapsed = DateTime.now().difference(_lastCheckTime!);
      if (elapsed < _checkInterval) return;
    }

    _isChecking = true;

    try {
      final response = await http
          .get(
            Uri.parse(_apiUrl),
            headers: {'Accept': 'application/vnd.github.v3+json'},
          )
          .timeout(_httpTimeout);

      if (response.statusCode != 200) {
        if (kDebugMode) {
          debugPrint(
            '[UpdateCheck] GitHub API returned ${response.statusCode}',
          );
        }
        return;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final tagName = data['tag_name'] as String?;
      if (tagName == null || tagName.isEmpty) return;

      // Parse remote version (strip leading 'v')
      final remoteVersion = tagName.startsWith('v')
          ? tagName.substring(1)
          : tagName;

      // Get installed version
      final packageInfo = await PackageInfo.fromPlatform();
      final localVersion = packageInfo.version;

      if (_isNewerVersion(remoteVersion, localVersion)) {
        // Find the direct download URL for this platform/arch
        final assets = data['assets'] as List<dynamic>? ?? [];
        final downloadUrl = _findDownloadUrl(assets);
        final releasePage =
            'https://github.com/$_owner/$_repo/releases/tag/$tagName';

        updateAvailable.value = UpdateInfo(
          currentVersion: localVersion,
          latestVersion: remoteVersion,
          downloadUrl: downloadUrl,
          releasePageUrl: releasePage,
        );

        if (kDebugMode) {
          debugPrint(
            '[UpdateCheck] Update available: $localVersion -> $remoteVersion',
          );
        }
      } else {
        // Clear any previous update notification
        updateAvailable.value = null;
        if (kDebugMode) {
          debugPrint('[UpdateCheck] Up to date ($localVersion)');
        }
      }

      _lastCheckTime = DateTime.now();
    } on TimeoutException {
      if (kDebugMode) {
        debugPrint('[UpdateCheck] Timeout');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[UpdateCheck] Failed: $e');
      }
    } finally {
      _isChecking = false;
    }
  }

  /// Compare two semver strings. Returns true if [remote] is newer than [local].
  static bool _isNewerVersion(String remote, String local) {
    final remoteParts = remote.split('.').map(int.tryParse).toList();
    final localParts = local.split('.').map(int.tryParse).toList();

    for (int i = 0; i < remoteParts.length && i < localParts.length; i++) {
      final r = remoteParts[i] ?? 0;
      final l = localParts[i] ?? 0;
      if (r > l) return true;
      if (r < l) return false;
    }
    // If remote has more parts (e.g. 1.0.29.1 vs 1.0.29), treat as newer
    return remoteParts.length > localParts.length;
  }

  /// Find the best matching download URL for the current platform and architecture.
  static String? _findDownloadUrl(List<dynamic> assets) {
    final assetNames = <String, String>{};
    for (final asset in assets) {
      if (asset is Map<String, dynamic>) {
        final name = asset['name'] as String?;
        final url = asset['browser_download_url'] as String?;
        if (name != null && url != null) {
          assetNames[name.toLowerCase()] = url;
        }
      }
    }

    if (assetNames.isEmpty) return null;

    // Determine what asset pattern to look for based on platform + arch
    final patterns = _getAssetPatterns();

    for (final pattern in patterns) {
      for (final entry in assetNames.entries) {
        if (entry.key.contains(pattern)) {
          return entry.value;
        }
      }
    }

    return null;
  }

  /// Get ordered list of asset name patterns to match for the current platform.
  /// First match wins — most specific patterns come first.
  /// Uses io_helper Platform (real on native, stub on web).
  static List<String> _getAssetPatterns() {
    if (Platform.isAndroid) {
      // Prefer arm64 (most common modern Android), fall back to others
      return ['android-armv8', 'android-arm64', 'android-x64', 'android'];
    }
    if (Platform.isLinux) {
      final arch = _getLinuxArch();
      if (arch == 'aarch64' || arch == 'arm64') {
        return [
          'linux-arm64.deb',
          'linux-aarch64.appimage',
          'linux-arm64',
          'linux-aarch64',
        ];
      }
      // x86_64 default
      return [
        'linux-amd64.deb',
        'linux-x86_64.appimage',
        'linux-x86_64.rpm',
        'linux-amd64',
        'linux-x86_64',
      ];
    }
    if (Platform.isWindows) {
      return ['windows-x64-setup.exe', 'windows-x64-portable.zip', 'windows'];
    }
    if (Platform.isMacOS) {
      return ['macos.dmg', 'macos'];
    }
    if (Platform.isIOS) {
      return ['ios'];
    }
    return [];
  }

  /// Detect Linux CPU architecture via uname.
  /// Falls back to x86_64 on any error (including web where Process is unavailable).
  static String _getLinuxArch() {
    try {
      // Process.runSync is only available on native platforms.
      // On web this will throw; the catch returns the safe default.
      final result = Process.runSync('uname', const <String>['-m']);
      return result.stdout.toString().trim().toLowerCase();
    } catch (_) {
      return 'x86_64';
    }
  }

  /// Launch the download URL for the current platform.
  /// Falls back to the release page if no direct download is available.
  static Future<void> launchDownload() async {
    final info = updateAvailable.value;
    if (info == null) return;

    final url = info.downloadUrl ?? info.releasePageUrl;
    final uri = Uri.parse(url);

    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (kDebugMode) {
        debugPrint('[UpdateCheck] Could not launch $url');
      }
    }
  }

  /// Dismiss the update notification (user chose to skip).
  static void dismiss() {
    updateAvailable.value = null;
  }
}

/// Information about an available update.
class UpdateInfo {
  final String currentVersion;
  final String latestVersion;

  /// Direct download URL for the current platform's asset, or null.
  final String? downloadUrl;

  /// URL to the GitHub releases page (always available).
  final String releasePageUrl;

  const UpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.downloadUrl,
    required this.releasePageUrl,
  });
}
