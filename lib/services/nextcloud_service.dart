import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Nextcloud Service - Credential-based (WebDAV/CalDAV/CardDAV)
///
/// Connects to Nextcloud servers for file, calendar, and contact management.
/// Web-safe: only uses package:http, no dart:io.
class NextcloudService {
  String? _serverUrl;
  String? _username;
  String? _password;

  bool get isConfigured =>
      _serverUrl != null && _username != null && _password != null;

  String? get serverUrl => _serverUrl;
  String? get username => _username;

  Future<void> loadSavedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    _serverUrl = prefs.getString('nextcloud_server_url');
    _username = prefs.getString('nextcloud_username');
    _password = prefs.getString('nextcloud_password');
  }

  Future<void> configure({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    _serverUrl = serverUrl.replaceAll(RegExp(r'/$'), '');
    _username = username;
    _password = password;
    await _saveCredentials();
  }

  Future<void> logout() async {
    _serverUrl = null;
    _username = null;
    _password = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('nextcloud_server_url');
    await prefs.remove('nextcloud_username');
    await prefs.remove('nextcloud_password');
  }

  Future<void> _saveCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    if (_serverUrl != null) {
      await prefs.setString('nextcloud_server_url', _serverUrl!);
    }
    if (_username != null) {
      await prefs.setString('nextcloud_username', _username!);
    }
    if (_password != null) {
      await prefs.setString('nextcloud_password', _password!);
    }
  }

  Map<String, String> get _authHeaders => {
    'Authorization':
        'Basic ${base64Encode(utf8.encode('$_username:$_password'))}',
    'OCS-APIRequest': 'true',
  };

  /// Build a WebDAV URL for a file inside the current user's Nextcloud root.
  ///
  /// Rejects AI-supplied paths that escape the user's own directory:
  /// * collapses `..`/`.` segments via `path.posix.normalize`,
  /// * forbids any remaining `..` segment (defence in depth),
  /// * percent-encodes each segment so `?`, `#`, `%`, spaces, and other
  ///   reserved characters can't split off a query or fragment,
  /// * throws [FormatException] on anything unsafe so every caller
  ///   (`downloadFile`, `uploadFile`, `deleteFile`, `createDirectory`,
  ///   `listFiles`) funnels through the same guard.
  Uri _buildUserFileUri(String remotePath) {
    if (_serverUrl == null || _username == null) {
      throw StateError('Nextcloud is not configured');
    }

    // Reject NULs and CR/LF up front — these don't belong in any URL path.
    if (remotePath.contains('\x00') ||
        remotePath.contains('\r') ||
        remotePath.contains('\n')) {
      throw const FormatException('remotePath contains control characters');
    }

    // Normalize using POSIX rules (Nextcloud DAV is '/'-separated
    // regardless of the client's OS) and strip any leading slash so the
    // result is always relative to the user's root.
    final normalized = p.posix.normalize(
      remotePath.startsWith('/') ? remotePath.substring(1) : remotePath,
    );

    // After normalization, a leading `..` means the caller tried to
    // escape — p.normalize preserves those rather than eating them.
    if (normalized == '..' || normalized.startsWith('../')) {
      throw const FormatException('remotePath escapes the user root');
    }

    // Build the segments: user root + the normalized path, each segment
    // percent-encoded. `''` from a trailing slash is dropped so `MKCOL`
    // and `PROPFIND` see a clean URL.
    final userRootSegments = ['remote.php', 'dav', 'files', _username!];
    final relativeSegments = normalized == '.'
        ? const <String>[]
        : normalized.split('/').where((s) => s.isNotEmpty);
    final allSegments = [...userRootSegments, ...relativeSegments];

    final base = Uri.parse(_serverUrl!);
    return base.replace(
      pathSegments: [
        ...base.pathSegments.where((s) => s.isNotEmpty),
        ...allSegments,
      ],
    );
  }

  /// Error payload returned when [_buildUserFileUri] rejects a path.
  Map<String, dynamic> _invalidPathError(Object e) => {
    'success': false,
    'error': 'Invalid remote path: $e',
  };

  Future<Map<String, dynamic>> testConnection() async {
    if (!isConfigured) {
      return {'success': false, 'error': 'Nextcloud is not configured'};
    }

    try {
      final request = http.Request(
        'PROPFIND',
        Uri.parse('$_serverUrl/remote.php/dav/files/$_username/'),
      );
      request.headers.addAll(_authHeaders);
      request.headers['Depth'] = '0';

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 207 || response.statusCode == 200) {
        return {
          'success': true,
          'message': 'Connected to Nextcloud successfully',
          'server': _serverUrl,
          'user': _username,
        };
      } else if (response.statusCode == 401) {
        return {
          'success': false,
          'error': 'Authentication failed. Check username and password.',
        };
      } else {
        return {
          'success': false,
          'error': 'Connection failed with status ${response.statusCode}',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Connection error: $e'};
    }
  }

  // ============== WebDAV File Operations ==============

  Future<Map<String, dynamic>> listFiles(String path) async {
    if (!isConfigured) {
      return {'success': false, 'error': 'Nextcloud is not configured'};
    }

    final Uri uri;
    try {
      uri = _buildUserFileUri(path);
    } on FormatException catch (e) {
      return _invalidPathError(e.message);
    }
    if (!path.startsWith('/')) path = '/$path';

    try {
      final request = http.Request('PROPFIND', uri);
      request.headers.addAll(_authHeaders);
      request.headers['Depth'] = '1';
      request.headers['Content-Type'] = 'application/xml';
      request.body =
          '<?xml version="1.0"?>'
          '<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">'
          '<d:prop>'
          '<d:displayname/><d:getcontenttype/>'
          '<d:getcontentlength/><d:getlastmodified/><oc:size/>'
          '</d:prop></d:propfind>';

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 207) {
        final files = _parseWebDavResponse(response.body, path);
        return {'success': true, 'path': path, 'files': files};
      } else {
        return {
          'success': false,
          'error': 'Failed to list files: ${response.statusCode}',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Error listing files: $e'};
    }
  }

  List<Map<String, dynamic>> _parseWebDavResponse(String xml, String basePath) {
    final files = <Map<String, dynamic>>[];

    final responseRegex = RegExp(
      r'<d:response>(.*?)</d:response>',
      dotAll: true,
    );
    final hrefRegex = RegExp(r'<d:href>(.*?)</d:href>');
    final displayNameRegex = RegExp(r'<d:displayname>(.*?)</d:displayname>');
    final contentTypeRegex = RegExp(
      r'<d:getcontenttype>(.*?)</d:getcontenttype>',
    );
    final contentLengthRegex = RegExp(
      r'<d:getcontentlength>(.*?)</d:getcontentlength>',
    );
    final lastModifiedRegex = RegExp(
      r'<d:getlastmodified>(.*?)</d:getlastmodified>',
    );
    final collectionRegex = RegExp(r'<d:collection\s*/?>');

    for (final match in responseRegex.allMatches(xml)) {
      final responseXml = match.group(1) ?? '';

      final href = hrefRegex.firstMatch(responseXml)?.group(1) ?? '';
      final displayName =
          displayNameRegex.firstMatch(responseXml)?.group(1) ?? '';
      final contentType = contentTypeRegex.firstMatch(responseXml)?.group(1);
      final contentLength = contentLengthRegex
          .firstMatch(responseXml)
          ?.group(1);
      final lastModified = lastModifiedRegex.firstMatch(responseXml)?.group(1);
      final isDirectory = collectionRegex.hasMatch(responseXml);

      final decodedHref = Uri.decodeComponent(href);
      if (decodedHref.endsWith(basePath) ||
          decodedHref.endsWith('$basePath/')) {
        continue;
      }

      final pathParts = decodedHref
          .split('/')
          .where((s) => s.isNotEmpty)
          .toList();
      final name = pathParts.isNotEmpty ? pathParts.last : displayName;

      files.add({
        'name': name,
        'displayName': displayName.isNotEmpty ? displayName : name,
        'path': decodedHref,
        'isDirectory': isDirectory,
        'contentType': contentType,
        'size': contentLength != null ? int.tryParse(contentLength) : null,
        'lastModified': lastModified,
      });
    }

    return files;
  }

  Future<Map<String, dynamic>> downloadFile(String remotePath) async {
    if (!isConfigured) {
      return {'success': false, 'error': 'Nextcloud is not configured'};
    }

    final Uri uri;
    try {
      uri = _buildUserFileUri(remotePath);
    } on FormatException catch (e) {
      return _invalidPathError(e.message);
    }
    if (!remotePath.startsWith('/')) remotePath = '/$remotePath';

    try {
      final response = await http.get(uri, headers: _authHeaders);

      if (response.statusCode == 200) {
        return {
          'success': true,
          'path': remotePath,
          'content': response.body,
          'contentType': response.headers['content-type'],
          'size': response.bodyBytes.length,
        };
      } else {
        return {
          'success': false,
          'error': 'Failed to download file: ${response.statusCode}',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Error downloading file: $e'};
    }
  }

  Future<Map<String, dynamic>> uploadFile(
    String remotePath,
    String content,
  ) async {
    if (!isConfigured) {
      return {'success': false, 'error': 'Nextcloud is not configured'};
    }

    final Uri uri;
    try {
      uri = _buildUserFileUri(remotePath);
    } on FormatException catch (e) {
      return _invalidPathError(e.message);
    }
    if (!remotePath.startsWith('/')) remotePath = '/$remotePath';

    try {
      final response = await http.put(
        uri,
        headers: {..._authHeaders, 'Content-Type': 'application/octet-stream'},
        body: utf8.encode(content),
      );

      if (response.statusCode == 201 || response.statusCode == 204) {
        return {
          'success': true,
          'message': 'File uploaded successfully',
          'path': remotePath,
        };
      } else {
        return {
          'success': false,
          'error': 'Failed to upload file: ${response.statusCode}',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Error uploading file: $e'};
    }
  }

  Future<Map<String, dynamic>> deleteFile(String remotePath) async {
    if (!isConfigured) {
      return {'success': false, 'error': 'Nextcloud is not configured'};
    }

    final Uri uri;
    try {
      uri = _buildUserFileUri(remotePath);
    } on FormatException catch (e) {
      return _invalidPathError(e.message);
    }
    if (!remotePath.startsWith('/')) remotePath = '/$remotePath';

    try {
      final request = http.Request('DELETE', uri);
      request.headers.addAll(_authHeaders);

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 204 || response.statusCode == 200) {
        return {
          'success': true,
          'message': 'File deleted successfully',
          'path': remotePath,
        };
      } else {
        return {
          'success': false,
          'error': 'Failed to delete file: ${response.statusCode}',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Error deleting file: $e'};
    }
  }

  Future<Map<String, dynamic>> createDirectory(String remotePath) async {
    if (!isConfigured) {
      return {'success': false, 'error': 'Nextcloud is not configured'};
    }

    final Uri uri;
    try {
      uri = _buildUserFileUri(remotePath);
    } on FormatException catch (e) {
      return _invalidPathError(e.message);
    }
    if (!remotePath.startsWith('/')) remotePath = '/$remotePath';

    try {
      final request = http.Request('MKCOL', uri);
      request.headers.addAll(_authHeaders);

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 201) {
        return {
          'success': true,
          'message': 'Directory created successfully',
          'path': remotePath,
        };
      } else {
        return {
          'success': false,
          'error': 'Failed to create directory: ${response.statusCode}',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Error creating directory: $e'};
    }
  }

  // ============== CalDAV Calendar Operations ==============

  Future<Map<String, dynamic>> getCalendars() async {
    if (!isConfigured) {
      return {'success': false, 'error': 'Nextcloud is not configured'};
    }

    try {
      final request = http.Request(
        'PROPFIND',
        Uri.parse('$_serverUrl/remote.php/dav/calendars/$_username/'),
      );
      request.headers.addAll(_authHeaders);
      request.headers['Depth'] = '1';
      request.headers['Content-Type'] = 'application/xml';
      request.body =
          '<?xml version="1.0"?>'
          '<d:propfind xmlns:d="DAV:" '
          'xmlns:cs="http://calendarserver.org/ns/" '
          'xmlns:c="urn:ietf:params:xml:ns:caldav">'
          '<d:prop><d:displayname/><cs:getctag/>'
          '<c:supported-calendar-component-set/>'
          '</d:prop></d:propfind>';

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 207) {
        final calendars = _parseCalendarList(response.body);
        return {'success': true, 'calendars': calendars};
      } else {
        return {
          'success': false,
          'error': 'Failed to get calendars: ${response.statusCode}',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Error getting calendars: $e'};
    }
  }

  List<Map<String, dynamic>> _parseCalendarList(String xml) {
    final calendars = <Map<String, dynamic>>[];

    final responseRegex = RegExp(
      r'<d:response>(.*?)</d:response>',
      dotAll: true,
    );
    final hrefRegex = RegExp(r'<d:href>(.*?)</d:href>');
    final displayNameRegex = RegExp(r'<d:displayname>(.*?)</d:displayname>');

    for (final match in responseRegex.allMatches(xml)) {
      final responseXml = match.group(1) ?? '';
      final href = hrefRegex.firstMatch(responseXml)?.group(1) ?? '';
      final displayName =
          displayNameRegex.firstMatch(responseXml)?.group(1) ?? '';

      if (href.endsWith('/calendars/$_username/')) continue;

      final pathParts = href.split('/').where((s) => s.isNotEmpty).toList();
      final calendarId = pathParts.isNotEmpty ? pathParts.last : '';

      if (calendarId.isNotEmpty &&
          !calendarId.startsWith('inbox') &&
          !calendarId.startsWith('outbox')) {
        calendars.add({
          'id': calendarId,
          'name': displayName.isNotEmpty ? displayName : calendarId,
          'href': href,
        });
      }
    }

    return calendars;
  }

  Future<Map<String, dynamic>> getEvents(
    String calendarId, {
    String? startDate,
    String? endDate,
  }) async {
    if (!isConfigured) {
      return {'success': false, 'error': 'Nextcloud is not configured'};
    }

    try {
      final now = DateTime.now();
      final start =
          startDate ??
          DateTime(now.year, now.month, 1).toIso8601String().split('T')[0];
      final end =
          endDate ??
          DateTime(now.year, now.month + 1, 0).toIso8601String().split('T')[0];

      final request = http.Request(
        'REPORT',
        Uri.parse(
          '$_serverUrl/remote.php/dav/calendars/$_username/$calendarId/',
        ),
      );
      request.headers.addAll(_authHeaders);
      request.headers['Depth'] = '1';
      request.headers['Content-Type'] = 'application/xml';
      request.body =
          '<?xml version="1.0"?>'
          '<c:calendar-query xmlns:d="DAV:" '
          'xmlns:c="urn:ietf:params:xml:ns:caldav">'
          '<d:prop><d:getetag/><c:calendar-data/></d:prop>'
          '<c:filter><c:comp-filter name="VCALENDAR">'
          '<c:comp-filter name="VEVENT">'
          '<c:time-range start="${start}T000000Z" '
          'end="${end}T235959Z"/>'
          '</c:comp-filter></c:comp-filter></c:filter>'
          '</c:calendar-query>';

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 207) {
        final events = _parseCalendarEvents(response.body);
        return {'success': true, 'calendar': calendarId, 'events': events};
      } else {
        return {
          'success': false,
          'error': 'Failed to get events: ${response.statusCode}',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Error getting events: $e'};
    }
  }

  List<Map<String, dynamic>> _parseCalendarEvents(String xml) {
    final events = <Map<String, dynamic>>[];

    final calendarDataRegex = RegExp(
      r'<c:calendar-data[^>]*>(.*?)</c:calendar-data>',
      dotAll: true,
    );

    for (final match in calendarDataRegex.allMatches(xml)) {
      final icalData = match.group(1) ?? '';
      final event = _parseICalEvent(icalData);
      if (event.isNotEmpty) {
        events.add(event);
      }
    }

    return events;
  }

  Map<String, dynamic> _parseICalEvent(String ical) {
    final event = <String, dynamic>{};

    final lines = ical.split(RegExp(r'\r?\n'));
    for (final line in lines) {
      if (line.startsWith('SUMMARY:')) {
        event['summary'] = line.substring(8);
      } else if (line.startsWith('DTSTART')) {
        final value = line.contains(':') ? line.split(':').last : '';
        event['start'] = _parseICalDate(value);
      } else if (line.startsWith('DTEND')) {
        final value = line.contains(':') ? line.split(':').last : '';
        event['end'] = _parseICalDate(value);
      } else if (line.startsWith('DESCRIPTION:')) {
        event['description'] = line.substring(12);
      } else if (line.startsWith('LOCATION:')) {
        event['location'] = line.substring(9);
      } else if (line.startsWith('UID:')) {
        event['uid'] = line.substring(4);
      }
    }

    return event;
  }

  String _parseICalDate(String value) {
    if (value.length >= 8) {
      final year = value.substring(0, 4);
      final month = value.substring(4, 6);
      final day = value.substring(6, 8);

      if (value.length >= 15) {
        final hour = value.substring(9, 11);
        final minute = value.substring(11, 13);
        return '$year-$month-${day}T$hour:$minute:00';
      }

      return '$year-$month-$day';
    }
    return value;
  }

  // ============== CardDAV Contacts Operations ==============

  Future<Map<String, dynamic>> getContacts() async {
    if (!isConfigured) {
      return {'success': false, 'error': 'Nextcloud is not configured'};
    }

    try {
      final request = http.Request(
        'PROPFIND',
        Uri.parse('$_serverUrl/remote.php/dav/addressbooks/users/$_username/'),
      );
      request.headers.addAll(_authHeaders);
      request.headers['Depth'] = '1';

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 207) {
        final hrefRegex = RegExp(r'<d:href>(.*?)</d:href>');
        String? contactsHref;

        for (final match in hrefRegex.allMatches(response.body)) {
          final href = match.group(1) ?? '';
          if (href.contains('/contacts/')) {
            contactsHref = href;
            break;
          }
        }

        if (contactsHref != null) {
          return await _getContactsFromAddressbook(contactsHref);
        }

        return {
          'success': true,
          'contacts': <Map<String, dynamic>>[],
          'message': 'No contacts addressbook found',
        };
      } else {
        return {
          'success': false,
          'error': 'Failed to get addressbooks: ${response.statusCode}',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Error getting contacts: $e'};
    }
  }

  Future<Map<String, dynamic>> _getContactsFromAddressbook(
    String addressbookHref,
  ) async {
    try {
      final request = http.Request(
        'REPORT',
        Uri.parse('$_serverUrl$addressbookHref'),
      );
      request.headers.addAll(_authHeaders);
      request.headers['Depth'] = '1';
      request.headers['Content-Type'] = 'application/xml';
      request.body =
          '<?xml version="1.0"?>'
          '<card:addressbook-query xmlns:d="DAV:" '
          'xmlns:card="urn:ietf:params:xml:ns:carddav">'
          '<d:prop><d:getetag/><card:address-data/></d:prop>'
          '</card:addressbook-query>';

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 207) {
        final contacts = _parseContacts(response.body);
        return {'success': true, 'contacts': contacts};
      } else {
        return {
          'success': false,
          'error': 'Failed to get contacts: ${response.statusCode}',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Error getting contacts: $e'};
    }
  }

  List<Map<String, dynamic>> _parseContacts(String xml) {
    final contacts = <Map<String, dynamic>>[];

    final addressDataRegex = RegExp(
      r'<card:address-data[^>]*>(.*?)</card:address-data>',
      dotAll: true,
    );

    for (final match in addressDataRegex.allMatches(xml)) {
      final vcardData = match.group(1) ?? '';
      final contact = _parseVCard(vcardData);
      if (contact.isNotEmpty) {
        contacts.add(contact);
      }
    }

    return contacts;
  }

  Map<String, dynamic> _parseVCard(String vcard) {
    final contact = <String, dynamic>{};

    final lines = vcard.split(RegExp(r'\r?\n'));
    for (final line in lines) {
      if (line.startsWith('FN:')) {
        contact['name'] = line.substring(3);
      } else if (line.startsWith('EMAIL')) {
        final value = line.contains(':') ? line.split(':').last : '';
        contact['email'] = value;
      } else if (line.startsWith('TEL')) {
        final value = line.contains(':') ? line.split(':').last : '';
        contact['phone'] = value;
      } else if (line.startsWith('ORG:')) {
        contact['organization'] = line.substring(4);
      } else if (line.startsWith('UID:')) {
        contact['uid'] = line.substring(4);
      }
    }

    return contact;
  }
}
