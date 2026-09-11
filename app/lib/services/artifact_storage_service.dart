// COWORK STUB. Upstream: chuk_chat/lib/services/artifact_storage_service.dart @ d31526a229fdde27c82adf3661d5d3a149db8340.
// Reason: hosted-only — upstream persists encrypted artifact documents and their
// version history in Supabase. CoWork's host produces files, which the relay
// delivers as sandbox artifacts into the local blob store; there is no
// client-side artifact database. Reads return empty, writes throw.
// Keep the public API signature-compatible with upstream so the imported chat UI compiles unchanged. Do not "improve" this file.

import 'dart:async';

import 'package:cowork/models/artifact.dart';
import 'package:flutter/foundation.dart';

class ArtifactStorageService {
  const ArtifactStorageService._();

  static final StreamController<void> _changesController =
      StreamController<void>.broadcast();

  static Stream<void> get changes => _changesController.stream;

  static final ValueNotifier<ArtifactDocument?> activeArtifactNotifier =
      ValueNotifier<ArtifactDocument?>(null);

  static final ValueNotifier<bool> panelOpenNotifier = ValueNotifier<bool>(
    false,
  );

  static final ValueNotifier<int> openRequestNotifier = ValueNotifier<int>(0);

  static final ValueNotifier<({String artifactId, int? version})?>
  pendingInitialOpen = ValueNotifier<({String artifactId, int? version})?>(
    null,
  );

  static void requestOpen({required String artifactId, int? version}) {}

  static String? _activeChatId;

  static String? get activeChatId => _activeChatId;

  static String? currentMessageId;

  static Future<void> setActiveChat(
    String? chatId, {
    bool forceRefresh = false,
  }) async {
    _activeChatId = chatId;
  }

  static Future<List<ArtifactDocument>> loadArtifactsForChat(
    String chatId, {
    bool forceRefresh = false,
  }) async => const <ArtifactDocument>[];

  static Future<ArtifactDocument?> loadArtifactById(String artifactId) async =>
      null;

  static Future<ArtifactDocument> createArtifact({
    required String chatId,
    required String artifactId,
    required String title,
    required ArtifactType type,
    required String content,
    String? language,
    String? messageId,
    String? attachmentPath,
  }) async {
    throw UnsupportedError('CoWork does not store artifacts on the client.');
  }

  static Future<ArtifactDocument> rewriteArtifact({
    required String artifactId,
    required String content,
    String? title,
    ArtifactType? type,
    String? language,
    String? attachmentPath,
    bool preserveMetadata = false,
    bool clearAttachment = false,
  }) async {
    throw UnsupportedError('CoWork does not store artifacts on the client.');
  }

  static Future<void> rollbackArtifactsForMessages(
    Iterable<String> messageIds,
  ) async {}

  static Future<void> deleteArtifactsByIds(
    Iterable<String> artifactIds,
  ) async {}

  static Future<List<ArtifactVersionSnapshot>> loadVersions(
    String artifactId,
  ) async => const <ArtifactVersionSnapshot>[];

  static Future<void> reset() async {}
}
