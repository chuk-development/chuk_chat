/// The kind of a file, read from its name and its mime type, and how the app
/// draws it: one glyph from the app's icon set and one colour per kind
/// (docs/DESIGN.md §5).
///
/// A list where every file wears the same grey sheet tells the reader
/// nothing. The kind is what the reader looks for, so a PDF is red, a sheet
/// is green, a document is blue, and so on. The colour is a fixed hue at a
/// fixed lightness for each theme, so the glyph always has contrast on its
/// tile. There is no glow and no gradient: a flat tonal tile and a flat glyph.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/huge_icon.dart';

enum FileKind {
  pdf,
  sheet,
  document,
  text,
  slides,
  code,
  data,
  shell,
  database,
  archive,
  image,
  video,
  audio,
  book,
  web,
  other;

  /// The kind of the file [name] with the mime type [mime]. The extension
  /// wins: a sandbox often writes `report.xlsx` with a generic
  /// octet-stream type. The mime type decides when the name says nothing.
  static FileKind of(String name, {String mime = ''}) {
    final String lower = name.toLowerCase();
    final int dot = lower.lastIndexOf('.');
    final String ext = dot >= 0 ? lower.substring(dot + 1) : '';
    final FileKind? known = _byExtension[ext];
    if (known != null) return known;
    final String m = mime.toLowerCase().split(';').first.trim();
    if (m.isEmpty) return FileKind.other;
    if (m.startsWith('image/')) return FileKind.image;
    if (m.startsWith('video/')) return FileKind.video;
    if (m.startsWith('audio/')) return FileKind.audio;
    if (m == 'application/pdf') return FileKind.pdf;
    if (m == 'text/markdown' || m == 'text/x-markdown') return FileKind.text;
    if (m == 'text/csv' || m.contains('spreadsheet') || m.contains('excel')) {
      return FileKind.sheet;
    }
    if (m.contains('presentation') || m.contains('powerpoint')) {
      return FileKind.slides;
    }
    if (m.contains('wordprocessing') || m.contains('msword')) {
      return FileKind.document;
    }
    if (m == 'application/json') return FileKind.data;
    if (m == 'text/html') return FileKind.web;
    if (m == 'application/xml') return FileKind.code;
    if (m.contains('zip') || m.contains('tar') || m.contains('compressed')) {
      return FileKind.archive;
    }
    if (m.startsWith('text/')) return FileKind.text;
    return FileKind.other;
  }

  static const Map<String, FileKind> _byExtension = <String, FileKind>{
    'pdf': FileKind.pdf,
    'csv': FileKind.sheet,
    'tsv': FileKind.sheet,
    'xls': FileKind.sheet,
    'xlsx': FileKind.sheet,
    'ods': FileKind.sheet,
    'numbers': FileKind.sheet,
    'doc': FileKind.document,
    'docx': FileKind.document,
    'odt': FileKind.document,
    'rtf': FileKind.document,
    'pages': FileKind.document,
    'md': FileKind.text,
    'markdown': FileKind.text,
    'rst': FileKind.text,
    'txt': FileKind.text,
    'log': FileKind.text,
    'ppt': FileKind.slides,
    'pptx': FileKind.slides,
    'odp': FileKind.slides,
    'key': FileKind.slides,
    'json': FileKind.data,
    'yaml': FileKind.data,
    'yml': FileKind.data,
    'toml': FileKind.data,
    'xml': FileKind.code,
    'css': FileKind.code,
    'js': FileKind.code,
    'ts': FileKind.code,
    'dart': FileKind.code,
    'py': FileKind.code,
    'rs': FileKind.code,
    'go': FileKind.code,
    'c': FileKind.code,
    'cpp': FileKind.code,
    'h': FileKind.code,
    'java': FileKind.code,
    'kt': FileKind.code,
    'swift': FileKind.code,
    'rb': FileKind.code,
    'php': FileKind.code,
    'html': FileKind.web,
    'htm': FileKind.web,
    'sh': FileKind.shell,
    'bash': FileKind.shell,
    'zsh': FileKind.shell,
    'fish': FileKind.shell,
    'sql': FileKind.database,
    'db': FileKind.database,
    'sqlite': FileKind.database,
    'zip': FileKind.archive,
    'tar': FileKind.archive,
    'gz': FileKind.archive,
    'tgz': FileKind.archive,
    'rar': FileKind.archive,
    '7z': FileKind.archive,
    'png': FileKind.image,
    'jpg': FileKind.image,
    'jpeg': FileKind.image,
    'gif': FileKind.image,
    'webp': FileKind.image,
    'bmp': FileKind.image,
    'heic': FileKind.image,
    'svg': FileKind.image,
    'mp4': FileKind.video,
    'mov': FileKind.video,
    'webm': FileKind.video,
    'mkv': FileKind.video,
    'avi': FileKind.video,
    'mp3': FileKind.audio,
    'wav': FileKind.audio,
    'ogg': FileKind.audio,
    'm4a': FileKind.audio,
    'flac': FileKind.audio,
    'opus': FileKind.audio,
    'epub': FileKind.book,
  };

  /// The glyph, from the app's icon set.
  HugeIconData get glyph => switch (this) {
    FileKind.pdf => HugeIcons.pdf01,
    FileKind.sheet => HugeIcons.sheet,
    FileKind.document => HugeIcons.fileText,
    FileKind.text => HugeIcons.text,
    FileKind.slides => HugeIcons.presentation01,
    FileKind.code => HugeIcons.sourceCode,
    FileKind.data => HugeIcons.braces,
    FileKind.shell => HugeIcons.terminal,
    FileKind.database => HugeIcons.database01,
    FileKind.archive => HugeIcons.zip01,
    FileKind.image => HugeIcons.image01,
    FileKind.video => HugeIcons.video01,
    FileKind.audio => HugeIcons.musicNote01,
    FileKind.book => HugeIcons.bookOpen01,
    FileKind.web => HugeIcons.globe02,
    FileKind.other => HugeIcons.file01,
  };

  /// The hue of the kind, in degrees. Null: no hue (a neutral tile).
  double? get _hue => switch (this) {
    FileKind.pdf => 4,
    FileKind.sheet => 142,
    FileKind.document => 214,
    FileKind.text => 200,
    FileKind.slides => 26,
    FileKind.code => 268,
    FileKind.data => 174,
    FileKind.shell => 90,
    FileKind.database => 238,
    FileKind.archive => 40,
    FileKind.image => 330,
    FileKind.video => 290,
    FileKind.audio => 188,
    FileKind.book => 18,
    FileKind.web => 222,
    FileKind.other => null,
  };

  /// The glyph colour on a tile of [tileColor] in [scheme].
  Color glyphColor(ColorScheme scheme) {
    final double? hue = _hue;
    if (hue == null) return scheme.onSurfaceVariant;
    final bool dark = scheme.brightness == Brightness.dark;
    return HSLColor.fromAHSL(1, hue, 0.62, dark ? 0.72 : 0.40).toColor();
  }

  /// The tile colour behind the glyph: the kind's hue, quiet, over the
  /// surface. A neutral kind takes the plain container colour.
  Color tileColor(ColorScheme scheme) {
    final double? hue = _hue;
    if (hue == null) return scheme.surfaceContainerHighest;
    final bool dark = scheme.brightness == Brightness.dark;
    return HSLColor.fromAHSL(
      1,
      hue,
      dark ? 0.32 : 0.70,
      dark ? 0.22 : 0.92,
    ).toColor();
  }
}

/// A square tile with the kind's glyph in the kind's colour. [size] is the
/// tile; the glyph is 46 % of it, the corner 34 % (the corner of the icon
/// targets in the chrome).
class FileKindTile extends StatelessWidget {
  const FileKindTile({super.key, required this.kind, this.size = 48});

  final FileKind kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: kind.tileColor(scheme),
        borderRadius: BorderRadius.circular(size * 0.34),
      ),
      child: HugeIcon(
        kind.glyph,
        size: size * 0.46,
        color: kind.glyphColor(scheme),
      ),
    );
  }
}
