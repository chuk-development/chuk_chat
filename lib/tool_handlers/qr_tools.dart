import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

/// Generate a QR code locally using pretty_qr_code — no network call, fully
/// private. The data never leaves the device.
Future<String> executeGenerateQr(Map<String, dynamic> args) async {
  final data = (args['data']?.toString() ?? '').trim();
  if (data.isEmpty) {
    return 'Error: "data" parameter required';
  }

  final sizeArg = args['size'];
  final requestedSize = sizeArg is num
      ? sizeArg.toInt()
      : int.tryParse(sizeArg?.toString() ?? '') ?? 400;
  final size = requestedSize.clamp(100, 1000);

  try {
    final qrCode = QrCode.fromData(
      data: data,
      errorCorrectLevel: QrErrorCorrectLevel.H,
    );
    final qrImage = QrImage(qrCode);

    final imageBytes = await qrImage.toImageAsBytes(
      size: size,
      format: ui.ImageByteFormat.png,
      decoration: const PrettyQrDecoration(
        background: ui.Color(0xFFFFFFFF),
        quietZone: PrettyQrQuietZone.standard,
        shape: PrettyQrSquaresSymbol(color: ui.Color(0xFF000000), rounding: 0),
      ),
    );

    if (imageBytes == null) {
      return 'Error: failed to render QR code image';
    }

    final bytes = imageBytes.buffer.asUint8List();
    if (bytes.isEmpty) {
      return 'Error: QR code image is empty';
    }

    final result = {
      'data_uri': 'data:image/png;base64,${base64Encode(bytes)}',
      'mime_type': 'image/png',
      'size_bytes': bytes.length,
    };

    return 'IMAGE_DATA:${jsonEncode(result)}';
  } catch (error) {
    if (kDebugMode) {
      debugPrint('QR generation error: $error');
    }
    return 'Error generating QR code: $error';
  }
}
