// The chuk_chat title sync reads `encrypted_chats` and removes every chat in
// memory that the list no longer names. An Agents thread never has a row
// there (it lives in `cowork_chats` and on the host), so it must survive the
// sync. Dropping it emptied the open Agents thread on the next switch and
// threw its replay cursor away.

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/chat_storage_sidebar.dart';

void main() {
  tearDown(() => debugAgentsChatCoreOverride = null);

  const chukChat = '320a5473-64bd-4efa-a87e-26b3d357a2e0';
  const deletedChukChat = '875150d7-1f49-42c4-aa06-fa50e2e77a7f';
  const hostThread = 'host:cowork-host';
  const localThread = 'local:steady-kestrel:1:966468694';

  test('a chuk_chat chat missing from the server list is gone', () {
    debugAgentsChatCoreOverride = true;
    final gone = ChatStorageSidebar.idsGoneFromServer(
      const <String>[chukChat, deletedChukChat],
      const <String>{chukChat},
    );
    expect(gone, <String>{deletedChukChat});
  });

  test('an Agents thread is never gone: encrypted_chats has no row for it', () {
    debugAgentsChatCoreOverride = true;
    final gone = ChatStorageSidebar.idsGoneFromServer(
      const <String>[chukChat, hostThread, localThread],
      const <String>{chukChat},
    );
    expect(gone, isEmpty);
  });

  test('an empty server list removes only chuk_chat chats', () {
    debugAgentsChatCoreOverride = true;
    final gone = ChatStorageSidebar.idsGoneFromServer(
      const <String>[chukChat, hostThread],
      const <String>{},
    );
    expect(gone, <String>{chukChat});
  });

  test('with Agents off every missing id is gone, as upstream', () {
    debugAgentsChatCoreOverride = false;
    final gone = ChatStorageSidebar.idsGoneFromServer(
      const <String>[chukChat, hostThread],
      const <String>{chukChat},
    );
    expect(gone, <String>{hostThread});
  });
}
