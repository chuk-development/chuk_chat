import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// Inworld read-aloud audio, cached encrypted in the user's private bucket.
class TtsAudioService {
  TtsAudioService._();

  static const String _bucket = 'tts-audio';
  static const String _model = 'inworld-tts-2-flash';
  static const String _voice = 'Bastian';
  static const int _maxRequestChars = 3800;
  static final ValueNotifier<bool> _isPlaying = ValueNotifier(false);
  static final ValueNotifier<String?> _activeText = ValueNotifier(null);
  static bool _hasPlayback = false;
  static final AudioPlayer _player = AudioPlayer();
  static final TtsPlaybackController _playback = TtsPlaybackController(
    playAudio: (bytes) =>
        _player.play(BytesSource(bytes, mimeType: 'audio/mpeg')),
    stopAudio: _player.stop,
    onComplete: _player.onPlayerComplete,
    isPlayingNotifier: _isPlaying,
    activeTextNotifier: _activeText,
  );
  static final Map<(String, Object), Future<Uint8List>> _inFlight = {};
  static _SpeechScope? _activeScope;

  static ValueListenable<bool> get isPlaying => _isPlaying;

  /// The answer being loaded or played; null when read aloud is idle.
  static ValueListenable<String?> get activeText => _activeText;

  /// Stop playback and cancel the current answer, including queued chunks.
  static Future<void> stop() {
    _activeScope = null;
    return _hasPlayback ? _playback.stop() : Future<void>.value();
  }

  /// Speak [text]. Repeated requests reuse the encrypted Supabase object.
  /// Starting another answer interrupts the current playback.
  static Future<void> speak(String text) async {
    final normalized = text.trim();
    if (normalized.isEmpty) return;

    final user = SupabaseService.auth.currentUser;
    if (user == null) throw StateError('Sign in to use read aloud.');
    if (!EncryptionService.hasKey) {
      throw StateError('Unlock chat encryption before using read aloud.');
    }

    final scope = _SpeechScope(user.id, EncryptionService.keyIdentity!);
    if (activeText.value == normalized) {
      await stop();
      return;
    }

    _activeScope = scope;
    void stopIfScopeChanged() {
      if (identical(_activeScope, scope) && !scope.isCurrent) {
        unawaited(stop());
      }
    }

    final authChanges = SupabaseService.auth.onAuthStateChange.listen((_) {
      stopIfScopeChanged();
    });
    // A key can be locked or replaced without an auth state event.
    final scopeWatch = Timer.periodic(const Duration(milliseconds: 250), (_) {
      stopIfScopeChanged();
    });
    try {
      _hasPlayback = true;
      await _playback.speak(
        _splitText(normalized),
        answerText: normalized,
        loadAudio: (chunk) => _audioForChunk(scope, chunk),
        isCurrent: () => scope.isCurrent,
      );
    } finally {
      if (identical(_activeScope, scope)) _activeScope = null;
      scopeWatch.cancel();
      await authChanges.cancel();
    }
  }

  static Future<Uint8List> _audioForChunk(_SpeechScope scope, String text) {
    scope.check();
    final key = sha256
        .convert(utf8.encode('v1\u0000$_model\u0000$_voice\u0000$text'))
        .toString();
    final path = '${scope.userId}/$key.enc';
    final flightKey = (path, scope.keyIdentity);
    final existing = _inFlight[flightKey];
    if (existing != null) return existing;

    late final Future<Uint8List> future;
    future = _loadOrGenerate(scope, path, text).whenComplete(() {
      if (identical(_inFlight[flightKey], future)) _inFlight.remove(flightKey);
    });
    _inFlight[flightKey] = future;
    return future;
  }

  static Future<Uint8List> _loadOrGenerate(
    _SpeechScope scope,
    String path,
    String text,
  ) async {
    final bucket = SupabaseService.client.storage.from(_bucket);
    try {
      final encryptedBytes = await bucket
          .download(path)
          .timeout(const Duration(seconds: 15));
      scope.check();
      final audio = await EncryptionService.decryptBytes(
        utf8.decode(encryptedBytes),
      );
      scope.check();
      if (audio.isNotEmpty) return audio;
    } on StorageException {
      // A cache read failure should not prevent a fresh, playable response.
    } catch (_) {
      // Corrupt or stale ciphertext is a cache miss, not a playback failure.
    }

    scope.check();
    final audio = await _generate(scope, text);
    scope.check();
    try {
      final encrypted = await EncryptionService.encryptBytes(audio);
      scope.check();
      await bucket
          .uploadBinary(
            path,
            Uint8List.fromList(utf8.encode(encrypted)),
            fileOptions: const FileOptions(
              contentType: 'application/octet-stream',
              upsert: true,
            ),
          )
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      // Play the generated audio even if the cache is temporarily unavailable.
    }
    scope.check();
    return audio;
  }

  static Future<Uint8List> _generate(_SpeechScope scope, String text) async {
    final session =
        await SupabaseService.refreshSession() ??
        SupabaseService.auth.currentSession;
    scope.check();
    if (session == null ||
        session.user.id != scope.userId ||
        session.accessToken.isEmpty) {
      throw StateError(
        'Your session expired. Sign in again to use read aloud.',
      );
    }
    final response = await http
        .post(
          Uri.parse('${ApiConfigService.apiBaseUrl}/v1/audio/speech'),
          headers: <String, String>{
            'Authorization': 'Bearer ${session.accessToken}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(<String, Object>{
            'input': text,
            'model': _model,
            'voice': _voice,
            'response_format': 'mp3',
          }),
        )
        .timeout(const Duration(seconds: 90));
    scope.check();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Speech generation failed (${response.statusCode}).');
    }
    if (response.bodyBytes.isEmpty) {
      throw StateError('Speech service returned no audio.');
    }
    return response.bodyBytes;
  }

  static List<String> _splitText(String text) {
    final chunks = <String>[];
    var remaining = text;
    while (remaining.length > _maxRequestChars) {
      var splitAt = remaining.lastIndexOf(
        RegExp(r'[\s.!?。！？]'),
        _maxRequestChars,
      );
      if (splitAt < _maxRequestChars ~/ 2) splitAt = _maxRequestChars;
      // Never split a UTF-16 surrogate pair.
      if (splitAt > 0 && splitAt < remaining.length) {
        final previous = remaining.codeUnitAt(splitAt - 1);
        final next = remaining.codeUnitAt(splitAt);
        if (previous >= 0xD800 &&
            previous <= 0xDBFF &&
            next >= 0xDC00 &&
            next <= 0xDFFF) {
          splitAt--;
        }
      }
      final chunk = remaining.substring(0, splitAt).trim();
      if (chunk.isNotEmpty) chunks.add(chunk);
      remaining = remaining.substring(splitAt).trimLeft();
    }
    if (remaining.isNotEmpty) chunks.add(remaining);
    return chunks;
  }

  @visibleForTesting
  static List<String> splitTextForTesting(String text) => _splitText(text);
}

class _SpeechScope {
  const _SpeechScope(this.userId, this.keyIdentity);

  final String userId;
  final Object keyIdentity;

  bool get isCurrent =>
      SupabaseService.auth.currentUser?.id == userId &&
      identical(EncryptionService.keyIdentity, keyIdentity);

  void check() {
    if (!isCurrent) {
      throw StateError('Read aloud stopped because your session changed.');
    }
  }
}

/// Serial answer playback with cancellation independent of player completion.
/// A stopped native player does not emit a completion event.
@visibleForTesting
class TtsPlaybackController {
  TtsPlaybackController({
    required this.playAudio,
    required this.stopAudio,
    required this.onComplete,
    ValueNotifier<bool>? isPlayingNotifier,
    ValueNotifier<String?>? activeTextNotifier,
  }) : _isPlaying = isPlayingNotifier ?? ValueNotifier(false),
       _activeText = activeTextNotifier ?? ValueNotifier(null);

  final Future<void> Function(Uint8List) playAudio;
  final Future<void> Function() stopAudio;
  final Stream<void> onComplete;
  final ValueNotifier<bool> _isPlaying;
  ValueListenable<bool> get isPlaying => _isPlaying;
  final ValueNotifier<String?> _activeText;
  ValueListenable<String?> get activeText => _activeText;
  Completer<void>? _cancel;
  int _generation = 0;

  Future<void> stop() async {
    _generation++;
    _cancel?.complete();
    _cancel = null;
    _isPlaying.value = false;
    _activeText.value = null;
    await stopAudio();
  }

  Future<void> speak(
    List<String> chunks, {
    String? answerText,
    required Future<Uint8List> Function(String) loadAudio,
    required bool Function() isCurrent,
  }) async {
    final answer = answerText ?? chunks.join('\n');
    if (_activeText.value == answer) {
      await stop();
      return;
    }
    final generation = ++_generation;
    _cancel?.complete();
    final cancel = Completer<void>();
    _cancel = cancel;
    _activeText.value = answer;
    _isPlaying.value = true;
    try {
      await stopAudio();
      if (generation != _generation || !isCurrent()) return;
      for (final chunk in chunks) {
        final audio = await Future.any<Uint8List?>([
          loadAudio(chunk),
          cancel.future.then((_) => null),
        ]);
        if (audio == null || cancel.isCompleted || !isCurrent()) return;
        final completed = Completer<void>();
        final subscription = onComplete.listen(
          (_) {
            if (!completed.isCompleted) completed.complete();
          },
          onError: (Object error, StackTrace stack) {
            if (!completed.isCompleted) completed.completeError(error, stack);
          },
        );
        try {
          await playAudio(audio);
          if (cancel.isCompleted || !isCurrent()) return;
          await Future.any([completed.future, cancel.future])
              .timeout(const Duration(minutes: 10));
        } finally {
          await subscription.cancel();
        }
        if (cancel.isCompleted || !isCurrent()) return;
      }
    } finally {
      if (identical(_cancel, cancel)) {
        _cancel = null;
        _isPlaying.value = false;
        _activeText.value = null;
        await stopAudio();
      }
    }
  }
}
