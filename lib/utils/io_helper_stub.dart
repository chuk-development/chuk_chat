// lib/utils/io_helper_stub.dart
// Web stub - provides no-op implementations for dart:io types

import 'dart:typed_data';

/// Stub File class for web
class File {
  final String path;
  File(this.path);
  Future<bool> exists() async => false;
  bool existsSync() => false;
  Future<int> length() async => 0;
  int lengthSync() => 0;
  Future<Uint8List> readAsBytes() async => Uint8List(0);
  Uint8List readAsBytesSync() => Uint8List(0);
  Future<String> readAsString() async => '';
  String readAsStringSync() => '';
  Future<File> writeAsBytes(List<int> bytes, {bool flush = false}) async => this;
  Future<File> writeAsString(String contents, {bool flush = false}) async => this;
  Future<void> delete({bool recursive = false}) async {}
  Stream<List<int>> openRead([int? start, int? end]) => Stream.empty();
}

/// Stub Directory class for web
class Directory {
  final String path;
  Directory(this.path);
  Future<bool> exists() async => false;
  bool existsSync() => false;
  Future<Directory> create({bool recursive = false}) async => this;
}

/// Stub Platform class for web
class Platform {
  static const bool isAndroid = false;
  static const bool isIOS = false;
  static const bool isMacOS = false;
  static const bool isWindows = false;
  static const bool isLinux = false;
  static const String pathSeparator = '/';
  static final Map<String, String> environment = {};
  static String get operatingSystem => 'web';
}

/// Stub SocketException for web
class SocketException implements Exception {
  final String message;
  const SocketException(this.message);
  @override
  String toString() => 'SocketException: $message';
}

/// Stub HttpException for web
class HttpException implements Exception {
  final String message;
  const HttpException(this.message);
  @override
  String toString() => 'HttpException: $message';
}
