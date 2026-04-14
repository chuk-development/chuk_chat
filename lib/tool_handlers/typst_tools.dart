import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:chuk_chat/models/artifact.dart';
import 'package:chuk_chat/services/artifact_storage_service.dart';
import 'package:chuk_chat/services/pdf_attachment_service.dart';

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

  final rawSource = args['source'];
  final source = rawSource is String ? rawSource.trim() : '';
  if (source.isEmpty) {
    return 'Error: "source" parameter required (Typst markup).';
  }

  final rawArtifactId = args['artifact_id'];
  final artifactId = rawArtifactId is String ? rawArtifactId.trim() : '';
  if (artifactId.isEmpty) {
    return 'Error: "artifact_id" parameter required '
        '(short slug like "report_v1").';
  }

  final rawTitle = args['title'];
  final title = (rawTitle is String && rawTitle.trim().isNotEmpty)
      ? rawTitle.trim()
      : artifactId;

  final rawMessageId = args['message_id'];
  final messageId =
      (rawMessageId is String && rawMessageId.trim().isNotEmpty)
          ? rawMessageId.trim()
          : null;

  // Compile once. We keep the bytes so we can persist the rendered PDF
  // as an encrypted attachment — the client no longer has to re-compile
  // every time the artifact is reopened.
  Uint8List pdfBytes;
  try {
    pdfBytes = await compileTypstToPdf(
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

  // Upload the PDF encrypted (same trust model as chat messages &
  // images). Failure here is not fatal — we fall back to live
  // recompilation on open, but surface the error to the AI so it
  // can tell the user why persistence didn't work.
  String? attachmentPath;
  String? uploadError;
  try {
    attachmentPath = await PdfAttachmentService.upload(pdfBytes);
  } catch (e) {
    attachmentPath = null;
    uploadError = e.toString();
  }

  try {
    final created = await ArtifactStorageService.createArtifact(
      chatId: chatId,
      artifactId: artifactId,
      title: title,
      type: ArtifactType.typst,
      content: source,
      messageId: messageId,
      attachmentPath: attachmentPath,
    );
    final persisted = attachmentPath != null
        ? 'stored end-to-end encrypted in Supabase'
        : 'source stored; PDF will be re-rendered on demand '
          '(attachment upload failed: ${uploadError ?? "unknown"})';
    return 'Typst artifact "${created.id}" created '
        '(version: ${created.version}, $persisted).';
  } on StateError catch (e) {
    // Artifact creation failed — don't leak the orphan attachment.
    if (attachmentPath != null) {
      unawaited(PdfAttachmentService.delete(attachmentPath));
    }
    return 'Error: ${e.message}';
  } catch (e) {
    if (attachmentPath != null) {
      unawaited(PdfAttachmentService.delete(attachmentPath));
    }
    return 'Error: Could not save Typst artifact: $e';
  }
}
