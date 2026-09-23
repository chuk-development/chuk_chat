/// Which world a chat id belongs to: a chuk_chat chat or an Agents thread.
///
/// The two share one in-memory map ([ChatStorageState.chatsById]), one SQLite
/// cache and the imported chat screen, but not their cloud table and not their
/// offline queue:
///
/// | kind          | Supabase table    | offline queue          |
/// |---------------|-------------------|------------------------|
/// | chuk_chat     | `encrypted_chats` | `OfflineQueueService`  |
/// | Agents thread | `cowork_chats`    | `AgentsTaskOutbox`     |
///
/// Every place that must pick one of the two asks [isAgentsThread]. With the
/// Agents build flag off it always answers false, so every chat takes
/// upstream's path.
///
/// How a thread is recognised:
///
/// * A chuk_chat chat id is always a UUID (`Uuid().v4()` in the send paths).
/// * An Agents thread id is the executor's `session_key`, which the host
///   mints as `default`, a slug-plus-digest (`amber-otter-2`) or the agent id.
///   It is not a UUID.
/// * A key that the Agents code has claimed ([claimAgentsThread]) counts as
///   an Agents thread whatever its shape, so a host that ever mints a
///   UUID-shaped key still routes right once the thread was opened.
library;

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/agents/agents_chat_core.dart';

class ChatOrigin {
  ChatOrigin._();

  /// Whether the Agents storage paths are live. Follows [agentsChatCore], the
  /// one switch for every Agents code path.
  static bool get agentsEnabled => agentsChatCore;

  /// A test picks a side here (tests run with the flag off). Sets the one
  /// shared override, so storage, transport and tools always agree.
  @visibleForTesting
  static set agentsEnabled(bool value) => debugAgentsChatCoreOverride = value;

  static final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{12}$',
  );

  static final Set<String> _claimed = <String>{};

  /// True when [chatId] names an Agents thread. Always false with the flag
  /// off, and for a null or empty id.
  static bool isAgentsThread(String? chatId) {
    if (!agentsEnabled) return false;
    if (chatId == null || chatId.isEmpty) return false;
    if (_claimed.contains(chatId)) return true;
    return !_uuid.hasMatch(chatId);
  }

  /// Records [sessionKey] as an Agents thread. Called by the Agents write
  /// paths before they store anything under the key.
  static void claimAgentsThread(String sessionKey) {
    if (!agentsEnabled || sessionKey.isEmpty) return;
    _claimed.add(sessionKey);
  }

  @visibleForTesting
  static void reset() {
    debugAgentsChatCoreOverride = null;
    _claimed.clear();
  }
}
