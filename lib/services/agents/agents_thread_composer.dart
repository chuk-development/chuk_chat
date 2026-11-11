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
///
/// It also carries a PREFILL: text the shell wants in a thread's composer,
/// not sent (a Home widget that opens the main agent with a prompt,
/// `main_agent_launcher.dart`). The shell parks it with [prefill]; the chat
/// screen that shows that thread takes it ([takePrefill]) when it mounts,
/// when it switches to the thread, and when [prefillChanges] fires.
library;

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/chat_model.dart';

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

  static ({String chatId, String text})? _prefill;
  static final ValueNotifier<int> _prefillTick = ValueNotifier<int>(0);

  /// Fires when a prefill is parked.
  static Listenable get prefillChanges => _prefillTick;

  /// Parks [text] for the composer of [chatId]. A newer prefill replaces an
  /// older one that no screen has taken yet. An empty [text] asks only for
  /// the composer's focus (Home's `Ask <agent>` pill): the screen keeps
  /// whatever draft it has and puts the caret in it.
  static void prefill(String chatId, String text, {bool notify = true}) {
    if (chatId.isEmpty) return;
    _prefill = (chatId: chatId, text: text);
    // Silent from a dispose: the tree is locked there, and the screen that
    // replaces the disposed one takes the prefill after its first frame.
    if (notify) _prefillTick.value++;
  }

  /// The parked text for [chatId], once: null for another chat or none, ''
  /// for "focus the composer, keep its draft".
  static String? takePrefill(String? chatId) {
    final ({String chatId, String text})? pending = _prefill;
    if (pending == null || chatId == null || pending.chatId != chatId) {
      return null;
    }
    _prefill = null;
    return pending.text;
  }

  /// True when text is parked for [chatId] and no screen took it yet.
  static bool hasPrefill(String chatId) => _prefill?.chatId == chatId;

  // --- a draft carried across a remount ------------------------------------

  static ({String chatId, List<AttachedFile> files})? _carried;

  static String? _remounting;

  /// The thread view is about to remount the chat screen of [chatId]. Only
  /// then does the screen going away hand its draft on.
  static void markRemount(String chatId) => _remounting = chatId;

  /// True once, when [chatId]'s screen goes away for a remount.
  static bool takeRemount(String chatId) {
    if (_remounting != chatId) return false;
    _remounting = null;
    return true;
  }

  /// Ready attachments of [chatId]'s composer, handed from a chat screen that
  /// is going away to the one that replaces it. The thread view remounts its
  /// chat screen when the host's replay lands (about a second after a thread
  /// is opened), and the files in the composer would be lost with it.
  static void carryFiles(String chatId, List<AttachedFile> files) {
    _carried = files.isEmpty ? null : (chatId: chatId, files: files);
  }

  /// The attachments carried for [chatId], once.
  static List<AttachedFile> takeCarriedFiles(String? chatId) {
    final carried = _carried;
    if (carried == null || chatId == null || carried.chatId != chatId) {
      return const <AttachedFile>[];
    }
    _carried = null;
    return carried.files;
  }

  /// Test seam.
  static void reset() {
    _senders.clear();
    _prefill = null;
    _carried = null;
    _remounting = null;
  }
}
