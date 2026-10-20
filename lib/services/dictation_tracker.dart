// lib/services/dictation_tracker.dart
//
// A user message that was dictated (composer microphone, speech to text,
// sent) carries `inputMode: 'voice'` and, when it is known, the length of the
// recording in `voiceDurationMs`. The bubble then draws it as a voice message
// with the transcript folded. No audio is kept anywhere: the flag only says
// how the text came in. A message without the flag is a typed message, and
// the model always gets the plain text.

/// The keys a dictated message carries in its UI map and in the payload.
abstract final class VoiceInputKeys {
  /// `'voice'` for a dictated message. Absent for a typed one.
  static const String inputMode = 'inputMode';

  /// Length of the recording in whole milliseconds, as a decimal string.
  static const String durationMs = 'voiceDurationMs';

  /// The value of [inputMode] for a dictated message.
  static const String voice = 'voice';
}

/// Whether the message map was dictated.
bool isVoiceInput(Map<String, dynamic> message) =>
    message[VoiceInputKeys.inputMode] == VoiceInputKeys.voice;

/// The recording length of a dictated message, or null when it is unknown.
Duration? voiceInputDuration(Map<String, dynamic> message) {
  final int? ms = int.tryParse('${message[VoiceInputKeys.durationMs] ?? ''}');
  if (ms == null || ms <= 0) return null;
  return Duration(milliseconds: ms);
}

/// How much of [sent] is still the text in [transcript], 0..1.
///
/// The common prefix plus the common suffix, over the longer of the two. A
/// transcript sent as it is gives 1. A fixed word in the middle stays high.
/// A transcript with a long typed paragraph after it falls below the bar.
double dictationCoverage(String transcript, String sent) {
  final String a = _normalize(transcript);
  final String b = _normalize(sent);
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 1;
  final int shorter = a.length < b.length ? a.length : b.length;
  int prefix = 0;
  while (prefix < shorter && a.codeUnitAt(prefix) == b.codeUnitAt(prefix)) {
    prefix++;
  }
  int suffix = 0;
  while (suffix < shorter - prefix &&
      a.codeUnitAt(a.length - 1 - suffix) ==
          b.codeUnitAt(b.length - 1 - suffix)) {
    suffix++;
  }
  final int longer = a.length > b.length ? a.length : b.length;
  return (prefix + suffix) / longer;
}

String _normalize(String text) => text.trim().replaceAll(RegExp(r'\s+'), ' ');

/// Below this share of dictated text, a message counts as typed.
const double kDictationCoverageMin = 0.6;

/// Remembers the last dictation until the composer sends it.
///
/// The recording handler records every transcript it hands to the composer.
/// The send path asks [takeFor] with the text it is about to send: when that
/// text is still mostly the transcript, it gets the voice keys. The entry is
/// used once, and it expires, so a later typed message never inherits it.
class DictationTracker {
  DictationTracker({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// The one tracker the app uses.
  static final DictationTracker instance = DictationTracker();

  /// A dictation older than this is not matched any more.
  static const Duration maxAge = Duration(minutes: 30);

  final DateTime Function() _clock;
  String? _transcript;
  Duration? _duration;
  DateTime? _recordedAt;

  /// Note a transcript the composer received. [duration] is the length of
  /// the recording, null when it is unknown.
  void record(String transcript, {Duration? duration}) {
    if (transcript.trim().isEmpty) return;
    _transcript = transcript;
    _duration = duration;
    _recordedAt = _clock();
  }

  /// Forget the pending dictation.
  void clear() {
    _transcript = null;
    _duration = null;
    _recordedAt = null;
  }

  /// The voice keys for a message with [text], or an empty map when [text]
  /// was not dictated. A match uses the dictation up.
  Map<String, String> takeFor(String text) {
    final String? transcript = _transcript;
    final DateTime? at = _recordedAt;
    if (transcript == null || at == null) return const <String, String>{};
    if (_clock().difference(at) > maxAge) {
      clear();
      return const <String, String>{};
    }
    if (dictationCoverage(transcript, text) < kDictationCoverageMin) {
      return const <String, String>{};
    }
    final Duration? duration = _duration;
    clear();
    return <String, String>{
      VoiceInputKeys.inputMode: VoiceInputKeys.voice,
      if (duration != null && duration.inMilliseconds > 0)
        VoiceInputKeys.durationMs: '${duration.inMilliseconds}',
    };
  }

  /// Update the voice keys of [message] for an edit to [newText].
  ///
  /// A fresh dictation of the new text makes it a voice message. Otherwise a
  /// voice message stays one while the edit keeps most of its text, and
  /// turns into a typed message when the edit rewrote it.
  void applyToEdit(Map<String, String> message, String newText) {
    final Map<String, String> fresh = takeFor(newText);
    if (fresh.isNotEmpty) {
      message
        ..remove(VoiceInputKeys.durationMs)
        ..addAll(fresh);
      return;
    }
    if (!isVoiceInput(message)) return;
    final String oldText = message['text'] ?? '';
    if (dictationCoverage(oldText, newText) >= kDictationCoverageMin) return;
    message
      ..remove(VoiceInputKeys.inputMode)
      ..remove(VoiceInputKeys.durationMs);
  }
}
