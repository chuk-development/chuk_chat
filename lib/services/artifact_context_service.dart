// COWORK STUB. Upstream: chuk_chat/lib/services/artifact_context_service.dart @ d31526a229fdde27c82adf3661d5d3a149db8340.
// Reason: hosted-only — artifacts live in Supabase upstream, and the system
// prompt is built by the host in CoWork. Returns null (no artifact context).
// Keep the public API signature-compatible with upstream so the imported chat UI compiles unchanged. Do not "improve" this file.

class ArtifactContextService {
  const ArtifactContextService._();

  static Future<String?> buildArtifactsSystemMessage(String chatId) async =>
      null;
}
