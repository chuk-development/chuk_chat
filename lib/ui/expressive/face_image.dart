/// One image provider for a coworker's picture, chosen at compile time.
///
/// A picture lives as a file in the app's support directory, and only a build
/// with a file system can read it. Both variants answer the same question — "is
/// there a picture at this path, and how do I paint it" — so no caller needs a
/// platform check.
library;

export 'face_image_stub.dart' if (dart.library.io) 'face_image_io.dart';
