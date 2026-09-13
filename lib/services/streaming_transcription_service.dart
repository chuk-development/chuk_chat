// AGENTS STUB. Upstream: chuk_chat/lib/services/streaming_transcription_service.dart @ d31526a229fdde27c82adf3661d5d3a149db8340.
// Reason: hosted-only — upstream streams PCM to the hosted transcription
// socket. Agents has no such endpoint; voice mode is off (kFeatureVoiceMode).
// Keep the public API signature-compatible with upstream so the imported chat UI compiles unchanged. Do not "improve" this file.

import 'dart:typed_data';

class StreamingTranscriptionService {
  bool get isConnected => false;

  Future<bool> connect({
    required String accessToken,
    int sampleRate = 16000,
    int channels = 1,
  }) async => false;

  void sendAudioChunk(Uint8List pcmData) {}

  Future<Map<String, dynamic>?> finishAndTranscribe() async => null;

  Future<void> abort() async {}

  Future<void> dispose() async {}
}
