/// Carries the composer draft of a chat screen to the chat screen that
/// replaces it in the same frame.
///
/// The phone layout (`ChukChatUIMobile`) and the wide layout
/// (`ChukChatUIDesktop`) are two different widgets. When a split-screen or
/// freeform window on a phone or tablet crosses the phone breakpoint
/// (`MobileLayout.isPhoneSize`), the root wrapper changes, the old chat
/// screen goes away and a new one mounts. Without this, the text the user
/// typed would be lost.
///
/// The old screen calls [stash] in `deactivate`. Flutter deactivates the old
/// subtree before it builds the new one, so the new screen calls [take] in
/// `initState` and gets the draft. A stash that nobody takes is dropped at
/// the end of the frame: it never reaches a screen that mounts later.
library;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show TextEditingValue;

class ComposerDraftCarry {
  ComposerDraftCarry._();

  static ({String? chatId, TextEditingValue value})? _carried;

  /// Keeps [value] for the screen of [chatId] that mounts in this frame.
  /// An empty draft keeps nothing.
  static void stash(String? chatId, TextEditingValue value) {
    if (value.text.isEmpty) return;
    _carried = (chatId: chatId, value: value);
    SchedulerBinding.instance.addPostFrameCallback((_) => _carried = null);
    // A stash outside a frame (no frame comes) still must not live on.
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  /// The draft stashed for [chatId] in this frame, once; null otherwise.
  static TextEditingValue? take(String? chatId) {
    final carried = _carried;
    if (carried == null || carried.chatId != chatId) return null;
    _carried = null;
    return carried.value;
  }
}
