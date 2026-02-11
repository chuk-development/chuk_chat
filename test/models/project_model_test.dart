import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/models/project_model.dart';

void main() {
  final testDate = DateTime(2025, 6, 15, 10, 30);
  final testFile = ProjectFile(
    id: 'file-1',
    projectId: 'proj-1',
    fileName: 'readme.md',
    storagePath: 'user/proj/readme.md',
    fileType: 'md',
    fileSize: 2048,
    uploadedAt: testDate,
    markdownSummary: '# Summary',
  );

  group('Project constructor', () {
    test('required fields', () {
      final project = Project(
        id: 'proj-1',
        name: 'My Project',
        createdAt: testDate,
        updatedAt: testDate,
      );
      expect(project.id, equals('proj-1'));
      expect(project.name, equals('My Project'));
      expect(project.description, isNull);
      expect(project.customSystemPrompt, isNull);
      expect(project.isArchived, isFalse);
      expect(project.chatIds, isEmpty);
      expect(project.files, isEmpty);
    });

    test('all fields', () {
      final project = Project(
        id: 'proj-2',
        name: 'Full Project',
        description: 'A test project',
        customSystemPrompt: 'You are a code reviewer',
        createdAt: testDate,
        updatedAt: testDate,
        isArchived: true,
        chatIds: ['chat-1', 'chat-2'],
        files: [testFile],
      );
      expect(project.description, equals('A test project'));
      expect(project.customSystemPrompt, equals('You are a code reviewer'));
      expect(project.isArchived, isTrue);
      expect(project.chatIds, hasLength(2));
      expect(project.files, hasLength(1));
    });
  });

  group('Project computed properties', () {
    test('chatCount', () {
      final project = Project(
        id: 'p',
        name: 'P',
        createdAt: testDate,
        updatedAt: testDate,
        chatIds: ['a', 'b', 'c'],
      );
      expect(project.chatCount, equals(3));
    });

    test('fileCount', () {
      final project = Project(
        id: 'p',
        name: 'P',
        createdAt: testDate,
        updatedAt: testDate,
        files: [testFile],
      );
      expect(project.fileCount, equals(1));
    });

    test('hasCustomPrompt true', () {
      final project = Project(
        id: 'p',
        name: 'P',
        createdAt: testDate,
        updatedAt: testDate,
        customSystemPrompt: 'Be helpful',
      );
      expect(project.hasCustomPrompt, isTrue);
    });

    test('hasCustomPrompt false when null', () {
      final project = Project(
        id: 'p',
        name: 'P',
        createdAt: testDate,
        updatedAt: testDate,
      );
      expect(project.hasCustomPrompt, isFalse);
    });

    test('hasCustomPrompt false when empty/whitespace', () {
      final project = Project(
        id: 'p',
        name: 'P',
        createdAt: testDate,
        updatedAt: testDate,
        customSystemPrompt: '   ',
      );
      expect(project.hasCustomPrompt, isFalse);
    });

    test('totalFileSize', () {
      final file2 = ProjectFile(
        id: 'f2',
        projectId: 'p',
        fileName: 'data.csv',
        storagePath: 'path',
        fileType: 'csv',
        fileSize: 4096,
        uploadedAt: testDate,
      );
      final project = Project(
        id: 'p',
        name: 'P',
        createdAt: testDate,
        updatedAt: testDate,
        files: [testFile, file2], // 2048 + 4096 = 6144
      );
      expect(project.totalFileSize, equals(6144));
    });

    test('totalFileSize empty', () {
      final project = Project(
        id: 'p',
        name: 'P',
        createdAt: testDate,
        updatedAt: testDate,
      );
      expect(project.totalFileSize, equals(0));
    });

    test('totalFileSizeFormatted', () {
      final project = Project(
        id: 'p',
        name: 'P',
        createdAt: testDate,
        updatedAt: testDate,
        files: [testFile], // 2048 bytes = 2.0 KB
      );
      expect(project.totalFileSizeFormatted, equals('2.0 KB'));
    });
  });

  group('Project fromJson', () {
    test('basic fields', () {
      final project = Project.fromJson({
        'id': 'p1',
        'name': 'Test',
        'created_at': '2025-06-15T10:30:00.000',
        'updated_at': '2025-06-15T10:30:00.000',
      });
      expect(project.id, equals('p1'));
      expect(project.name, equals('Test'));
      expect(project.isArchived, isFalse);
    });

    test('with nested files', () {
      final project = Project.fromJson({
        'id': 'p1',
        'name': 'Test',
        'created_at': '2025-06-15T10:30:00.000',
        'updated_at': '2025-06-15T10:30:00.000',
        'files': [
          {
            'id': 'f1',
            'project_id': 'p1',
            'file_name': 'test.txt',
            'storage_path': 'path/test.txt',
            'file_type': 'txt',
            'file_size': 100,
            'uploaded_at': '2025-06-15T10:30:00.000',
          },
        ],
      });
      expect(project.files, hasLength(1));
      expect(project.files.first.fileName, equals('test.txt'));
    });

    test('with chatIds', () {
      final project = Project.fromJson({
        'id': 'p1',
        'name': 'Test',
        'created_at': '2025-06-15T10:30:00.000',
        'updated_at': '2025-06-15T10:30:00.000',
        'chatIds': ['c1', 'c2'],
      });
      expect(project.chatIds, equals(['c1', 'c2']));
    });
  });

  group('Project toJson', () {
    test('includes required fields', () {
      final project = Project(
        id: 'p1',
        name: 'Test',
        createdAt: testDate,
        updatedAt: testDate,
      );
      final json = project.toJson();
      expect(json['id'], equals('p1'));
      expect(json['name'], equals('Test'));
      expect(json['created_at'], isNotNull);
      expect(json['updated_at'], isNotNull);
      expect(json['is_archived'], isFalse);
    });

    test('omits null optional fields', () {
      final project = Project(
        id: 'p1',
        name: 'Test',
        createdAt: testDate,
        updatedAt: testDate,
      );
      final json = project.toJson();
      expect(json.containsKey('description'), isFalse);
      expect(json.containsKey('custom_system_prompt'), isFalse);
    });

    test('includes non-null optional fields', () {
      final project = Project(
        id: 'p1',
        name: 'Test',
        description: 'Desc',
        customSystemPrompt: 'Prompt',
        createdAt: testDate,
        updatedAt: testDate,
      );
      final json = project.toJson();
      expect(json['description'], equals('Desc'));
      expect(json['custom_system_prompt'], equals('Prompt'));
    });
  });

  group('Project fromJson/toJson roundtrip', () {
    test('preserves all data', () {
      final original = Project(
        id: 'roundtrip',
        name: 'Round Trip',
        description: 'Testing roundtrip',
        customSystemPrompt: 'Be helpful',
        createdAt: testDate,
        updatedAt: testDate,
        isArchived: true,
        chatIds: ['c1'],
        files: [testFile],
      );
      final restored = Project.fromJson(original.toJson());
      expect(restored.id, equals(original.id));
      expect(restored.name, equals(original.name));
      expect(restored.description, equals(original.description));
      expect(restored.customSystemPrompt, equals(original.customSystemPrompt));
      expect(restored.isArchived, equals(original.isArchived));
      expect(restored.chatIds, equals(original.chatIds));
      expect(restored.files, hasLength(1));
    });
  });

  group('Project copyWith', () {
    test('changes specific fields', () {
      final original = Project(
        id: 'p1',
        name: 'Original',
        createdAt: testDate,
        updatedAt: testDate,
        isArchived: false,
      );
      final copy = original.copyWith(name: 'Updated', isArchived: true);
      expect(copy.id, equals('p1'));
      expect(copy.name, equals('Updated'));
      expect(copy.isArchived, isTrue);
    });
  });

  group('ProjectFile', () {
    test('constructor', () {
      expect(testFile.id, equals('file-1'));
      expect(testFile.projectId, equals('proj-1'));
      expect(testFile.fileName, equals('readme.md'));
      expect(testFile.storagePath, equals('user/proj/readme.md'));
      expect(testFile.fileType, equals('md'));
      expect(testFile.fileSize, equals(2048));
      expect(testFile.markdownSummary, equals('# Summary'));
    });

    test('hasMarkdownSummary true', () {
      expect(testFile.hasMarkdownSummary, isTrue);
    });

    test('hasMarkdownSummary false when null', () {
      final file = ProjectFile(
        id: 'f',
        projectId: 'p',
        fileName: 'test.txt',
        storagePath: 'path',
        fileType: 'txt',
        fileSize: 100,
        uploadedAt: testDate,
      );
      expect(file.hasMarkdownSummary, isFalse);
    });

    test('hasMarkdownSummary false when empty', () {
      final file = ProjectFile(
        id: 'f',
        projectId: 'p',
        fileName: 'test.txt',
        storagePath: 'path',
        fileType: 'txt',
        fileSize: 100,
        uploadedAt: testDate,
        markdownSummary: '   ',
      );
      expect(file.hasMarkdownSummary, isFalse);
    });

    test('extension', () {
      expect(testFile.extension, equals('md'));
    });

    test('isPdf', () {
      final pdf = ProjectFile(
        id: 'f',
        projectId: 'p',
        fileName: 'doc.pdf',
        storagePath: 'path',
        fileType: 'pdf',
        fileSize: 100,
        uploadedAt: testDate,
      );
      expect(pdf.isPdf, isTrue);
      expect(testFile.isPdf, isFalse);
    });

    test('fileSizeFormatted bytes', () {
      final file = ProjectFile(
        id: 'f',
        projectId: 'p',
        fileName: 'tiny.txt',
        storagePath: 'path',
        fileType: 'txt',
        fileSize: 500,
        uploadedAt: testDate,
      );
      expect(file.fileSizeFormatted, equals('500 B'));
    });

    test('fileSizeFormatted KB', () {
      expect(testFile.fileSizeFormatted, equals('2.0 KB'));
    });

    test('fileSizeFormatted MB', () {
      final file = ProjectFile(
        id: 'f',
        projectId: 'p',
        fileName: 'big.zip',
        storagePath: 'path',
        fileType: 'zip',
        fileSize: 5 * 1024 * 1024,
        uploadedAt: testDate,
      );
      expect(file.fileSizeFormatted, equals('5.0 MB'));
    });
  });

  group('ProjectFile fromJson/toJson', () {
    test('roundtrip', () {
      final json = testFile.toJson();
      final restored = ProjectFile.fromJson(json);
      expect(restored.id, equals(testFile.id));
      expect(restored.projectId, equals(testFile.projectId));
      expect(restored.fileName, equals(testFile.fileName));
      expect(restored.storagePath, equals(testFile.storagePath));
      expect(restored.fileType, equals(testFile.fileType));
      expect(restored.fileSize, equals(testFile.fileSize));
      expect(restored.markdownSummary, equals(testFile.markdownSummary));
    });

    test('toJson omits null markdown_summary', () {
      final file = ProjectFile(
        id: 'f',
        projectId: 'p',
        fileName: 'test.txt',
        storagePath: 'path',
        fileType: 'txt',
        fileSize: 100,
        uploadedAt: testDate,
      );
      final json = file.toJson();
      expect(json.containsKey('markdown_summary'), isFalse);
    });
  });

  group('ProjectFile copyWith', () {
    test('changes specific fields', () {
      final copy = testFile.copyWith(
        fileName: 'updated.md',
        fileSize: 4096,
      );
      expect(copy.fileName, equals('updated.md'));
      expect(copy.fileSize, equals(4096));
      expect(copy.id, equals(testFile.id));
      expect(copy.projectId, equals(testFile.projectId));
    });
  });
}
