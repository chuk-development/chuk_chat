// lib/utils/path_provider_stub.dart
// Web stub for package:path_provider
import 'package:chuk_chat/utils/io_helper.dart';

Future<Directory> getTemporaryDirectory() async => Directory('/tmp');
Future<Directory> getApplicationDocumentsDirectory() async => Directory('/tmp');
