import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

/// Creates shareable Excalidraw links by uploading encrypted scene payloads to
/// Excalidraw's public store backend.
class ExcalidrawShareService {
  const ExcalidrawShareService._();

  static final Uri _storePostUri = Uri.parse(
    'https://json.excalidraw.com/api/v2/post/',
  );

  static const String _editorBaseUrl = 'https://excalidraw.com/';
  static const int _aesKeyBytes = 16; // 128 bits
  static const int _ivBytes = 12;
  static const int _headerFieldBytes = 4;
  static const Map<String, dynamic> _encodingMetadata = {
    'version': 2,
    'compression': 'pako@1',
    'encryption': 'AES-GCM',
  };

  static final AesGcm _cipher = AesGcm.with128bits();

  static Uri get editorHomeUri => Uri.parse(_editorBaseUrl);

  static Future<Uri> createShareLink(
    String sceneJson, {
    http.Client? client,
  }) async {
    final keyBytes = _randomBytes(_aesKeyBytes);
    final key = _base64UrlNoPadding(keyBytes);
    final payload = await _buildPayload(
      sceneJson: sceneJson,
      keyBytes: keyBytes,
    );

    final ownClient = client ?? http.Client();
    final closeClient = client == null;
    try {
      final response = await ownClient
          .post(
            _storePostUri,
            headers: const {'content-type': 'application/octet-stream'},
            body: payload,
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('Excalidraw upload failed (${response.statusCode}).');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Unexpected Excalidraw upload response.');
      }
      final id = decoded['id'];
      if (id is! String || id.trim().isEmpty) {
        throw const FormatException('Missing Excalidraw share id.');
      }
      return Uri.parse('$_editorBaseUrl#json=$id,$key');
    } finally {
      if (closeClient) {
        ownClient.close();
      }
    }
  }

  static Future<Uint8List> _buildPayload({
    required String sceneJson,
    required Uint8List keyBytes,
  }) async {
    final encodingMetadataBytes = Uint8List.fromList(
      utf8.encode(jsonEncode(_encodingMetadata)),
    );
    final contentMetadataBytes = Uint8List.fromList(utf8.encode('null'));
    final sceneBytes = Uint8List.fromList(utf8.encode(sceneJson));

    final plaintext = _concatBuffers([contentMetadataBytes, sceneBytes]);
    final compressed = ZLibEncoder().encode(plaintext);

    final iv = _randomBytes(_ivBytes);
    final secretBox = await _cipher.encrypt(
      Uint8List.fromList(compressed),
      secretKey: SecretKey(keyBytes),
      nonce: iv,
    );
    final encrypted =
        Uint8List(secretBox.cipherText.length + secretBox.mac.bytes.length)
          ..setRange(0, secretBox.cipherText.length, secretBox.cipherText)
          ..setRange(
            secretBox.cipherText.length,
            secretBox.cipherText.length + secretBox.mac.bytes.length,
            secretBox.mac.bytes,
          );

    return _concatBuffers([encodingMetadataBytes, iv, encrypted]);
  }

  static Uint8List _concatBuffers(List<List<int>> chunks) {
    final totalLength =
        _headerFieldBytes +
        (_headerFieldBytes * chunks.length) +
        chunks.fold<int>(0, (sum, chunk) => sum + chunk.length);
    final out = Uint8List(totalLength);
    final data = ByteData.sublistView(out);
    var cursor = 0;

    data.setUint32(cursor, 1);
    cursor += _headerFieldBytes;

    for (final chunk in chunks) {
      data.setUint32(cursor, chunk.length);
      cursor += _headerFieldBytes;
      out.setRange(cursor, cursor + chunk.length, chunk);
      cursor += chunk.length;
    }
    return out;
  }

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  static String _base64UrlNoPadding(List<int> bytes) =>
      base64UrlEncode(bytes).replaceAll('=', '');
}
