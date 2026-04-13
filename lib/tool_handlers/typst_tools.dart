import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:chuk_chat/models/artifact.dart';
import 'package:chuk_chat/services/artifact_storage_service.dart';

/// Compile Typst source via the backend. Returns PDF bytes on success.
/// Nothing is persisted on the server — the backend wipes its tempdir
/// the moment the response is sent.
Future<Uint8List> compileTypstToPdf({
  required String serverHttpUrl,
  required String? accessToken,
  required String source,
  String format = 'pdf',
}) async {
  final uri = Uri.parse('$serverHttpUrl/v1/ai/typst/compile');
  final response = await http
      .post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          if (accessToken != null && accessToken.isNotEmpty)
            'Authorization': 'Bearer $accessToken',
        },
        body: jsonEncode({'source': source, 'format': format}),
      )
      .timeout(const Duration(seconds: 30));

  if (response.statusCode != 200) {
    String detail = 'HTTP ${response.statusCode}';
    try {
      final data = jsonDecode(response.body);
      if (data is Map && data['detail'] is String) {
        detail = data['detail'] as String;
      }
    } catch (_) {
      if (response.body.isNotEmpty) {
        detail = response.body;
      }
    }
    throw _TypstCompileError(detail);
  }

  return response.bodyBytes;
}

class _TypstCompileError implements Exception {
  _TypstCompileError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Tool handler: validate the Typst source by compiling it, then create a
/// persistent `typst` artifact with the source text. The UI re-compiles on
/// demand when the artifact panel opens, so no PDF bytes are stored.
Future<String> executeTypstCompile({
  required String? serverHttpUrl,
  required String? accessToken,
  required String? chatId,
  required Map<String, dynamic> args,
}) async {
  if (chatId == null || chatId.isEmpty) {
    return 'Error: No active chat. Start or select a chat first.';
  }
  final baseUrl = (serverHttpUrl ?? '').trim();
  if (baseUrl.isEmpty) {
    return 'Error: Not connected to server.';
  }

  final source = (args['source'] as String? ?? '').trim();
  if (source.isEmpty) {
    return 'Error: "source" parameter required (Typst markup).';
  }

  final artifactId = (args['artifact_id'] as String? ?? '').trim();
  if (artifactId.isEmpty) {
    return 'Error: "artifact_id" parameter required '
        '(short slug like "report_v1").';
  }

  final title =
      (args['title'] as String? ?? '').trim().isEmpty
          ? artifactId
          : (args['title'] as String).trim();

  final messageId = (args['message_id'] as String?)?.trim();

  // Compile once to validate — bytes are discarded. This round-trip also
  // triggers the backend rate limit, which is what we want: one compile per
  // tool call.
  try {
    await compileTypstToPdf(
      serverHttpUrl: baseUrl,
      accessToken: accessToken,
      source: source,
      format: 'pdf',
    );
  } on _TypstCompileError catch (e) {
    return 'Typst compile failed:\n${e.message}';
  } catch (e) {
    return 'Typst compile failed: $e';
  }

  try {
    final created = await ArtifactStorageService.createArtifact(
      chatId: chatId,
      artifactId: artifactId,
      title: title,
      type: ArtifactType.typst,
      content: source,
      messageId: (messageId == null || messageId.isEmpty) ? null : messageId,
    );
    return 'Typst artifact "${created.id}" created '
        '(rendered on demand — PDF is never stored server-side).';
  } on StateError catch (e) {
    // Likely duplicate id — tell the AI to rewrite.
    return 'Error: ${e.message}';
  } catch (e) {
    return 'Error: Could not save Typst artifact: $e';
  }
}
