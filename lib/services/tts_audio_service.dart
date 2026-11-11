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
  static final ValueNotifier<TtsPhase> _phase = ValueNotifier(TtsPhase.idle);
  static bool _hasPlayback = false;
  static final AudioPlayer _player = AudioPlayer();
  static final TtsPlaybackController _playback = TtsPlaybackController(
    playAudio: (bytes) =>
        _player.play(BytesSource(bytes, mimeType: 'audio/mpeg')),
    stopAudio: _player.stop,
    pauseAudio: _player.pause,
    resumeAudio: _player.resume,
    onComplete: _player.onPlayerComplete,
    isPlayingNotifier: _isPlaying,
    activeTextNotifier: _activeText,
    phaseNotifier: _phase,
  );
  static final Map<(String, Object), Future<Uint8List>> _inFlight = {};
  static _SpeechScope? _activeScope;

  static ValueListenable<bool> get isPlaying => _isPlaying;

  /// The answer being loaded or played; null when read aloud is idle.
  static ValueListenable<String?> get activeText => _activeText;

  /// Loading, playing or paused for [activeText]; idle otherwise.
  static ValueListenable<TtsPhase> get phase => _phase;

  /// Stop playback and cancel the current answer, including queued chunks.
  static Future<void> stop() {
    _activeScope = null;
    return _hasPlayback ? _playback.stop() : Future<void>.value();
  }

  /// Speak [text]. Repeated requests reuse the encrypted Supabase object.
  /// Starting another answer interrupts the current playback. For the
  /// active answer, a call cancels the load, pauses, or resumes at the
  /// saved position ([TtsPlaybackController.toggle]).
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
      await _playback.toggle();
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

/// Where read aloud stands for the active answer.
enum TtsPhase {
  /// Nothing is loaded or played.
  idle,

  /// The first audio of the answer is fetched or generated.
  loading,

  /// Audio plays. Between two chunks the next chunk can still load.
  playing,

  /// Playback holds its position. Resume continues from that position.
  paused,
}

/// Serial answer playback with cancellation independent of player completion.
/// A stopped native player does not emit a completion event.
///
/// A tap on the active answer moves the phase: [TtsPhase.loading] stops (the
/// load is cancelled), [TtsPhase.playing] pauses, [TtsPhase.paused] resumes at
/// the saved position. Another answer, [stop] or the end of the answer resets
/// the phase to [TtsPhase.idle].
@visibleForTesting
class TtsPlaybackController {
  TtsPlaybackController({
    required this.playAudio,
    required this.stopAudio,
    required this.onComplete,
    Future<void> Function()? pauseAudio,
    Future<void> Function()? resumeAudio,
    ValueNotifier<bool>? isPlayingNotifier,
    ValueNotifier<String?>? activeTextNotifier,
    ValueNotifier<TtsPhase>? phaseNotifier,
  }) : pauseAudio = pauseAudio ?? _noop,
       resumeAudio = resumeAudio ?? _noop,
       _isPlaying = isPlayingNotifier ?? ValueNotifier(false),
       _activeText = activeTextNotifier ?? ValueNotifier(null),
       _phase = phaseNotifier ?? ValueNotifier(TtsPhase.idle);

  static Future<void> _noop() async {}

  final Future<void> Function(Uint8List) playAudio;
  final Future<void> Function() stopAudio;
  final Future<void> Function() pauseAudio;
  final Future<void> Function() resumeAudio;
  final Stream<void> onComplete;

  /// True while an answer is loading, playing or paused.
  final ValueNotifier<bool> _isPlaying;
  ValueListenable<bool> get isPlaying => _isPlaying;
  final ValueNotifier<String?> _activeText;
  ValueListenable<String?> get activeText => _activeText;
  final ValueNotifier<TtsPhase> _phase;
  ValueListenable<TtsPhase> get phase => _phase;
  Completer<void>? _cancel;
  int _generation = 0;

  /// Completes when a paused answer resumes; null while not paused.
  Completer<void>? _resumed;

  /// True while a chunk is in the native player and has not completed.
  bool _chunkInPlayer = false;

  /// Counts pause and resume steps, so a paused wait is not a stuck player.
  int _pauseSteps = 0;

  void _setPhase(TtsPhase value) {
    _phase.value = value;
    _isPlaying.value = value != TtsPhase.idle;
  }

  void _releasePause() {
    final resumed = _resumed;
    _resumed = null;
    if (resumed != null && !resumed.isCompleted) resumed.complete();
  }

  Future<void> stop() async {
    _generation++;
    _cancel?.complete();
    _cancel = null;
    _releasePause();
    _chunkInPlayer = false;
    _activeText.value = null;
    _setPhase(TtsPhase.idle);
    await stopAudio();
  }

  /// The tap on the active answer: cancel a load, pause, or resume.
  Future<void> toggle() async {
    switch (_phase.value) {
      case TtsPhase.idle:
        return;
      case TtsPhase.loading:
        await stop();
      case TtsPhase.playing:
        await pause();
      case TtsPhase.paused:
        await resume();
    }
  }

  /// Hold playback at the current position.
  Future<void> pause() async {
    if (_phase.value != TtsPhase.playing) return;
    _resumed = Completer<void>();
    _pauseSteps++;
    _setPhase(TtsPhase.paused);
    if (_chunkInPlayer) await pauseAudio();
  }

  /// Continue from the position where [pause] stopped.
  Future<void> resume() async {
    if (_phase.value != TtsPhase.paused) return;
    _pauseSteps++;
    _setPhase(TtsPhase.playing);
    final inPlayer = _chunkInPlayer;
    _releasePause();
    if (inPlayer) await resumeAudio();
  }

  Future<void> speak(
    List<String> chunks, {
    String? answerText,
    required Future<Uint8List> Function(String) loadAudio,
    required bool Function() isCurrent,
  }) async {
    final answer = answerText ?? chunks.join('\n');
    if (_activeText.value == answer) {
      await toggle();
      return;
    }
    final generation = ++_generation;
    _cancel?.complete();
    final cancel = Completer<void>();
    _cancel = cancel;
    _releasePause();
    _chunkInPlayer = false;
    _activeText.value = answer;
    _setPhase(TtsPhase.loading);
    bool isLive() =>
        generation == _generation && !cancel.isCompleted && isCurrent();
    try {
      await stopAudio();
      if (!isLive()) return;
      Future<Uint8List>? prefetched;
      for (var i = 0; i < chunks.length; i++) {
        final pending = prefetched ?? loadAudio(chunks[i]);
        prefetched = null;
        final audio = await Future.any<Uint8List?>([
          pending,
          cancel.future.then((_) => null),
        ]);
        if (audio == null || !isLive()) return;
        if (!await _waitWhilePaused(cancel) || !isLive()) return;
        if (i + 1 < chunks.length) {
          // Load the next chunk while this one plays, so the gap is short.
          final next = loadAudio(chunks[i + 1]);
          unawaited(next.then<void>((_) {}, onError: (Object _) {}));
          prefetched = next;
        }
        final completed = Completer<void>();
        final subscription = onComplete.listen(
          (_) {
            if (generation == _generation) _chunkInPlayer = false;
            if (!completed.isCompleted) completed.complete();
          },
          onError: (Object error, StackTrace stack) {
            if (!completed.isCompleted) completed.completeError(error, stack);
          },
        );
        try {
          _chunkInPlayer = true;
          if (_phase.value == TtsPhase.loading) _setPhase(TtsPhase.playing);
          await playAudio(audio);
          if (!isLive()) return;
          // A pause during the start of the player must still hold it.
          if (_phase.value == TtsPhase.paused) await pauseAudio();
          await _waitForChunkEnd(completed.future, cancel.future);
        } finally {
          if (generation == _generation) _chunkInPlayer = false;
          await subscription.cancel();
        }
        if (!isLive()) return;
      }
    } finally {
      if (identical(_cancel, cancel)) {
        _cancel = null;
        _releasePause();
        _chunkInPlayer = false;
        _activeText.value = null;
        _setPhase(TtsPhase.idle);
        await stopAudio();
      }
    }
  }

  /// Returns false when the answer was cancelled while paused.
  Future<bool> _waitWhilePaused(Completer<void> cancel) async {
    while (_phase.value == TtsPhase.paused && !cancel.isCompleted) {
      final resumed = _resumed;
      if (resumed == null) break;
      await Future.any<void>([resumed.future, cancel.future]);
    }
    return !cancel.isCompleted;
  }

  /// Waits for the native completion event. A paused chunk can wait longer
  /// than the stuck-player limit; only a wait without a pause step times out.
  Future<void> _waitForChunkEnd(
    Future<void> completed,
    Future<void> cancelled,
  ) async {
    while (true) {
      final steps = _pauseSteps;
      try {
        await Future.any<void>([completed, cancelled])
            .timeout(const Duration(minutes: 10));
        return;
      } on TimeoutException {
        if (_phase.value != TtsPhase.paused && steps == _pauseSteps) rethrow;
      }
    }
  }
}
