import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:pdfrx/pdfrx.dart';

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
    return _compileErrorGuidance(e.message);
  } catch (e) {
    return _compileErrorGuidance(e.toString());
  }

  // Inspect layout so the AI knows page count + how full the last page
  // is. Lets the model decide whether to retry with tighter layout to
  // avoid an orphan last page.
  final layout = await _analyzePdfLayout(pdfBytes);

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
        '(version: ${stored.version}, $persisted).$layoutNote';
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

/// Snapshot of a compiled Typst PDF's layout used to nudge the AI when
/// the last page is an orphan (only a tiny slice of content).
class _PdfLayoutSnapshot {
  const _PdfLayoutSnapshot({
    required this.pageCount,
    required this.lastPageFillPct,
  });
  final int pageCount;
  final double lastPageFillPct;
}

/// Below this fill % on the last page we tell the AI the page is an
/// orphan and worth re-shaping the document to avoid.
const double _orphanFillPctThreshold = 15.0;

/// Renders the last PDF page at low DPI and counts non-white pixels to
/// estimate how full the page is. Returns null on any failure so the
/// caller can silently degrade.
Future<_PdfLayoutSnapshot?> _analyzePdfLayout(Uint8List bytes) async {
  PdfDocument? doc;
  try {
    await pdfrxFlutterInitialize();
    doc = await PdfDocument.openData(bytes, sourceName: 'typst-orphan-check');
    final pages = doc.pages;
    if (pages.isEmpty) return null;
    final last = pages.last;
    if (last.width <= 0 || last.height <= 0) {
      return _PdfLayoutSnapshot(
        pageCount: pages.length,
        lastPageFillPct: 0,
      );
    }
    const targetW = 200;
    final scale = targetW / last.width;
    final targetH = (last.height * scale).round().clamp(1, 4000);
    final image = await last.render(
      fullWidth: targetW.toDouble(),
      fullHeight: targetH.toDouble(),
    );
    if (image == null) return null;
    final pixels = image.pixels;
    final total = image.width * image.height;
    if (total <= 0) return null;
    int ink = 0;
    for (var i = 0; i + 3 < pixels.length; i += 4) {
      // PDFium delivers BGRA. Anything appreciably darker than white
      // counts as ink — Typst's default background is pure white.
      if (pixels[i] < 240 || pixels[i + 1] < 240 || pixels[i + 2] < 240) {
        ink++;
      }
    }
    return _PdfLayoutSnapshot(
      pageCount: pages.length,
      lastPageFillPct: (ink * 100.0) / total,
    );
  } catch (e) {
    if (kDebugMode) {
      debugPrint('Typst orphan check failed: $e');
    }
    return null;
  } finally {
    try {
      await doc?.dispose();
    } catch (_) {
      // ignore — best effort cleanup
    }
  }
}

/// Builds the layout suffix appended to the tool result string. Always
/// includes page count + fill %; flags orphan pages so the AI can
/// decide whether to retry with a tighter layout.
String _layoutGuidance(_PdfLayoutSnapshot? layout) {
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
