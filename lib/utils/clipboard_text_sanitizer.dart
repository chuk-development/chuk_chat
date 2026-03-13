class ClipboardTextSanitizer {
  const ClipboardTextSanitizer._();

  static final RegExp _markdownImageDataUrlPattern = RegExp(
    r'!\[[^\]]*\]\(\s*data:image\\?/[a-zA-Z0-9.+-]+;base64,[^)]+\)',
    caseSensitive: false,
  );

  static final RegExp _imageDataUrlPattern = RegExp(
    r'''data:image\\?/[a-zA-Z0-9.+-]+;base64,[^"'\s)\]]+''',
    caseSensitive: false,
  );

  static bool containsImageData(String text) {
    if (text.isEmpty) {
      return false;
    }

    return _markdownImageDataUrlPattern.hasMatch(text) ||
        _imageDataUrlPattern.hasMatch(text);
  }

  static String sanitize(String text) {
    if (text.isEmpty) {
      return text;
    }

    var sanitized = text.replaceAllMapped(
      _markdownImageDataUrlPattern,
      (_) => '[image removed]',
    );

    sanitized = sanitized.replaceAllMapped(
      _imageDataUrlPattern,
      (_) => '[image removed]',
    );

    sanitized = sanitized.replaceAllMapped(
      RegExp(r'(?:\[image removed\]\s*){2,}', caseSensitive: false),
      (_) => '[image removed] ',
    );

    return sanitized;
  }
}
