// lib/utils/shift_key_tracker_native.dart
// Native platforms: delegate to Flutter's HardwareKeyboard
import 'package:flutter/services.dart';

void initShiftKeyTracker() {
  // No-op on native — HardwareKeyboard works correctly
}

bool get isShiftKeyPressed => HardwareKeyboard.instance.isShiftPressed;
