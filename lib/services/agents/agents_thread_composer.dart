/// The send path of the Agents thread on screen, for the few things outside
/// the composer that must send a message the way the composer does.
///
/// Today that is "Run anyway" on a budget refusal (docs/WIRE_CONTRACT.md,
/// "The stop at 100 %"): it sends the refused prompt again, as a normal turn
/// of the thread, so the answer streams into the chat like any other.
///
/// The chat screen attaches its sender when it mounts as an Agents thread
/// and detaches it when it goes. A sender answers false for a chat it does
/// not show or while it is busy, so a press never sends into the wrong
/// thread.
library;

/// Sends [text] as a user message of [chatId]. False when this screen does
/// not show that chat or cannot send right now.
typedef AgentsThreadSender = bool Function(String chatId, String text);

class AgentsThreadComposer {
  AgentsThreadComposer._();

  static final List<AgentsThreadSender> _senders = <AgentsThreadSender>[];

  static void attach(AgentsThreadSender sender) {
    if (!_senders.contains(sender)) _senders.add(sender);
  }

  static void detach(AgentsThreadSender sender) => _senders.remove(sender);

  /// True when a screen took the message.
  static bool send(String chatId, String text) {
    if (chatId.isEmpty || text.trim().isEmpty) return false;
    // The newest screen first: it is the one in front.
    for (final AgentsThreadSender sender in _senders.reversed.toList()) {
      if (sender(chatId, text)) return true;
    }
    return false;
  }

  /// Test seam.
  static void reset() => _senders.clear();
}
