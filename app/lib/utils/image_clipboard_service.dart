import 'dart:typed_data';

import 'package:chuk_chat/utils/io_helper.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pasteboard/pasteboard.dart';

class ImageClipboardService {
  const ImageClipboardService._();

  static Future<bool> copyImageBytes(Uint8List bytes) async {
    try {
      if (Platform.isLinux) {
        final tempDir = await getTemporaryDirectory();
        final file = File(
          '${tempDir.path}${Platform.pathSeparator}chuk_chat_clipboard_image.png',
        );
        try {
          await file.writeAsBytes(bytes, flush: true);
          final wroteFile = await Pasteboard.writeFiles([file.path]);
          if (wroteFile) {
            return true;
          }
        } finally {
          if (await file.exists()) {
            await file.delete();
          }
        }
      }

      await Pasteboard.writeImage(bytes);
      return true;
    } catch (_) {
      return false;
    }
  }
}
