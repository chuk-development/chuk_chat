// lib/utils/shift_key_tracker_web.dart
// Web platform: track shift key via raw DOM listener.
// Works with Firefox/LibreWolf's privacy.resistFingerprinting which can
// break Flutter's HardwareKeyboard shift detection by spoofing event.code.
// The DOM event.shiftKey property is never spoofed by resistFingerprinting.
import 'dart:js_interop';
import 'package:web/web.dart' as web;

bool _shiftDown = false;
bool _initialized = false;

void initShiftKeyTracker() {
  if (_initialized) return;
  _initialized = true;

  web.window.addEventListener(
    'keydown',
    ((web.KeyboardEvent e) {
      _shiftDown = e.shiftKey;
    }).toJS,
  );
  web.window.addEventListener(
    'keyup',
    ((web.KeyboardEvent e) {
      _shiftDown = e.shiftKey;
    }).toJS,
  );
  // Also clear on window blur (user may release shift while window unfocused)
  web.window.addEventListener(
    'blur',
    ((web.Event e) {
      _shiftDown = false;
    }).toJS,
  );
}

bool get isShiftKeyPressed => _shiftDown;
