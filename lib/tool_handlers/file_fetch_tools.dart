// lib/tool_handlers/file_fetch_tools.dart
//
// `fetch_files`: the app downloads files from URLs itself and hands them to
// the user as one file card, the same card an Agents host delivery draws
// (`SandboxArtifactBlock`). Several files are packed into one ZIP on the
// device. No sandbox and no server round-trip: the download runs here, the
// result is encrypted and stored like every other chat attachment.

import 'dart:async';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/format_bytes.dart';
import 'package:chuk_chat/utils/host_lookup.dart';

/// Most URLs one call may fetch.
const int kFetchFilesMaxCount = 20;

/// Largest single download.
const int kFetchFilesMaxFileBytes = 15 * 1024 * 1024;

/// Largest sum of all downloads. The encrypted upload is about 1.4x the
/// plain bytes and the storage limit is 50 MiB, so 25 MB keeps a margin.
const int kFetchFilesMaxTotalBytes = 25 * 1024 * 1024;

/// What one `fetch_files` call produced.
class FetchFilesResult {
  const FetchFilesResult({
    required this.text,
    required this.isError,
    this.file,
  });

  /// The answer the model reads.
  final String text;
  final bool isError;

  /// The file card for the user. Null when nothing could be fetched.
  final SandboxArtifactPayload? file;
}

class _Fetched {
  _Fetched(this.name, this.mime, this.bytes);
  final String name;
  final String mime;
  final Uint8List bytes;
}

/// Downloads the files in `args['files']` and stores them as one card.
///
/// `files` is a list of URLs or of `{url, name}` objects. One file without
/// `zip: true` is delivered as itself; several files become `zip_name`.
/// [upload], [client] and [lookup] exist for tests.
Future<FetchFilesResult> executeFetchFiles(
  Map<String, dynamic> args, {
  http.Client? client,
  Future<String> Function(Uint8List bytes)? upload,
  Future<List<String>> Function(String host) lookup = lookupHostAddresses,
}) async {
  final invalid = <String>[];
  final requests = _parseRequests(args, invalid);
  if (requests.isEmpty) {
    return const FetchFilesResult(
      text: 'Error: "files" must list at least one http(s) URL.',
      isError: true,
    );
  }
  if (requests.length > kFetchFilesMaxCount) {
    return FetchFilesResult(
      text:
          'Error: too many files (${requests.length}). '
          'The limit is $kFetchFilesMaxCount per call.',
      isError: true,
    );
  }

  // Without a connection of our own (web) a host name cannot be held to a
  // checked address, and the browser's CORS rules block most file hosts
  // anyway. The tool stays a native feature.
  final effectiveClient = client ?? publicOnlyHttpClient(_isNonPublic);
  if (effectiveClient == null || (client == null && kIsWeb)) {
    return const FetchFilesResult(
      text: 'Error: fetch_files is not available in the web app.',
      isError: true,
    );
  }
  // A fetched file may be private. It is stored only encrypted, never as a
  // plain local blob.
  if (upload == null &&
      (SupabaseService.auth.currentUser == null || !EncryptionService.hasKey)) {
    if (client == null) effectiveClient.close();
    return const FetchFilesResult(
      text: 'Error: sign in first; files are stored only encrypted.',
      isError: true,
    );
  }
  final fetched = <_Fetched>[];
  final failures = <String>[...invalid];
  final usedNames = <String>{};
  var total = 0;
  final callEnd = DateTime.now().add(_callDeadline);
  try {
    for (var i = 0; i < requests.length; i++) {
      final req = requests[i];
      final now = DateTime.now();
      if (!now.isBefore(callEnd)) {
        for (final rest in requests.skip(i)) {
          failures.add('${rest.url} (time limit for this call reached)');
        }
        break;
      }
      final fileEnd = now.add(_downloadDeadline);
      final uri = Uri.tryParse(req.url);
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
        failures.add('${req.url} (not an http(s) URL)');
        continue;
      }
      final room = kFetchFilesMaxTotalBytes - total;
      if (room <= 0) {
        failures.add('${req.url} (total size limit reached)');
        continue;
      }
      try {
        final download = await _download(
          effectiveClient,
          uri,
          maxBytes: room < kFetchFilesMaxFileBytes
              ? room
              : kFetchFilesMaxFileBytes,
          lookup: lookup,
          deadline: fileEnd.isBefore(callEnd) ? fileEnd : callEnd,
        );
        total += download.bytes.length;
        final mime = _mimeOf(download.contentType, download.uri.path);
        final name = _uniqueName(
          _fileName(
            requested: req.name,
            disposition: download.disposition,
            uri: download.uri,
            mime: mime,
            index: i + 1,
          ),
          usedNames,
        );
        fetched.add(_Fetched(name, mime, download.bytes));
      } on _FetchFailure catch (f) {
        failures.add('${req.url} (${f.reason})');
      } catch (e) {
        failures.add('${req.url} (${_shortError(e)})');
      }
    }
  } finally {
    if (client == null) effectiveClient.close();
  }

  if (fetched.isEmpty) {
    return FetchFilesResult(
      text: 'Error: no file could be downloaded. ${failures.join('; ')}',
      isError: true,
    );
  }

  final wantZip = fetched.length > 1 || args['zip'] == true;
  final String filename;
  final String mime;
  final Uint8List bytes;
  if (wantZip) {
    final archive = Archive();
    for (final f in fetched) {
      archive.addFile(ArchiveFile.bytes(f.name, f.bytes));
    }
    bytes = ZipEncoder().encodeBytes(archive);
    filename = _zipName(args['zip_name']);
    mime = 'application/zip';
  } else {
    bytes = fetched.single.bytes;
    filename = fetched.single.name;
    mime = fetched.single.mime;
  }

  final String storagePath;
  try {
    storagePath = await (upload ?? _uploadEncryptedOnly)(bytes);
  } catch (e) {
    return FetchFilesResult(
      text: 'Error: the file could not be stored (${_shortError(e)}).',
      isError: true,
    );
  }

  final buf = StringBuffer()
    ..write('Delivered to the user as a file card: $filename ')
    ..write('(${formatBytes(bytes.length)}');
  if (wantZip) {
    buf.write(', ${fetched.length} files: ');
    buf.write(fetched.map((f) => f.name).join(', '));
  }
  buf.write(').');
  if (failures.isNotEmpty) {
    buf.write(' Not included: ${failures.join('; ')}.');
  }
  buf.write(
    ' The card with a download button is shown under your answer. '
    'Do not paste a download link for it.',
  );

  return FetchFilesResult(
    text: buf.toString(),
    isError: false,
    file: SandboxArtifactPayload(
      storagePath: storagePath,
      filename: filename,
      mime: mime,
      sizeBytes: bytes.length,
      origin: SandboxArtifactPayload.originFetchFiles,
    ),
  );
}

class _FetchFailure implements Exception {
  const _FetchFailure(this.reason);
  final String reason;
}

class _Download {
  const _Download(this.uri, this.bytes, this.contentType, this.disposition);
  final Uri uri;
  final Uint8List bytes;
  final String? contentType;
  final String? disposition;
}

/// Stores the file encrypted or not at all: a sign-out during the download
/// must not leave it as a plain local blob.
Future<String> _uploadEncryptedOnly(Uint8List bytes) =>
    ImageStorageService.uploadEncryptedBytes(bytes, requireEncryption: true);

const int _maxRedirects = 5;

/// Longest one download may take, redirects and body included.
const Duration _downloadDeadline = Duration(seconds: 60);

/// Longest the whole call may take. Files not reached by then are reported
/// as not fetched.
const Duration _callDeadline = Duration(minutes: 3);

/// Longest pause between two parts of a response.
const Duration _idleTimeout = Duration(seconds: 30);

/// GETs [start] and reads at most [maxBytes] of the body before [deadline].
///
/// Redirects are followed by hand, so every hop goes through
/// [_checkPublicHost]: the model picks the URLs, and an injected page could
/// otherwise point the app at the user's router or a local service. The body
/// is read as a stream and dropped the moment it passes [maxBytes], so an
/// endless response cannot fill the phone's memory. A response that is not
/// read is cancelled, not drained.
Future<_Download> _download(
  http.Client client,
  Uri start, {
  required int maxBytes,
  required Future<List<String>> Function(String host) lookup,
  required DateTime deadline,
}) async {
  Duration left() {
    final d = deadline.difference(DateTime.now());
    if (d <= Duration.zero) throw const _FetchFailure('timed out');
    return d < _idleTimeout ? d : _idleTimeout;
  }

  var uri = start;
  for (var hop = 0; ; hop++) {
    await _checkPublicHost(uri, lookup, left());
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers.addAll(const {
        'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64)',
        'Accept': '*/*',
      });
    final response = await client.send(request).timeout(left());
    final status = response.statusCode;
    if (status >= 300 && status < 400) {
      await _discard(response);
      final location = response.headers['location'];
      if (location == null || location.isEmpty) {
        throw _FetchFailure('HTTP $status without a target');
      }
      if (hop >= _maxRedirects) throw const _FetchFailure('too many redirects');
      uri = uri.resolve(location);
      if (uri.scheme != 'http' && uri.scheme != 'https') {
        throw const _FetchFailure('redirect to a non-http(s) URL');
      }
      continue;
    }
    if (status != 200) {
      await _discard(response);
      throw _FetchFailure('HTTP $status');
    }
    final declared = response.contentLength;
    if (declared != null && declared > maxBytes) {
      await _discard(response);
      throw _FetchFailure('${formatBytes(declared)}, too large');
    }
    final builder = BytesBuilder(copy: false);
    final iterator = StreamIterator(response.stream);
    try {
      while (await iterator.moveNext().timeout(left())) {
        builder.add(iterator.current);
        if (builder.length > maxBytes) {
          throw const _FetchFailure('too large');
        }
      }
    } on TimeoutException {
      throw const _FetchFailure('timed out');
    } finally {
      await iterator.cancel();
    }
    if (builder.isEmpty) throw const _FetchFailure('empty response');
    return _Download(
      uri,
      builder.takeBytes(),
      response.headers['content-type'],
      response.headers['content-disposition'],
    );
  }
}

/// Drops a response body without reading it.
Future<void> _discard(http.StreamedResponse response) async {
  try {
    await response.stream.listen(null).cancel();
  } catch (_) {}
}

/// Refuses hosts on the user's own machine or network: loopback, private
/// ranges, link-local (cloud metadata), carrier-grade NAT (Tailscale) and
/// names that resolve there. On web there is no DNS access, so only
/// literal addresses and local names are caught.
Future<void> _checkPublicHost(
  Uri uri,
  Future<List<String>> Function(String host) lookup,
  Duration timeout,
) async {
  final host = uri.host.toLowerCase();
  if (host.isEmpty) throw const _FetchFailure('no host');
  if (host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.internal')) {
    throw const _FetchFailure('local address not allowed');
  }
  final literal = _parseIp(host);
  if (literal != null) {
    if (_isNonPublic(literal)) {
      throw const _FetchFailure('local address not allowed');
    }
    return;
  }
  final List<String> addresses;
  try {
    addresses = await lookup(host).timeout(timeout);
  } catch (_) {
    throw const _FetchFailure('host not found');
  }
  for (final a in addresses) {
    final ip = _parseIp(a);
    if (ip == null || _isNonPublic(ip)) {
      throw const _FetchFailure('local address not allowed');
    }
  }
}

/// The address bytes of an IPv4 or IPv6 literal, or null for a name.
List<int>? _parseIp(String host) {
  var h = host;
  if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
  final zone = h.indexOf('%');
  if (zone >= 0) h = h.substring(0, zone);
  try {
    return Uri.parseIPv4Address(h);
  } on FormatException {
    // Not IPv4; try IPv6 below.
  }
  if (!h.contains(':')) return null;
  try {
    return Uri.parseIPv6Address(h);
  } on FormatException {
    return null;
  }
}

bool _isNonPublic(List<int> ip) {
  if (ip.length == 4) {
    final a = ip[0], b = ip[1];
    return a == 0 ||
        a == 10 ||
        a == 127 ||
        (a == 100 && b >= 64 && b <= 127) ||
        (a == 169 && b == 254) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 198 && (b == 18 || b == 19)) ||
        a >= 224;
  }
  if (ip.length == 16) {
    final allZeroHead = ip.sublist(0, 10).every((x) => x == 0);
    // IPv4-mapped (::ffff:a.b.c.d) and IPv4-compatible (::a.b.c.d).
    if (allZeroHead &&
        ((ip[10] == 0xff && ip[11] == 0xff) || (ip[10] == 0 && ip[11] == 0))) {
      final v4 = ip.sublist(12);
      if (ip[10] == 0 && v4.every((x) => x == 0)) return true; // ::
      if (ip[10] == 0 && v4[0] == 0 && v4[1] == 0 && v4[2] == 0) {
        return true; // ::1 and friends
      }
      return _isNonPublic(v4);
    }
    return (ip[0] & 0xfe) == 0xfc || // fc00::/7 unique local
        (ip[0] == 0xfe && (ip[1] & 0xc0) == 0x80) || // fe80::/10 link-local
        ip[0] == 0xff; // multicast
  }
  return true;
}

class _Request {
  const _Request(this.url, this.name);
  final String url;
  final String? name;
}

List<_Request> _parseRequests(Map<String, dynamic> args, List<String> invalid) {
  final out = <_Request>[];
  void add(Object? item) {
    if (item is String && item.trim().isNotEmpty) {
      out.add(_Request(item.trim(), null));
      return;
    } else if (item is Map) {
      final url = item['url'];
      if (url is String && url.trim().isNotEmpty) {
        final name = item['name'];
        out.add(
          _Request(
            url.trim(),
            name is String && name.trim().isNotEmpty ? name.trim() : null,
          ),
        );
        return;
      }
    }
    if (item != null) invalid.add('$item (no usable url)');
  }

  final files = args['files'];
  if (files is List) {
    files.forEach(add);
  } else if (files != null) {
    add(files);
  }
  // A model that sends one `url` instead of a list still gets its file.
  if (out.isEmpty && args['url'] != null) add(args['url']);
  return out;
}

String _fileName({
  required String? requested,
  required String? disposition,
  required Uri uri,
  required String mime,
  required int index,
}) {
  var name = requested ?? _dispositionName(disposition);
  if (name == null || name.isEmpty) {
    final segments = uri.pathSegments.where((s) => s.isNotEmpty);
    name = segments.isEmpty ? '' : segments.last;
  }
  name = _sanitize(name);
  if (name.isEmpty) name = 'file-$index';
  if (!name.contains('.')) {
    final ext = _extensionFor(mime);
    if (ext != null) name = '$name.$ext';
  }
  return name;
}

String? _dispositionName(String? header) {
  if (header == null) return null;
  final star = RegExp(
    r"filename\*\s*=\s*[^']*''([^;]+)",
    caseSensitive: false,
  ).firstMatch(header);
  if (star != null) {
    try {
      return Uri.decodeComponent(star.group(1)!.trim());
    } catch (_) {}
  }
  final plain = RegExp(
    r'filename\s*=\s*"?([^";]+)"?',
    caseSensitive: false,
  ).firstMatch(header);
  return plain?.group(1)?.trim();
}

/// Keeps a name safe as a ZIP entry and as a saved file: no folders, no
/// characters that Windows or Android refuse.
String _sanitize(String name) {
  final base = name.split(RegExp(r'[/\\]')).last;
  return base
      .replaceAll(RegExp(r'[<>:"|?*\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'^\.+'), '')
      .trim();
}

String _uniqueName(String name, Set<String> used) {
  if (used.add(name.toLowerCase())) return name;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  for (var n = 2; ; n++) {
    final candidate = '$stem ($n)$ext';
    if (used.add(candidate.toLowerCase())) return candidate;
  }
}

String _zipName(Object? requested) {
  var name = requested is String ? _sanitize(requested) : '';
  if (name.isEmpty) name = 'files';
  if (!name.toLowerCase().endsWith('.zip')) name = '$name.zip';
  return name;
}

const Map<String, String> _extToMime = {
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'svg': 'image/svg+xml',
  'pdf': 'application/pdf',
  'zip': 'application/zip',
  'txt': 'text/plain',
  'csv': 'text/csv',
  'json': 'application/json',
  'md': 'text/markdown',
  'html': 'text/html',
  'xml': 'application/xml',
  'mp3': 'audio/mpeg',
  'mp4': 'video/mp4',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
};

String _mimeOf(String? contentType, String path) {
  final ct = contentType?.split(';').first.trim().toLowerCase() ?? '';
  if (ct.isNotEmpty && ct != 'application/octet-stream') return ct;
  final dot = path.lastIndexOf('.');
  if (dot >= 0) {
    final byExt = _extToMime[path.substring(dot + 1).toLowerCase()];
    if (byExt != null) return byExt;
  }
  return 'application/octet-stream';
}

String? _extensionFor(String mime) {
  if (mime == 'image/jpeg') return 'jpg';
  for (final e in _extToMime.entries) {
    if (e.value == mime) return e.key;
  }
  return null;
}

String _shortError(Object e) {
  final s = e.toString().replaceFirst('Exception: ', '');
  return s.length > 120 ? '${s.substring(0, 120)}...' : s;
}
