/// Native: paint the coworker's picture straight from the file the profile
/// store copied into the app's support directory.
library;

import 'dart:io';

import 'package:flutter/widgets.dart';

ImageProvider<Object>? faceImageProvider(String? path) {
  if (path == null || path.isEmpty) return null;
  final File file = File(path);
  if (!file.existsSync()) return null;
  return FileImage(file);
}
