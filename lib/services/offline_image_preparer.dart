// lib/services/offline_image_preparer.dart
//
// Images attached while the network is down. Design: docs/OFFLINE_SEND.md.
//
// * [OfflineImageAttach.uploadOrKeep]: the attach step of both composers.
//   Online it uploads as before; offline, or when the upload breaks on the
//   network, it keeps the image encrypted on the device
//   ([ImageStorageService.storeOfflineImage]) instead of dropping it.
// * [OfflineAttachmentWatcher]: while such an image still sits in a
//   composer, it is uploaded as soon as the network is back.
// * [OfflineImagePreparer]: the outbox step. Before a queued message goes
//   out, every offline image in it is uploaded, the stored bubble and the
//   payload get the bucket paths, and the message is sent.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/offline_retry_manager.dart';
import 'package:chuk_chat/services/offline_send_coordinator.dart';

/// Payload key: offline paths this row already promoted. [onDone] deletes
/// their markers once the row is gone.
const String kPromotedOfflineImagesKey = 'promotedOfflineImages';

/// The attach step shared by the mobile and the desktop composer.
abstract final class OfflineImageAttach {
  /// Test seam: the normal upload.
  @visibleForTesting
  static Future<String> Function(Uint8List bytes) upload =
      ImageStorageService.uploadEncryptedImage;

  /// Test seam: the offline store.
  @visibleForTesting
  static Future<String> Function(Uint8List bytes) store =
      ImageStorageService.storeOfflineImage;

  /// Test seam: whether the offline store can work now.
  @visibleForTesting
  static bool Function() canStore = () => ImageStorageService.canStoreOffline;

  /// Test seam: the network state.
  @visibleForTesting
  static bool Function() isOnline = () => NetworkStatusService.isOnline;

  @visibleForTesting
  static void resetForTesting() {
    upload = ImageStorageService.uploadEncryptedImage;
    store = ImageStorageService.storeOfflineImage;
    canStore = () => ImageStorageService.canStoreOffline;
    isOnline = () => NetworkStatusService.isOnline;
  }

  /// Uploads [bytes] like before, or keeps them on the device when the
  /// network is down. Returns a bucket path or an offline path. A failure
  /// that is not about the network is thrown as before.
  static Future<String> uploadOrKeep(Uint8List bytes) async {
    if (!isOnline() && canStore()) {
      return store(bytes);
    }
    try {
      return await upload(bytes);
    } catch (error, stack) {
      if (!isNetworkFailure(error) || !canStore()) rethrow;
      try {
        return await store(bytes);
      } catch (_) {
        Error.throwWithStackTrace(error, stack);
      }
    }
  }

  /// Whether [error] means "the network is bad", not "this image is bad".
  static bool isNetworkFailure(Object error) {
    if (NetworkStatusService.isNetworkError(error)) return true;
    final text = error.toString().toLowerCase();
    return text.contains('socket') ||
        text.contains('clientexception') ||
        text.contains('connection') ||
        text.contains('network') ||
        text.contains('handshake') ||
        text.contains(' 502') ||
        text.contains(' 503') ||
        text.contains(' 504');
  }
}

/// Uploads the offline images of one composer once the network is back and
/// swaps their paths in place. Listens only while such an image is there.
class OfflineAttachmentWatcher {
  OfflineAttachmentWatcher({
    required this.attachments,
    required this.onChanged,
    ValueListenable<bool>? online,
    Future<String> Function(String offlinePath)? promote,
  }) : _online = online ?? NetworkStatusService.isOnlineListenable,
       _promote = promote ?? ImageStorageService.promoteOfflineImage;

  /// The composer's live list. Entries are replaced in place.
  final List<AttachedFile> Function() attachments;

  /// Called after a path was swapped.
  final VoidCallback onChanged;

  final ValueListenable<bool> _online;
  final Future<String> Function(String offlinePath) _promote;
  bool _listening = false;
  bool _running = false;
  bool _disposed = false;

  bool get isListening => _listening;

  /// Call after an offline image was added to the composer.
  void track() {
    if (_disposed || _listening) return;
    _online.addListener(_onNetwork);
    _listening = true;
  }

  void _onNetwork() {
    if (_online.value) unawaited(promoteAll());
  }

  /// Uploads every offline image still in the composer. A failed one stays
  /// offline; the outbox uploads it when the message is sent.
  Future<void> promoteAll() async {
    if (_disposed || _running) return;
    _running = true;
    try {
      for (final file in List<AttachedFile>.of(attachments())) {
        final path = file.encryptedImagePath;
        if (path == null || !ImageStorageService.isOfflinePath(path)) {
          continue;
        }
        String uploaded;
        try {
          uploaded = await _promote(path);
        } catch (e) {
          if (kDebugMode) {
            debugPrint(
              '[OfflineImage] composer upload failed: ${e.runtimeType}',
            );
          }
          continue;
        }
        if (_disposed) return;
        final list = attachments();
        final index = list.indexWhere(
          (f) => f.id == file.id && f.encryptedImagePath == path,
        );
        if (index == -1) continue; // Sent or removed meanwhile.
        list[index] = list[index].copyWith(encryptedImagePath: uploaded);
        onChanged();
      }
      final stillOffline = attachments().any(
        (f) =>
            f.encryptedImagePath != null &&
            ImageStorageService.isOfflinePath(f.encryptedImagePath!),
      );
      if (!stillOffline) _stop();
    } finally {
      _running = false;
    }
  }

  void _stop() {
    if (!_listening) return;
    _online.removeListener(_onNetwork);
    _listening = false;
  }

  void dispose() {
    _disposed = true;
    _stop();
  }
}

/// The outbox step that uploads a queued message's offline images.
abstract final class OfflineImagePreparer {
  static const String name = 'images';

  /// Test seam: the upload of one offline image.
  @visibleForTesting
  static Future<String> Function(String offlinePath) promote =
      ImageStorageService.promoteOfflineImage;

  /// Test seam: the rewrite of the stored bubble.
  @visibleForTesting
  static Future<bool> Function(
    String chatId,
    String queueId,
    Map<String, String> mapping,
  )
  replaceImages = OfflineSendCoordinator.replaceMessageImages;

  /// Test seam: the delete of one offline image.
  @visibleForTesting
  static Future<void> Function(String offlinePath) deleteImage =
      ImageStorageService.deleteOfflineImage;

  @visibleForTesting
  static void resetForTesting() {
    promote = ImageStorageService.promoteOfflineImage;
    replaceImages = OfflineSendCoordinator.replaceMessageImages;
    deleteImage = ImageStorageService.deleteOfflineImage;
  }

  /// Registers the step with the outbox. Call once at app start.
  static void register() {
    OfflineRetryManager.instance.registerPreparer(preparer);
  }

  static OutboxPreparer get preparer => const OutboxPreparer(
    name: name,
    appliesTo: appliesTo,
    prepare: prepare,
    onDone: onDone,
  );

  static const List<String> _imageKeys = <String>[
    'imagesJson',
    'attachedFilesJson',
  ];

  /// Every offline path the payload still names, in order, no duplicates.
  static List<String> offlinePathsIn(Map<String, dynamic> payload) {
    final found = <String>{};
    for (final key in _imageKeys) {
      final value = payload[key];
      if (value is! String || value.isEmpty) continue;
      for (final m in ImageStorageService.offlinePathPattern.allMatches(
        value,
      )) {
        found.add(m[0]!);
      }
    }
    return found.toList();
  }

  static bool appliesTo(QueuedMessage row) =>
      offlinePathsIn(row.sendPayload).isNotEmpty;

  static Future<PrepareResult> prepare(QueuedMessage row) async {
    final paths = offlinePathsIn(row.sendPayload);
    if (paths.isEmpty) return const PrepareResult.ok();
    final mapping = <String, String>{};
    for (final path in paths) {
      try {
        mapping[path] = await promote(path);
      } on OfflineImageMissingException {
        // Not retryable: the "(404)" in the text tells the outbox so.
        return const PrepareResult.failure('image missing (404)');
      } on StateError catch (e) {
        return PrepareResult.deferred('no session: ${e.message}');
      } catch (e) {
        if (OfflineImageAttach.isNetworkFailure(e) ||
            !NetworkStatusService.isOnline) {
          return PrepareResult.failure('network: $e');
        }
        return PrepareResult.failure('image upload failed: $e');
      }
    }

    try {
      await replaceImages(row.chatId, row.id, mapping);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[OfflineImage] bubble update failed: ${e.runtimeType}');
      }
      // The uploads are done and remembered; the next attempt only redoes
      // this step.
      return PrepareResult.failure('chat update failed: $e');
    }

    return PrepareResult.ok(payload: rewritePayload(row.sendPayload, mapping));
  }

  /// [payload] with every offline path in [mapping] replaced, and the
  /// replaced paths remembered under [kPromotedOfflineImagesKey].
  static Map<String, dynamic> rewritePayload(
    Map<String, dynamic> payload,
    Map<String, String> mapping,
  ) {
    final next = Map<String, dynamic>.of(payload);
    for (final key in _imageKeys) {
      final value = next[key];
      if (value is! String || value.isEmpty) continue;
      next[key] = value.replaceAllMapped(
        ImageStorageService.offlinePathPattern,
        (m) => mapping[m[0]!] ?? m[0]!,
      );
    }
    final done = <String>{..._promotedIn(payload), ...mapping.keys};
    next[kPromotedOfflineImagesKey] = done.toList();
    return next;
  }

  static List<String> _promotedIn(Map<String, dynamic> payload) {
    final raw = payload[kPromotedOfflineImagesKey];
    if (raw is List) return raw.whereType<String>().toList();
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) return decoded.whereType<String>().toList();
      } catch (_) {}
    }
    return const <String>[];
  }

  /// The row is gone (sent, deleted, wiped): delete its offline files and
  /// the markers of the ones it uploaded.
  static Future<void> onDone(QueuedMessage row) async {
    final paths = <String>{
      ...offlinePathsIn(row.sendPayload),
      ..._promotedIn(row.sendPayload),
    };
    for (final path in paths) {
      if (!ImageStorageService.isOfflinePath(path)) continue;
      try {
        await deleteImage(path);
      } catch (_) {}
    }
  }
}
