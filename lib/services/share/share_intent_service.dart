/// Content shared INTO the app from the Android share sheet, and the Direct
/// Share contacts (one per agent) the sheet offers.
///
/// Native side: `android/.../share/ShareReceiverActivity.kt` takes the
/// ACTION_SEND intent, `ShareBridge.kt` copies the files into the cache and
/// talks to this class over the `chuk/share` channel.
///
/// Routing: [incoming] holds the share until a screen takes it.
///  * A share without a [SharedContent.agentId] (the plain "Chuk Chat" entry)
///    goes into a new chuk chat (`RootWrapperMobile`).
///  * A share picked on an agent's contact goes into that agent's thread
///    (`MessengerShell`). Its files wait in [parkFiles] until the thread's
///    chat screen takes them ([takeParkedFiles]).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One file the share carried, copied into the app cache.
@immutable
class SharedFile {
  const SharedFile({required this.path, required this.name, this.mime});

  final String path;
  final String name;
  final String? mime;
}

/// What the user shared.
@immutable
class SharedContent {
  const SharedContent({
    this.text,
    this.subject,
    this.agentId,
    this.files = const <SharedFile>[],
  });

  /// Builds a share from the channel map. Null when it carries nothing.
  static SharedContent? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final List<SharedFile> files = <SharedFile>[];
    final Object? rawFiles = raw['files'];
    if (rawFiles is List) {
      for (final Object? f in rawFiles) {
        if (f is! Map) continue;
        final Object? path = f['path'];
        final Object? name = f['name'];
        if (path is! String || path.isEmpty) continue;
        files.add(
          SharedFile(
            path: path,
            name: name is String && name.isNotEmpty ? name : 'shared',
            mime: f['mime'] is String ? f['mime'] as String : null,
          ),
        );
      }
    }
    String? str(String key) {
      final Object? v = raw[key];
      return v is String && v.trim().isNotEmpty ? v : null;
    }

    final SharedContent share = SharedContent(
      text: str('text'),
      subject: str('subject'),
      agentId: str('target'),
      files: files,
    );
    return share.isEmpty ? null : share;
  }

  final String? text;
  final String? subject;

  /// The agent whose Direct Share contact was picked, or null for the app.
  final String? agentId;
  final List<SharedFile> files;

  bool get isEmpty => composerText.isEmpty && files.isEmpty;

  /// The text for the composer. A subject that the text does not already
  /// start with (a shared web page: title + link) goes on its own line first.
  String get composerText {
    final String body = text?.trim() ?? '';
    final String head = subject?.trim() ?? '';
    if (head.isEmpty || body.startsWith(head)) return body;
    if (body.isEmpty) return head;
    return '$head\n$body';
  }
}

/// One Direct Share contact: an id the share comes back with, the name the
/// sheet shows and the PNG icon (an adaptive-icon layout, see
/// `share_target_icon.dart`).
@immutable
class ShareTarget {
  const ShareTarget({required this.id, required this.label, this.icon});

  final String id;
  final String label;
  final Uint8List? icon;

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'label': label,
    'icon': icon,
  };
}

class ShareIntentService {
  ShareIntentService._();

  static final ShareIntentService instance = ShareIntentService._();

  static const MethodChannel _channel = MethodChannel('chuk/share');

  /// The share no screen has taken yet.
  final ValueNotifier<SharedContent?> incoming = ValueNotifier<SharedContent?>(
    null,
  );

  bool _started = false;

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Starts listening and fetches a share that launched the app. Safe to call
  /// more than once.
  Future<void> start() async {
    if (_started || !isSupported) return;
    _started = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'shareAvailable') await _fetch();
      return null;
    });
    await _fetch();
  }

  Future<void> _fetch() async {
    try {
      final SharedContent? share = SharedContent.fromMap(
        await _channel.invokeMethod<Object?>('takeShare'),
      );
      if (share != null) incoming.value = share;
    } on PlatformException catch (e) {
      if (kDebugMode) debugPrint('share: takeShare failed (${e.code})');
    } on MissingPluginException {
      // A test or a build without the native side.
    }
  }

  /// Takes the pending share. Null when there is none.
  SharedContent? take() {
    final SharedContent? share = incoming.value;
    incoming.value = null;
    return share;
  }

  // --- files waiting for an agent thread -----------------------------------

  ({String chatId, List<SharedFile> files})? _parked;

  /// Parks [files] for the chat screen that opens [chatId].
  void parkFiles(String chatId, List<SharedFile> files) {
    _parked = files.isEmpty ? null : (chatId: chatId, files: files);
  }

  /// The files parked for [chatId], once.
  List<SharedFile> takeParkedFiles(String? chatId) {
    final parked = _parked;
    if (parked == null || chatId == null || parked.chatId != chatId) {
      return const <SharedFile>[];
    }
    _parked = null;
    return parked.files;
  }

  // --- Direct Share contacts -----------------------------------------------

  String? _lastTargetsKey;

  /// Publishes [targets] as the share sheet's Direct Share contacts, in this
  /// order. Replaces the earlier set; an unchanged set is not sent again.
  Future<void> publishTargets(List<ShareTarget> targets) async {
    if (!isSupported) return;
    final String key = targets
        .map((t) => '${t.id}\u0000${t.label}\u0000${t.icon?.length ?? 0}')
        .join('\u0001');
    if (key == _lastTargetsKey) return;
    _lastTargetsKey = key;
    try {
      await _channel.invokeMethod<bool>('setShareTargets', <String, Object?>{
        'targets': targets.map((t) => t.toMap()).toList(),
      });
    } on PlatformException catch (e) {
      _lastTargetsKey = null;
      if (kDebugMode) debugPrint('share: setShareTargets failed (${e.code})');
    } on MissingPluginException {
      _lastTargetsKey = null;
    }
  }

  @visibleForTesting
  void resetForTest() {
    incoming.value = null;
    _parked = null;
    _lastTargetsKey = null;
    _started = false;
  }
}
