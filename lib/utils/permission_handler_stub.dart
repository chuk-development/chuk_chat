// lib/utils/permission_handler_stub.dart
// Web stub for package:permission_handler

class Permission {
  static final Permission microphone = Permission._('microphone');

  final String _name;
  const Permission._(this._name);

  Future<PermissionStatus> request() async => PermissionStatus.denied;
  Future<PermissionStatus> get status async => PermissionStatus.denied;
}

enum PermissionStatus {
  granted,
  denied,
  permanentlyDenied,
  restricted,
  limited,
  provisional;

  bool get isGranted => this == PermissionStatus.granted;
  bool get isPermanentlyDenied => this == PermissionStatus.permanentlyDenied;
}
