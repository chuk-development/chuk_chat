// lib/utils/url_launcher_helper.dart

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens [url] in the system browser.
///
/// A failure is not shown to the user: every caller is a footer link (terms,
/// privacy, the project page). There is nothing to recover from and nothing
/// worth interrupting the screen for, so the failure only reaches the debug
/// log.
Future<void> launchExternalUrl(String url) async {
  final Uri uri = Uri.parse(url);
  if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
    if (kDebugMode) {
      // The URL itself is not logged: these carry query values that can
      // include tokens or an email address.
      debugPrint('Could not launch external URL');
    }
  }
}
