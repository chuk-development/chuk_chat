// lib/utils/certificate_pinning_register_io.dart
//
// Native (dart:io) platform — registers the real certificate pinning
// configurator that sets badCertificateCallback on Dio's HttpClient.

import 'package:chuk_chat/utils/certificate_pinning.dart';
import 'package:chuk_chat/utils/certificate_pinning_io.dart' as pinning_io;

/// Register the native certificate pinning configurator.
/// Must be called once during app startup, before any Dio requests.
void registerCertificatePinning() {
  CertificatePinning.registerNativeConfigurator(
    pinning_io.configureDioWithPinning,
  );
}
