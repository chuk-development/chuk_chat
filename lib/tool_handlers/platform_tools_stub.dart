// Web stubs for platform-specific tools.
//
// These tools require dart:io and are not available on web builds.

Future<String> executeSpotify(Map<String, dynamic> args) async {
  return 'Spotify control is not available on web.';
}

Future<String> executeBash(Map<String, dynamic> args) async {
  return 'Bash commands are not available on web.';
}

Future<String> executeGitHub(Map<String, dynamic> args) async {
  return 'GitHub integration is not available on web.';
}

Future<String> executeSlack(Map<String, dynamic> args) async {
  return 'Slack integration is not available on web.';
}

Future<String> executeGoogleCalendar(Map<String, dynamic> args) async {
  return 'Google Calendar is not available on web.';
}

Future<String> executeGmail(Map<String, dynamic> args) async {
  return 'Gmail is not available on web.';
}

Future<String> executeEmail(Map<String, dynamic> args) async {
  return 'Email (IMAP/SMTP) is not available on web.';
}

Future<String> executeDevice(Map<String, dynamic> args) async {
  return 'Device features are not available on web.';
}

/// Initialize platform services (no-op on web).
Future<void> initPlatformServices() async {}

/// Check if a platform service is connected (always false on web).
bool isPlatformServiceConnected(String service) => false;
