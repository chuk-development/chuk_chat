// lib/utils/host_lookup.dart
// Conditional export: DNS lookup on native, nothing on web (the browser
// resolves names itself and gives the page no access to the answer).
export 'host_lookup_stub.dart' if (dart.library.io) 'host_lookup_io.dart';
