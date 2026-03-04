import 'package:chuk_chat/services/nextcloud_service.dart';

/// Singleton Nextcloud service instance.
///
/// Web-safe: NextcloudService only uses package:http, no dart:io.
final NextcloudService _nextcloudService = NextcloudService();

/// Initialize Nextcloud — load saved credentials.
Future<void> initNextcloudService() async {
  await _nextcloudService.loadSavedCredentials();
}

/// Check if Nextcloud is configured.
bool isNextcloudConnected() => _nextcloudService.isConfigured;

/// Execute a Nextcloud tool action.
Future<String> executeNextcloud(Map<String, dynamic> args) async {
  if (!_nextcloudService.isConfigured) {
    return 'Error: Nextcloud not configured. '
        'Please set up Nextcloud credentials in Settings.';
  }

  final action = args['action'] as String?;
  if (action == null) return 'Error: No action specified';

  try {
    switch (action.toLowerCase()) {
      case 'list_files':
        final path = args['path'] as String? ?? '/';
        final result = await _nextcloudService.listFiles(path);
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        final files = result['files'] as List? ?? [];
        if (files.isEmpty) return 'No files found in $path';
        return 'Files in $path:\n${files.map((f) => '- ${(f as Map<String, dynamic>)['name']} (${f['isDirectory'] == true ? 'folder' : '${f['size'] ?? 0} bytes'})').join('\n')}';

      case 'download_file':
        final path = args['path'] as String?;
        if (path == null) return 'Error: No file path specified';
        final result = await _nextcloudService.downloadFile(path);
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        return 'File content:\n${result['content']}';

      case 'upload_file':
        final path = args['path'] as String?;
        final content = args['content'] as String?;
        if (path == null) return 'Error: No file path specified';
        if (content == null) return 'Error: No content specified';
        final result = await _nextcloudService.uploadFile(path, content);
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        return 'File uploaded successfully to $path';

      case 'delete_file':
        final path = args['path'] as String?;
        if (path == null) return 'Error: No file path specified';
        final result = await _nextcloudService.deleteFile(path);
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        return 'File deleted: $path';

      case 'create_directory':
        final path = args['path'] as String?;
        if (path == null) return 'Error: No directory path specified';
        final result = await _nextcloudService.createDirectory(path);
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        return 'Directory created: $path';

      case 'get_calendars':
        final result = await _nextcloudService.getCalendars();
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        final calendars = result['calendars'] as List? ?? [];
        if (calendars.isEmpty) return 'No calendars found';
        return 'Calendars:\n${calendars.map((c) => '- ${(c as Map<String, dynamic>)['name']} (${c['id']})').join('\n')}';

      case 'get_events':
        final calendarId = args['calendar_id'] as String?;
        if (calendarId == null) return 'Error: No calendar_id specified';
        final start = args['start_date'] as String?;
        final end = args['end_date'] as String?;
        final result = await _nextcloudService.getEvents(
          calendarId,
          startDate: start,
          endDate: end,
        );
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        final events = result['events'] as List? ?? [];
        if (events.isEmpty) return 'No events found';
        return 'Events:\n${events.map((e) => '- ${(e as Map<String, dynamic>)['summary']} (${e['start']} - ${e['end']})').join('\n')}';

      case 'get_contacts':
        final result = await _nextcloudService.getContacts();
        if (result['success'] != true) {
          return 'Error: ${result['error']}';
        }
        final contacts = result['contacts'] as List? ?? [];
        if (contacts.isEmpty) return 'No contacts found';
        return 'Contacts:\n${contacts.map((c) => '- ${(c as Map<String, dynamic>)['name']}${c['email'] != null ? ' (${c['email']})' : ''}').join('\n')}';

      default:
        return 'Unknown Nextcloud action: $action. '
            'Available: list_files, download_file, upload_file, '
            'delete_file, create_directory, get_calendars, '
            'get_events, get_contacts';
    }
  } catch (e) {
    return 'Nextcloud error: $e';
  }
}
