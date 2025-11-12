// lib/constants/file_constants.dart

/// Shared constants for file handling across the application.
/// This prevents duplication and ensures consistent file extension
/// support across mobile and desktop platforms.
class FileConstants {
  FileConstants._();

  /// Maximum file size allowed for uploads (10MB)
  static const int maxFileSizeBytes = 10 * 1024 * 1024;

  /// Maximum number of concurrent file uploads
  static const int maxConcurrentUploads = 5;

  /// List of allowed file extensions for uploads.
  /// This includes various document types, media files, code files, and more.
  static const List<String> allowedExtensions = [
    // Audio (with transcription)
    'wav',
    'mp3',
    'm4a',
    'aac',
    'flac',
    'ogg',
    // Video
    'mp4',
    // Documents (PDF, Word, PowerPoint, Excel, OpenDocument)
    'pdf',
    'doc',
    'docx',
    'ppt',
    'pptx',
    'xls',
    'xlsx',
    'odt',
    'ods',
    'odp',
    'odg',
    'odf',
    // Text (CSV, JSON, XML, HTML, Markdown)
    'csv',
    'json',
    'jsonl',
    'xml',
    'html',
    'htm',
    'md',
    'markdown',
    'txt',
    'text',
    // Images (PNG, JPEG, GIF, BMP, TIFF, WebP with EXIF and OCR)
    'png',
    'jpg',
    'jpeg',
    'gif',
    'bmp',
    'tiff',
    'tif',
    'webp',
    'heic',
    'heif',
    // Archives (ZIP)
    'zip',
    // E-books (EPUB)
    'epub',
    // Email (MSG, EML)
    'msg',
    'eml',
    // Code and other formats
    'py',
    'js',
    'ts',
    'jsx',
    'tsx',
    'java',
    'c',
    'cpp',
    'h',
    'hpp',
    'go',
    'rs',
    'rb',
    'php',
    'swift',
    'kt',
    'cs',
    'sh',
    'bash',
    'yaml',
    'yml',
    'toml',
    'ini',
    'cfg',
    'conf',
    'sql',
    'prisma',
    'graphql',
    'proto',
    'css',
    'scss',
    'sass',
    'less',
    'vue',
    'svelte',
    'ipynb',
    'rss',
    'atom',
  ];

  /// Set of image file extensions for quick lookup
  static const Set<String> imageExtensions = <String>{
    'jpg',
    'jpeg',
    'png',
    'gif',
    'bmp',
    'tiff',
    'tif',
    'webp',
    'heic',
    'heif',
  };

  /// Set of audio file extensions for quick lookup
  static const Set<String> audioExtensions = <String>{
    'wav',
    'mp3',
    'm4a',
    'aac',
    'flac',
    'ogg',
  };
}
