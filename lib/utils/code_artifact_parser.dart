// lib/utils/code_artifact_parser.dart

import 'package:chuk_chat/models/code_artifact.dart';

class CodeArtifactExtraction {
  const CodeArtifactExtraction({
    required this.displayText,
    required this.blocks,
  });

  final String displayText;
  final List<CodeArtifactBlock> blocks;

  bool get hasArtifacts => blocks.isNotEmpty;
}

class CodeArtifactBlock {
  const CodeArtifactBlock({
    required this.blockIndex,
    required this.language,
    required this.code,
    required this.placeholderLabel,
  });

  final int blockIndex;
  final String language;
  final String code;
  final String placeholderLabel;

  CodeArtifact toArtifact(int messageIndex) {
    return CodeArtifact(
      messageIndex: messageIndex,
      blockIndex: blockIndex,
      language: language,
      code: code,
      placeholderLabel: placeholderLabel,
    );
  }
}

class CodeArtifactParser {
  static final RegExp _codeBlockRegex = RegExp(
    r'```([^\n`]*)\n([\s\S]*?)```',
    multiLine: true,
  );

  static CodeArtifactExtraction extract(String input) {
    if (input.isEmpty) {
      return const CodeArtifactExtraction(displayText: '', blocks: []);
    }

    final Iterable<RegExpMatch> matches = _codeBlockRegex.allMatches(input);
    if (matches.isEmpty) {
      return CodeArtifactExtraction(displayText: input, blocks: const []);
    }

    final StringBuffer buffer = StringBuffer();
    final List<CodeArtifactBlock> blocks = <CodeArtifactBlock>[];
    int lastIndex = 0;
    int blockCounter = 0;

    for (final RegExpMatch match in matches) {
      if (match.start > lastIndex) {
        buffer.write(input.substring(lastIndex, match.start));
      }

      final String language = (match.group(1) ?? '').trim();
      String code = match.group(2) ?? '';
      code = code.replaceAll('\r\n', '\n');

      if (code.startsWith('\n')) {
        code = code.substring(1);
      }
      code = _dedent(code).trimRight();

      final String placeholder = _buildPlaceholder(language, blockCounter);
      buffer.write('\n$placeholder\n');

      blocks.add(
        CodeArtifactBlock(
          blockIndex: blockCounter,
          language: language,
          code: code,
          placeholderLabel: placeholder,
        ),
      );

      lastIndex = match.end;
      blockCounter++;
    }

    if (lastIndex < input.length) {
      buffer.write(input.substring(lastIndex));
    }

    final String displayText = _normalizeDisplayText(buffer.toString());
    return CodeArtifactExtraction(displayText: displayText, blocks: blocks);
  }

  static String _buildPlaceholder(String language, int ordinal) {
    final String label = language.trim().isEmpty
        ? 'code'
        : language.trim().toLowerCase();
    return '[View $label artifact #${ordinal + 1}]';
  }

  static String _normalizeDisplayText(String value) {
    final String collapsed = value.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    final String trimmed = collapsed.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    return trimmed;
  }

  static String _dedent(String code) {
    final List<String> lines = code.split('\n');
    int minIndent = -1;

    for (final String line in lines) {
      if (line.trim().isEmpty) {
        continue;
      }
      final int indent = line.length - line.trimLeft().length;
      if (minIndent == -1 || indent < minIndent) {
        minIndent = indent;
      }
      if (minIndent == 0) {
        break;
      }
    }

    if (minIndent <= 0) {
      return code;
    }

    final int indentWidth = minIndent;
    final String dedented = lines
        .map(
          (line) => line.trim().isEmpty
              ? ''
              : line.length > indentWidth
              ? line.substring(indentWidth)
              : line.trimLeft(),
        )
        .join('\n');
    return dedented;
  }
}
