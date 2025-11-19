
import 'package:chuk_chat/utils/highlight_registry.dart';
import 'package:flutter/foundation.dart';

void main() {
  print('Verifying languages...');
  try {
    final keys = allLanguages.keys.toList();
    print('Found ${keys.length} languages.');
    for (final key in keys) {
      if (allLanguages[key] == null) {
        print('Language $key is null!');
      }
    }
    print('Verification complete.');
  } catch (e) {
    print('Error verifying languages: $e');
  }
}

