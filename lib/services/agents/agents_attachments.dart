/// Uploads the files of one Agents task to the host in chunks
/// (docs/WIRE_CONTRACT.md, "Attachments to Agents").
///
/// Each file goes out as sealed `attachment_put` frames of at most 256 KiB
/// raw bytes, at most four in flight. Every chunk waits for its
/// `attachment_ack`; a chunk with no answer, or an `ok: false`, is sent
/// again. A hash mismatch drops the upload on the host, so the file starts
/// again from chunk 0 under a fresh id. The task is sent only once every
/// file is `complete`; it names the files by `blob_id`.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/agents/agents_attachment_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_reply_frames.dart';
import 'package:chuk_chat/services/image_storage_service.dart';

/// Raw bytes per chunk (`CHUNK_BYTES` on the host).
const int kAgentsChunkBytes = 262144;

/// The largest file the host takes.
const int kAgentsAttachmentMaxBytes = 25 * 1024 * 1024;

/// The most files one task may carry.
const int kAgentsAttachmentMaxFiles = 10;

/// Chunks of one file on the wire at the same time.
const int kAgentsChunksInFlight = 4;

/// `ceil(size / 262144)`: the `count` of every chunk of a file of [size].
int agentsChunkCount(int size) =>
    size <= 0 ? 0 : (size + kAgentsChunkBytes - 1) ~/ kAgentsChunkBytes;

/// Bytes `[index*262144, (index+1)*262144)` of [bytes], cut at the end.
Uint8List agentsChunk(Uint8List bytes, int index) {
  final int start = index * kAgentsChunkBytes;
  if (index < 0 || start >= bytes.length) {
    throw RangeError.range(index, 0, agentsChunkCount(bytes.length) - 1);
  }
  final int end = min(start + kAgentsChunkBytes, bytes.length);
  return Uint8List.sublistView(bytes, start, end);
}

/// The lower-case hex sha256 of [bytes].
String agentsSha256Hex(Uint8List bytes) => sha256.convert(bytes).toString();

final Random _random = Random.secure();

/// A fresh `upload_id`: 22 base64url characters (128 random bits).
String mintAgentsUploadId() {
  final Uint8List raw = Uint8List.fromList(
    List<int>.generate(16, (_) => _random.nextInt(256)),
  );
  return base64Url.encode(raw).replaceAll('=', '');
}

/// One file, read and ready to go out.
@immutable
class AgentsOutgoingAttachment {
  const AgentsOutgoingAttachment({
    required this.name,
    required this.mime,
    required this.bytes,
    this.localPath,
  });

  final String name;
  final String mime;
  final Uint8List bytes;

  /// The local copy it was read from (a store ref or an image path).
  final String? localPath;

  int get size => bytes.length;
}

/// One file the host holds.
@immutable
class AgentsUploadedAttachment {
  const AgentsUploadedAttachment({
    required this.blobId,
    required this.name,
    required this.mime,
    required this.size,
    this.kind = 'file',
    this.path,
    this.localPath,
  });

  final String blobId;
  final String name;
  final String mime;
  final int size;

  /// `image` or `file`, as the host said.
  final String kind;

  /// `.agents/inbox/<id>/<name>` in the workspace.
  final String? path;
  final String? localPath;

  /// The entry of `task.attachments`.
  Map<String, String> toTaskEntry() => <String, String>{'blob_id': blobId};
}

/// Why an upload did not finish.
enum AgentsAttachmentFailure {
  /// The file is over [kAgentsAttachmentMaxBytes].
  tooLarge,

  /// More than [kAgentsAttachmentMaxFiles] files.
  tooMany,

  /// An empty file: there is nothing to send.
  empty,

  /// The local copy is gone or does not open.
  missing,

  /// The link could not take a frame.
  notSent,

  /// The host did not acknowledge a chunk after every retry, or refused it.
  refused,
}

class AgentsAttachmentException implements Exception {
  const AgentsAttachmentException(this.failure, {this.name, this.detail});

  final AgentsAttachmentFailure failure;
  final String? name;
  final String? detail;

  /// The selection itself is the problem: sending again will not help, the
  /// user has to change it. Anything else is the link or the host, and the
  /// prompt waits in the outbox.
  bool get isUserFixable => switch (failure) {
    AgentsAttachmentFailure.tooLarge ||
    AgentsAttachmentFailure.tooMany ||
    AgentsAttachmentFailure.empty ||
    AgentsAttachmentFailure.missing => true,
    _ => false,
  };

  @override
  String toString() =>
      'AgentsAttachmentException(${failure.name}${name == null ? '' : ', $name'})';
}

/// Progress of one file.
@immutable
class AgentsUploadProgress {
  const AgentsUploadProgress({
    required this.name,
    required this.received,
    required this.count,
    this.complete = false,
  });

  final String name;
  final int received;
  final int count;
  final bool complete;

  double get fraction => count == 0 ? 1 : received / count;
}

/// The uploads in flight per thread, for the strip above the composer.
class AgentsUploadTracker extends ChangeNotifier {
  AgentsUploadTracker._();

  static final AgentsUploadTracker instance = AgentsUploadTracker._();

  final Map<String, List<AgentsUploadProgress>> _bySession =
      <String, List<AgentsUploadProgress>>{};

  List<AgentsUploadProgress> of(String sessionKey) =>
      _bySession[sessionKey] ?? const <AgentsUploadProgress>[];

  void set(String sessionKey, int index, AgentsUploadProgress progress) {
    final List<AgentsUploadProgress> list = <AgentsUploadProgress>[
      ...of(sessionKey),
    ];
    while (list.length <= index) {
      list.add(
        AgentsUploadProgress(name: progress.name, received: 0, count: 0),
      );
    }
    list[index] = progress;
    _bySession[sessionKey] = list;
    notifyListeners();
  }

  void clear(String sessionKey) {
    if (_bySession.remove(sessionKey) != null) notifyListeners();
  }
}

/// Validates the caps BEFORE anything goes out: at most
/// [kAgentsAttachmentMaxFiles] files, each 1 byte to 25 MiB. Throws the
/// first [AgentsAttachmentException] that applies.
void checkAgentsAttachmentCaps(List<AgentsOutgoingAttachment> files) {
  if (files.length > kAgentsAttachmentMaxFiles) {
    throw const AgentsAttachmentException(AgentsAttachmentFailure.tooMany);
  }
  for (final AgentsOutgoingAttachment f in files) {
    if (f.size > kAgentsAttachmentMaxBytes) {
      throw AgentsAttachmentException(
        AgentsAttachmentFailure.tooLarge,
        name: f.name,
      );
    }
    if (f.size == 0) {
      throw AgentsAttachmentException(
        AgentsAttachmentFailure.empty,
        name: f.name,
      );
    }
  }
}

/// The file starts again from chunk 0 under a fresh `upload_id`: a hash
/// mismatch dropped the upload on the host, or every chunk was acked and
/// still no ack said complete (the host lost the upload, e.g. an error ack
/// that was lost and a chunk sent again into a fresh upload).
class _StartOver implements Exception {
  const _StartOver(this.detail);

  final String detail;
}

class AgentsAttachmentUploader {
  AgentsAttachmentUploader({
    required this.send,
    Stream<Map<String, dynamic>>? acks,
    this.ackTimeout = const Duration(seconds: 20),
    this.maxChunkAttempts = 4,
    this.maxFileRestarts = 2,
  }) : _acks = acks ?? AgentsReplyFrames.instance.ofType('attachment_ack');

  final AgentsFrameSender send;
  final Stream<Map<String, dynamic>> _acks;
  final Duration ackTimeout;
  final int maxChunkAttempts;
  final int maxFileRestarts;

  /// Uploads every file in order. Checks the caps first, so nothing goes
  /// out for a selection the host would refuse.
  Future<List<AgentsUploadedAttachment>> uploadAll(
    List<AgentsOutgoingAttachment> files, {
    required String sessionKey,
    void Function(int index, AgentsUploadProgress progress)? onProgress,
  }) async {
    checkAgentsAttachmentCaps(files);
    final List<AgentsUploadedAttachment> out = <AgentsUploadedAttachment>[];
    for (int i = 0; i < files.length; i++) {
      out.add(
        await upload(
          files[i],
          sessionKey: sessionKey,
          onProgress: onProgress == null ? null : (p) => onProgress(i, p),
        ),
      );
    }
    return out;
  }

  /// Uploads one file and completes with the host's record of it.
  Future<AgentsUploadedAttachment> upload(
    AgentsOutgoingAttachment file, {
    required String sessionKey,
    void Function(AgentsUploadProgress progress)? onProgress,
  }) async {
    checkAgentsAttachmentCaps(<AgentsOutgoingAttachment>[file]);
    final String sha = agentsSha256Hex(file.bytes);
    for (int restart = 0; ; restart++) {
      try {
        return await _uploadOnce(
          file,
          sha: sha,
          sessionKey: sessionKey,
          onProgress: onProgress,
        );
      } on _StartOver catch (why) {
        if (restart >= maxFileRestarts) {
          throw AgentsAttachmentException(
            AgentsAttachmentFailure.refused,
            name: file.name,
            detail: why.detail,
          );
        }
      }
    }
  }

  Future<AgentsUploadedAttachment> _uploadOnce(
    AgentsOutgoingAttachment file, {
    required String sha,
    required String sessionKey,
    void Function(AgentsUploadProgress progress)? onProgress,
  }) async {
    final String uploadId = mintAgentsUploadId();
    final int count = agentsChunkCount(file.size);
    final Map<int, Completer<Map<String, dynamic>>> waiting =
        <int, Completer<Map<String, dynamic>>>{};
    final StreamSubscription<Map<String, dynamic>> sub = _acks.listen((
      Map<String, dynamic> ack,
    ) {
      if (ack['upload_id'] != uploadId) return;
      final Object? index = ack['index'];
      final Completer<Map<String, dynamic>>? c = index is int
          ? waiting[index]
          : null;
      if (c != null && !c.isCompleted) c.complete(ack);
    });
    final Queue<int> queue = Queue<int>.of(List<int>.generate(count, (i) => i));
    int received = 0;
    Map<String, dynamic>? completeAck;
    bool aborted = false;
    onProgress?.call(
      AgentsUploadProgress(name: file.name, received: 0, count: count),
    );

    Future<void> sendChunk(int index) async {
      final Map<String, dynamic> frame = <String, dynamic>{
        'type': 'attachment_put',
        'session_key': sessionKey,
        'upload_id': uploadId,
        'name': file.name,
        'mime': file.mime,
        'size': file.size,
        'sha256': sha,
        'index': index,
        'count': count,
        'data': base64Encode(agentsChunk(file.bytes, index)),
      };
      for (int attempt = 1; attempt <= maxChunkAttempts; attempt++) {
        if (aborted) return;
        final Completer<Map<String, dynamic>> answer =
            Completer<Map<String, dynamic>>();
        waiting[index] = answer;
        try {
          await send(frame);
        } catch (error) {
          throw AgentsAttachmentException(
            AgentsAttachmentFailure.notSent,
            name: file.name,
            detail: '$error',
          );
        }
        final Map<String, dynamic> ack;
        try {
          ack = await answer.future.timeout(ackTimeout);
        } on TimeoutException {
          continue;
        }
        // A complete ack is success whatever else it says: after a lost
        // final ack the chunk goes again, and the host answers it with the
        // record of the finished file (`already_complete`).
        if (ack['ok'] == true || ack['complete'] == true) {
          final Object? got = ack['received'];
          if (got is int && got > received) received = got;
          if (ack['complete'] == true) {
            completeAck = ack;
            received = count;
          }
          onProgress?.call(
            AgentsUploadProgress(
              name: file.name,
              received: received,
              count: count,
              complete: completeAck != null,
            ),
          );
          return;
        }
        final String error = '${ack['error'] ?? ''}'.toLowerCase();
        if (error.contains('sha256') ||
            error.contains('hash') ||
            error.contains('mismatch')) {
          throw const _StartOver('hash mismatch');
        }
      }
      throw AgentsAttachmentException(
        AgentsAttachmentFailure.refused,
        name: file.name,
        detail: 'chunk $index got no ack',
      );
    }

    Future<void> worker() async {
      while (!aborted && queue.isNotEmpty) {
        await sendChunk(queue.removeFirst());
      }
    }

    try {
      await Future.wait(<Future<void>>[
        for (int i = 0; i < min(kAgentsChunksInFlight, count); i++) worker(),
      ], eagerError: true);
    } catch (_) {
      aborted = true;
      rethrow;
    } finally {
      // Not awaited: a broadcast subscription's cancel future belongs to the
      // root zone (a widget test's fake clock would never return it).
      unawaited(sub.cancel());
    }
    final Map<String, dynamic>? done = completeAck;
    if (done == null) {
      throw const _StartOver('the host never said complete');
    }
    final Object? blobId = done['blob_id'];
    final Object? path = done['path'];
    final Object? kind = done['kind'];
    return AgentsUploadedAttachment(
      blobId: blobId is String && blobId.isNotEmpty ? blobId : uploadId,
      name: file.name,
      mime: file.mime,
      size: file.size,
      kind: kind is String && kind.isNotEmpty
          ? kind
          : (file.mime.startsWith('image/') ? 'image' : 'file'),
      path: path is String ? path : null,
      localPath: file.localPath,
    );
  }
}

// ── reading the local copies ───────────────────────────────────────────────

/// Reads one attachment path of a send: a store ref (a file) or an image
/// path (offline, bucket or local blob). Replaceable in tests.
typedef AgentsAttachmentReader = Future<AgentsOutgoingAttachment> Function(
  String path,
  int index,
);

class AgentsAttachmentPaths {
  AgentsAttachmentPaths._();

  @visibleForTesting
  static AgentsAttachmentReader? readerOverride;

  @visibleForTesting
  static AgentsFrameSender? senderOverride;

  /// Reads every path. Throws [AgentsAttachmentException] (missing) when one
  /// is gone.
  static Future<List<AgentsOutgoingAttachment>> readAll(
    List<String> paths,
  ) async {
    if (paths.length > kAgentsAttachmentMaxFiles) {
      throw const AgentsAttachmentException(AgentsAttachmentFailure.tooMany);
    }
    final AgentsAttachmentReader read = readerOverride ?? _read;
    return <AgentsOutgoingAttachment>[
      for (int i = 0; i < paths.length; i++) await read(paths[i], i),
    ];
  }

  static Future<AgentsOutgoingAttachment> _read(String path, int index) async {
    if (AgentsAttachmentStore.isRef(path)) {
      final AgentsStoredAttachment? stored = await AgentsAttachmentStore.read(
        path,
      );
      if (stored == null) {
        throw const AgentsAttachmentException(AgentsAttachmentFailure.missing);
      }
      return AgentsOutgoingAttachment(
        name: stored.meta.name,
        mime: stored.meta.mime,
        bytes: stored.bytes,
        localPath: path,
      );
    }
    final Uint8List bytes;
    try {
      bytes = await ImageStorageService.downloadAndDecryptImage(path);
    } catch (error) {
      throw AgentsAttachmentException(
        AgentsAttachmentFailure.missing,
        detail: '$error',
      );
    }
    final String mime = agentsSniffImageMime(bytes) ?? 'image/jpeg';
    final String ext = switch (mime) {
      'image/png' => 'png',
      'image/webp' => 'webp',
      'image/gif' => 'gif',
      _ => 'jpg',
    };
    final String? remembered = AgentsAttachmentStore.nameOf(path);
    return AgentsOutgoingAttachment(
      name: remembered ?? 'image-${index + 1}.$ext',
      mime: mime,
      bytes: bytes,
      localPath: path,
    );
  }

  /// The sender for [controller]'s link, or null when it cannot carry an
  /// attachment frame.
  static AgentsFrameSender? senderFor(AgentsRelayController controller) {
    final AgentsFrameSender? override = senderOverride;
    if (override != null) return override;
    if (controller is AgentsRelayClient) return controller.sendControlFrame;
    return null;
  }

  /// Reads [paths], uploads them through [controller] and returns the blob
  /// ids for `task.attachments`. Progress goes to [AgentsUploadTracker] for
  /// [sessionKey]; the tracker is cleared at the end, success or not.
  static Future<List<String>> upload(
    AgentsRelayController controller, {
    required String sessionKey,
    required List<String> paths,
    VoidCallback? onChunk,
    Stream<Map<String, dynamic>>? acks,
  }) async {
    if (paths.isEmpty) return const <String>[];
    final AgentsFrameSender? send = senderFor(controller);
    if (send == null) {
      throw const AgentsAttachmentException(AgentsAttachmentFailure.notSent);
    }
    final List<AgentsOutgoingAttachment> files = await readAll(paths);
    checkAgentsAttachmentCaps(files);
    final AgentsUploadTracker tracker = AgentsUploadTracker.instance;
    try {
      final List<AgentsUploadedAttachment> done =
          await AgentsAttachmentUploader(send: send, acks: acks).uploadAll(
            files,
            sessionKey: sessionKey,
            onProgress: (int index, AgentsUploadProgress p) {
              tracker.set(sessionKey, index, p);
              onChunk?.call();
            },
          );
      for (final AgentsUploadedAttachment a in done) {
        final String? local = a.localPath;
        if (local != null) {
          unawaited(
            AgentsAttachmentStore.rememberBlob(
              a.blobId,
              local,
            ).catchError((Object _) {}),
          );
        }
      }
      return <String>[for (final AgentsUploadedAttachment a in done) a.blobId];
    } finally {
      tracker.clear(sessionKey);
    }
  }
}

/// The English sentence for a refused selection (the transport has no
/// locale; the thread view shows the localised one from the notice).
String agentsAttachmentRefusalText(
  AgentsAttachmentFailure failure, {
  String? name,
}) {
  final String file = name == null ? 'A file' : '"$name"';
  return switch (failure) {
    AgentsAttachmentFailure.tooLarge =>
      '$file is larger than 25 MB. Nothing was sent.',
    AgentsAttachmentFailure.tooMany =>
      'At most $kAgentsAttachmentMaxFiles files per message. Nothing was '
          'sent.',
    AgentsAttachmentFailure.empty => '$file is empty. Nothing was sent.',
    AgentsAttachmentFailure.missing =>
      'A file of this message is no longer on this device. Attach it again.',
    _ => 'The files could not be sent.',
  };
}

/// True for the host's refusal of a task whose blob it does not know.
bool isUnknownAttachmentError(String message) =>
    message.toLowerCase().contains('unknown attachment');

// ── what the user bubble shows ─────────────────────────────────────────────

/// One attachment on a user bubble: from the live send (a local path) or
/// from the host's replayed `user.attachments`.
@immutable
class AgentsAttachmentInfo {
  const AgentsAttachmentInfo({
    this.name,
    this.mime,
    this.size,
    this.kind,
    this.blobId,
    this.localPath,
  });

  final String? name;
  final String? mime;
  final int? size;
  final String? kind;
  final String? blobId;

  /// A store ref or an image path on this device, for the thumbnail.
  final String? localPath;

  bool get isImage => kind == 'image' || (mime?.startsWith('image/') ?? false);

  /// The replayed `user.attachments`: `[{blob_id, name, mime, size, kind,
  /// path}]`. A malformed entry is skipped.
  static List<AgentsAttachmentInfo> listFromJson(Object? raw) {
    Object? value = raw;
    if (value is String) {
      try {
        value = jsonDecode(value);
      } catch (_) {
        return const <AgentsAttachmentInfo>[];
      }
    }
    if (value is! List) return const <AgentsAttachmentInfo>[];
    return <AgentsAttachmentInfo>[
      for (final Object? e in value)
        if (e is Map)
          AgentsAttachmentInfo(
            name: e['name'] is String ? e['name'] as String : null,
            mime: e['mime'] is String ? e['mime'] as String : null,
            size: e['size'] is int ? e['size'] as int : null,
            kind: e['kind'] is String ? e['kind'] as String : null,
            blobId: e['blob_id'] is String ? e['blob_id'] as String : null,
            localPath: e['blob_id'] is String
                ? AgentsAttachmentStore.localPathOfBlob(e['blob_id'] as String)
                : null,
          ),
    ];
  }
}

/// "734 KB": a plain binary size.
String agentsAttachmentSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
