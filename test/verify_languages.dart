
import 'package:chuk_chat/utils/highlight_registry.dart';
import 'package:flutter/foundation.dart';

void main() {
  debugPrint('Verifying languages...');
  try {
    final keys = allLanguages.keys.toList();
    debugPrint('Found ${keys.length} languages.');
    for (final key in keys) {
      if (allLanguages[key] == null) {
        debugPrint('Language $key is null!');
      }
    }
    debugPrint('Verification complete.');
  } catch (e) {
    debugPrint('Error verifying languages: $e');
  }
}

