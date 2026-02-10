// lib/constants/file_constants.dart

/// Shared constants for file handling across the application.
/// This prevents duplication and ensures consistent file extension
/// support across mobile and desktop platforms.
class FileConstants {
  FileConstants._();

  /// Maximum file size allowed for non-image uploads (10MB)
  /// Note: Images have no size limit - they are automatically compressed to WebP format
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

  /// Set of plain text file extensions that should be read directly
  /// without going through the convert-file API endpoint.
  /// These files are sent as-is to the LLM.
  static const Set<String> plainTextExtensions = <String>{
    // Text files
    'txt', 'text', 'md', 'markdown', 'log', 'readme',
    // Data files
    'json', 'jsonl', 'yaml', 'yml', 'csv', 'xml', 'toml', 'ini', 'cfg', 'conf',
    // Shell/scripts
    'sh', 'bash', 'zsh', 'fish', 'bat', 'cmd', 'ps1',
    // Programming languages
    'dart', 'js', 'ts', 'jsx', 'tsx', 'py', 'pyw',
    'java', 'kt', 'kts', 'scala', 'groovy',
    'cpp', 'c', 'h', 'hpp', 'cc', 'cxx',
    'cs', 'fs', 'vb',
    'rs', 'go', 'rb', 'php', 'swift', 'lua', 'r',
    'pl', 'pm', 'ex', 'exs', 'erl', 'hrl',
    'clj', 'cljs', 'cljc', 'hs', 'lhs',
    // Web
    'html', 'htm', 'css', 'scss', 'sass', 'less',
    'vue', 'svelte', 'astro',
    // Database/query
    'sql', 'graphql', 'gql', 'prisma', 'proto',
    // DevOps/config
    'dockerfile', 'containerfile', 'vagrantfile',
    'makefile', 'cmake', 'gradle',
    'env', 'gitignore', 'dockerignore', 'editorconfig',
    // Other
    'ipynb', 'rss', 'atom',
  };

  /// Set of file extensions that require the convert-file API
  /// (PDFs, Office docs, audio, etc.)
  static const Set<String> convertApiExtensions = <String>{
    // Documents that need conversion
    'pdf', 'doc', 'docx', 'ppt', 'pptx', 'xls', 'xlsx',
    'odt', 'ods', 'odp', 'odg', 'odf',
    // Audio (needs transcription)
    'wav', 'mp3', 'm4a', 'aac', 'flac', 'ogg',
    // E-books
    'epub',
    // Email
    'msg', 'eml',
  };

  /// Check if a file extension is a plain text file that can be read directly
  static bool isPlainText(String extension) {
    return plainTextExtensions.contains(extension.toLowerCase());
  }

  /// Check if a file extension requires the convert-file API
  static bool requiresConversion(String extension) {
    return convertApiExtensions.contains(extension.toLowerCase());
  }

  /// Check if a file extension is an image
  static bool isImage(String extension) {
    return imageExtensions.contains(extension.toLowerCase());
  }
}
