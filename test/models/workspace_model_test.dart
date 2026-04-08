import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/models/workspace_model.dart';

void main() {
  final testDate = DateTime(2025, 6, 15, 10, 30);
  final testFile = WorkspaceFile(
    id: 'file-1',
    workspaceId: 'proj-1',
    fileName: 'readme.md',
    storagePath: 'user/proj/readme.md',
    fileType: 'md',
    fileSize: 2048,
    uploadedAt: testDate,
    markdownSummary: '# Summary',
  );

  group('Workspace constructor', () {
    test('required fields', () {
      final project = Workspace(
        id: 'proj-1',
        name: 'My Workspace',
        createdAt: testDate,
        updatedAt: testDate,
      );
      expect(project.id, equals('proj-1'));
      expect(project.name, equals('My Workspace'));
      expect(project.description, isNull);
      expect(project.customSystemPrompt, isNull);
      expect(project.isArchived, isFalse);
      expect(project.chatIds, isEmpty);
      expect(project.files, isEmpty);
    });

    test('all fields', () {
      final project = Workspace(
        id: 'proj-2',
        name: 'Full Workspace',
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

  group('Workspace computed properties', () {
    test('chatCount', () {
      final project = Workspace(
        id: 'p',
        name: 'P',
        createdAt: testDate,
        updatedAt: testDate,
        chatIds: ['a', 'b', 'c'],
      );
      expect(project.chatCount, equals(3));
    });

    test('fileCount', () {
      final project = Workspace(
        id: 'p',
        name: 'P',
        createdAt: testDate,
        updatedAt: testDate,
        files: [testFile],
      );
      expect(project.fileCount, equals(1));
    });

    test('hasCustomPrompt true', () {
      final project = Workspace(
        id: 'p',
        name: 'P',
        createdAt: testDate,
        updatedAt: testDate,
        customSystemPrompt: 'Be helpful',
      );
      expect(project.hasCustomPrompt, isTrue);
    });

    test('hasCustomPrompt false when null', () {
      final project = Workspace(
        id: 'p',
        name: 'P',
        createdAt: testDate,
        updatedAt: testDate,
      );
      expect(project.hasCustomPrompt, isFalse);
    });

    test('hasCustomPrompt false when empty/whitespace', () {
      final project = Workspace(
        id: 'p',
        name: 'P',
        createdAt: testDate,
        updatedAt: testDate,
        customSystemPrompt: '   ',
      );
      expect(project.hasCustomPrompt, isFalse);
    });

    test('totalFileSize', () {
      final file2 = WorkspaceFile(
        id: 'f2',
        workspaceId: 'p',
        fileName: 'data.csv',
        storagePath: 'path',
        fileType: 'csv',
        fileSize: 4096,
        uploadedAt: testDate,
      );
      final project = Workspace(
        id: 'p',
        name: 'P',
        createdAt: testDate,
        updatedAt: testDate,
        files: [testFile, file2], // 2048 + 4096 = 6144
      );
      expect(project.totalFileSize, equals(6144));
    });

    test('totalFileSize empty', () {
      final project = Workspace(
        id: 'p',
        name: 'P',
        createdAt: testDate,
        updatedAt: testDate,
      );
      expect(project.totalFileSize, equals(0));
    });

    test('totalFileSizeFormatted', () {
      final project = Workspace(
        id: 'p',
        name: 'P',
        createdAt: testDate,
        updatedAt: testDate,
        files: [testFile], // 2048 bytes = 2.0 KB
      );
      expect(project.totalFileSizeFormatted, equals('2.0 KB'));
    });
  });

  group('Workspace fromJson', () {
    test('basic fields', () {
      final project = Workspace.fromJson({
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
      final project = Workspace.fromJson({
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
      final project = Workspace.fromJson({
        'id': 'p1',
        'name': 'Test',
        'created_at': '2025-06-15T10:30:00.000',
        'updated_at': '2025-06-15T10:30:00.000',
        'chatIds': ['c1', 'c2'],
      });
      expect(project.chatIds, equals(['c1', 'c2']));
    });
  });

  group('Workspace toJson', () {
    test('includes required fields', () {
      final project = Workspace(
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
      final project = Workspace(
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
      final project = Workspace(
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

  group('Workspace fromJson/toJson roundtrip', () {
    test('preserves all data', () {
      final original = Workspace(
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
      final restored = Workspace.fromJson(original.toJson());
      expect(restored.id, equals(original.id));
      expect(restored.name, equals(original.name));
      expect(restored.description, equals(original.description));
      expect(restored.customSystemPrompt, equals(original.customSystemPrompt));
      expect(restored.isArchived, equals(original.isArchived));
      expect(restored.chatIds, equals(original.chatIds));
      expect(restored.files, hasLength(1));
    });
  });

  group('Workspace copyWith', () {
    test('changes specific fields', () {
      final original = Workspace(
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

  group('WorkspaceFile', () {
    test('constructor', () {
      expect(testFile.id, equals('file-1'));
      expect(testFile.workspaceId, equals('proj-1'));
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
      final file = WorkspaceFile(
        id: 'f',
        workspaceId: 'p',
        fileName: 'test.txt',
        storagePath: 'path',
        fileType: 'txt',
        fileSize: 100,
        uploadedAt: testDate,
      );
      expect(file.hasMarkdownSummary, isFalse);
    });

    test('hasMarkdownSummary false when empty', () {
      final file = WorkspaceFile(
        id: 'f',
        workspaceId: 'p',
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
      final pdf = WorkspaceFile(
        id: 'f',
        workspaceId: 'p',
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
      final file = WorkspaceFile(
        id: 'f',
        workspaceId: 'p',
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
      final file = WorkspaceFile(
        id: 'f',
        workspaceId: 'p',
        fileName: 'big.zip',
        storagePath: 'path',
        fileType: 'zip',
        fileSize: 5 * 1024 * 1024,
        uploadedAt: testDate,
      );
      expect(file.fileSizeFormatted, equals('5.0 MB'));
    });
  });

  group('WorkspaceFile fromJson/toJson', () {
    test('roundtrip', () {
      final json = testFile.toJson();
      final restored = WorkspaceFile.fromJson(json);
      expect(restored.id, equals(testFile.id));
      expect(restored.workspaceId, equals(testFile.workspaceId));
      expect(restored.fileName, equals(testFile.fileName));
      expect(restored.storagePath, equals(testFile.storagePath));
      expect(restored.fileType, equals(testFile.fileType));
      expect(restored.fileSize, equals(testFile.fileSize));
      expect(restored.markdownSummary, equals(testFile.markdownSummary));
    });

    test('toJson omits null markdown_summary', () {
      final file = WorkspaceFile(
        id: 'f',
        workspaceId: 'p',
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

  group('WorkspaceFile copyWith', () {
    test('changes specific fields', () {
      final copy = testFile.copyWith(fileName: 'updated.md', fileSize: 4096);
      expect(copy.fileName, equals('updated.md'));
      expect(copy.fileSize, equals(4096));
      expect(copy.id, equals(testFile.id));
      expect(copy.workspaceId, equals(testFile.workspaceId));
    });
  });

  group('WorkspaceFile estimatedTokens', () {
    test('text file uses fileSize-based estimate', () {
      final file = WorkspaceFile(
        id: 'f',
        workspaceId: 'p',
        fileName: 'code.dart',
        storagePath: 'path',
        fileType: 'dart',
        fileSize: 4000,
        uploadedAt: testDate,
      );
      // (4000 + 200) / 4 = 1050
      expect(file.estimatedTokens, equals(1050));
    });

    test('file with markdown summary uses summary length', () {
      final file = WorkspaceFile(
        id: 'f',
        workspaceId: 'p',
        fileName: 'doc.pdf',
        storagePath: 'path',
        fileType: 'pdf',
        fileSize: 1000000,
        uploadedAt: testDate,
        markdownSummary: 'A' * 800,
      );
      // (800 + 200) / 4 = 250
      expect(file.estimatedTokens, equals(250));
    });

    test('PDF without summary uses minimal estimate', () {
      final file = WorkspaceFile(
        id: 'f',
        workspaceId: 'p',
        fileName: 'doc.pdf',
        storagePath: 'path',
        fileType: 'pdf',
        fileSize: 5000000,
        uploadedAt: testDate,
      );
      // 150 / 4 = 38
      expect(file.estimatedTokens, equals(38));
    });

    test('image uses minimal estimate', () {
      final file = WorkspaceFile(
        id: 'f',
        workspaceId: 'p',
        fileName: 'photo.png',
        storagePath: 'path',
        fileType: 'png',
        fileSize: 2000000,
        uploadedAt: testDate,
      );
      // 100 / 4 = 25
      expect(file.estimatedTokens, equals(25));
    });

    test('estimatedTokensFormatted small', () {
      final file = WorkspaceFile(
        id: 'f',
        workspaceId: 'p',
        fileName: 'tiny.txt',
        storagePath: 'path',
        fileType: 'txt',
        fileSize: 100,
        uploadedAt: testDate,
      );
      // (100 + 200) / 4 = 75
      expect(file.estimatedTokensFormatted, equals('75 tokens'));
    });

    test('estimatedTokensFormatted thousands', () {
      final file = WorkspaceFile(
        id: 'f',
        workspaceId: 'p',
        fileName: 'big.dart',
        storagePath: 'path',
        fileType: 'dart',
        fileSize: 20000,
        uploadedAt: testDate,
      );
      // (20000 + 200) / 4 = 5050
      expect(file.estimatedTokensFormatted, equals('5.0k tokens'));
    });
  });
}
