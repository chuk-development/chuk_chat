import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/models/chat_message.dart';

void main() {
  final testDate = DateTime(2025, 6, 15, 10, 30);
  final testMessages = [
    ChatMessage(role: 'user', text: 'Hello'),
    ChatMessage(role: 'assistant', text: 'Hi there!'),
  ];

  group('StoredChat constructor', () {
    test('with messages', () {
      final chat = StoredChat(
        id: 'chat-1',
        messages: testMessages,
        createdAt: testDate,
        isStarred: false,
      );
      expect(chat.id, equals('chat-1'));
      expect(chat.messages, hasLength(2));
      expect(chat.createdAt, equals(testDate));
      expect(chat.isStarred, isFalse);
      expect(chat.title, isNull);
      expect(chat.customName, isNull);
      expect(chat.updatedAt, isNull);
    });

    test('with all fields', () {
      final updated = DateTime(2025, 6, 16);
      final chat = StoredChat(
        id: 'chat-2',
        messages: testMessages,
        createdAt: testDate,
        isStarred: true,
        title: 'My Chat',
        customName: 'Custom',
        updatedAt: updated,
      );
      expect(chat.isStarred, isTrue);
      expect(chat.title, equals('My Chat'));
      expect(chat.customName, equals('Custom'));
      expect(chat.updatedAt, equals(updated));
    });
  });

  group('forSidebar', () {
    test('creates chat without messages', () {
      final chat = StoredChat.forSidebar(
        id: 'sidebar-1',
        createdAt: testDate,
        isStarred: false,
        title: 'Sidebar Title',
      );
      expect(chat.id, equals('sidebar-1'));
      expect(chat.isFullyLoaded, isFalse);
      expect(chat.messagesOrNull, isNull);
      expect(chat.title, equals('Sidebar Title'));
    });
  });

  group('isFullyLoaded', () {
    test('true when messages provided', () {
      final chat = StoredChat(
        id: 'c1',
        messages: testMessages,
        createdAt: testDate,
        isStarred: false,
      );
      expect(chat.isFullyLoaded, isTrue);
    });

    test('false when no messages', () {
      final chat = StoredChat.forSidebar(
        id: 'c2',
        createdAt: testDate,
        isStarred: false,
      );
      expect(chat.isFullyLoaded, isFalse);
    });

    test('true for empty message list', () {
      final chat = StoredChat(
        id: 'c3',
        messages: [],
        createdAt: testDate,
        isStarred: false,
      );
      expect(chat.isFullyLoaded, isTrue);
    });
  });

  group('messages access', () {
    test('returns messages when loaded', () {
      final chat = StoredChat(
        id: 'c1',
        messages: testMessages,
        createdAt: testDate,
        isStarred: false,
      );
      expect(chat.messages, hasLength(2));
    });

    test('throws StateError when not loaded', () {
      final chat = StoredChat.forSidebar(
        id: 'c2',
        createdAt: testDate,
        isStarred: false,
      );
      expect(() => chat.messages, throwsA(isA<StateError>()));
    });
  });

  group('messagesOrNull', () {
    test('returns messages when loaded', () {
      final chat = StoredChat(
        id: 'c1',
        messages: testMessages,
        createdAt: testDate,
        isStarred: false,
      );
      expect(chat.messagesOrNull, isNotNull);
      expect(chat.messagesOrNull, hasLength(2));
    });

    test('returns null when not loaded', () {
      final chat = StoredChat.forSidebar(
        id: 'c2',
        createdAt: testDate,
        isStarred: false,
      );
      expect(chat.messagesOrNull, isNull);
    });
  });

  group('previewText', () {
    test('uses title when available', () {
      final chat = StoredChat.forSidebar(
        id: 'c1',
        createdAt: testDate,
        isStarred: false,
        title: 'Chat about Flutter',
      );
      expect(chat.previewText, equals('Chat about Flutter'));
    });

    test('truncates long title to 100 chars', () {
      final longTitle = 'A' * 150;
      final chat = StoredChat.forSidebar(
        id: 'c1',
        createdAt: testDate,
        isStarred: false,
        title: longTitle,
      );
      expect(chat.previewText.length, equals(103)); // 100 + "..."
      expect(chat.previewText, endsWith('...'));
    });

    test('uses first user message when no title', () {
      final chat = StoredChat(
        id: 'c1',
        messages: [
          ChatMessage(role: 'system', text: 'You are helpful'),
          ChatMessage(role: 'user', text: 'What is Flutter?'),
        ],
        createdAt: testDate,
        isStarred: false,
      );
      expect(chat.previewText, equals('What is Flutter?'));
    });

    test('falls back to first message if no user message', () {
      final chat = StoredChat(
        id: 'c1',
        messages: [
          ChatMessage(role: 'assistant', text: 'Welcome!'),
        ],
        createdAt: testDate,
        isStarred: false,
      );
      expect(chat.previewText, equals('Welcome!'));
    });

    test('empty when no title and no messages loaded', () {
      final chat = StoredChat.forSidebar(
        id: 'c1',
        createdAt: testDate,
        isStarred: false,
      );
      expect(chat.previewText, equals(''));
    });

    test('empty when no title and empty messages', () {
      final chat = StoredChat(
        id: 'c1',
        messages: [],
        createdAt: testDate,
        isStarred: false,
      );
      expect(chat.previewText, equals(''));
    });
  });

  group('fromRow', () {
    test('creates from database row', () {
      final chat = StoredChat.fromRow(
        {
          'id': 'db-id-123',
          'created_at': '2025-06-15T10:30:00.000Z',
          'updated_at': '2025-06-16T12:00:00.000Z',
          'is_starred': true,
        },
        testMessages,
        title: 'DB Chat',
        customName: 'Custom',
      );
      expect(chat.id, equals('db-id-123'));
      expect(chat.messages, hasLength(2));
      expect(chat.isStarred, isTrue);
      expect(chat.title, equals('DB Chat'));
      expect(chat.customName, equals('Custom'));
      expect(chat.updatedAt, isNotNull);
    });

    test('handles null updated_at', () {
      final chat = StoredChat.fromRow(
        {
          'id': 'db-id',
          'created_at': '2025-06-15T10:30:00.000Z',
          'is_starred': false,
        },
        [],
      );
      expect(chat.updatedAt, isNull);
    });

    test('handles null is_starred defaults to false', () {
      final chat = StoredChat.fromRow(
        {
          'id': 'db-id',
          'created_at': '2025-06-15T10:30:00.000Z',
        },
        [],
      );
      expect(chat.isStarred, isFalse);
    });
  });

  group('fromRowTitleOnly', () {
    test('creates sidebar chat from row', () {
      final chat = StoredChat.fromRowTitleOnly(
        {
          'id': 'sidebar-id',
          'created_at': '2025-06-15T10:30:00.000Z',
          'is_starred': true,
        },
        title: 'Sidebar Title',
      );
      expect(chat.id, equals('sidebar-id'));
      expect(chat.isFullyLoaded, isFalse);
      expect(chat.title, equals('Sidebar Title'));
      expect(chat.isStarred, isTrue);
    });
  });

  group('copyWith', () {
    test('copies with new values', () {
      final original = StoredChat(
        id: 'c1',
        messages: testMessages,
        createdAt: testDate,
        isStarred: false,
        title: 'Original',
      );
      final copy = original.copyWith(
        isStarred: true,
        title: 'Updated',
      );
      expect(copy.id, equals('c1'));
      expect(copy.isStarred, isTrue);
      expect(copy.title, equals('Updated'));
      expect(copy.messages, hasLength(2));
    });

    test('preserves original when no changes', () {
      final original = StoredChat(
        id: 'c1',
        messages: testMessages,
        createdAt: testDate,
        isStarred: true,
        title: 'Keep',
      );
      final copy = original.copyWith();
      expect(copy.id, equals(original.id));
      expect(copy.isStarred, equals(original.isStarred));
      expect(copy.title, equals(original.title));
    });
  });

  group('withMessages', () {
    test('adds messages to sidebar chat', () {
      final sidebar = StoredChat.forSidebar(
        id: 'c1',
        createdAt: testDate,
        isStarred: false,
        title: 'Chat',
      );
      expect(sidebar.isFullyLoaded, isFalse);

      final loaded = sidebar.withMessages(testMessages);
      expect(loaded.isFullyLoaded, isTrue);
      expect(loaded.messages, hasLength(2));
      expect(loaded.id, equals('c1'));
      expect(loaded.title, equals('Chat'));
    });

    test('can override customName', () {
      final sidebar = StoredChat.forSidebar(
        id: 'c1',
        createdAt: testDate,
        isStarred: false,
      );
      final loaded = sidebar.withMessages(
        testMessages,
        customName: 'New Name',
      );
      expect(loaded.customName, equals('New Name'));
    });
  });
}
