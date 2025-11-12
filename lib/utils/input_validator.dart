/// Input validation and sanitization utilities for security.
///
/// This utility provides validation and sanitization functions to prevent
/// injection attacks, XSS, and DoS via malformed inputs.
class InputValidator {
  InputValidator._();

  /// Maximum message length (20 million characters).
  /// This is well above the maximum context window of any current LLM (10M).
  static const int maxMessageLength = 20000000;

  /// Maximum email length (reasonable limit for email addresses).
  static const int maxEmailLength = 320; // RFC 5321 standard

  /// Maximum file name length (reasonable limit for file names).
  static const int maxFileNameLength = 255;

  /// RFC 5322 compliant email validation regex (simplified).
  /// Validates: local-part@domain with proper character restrictions.
  static final RegExp _emailRegex = RegExp(
    r"^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$",
  );

  /// Validates email address format and length.
  ///
  /// Returns null if valid, otherwise returns an error message.
  static String? validateEmail(String? email) {
    if (email == null || email.trim().isEmpty) {
      return 'Email address is required.';
    }

    final trimmedEmail = email.trim();

    if (trimmedEmail.length > maxEmailLength) {
      return 'Email address is too long.';
    }

    if (!_emailRegex.hasMatch(trimmedEmail)) {
      return 'Please enter a valid email address.';
    }

    return null;
  }

  /// Validates message length.
  ///
  /// Returns null if valid, otherwise returns an error message.
  static String? validateMessageLength(String message) {
    if (message.length > maxMessageLength) {
      return 'Message is too long. Maximum length is ${_formatNumber(maxMessageLength)} characters.';
    }
    return null;
  }

  /// Sanitizes a file name by removing or escaping potentially dangerous characters.
  ///
  /// This prevents path traversal attacks and injection attacks via file names.
  /// Replaces dangerous characters with underscores and limits length.
  static String sanitizeFileName(String fileName) {
    if (fileName.isEmpty) {
      return 'unnamed_file';
    }

    // Remove path separators and null bytes
    String sanitized = fileName
        .replaceAll('/', '_')
        .replaceAll('\\', '_')
        .replaceAll('\x00', '_')
        .replaceAll('..', '_');

    // Remove control characters (ASCII 0-31 and 127)
    sanitized = sanitized.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '_');

    // Trim whitespace
    sanitized = sanitized.trim();

    // Limit length
    if (sanitized.length > maxFileNameLength) {
      final extension = _getFileExtension(sanitized);
      final nameWithoutExt = sanitized.substring(
        0,
        sanitized.length - extension.length,
      );
      sanitized = nameWithoutExt.substring(0, maxFileNameLength - extension.length) + extension;
    }

    // Ensure we have a valid file name
    if (sanitized.isEmpty) {
      return 'unnamed_file';
    }

    return sanitized;
  }

  /// Escapes special characters in file name for safe display in messages.
  ///
  /// This prevents markdown injection and other formatting issues.
  static String escapeFileNameForDisplay(String fileName) {
    // Escape markdown special characters
    return fileName
        .replaceAll('\\', '\\\\')
        .replaceAll('`', '\\`')
        .replaceAll('*', '\\*')
        .replaceAll('_', '\\_')
        .replaceAll('[', '\\[')
        .replaceAll(']', '\\]')
        .replaceAll('(', '\\(')
        .replaceAll(')', '\\)')
        .replaceAll('#', '\\#')
        .replaceAll('+', '\\+')
        .replaceAll('-', '\\-')
        .replaceAll('.', '\\.')
        .replaceAll('!', '\\!')
        .replaceAll('|', '\\|');
  }

  /// Validates and sanitizes user message input before sending to API.
  ///
  /// Returns a map with 'valid' (bool), 'sanitized' (String), and optional 'error' (String).
  static Map<String, dynamic> validateAndSanitizeMessage(String message) {
    final trimmed = message.trim();

    // Check length
    final lengthError = validateMessageLength(trimmed);
    if (lengthError != null) {
      return {
        'valid': false,
        'error': lengthError,
        'sanitized': '',
      };
    }

    // Message is valid, return sanitized version
    // For now, we just trim and validate length.
    // Additional sanitization can be added here if needed.
    return {
      'valid': true,
      'sanitized': trimmed,
      'error': null,
    };
  }

  /// Gets the file extension from a file name (including the dot).
  static String _getFileExtension(String fileName) {
    final lastDot = fileName.lastIndexOf('.');
    if (lastDot == -1 || lastDot == fileName.length - 1) {
      return '';
    }
    return fileName.substring(lastDot);
  }

  /// Formats a large number with commas for readability.
  static String _formatNumber(int number) {
    return number.toString().replaceAllMapped(
          RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
          (Match m) => '${m[1]},',
        );
  }
}
