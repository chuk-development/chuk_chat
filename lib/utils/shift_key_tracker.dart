// lib/utils/shift_key_tracker.dart
// Conditional export: web uses raw DOM listener (works with resistFingerprinting),
// native delegates to HardwareKeyboard.instance.
export 'shift_key_tracker_native.dart'
    if (dart.library.js_interop) 'shift_key_tracker_web.dart';
