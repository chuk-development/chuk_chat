import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:chuk_chat/models/artifact.dart';
import 'package:chuk_chat/services/artifact_storage_service.dart';
import 'package:chuk_chat/services/pdf_attachment_service.dart';

/// Result of a Typst compile: the rendered bytes plus optional layout
/// info derived by the server (page count + last-page fill %) so the
/// AI can decide whether to retry with a tighter layout.
class TypstCompileResult {
  const TypstCompileResult({required this.bytes, this.layout});
  final Uint8List bytes;
  final TypstLayoutSnapshot? layout;
}

/// Compile Typst source via the backend. Returns the rendered bytes and
/// any layout metadata the server reported in response headers.
/// Nothing is persisted on the server — the backend wipes its tempdir
/// the moment the response is sent.
Future<TypstCompileResult> compileTypstToPdf({
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

  return TypstCompileResult(
    bytes: response.bodyBytes,
    layout: _layoutFromHeaders(response.headers),
  );
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
  TypstCompileResult compile;
  try {
    compile = await compileTypstToPdf(
      serverHttpUrl: baseUrl,
      accessToken: accessToken,
      source: source,
      format: 'pdf',
    );
  } on _TypstCompileError catch (e) {
    return _compileErrorGuidance(e.message);
  } catch (e) {
    return _compileErrorGuidance(e.toString());
  }

  final pdfBytes = compile.bytes;
  final layout = compile.layout;

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

  // If the artifact already exists, this call is an update: rewrite the
  // source + swap the attachment. Otherwise create a fresh record.
  final existing = await ArtifactStorageService.loadArtifactById(artifactId);

  try {
    final ArtifactDocument stored;
    final String verb;
    if (existing == null) {
      stored = await ArtifactStorageService.createArtifact(
        chatId: chatId,
        artifactId: artifactId,
        title: title,
        type: ArtifactType.typst,
        content: source,
        messageId: messageId,
        attachmentPath: attachmentPath,
      );
      verb = 'created';
    } else {
      final oldAttachment = existing.attachmentPath;
      stored = await ArtifactStorageService.rewriteArtifact(
        artifactId: artifactId,
        content: source,
        title: title,
        type: ArtifactType.typst,
        attachmentPath: attachmentPath,
        clearAttachment: attachmentPath == null,
      );
      verb = 'rewritten';
      // Drop the now-orphaned previous PDF from storage.
      if (oldAttachment != null && oldAttachment != attachmentPath) {
        unawaited(PdfAttachmentService.delete(oldAttachment));
      }
    }

    final persisted = attachmentPath != null
        ? 'stored end-to-end encrypted in Supabase'
        : 'source stored; PDF will be re-rendered on demand '
          '(attachment upload failed: ${uploadError ?? "unknown"})';
    final layoutNote = _layoutGuidance(layout);
    return 'Typst artifact "${stored.id}" $verb '
        '(version: ${stored.version}, $persisted).$layoutNote'
        '$_deliveryNote';
  } on StateError catch (e) {
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

/// Appended to every successful compile result. The compiled PDF is shown to
/// the user as a downloadable artifact card the moment this tool returns —
/// the compile IS the delivery. Models otherwise try to "hand over" the file
/// with send_file_to_user (which fails: the PDF is an artifact, not a sandbox
/// file) and then thrash the sandbox looking for it. Say plainly it is done.
const String _deliveryNote =
    ' The PDF is now shown to the user as a downloadable artifact card — it is '
    'delivered. Do NOT call send_file_to_user and do NOT use the sandbox to '
    'send it; there is no file to send. Just tell the user it is ready.';

/// Snapshot of a compiled Typst PDF's layout (page count + last-page
/// fill %) reported by the server in response headers. Used to nudge
/// the AI when the last page is an orphan (tiny slice of content).
class TypstLayoutSnapshot {
  const TypstLayoutSnapshot({
    required this.pageCount,
    required this.lastPageFillPct,
  });
  final int pageCount;
  final double lastPageFillPct;
}

/// Below this fill % on the last page we tell the AI the page is an
/// orphan and worth re-shaping the document to avoid. Must match the
/// server-side threshold (`TYPST_ORPHAN_FILL_PCT_THRESHOLD`).
const double _orphanFillPctThreshold = 15.0;

/// Parses layout headers the server attaches to every PDF compile:
///   X-Typst-Pages: 3
///   X-Typst-Last-Page-Fill-Pct: 12.7
/// Returns null if either header is missing or malformed.
TypstLayoutSnapshot? _layoutFromHeaders(Map<String, String> headers) {
  final rawPages = headers['x-typst-pages'];
  final rawFill = headers['x-typst-last-page-fill-pct'];
  if (rawPages == null || rawFill == null) return null;
  final pages = int.tryParse(rawPages);
  final fill = double.tryParse(rawFill);
  if (pages == null || pages <= 0 || fill == null) return null;
  return TypstLayoutSnapshot(pageCount: pages, lastPageFillPct: fill);
}

/// Builds the layout suffix appended to the tool result string. Always
/// includes page count + fill %; flags orphan pages so the AI can
/// decide whether to retry with a tighter layout.
String _layoutGuidance(TypstLayoutSnapshot? layout) {
  if (layout == null) return '';
  final pct = layout.lastPageFillPct.toStringAsFixed(1);
  if (layout.pageCount <= 1) {
    return ' PDF: 1 page (~$pct% filled).';
  }
  final base =
      ' PDF: ${layout.pageCount} pages; last page ~$pct% filled.';
  if (layout.lastPageFillPct >= _orphanFillPctThreshold) {
    return base;
  }
  return '$base Last page is an orphan — only a small slice of content '
      'spills onto it, which looks ugly. If you can, retry typst_compile '
      'with a tighter layout so the content fits on '
      '${layout.pageCount - 1} pages: e.g. shrink margins '
      '(`#set page(margin: 1.5cm)`), reduce font size '
      '(`#set text(size: 10pt)`), tighten paragraph/leading spacing '
      '(`#set par(leading: 0.55em)`), or trim filler text. Keep the '
      'same `artifact_id` so the version updates in place.';
}

/// Wraps a Typst compile error so the AI sees both the compiler output
/// *and* an explicit nudge to emit a retry. Kimi-style models otherwise
/// tend to stop at an intention-only reply ("let me fix that") without
/// calling the tool again.
String _compileErrorGuidance(String compilerError) {
  return 'Typst compile failed. The source was NOT saved.\n\n'
      '--- Compiler output ---\n'
      '$compilerError\n'
      '--- End compiler output ---\n\n'
      'Action required: fix the source based on the error above and emit '
      'another <tool_call> for typst_compile with the corrected `source`. '
      'Do NOT end the turn with intention-only text like "I will fix it" — '
      'retry now in the SAME response.';
}
