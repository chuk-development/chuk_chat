import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/window_title_service.dart';

void main() {
  final List<String> titles = <String>[];

  setUp(() {
    titles.clear();
    ChatStorageService.selectedChatId = null;
    WindowTitleService.debugStart((String title) async => titles.add(title));
  });

  tearDown(() {
    WindowTitleService.debugReset();
    ChatStorageService.selectedChatId = null;
  });

  test('a new chat is the app name alone', () {
    expect(WindowTitleService.compose(null), 'Chuk Chat');
    expect(WindowTitleService.compose('   '), 'Chuk Chat');
    expect(titles, <String>['Chuk Chat']);
  });

  test('a named chat is "Chuk Chat - <name>"', () {
    expect(WindowTitleService.compose(' Trip plan '), 'Chuk Chat - Trip plan');
  });

  test('the title follows the chat in view, with the resolver first', () {
    WindowTitleService.nameResolver = (String id) =>
        id == 'thread-1' ? 'Ada' : null;

    ChatStorageService.selectedChatId = 'thread-1';
    expect(titles.last, 'Chuk Chat - Ada');

    // A chat that is not known (no stored title yet) is a new chat.
    ChatStorageService.selectedChatId = 'unknown-chat';
    expect(titles.last, 'Chuk Chat');

    ChatStorageService.selectedChatId = 'thread-1';
    ChatStorageService.selectedChatId = null;
    expect(titles, <String>[
      'Chuk Chat',
      'Chuk Chat - Ada',
      'Chuk Chat',
      'Chuk Chat - Ada',
      'Chuk Chat',
    ]);
  });

  test('an unchanged title is not written again', () {
    WindowTitleService.refresh();
    WindowTitleService.refresh();
    expect(titles, <String>['Chuk Chat']);
  });
}
