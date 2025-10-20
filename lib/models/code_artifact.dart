// lib/models/code_artifact.dart

class CodeArtifact {
  const CodeArtifact({
    required this.messageIndex,
    required this.blockIndex,
    required this.language,
    required this.code,
    required this.placeholderLabel,
  });

  final int messageIndex;
  final int blockIndex;
  final String language;
  final String code;
  final String placeholderLabel;

  String get _normalizedLanguage {
    final String trimmed = language.trim();
    if (trimmed.isEmpty) {
      return 'code';
    }
    return trimmed.toLowerCase();
  }

  String get languageLabel {
    final String normalized = _normalizedLanguage;
    return normalized.isEmpty ? 'code' : normalized;
  }

  String get displayTitle {
    final String base = languageLabel.isEmpty ? 'Code' : languageLabel;
    return '${_capitalize(base)} artifact #${blockIndex + 1}';
  }

  String preview({int maxLines = 8}) {
    if (code.isEmpty) {
      return '';
    }
    final List<String> lines = code.split('\n');
    if (lines.length <= maxLines) {
      return code.trimRight();
    }
    return lines.take(maxLines).join('\n').trimRight();
  }

  CodeArtifact copyWith({
    int? messageIndex,
    int? blockIndex,
    String? language,
    String? code,
    String? placeholderLabel,
  }) {
    return CodeArtifact(
      messageIndex: messageIndex ?? this.messageIndex,
      blockIndex: blockIndex ?? this.blockIndex,
      language: language ?? this.language,
      code: code ?? this.code,
      placeholderLabel: placeholderLabel ?? this.placeholderLabel,
    );
  }

  static String _capitalize(String value) {
    if (value.isEmpty) {
      return value;
    }
    if (value.length == 1) {
      return value.toUpperCase();
    }
    return value[0].toUpperCase() + value.substring(1);
  }
}

class CodeArtifactRef {
  const CodeArtifactRef({required this.messageIndex, required this.blockIndex});

  final int messageIndex;
  final int blockIndex;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! CodeArtifactRef) return false;
    return messageIndex == other.messageIndex && blockIndex == other.blockIndex;
  }

  @override
  int get hashCode => Object.hash(messageIndex, blockIndex);
}
