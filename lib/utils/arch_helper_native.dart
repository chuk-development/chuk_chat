// lib/utils/arch_helper_native.dart
// Native implementation — uses dart:ffi Abi for architecture detection.

import 'dart:ffi' show Abi;

/// Returns the CPU architecture string for the current platform.
///
/// Android: 'arm64' | 'arm' | 'x64' | 'ia32' | 'riscv64'
/// Linux:   'x64'   | 'arm64' | 'ia32' | 'riscv64'
/// Windows: 'x64'   | 'arm64' | 'ia32'
/// macOS:   'x64'   | 'arm64'
String getCurrentArch() {
  final abi = Abi.current();

  // Android
  if (abi == Abi.androidArm64) return 'arm64';
  if (abi == Abi.androidArm) return 'arm';
  if (abi == Abi.androidX64) return 'x64';
  if (abi == Abi.androidIA32) return 'ia32';
  if (abi == Abi.androidRiscv64) return 'riscv64';

  // Linux
  if (abi == Abi.linuxX64) return 'x64';
  if (abi == Abi.linuxArm64) return 'arm64';
  if (abi == Abi.linuxIA32) return 'ia32';
  if (abi == Abi.linuxRiscv64) return 'riscv64';

  // Windows
  if (abi == Abi.windowsX64) return 'x64';
  if (abi == Abi.windowsArm64) return 'arm64';
  if (abi == Abi.windowsIA32) return 'ia32';

  // macOS
  if (abi == Abi.macosX64) return 'x64';
  if (abi == Abi.macosArm64) return 'arm64';

  // iOS
  if (abi == Abi.iosX64) return 'x64';
  if (abi == Abi.iosArm64) return 'arm64';

  return 'unknown';
}
