// lib/platform_specific/chat/regen_variant_seed.dart
//
// Shared answer-version-pager plumbing for the desktop and mobile chat States.
//
// When the user regenerates an answer, the previous answer(s) are archived as a
// "seed" so the freshly finished answer can be appended as a new pager variant
// instead of replacing the old one. The subtle part is surviving a chat switch:
// a regenerate can finish in the BACKGROUND after the user has moved to another
// chat, and a second regenerate can be running in a different chat at the same
// time. A single mutable seed field (the original design) could not handle
// either — it was cleared on every switch and overwritten by a second
// regenerate, so the previous answer was silently lost from the pager.
//
// This mixin keeps one seed for the visible chat plus a per-chat stash for
// chats whose turn is still finishing in the background. Both the desktop
// (`chat_ui_desktop.dart` + its `part` send logic) and mobile
// (`chat_ui_mobile.dart`) States mix it in and drive it through the small
// public API below; each supplies two hooks for the state it owns.

import 'package:flutter/widgets.dart';

import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';

mixin RegenVariantSeedMixin<W extends StatefulWidget> on State<W> {
  /// Archived previous answer(s) for the CURRENTLY VISIBLE chat's in-flight
  /// regenerate, and the messageId of the new assistant turn they attach to.
  /// The messageId guard means a lingering seed can only ever fold onto the
  /// exact message it was armed for.
  List<Map<String, dynamic>>? _pendingVariantSeed;
  String? _pendingVariantMessageId;

  /// Seeds for chats that are no longer visible but whose regenerate is still
  /// finishing in the background, keyed by chatId. Populated on a chat switch,
  /// read by the background completion, and evicted once its fold lands (the
  /// background fold is a one-shot at the final answer). Returning to such a
  /// chat moves its seed back to the visible-chat fields.
  final Map<String, List<Map<String, dynamic>>> _backgroundVariantSeedByChat =
      {};
  final Map<String, String> _backgroundVariantMessageIdByChat = {};

  // --- Hooks the host State provides -------------------------------------

  /// The chat currently owning the visible message list (`_activeChatId`).
  String? get variantActiveChatId;

  // --- Public API the host calls -----------------------------------------

  /// Arm the fold for a new assistant turn. Pass the regenerate seed (null for
  /// a normal send, which disarms) and the new turn's messageId.
  void armVariantSeed(List<Map<String, dynamic>>? seed, String messageId) {
    _pendingVariantSeed = seed;
    _pendingVariantMessageId = seed != null ? messageId : null;
  }

  /// Drop the visible chat's armed seed with no attempt to preserve it. Used
  /// when the message list is replaced and there is no running turn to keep.
  void clearVariantSeed() {
    _pendingVariantSeed = null;
    _pendingVariantMessageId = null;
  }

  /// Called when leaving the visible chat. When a seed is armed, hand it to the
  /// per-chat stash instead of dropping it, so a regenerate that finishes in
  /// the background after the switch can still fold — the exact case the old
  /// single field lost. Always clears the visible-chat fields afterwards.
  ///
  /// It stashes whenever a seed is armed, without checking that the outgoing
  /// chat's turn is still running: a seed is only ever armed by a regenerate
  /// (a normal send disarms it), the messageId guard means a stash can only
  /// fold onto the exact turn it was armed for, and returning to the chat
  /// evicts it — so a stash whose turn already finished is inert, not a leak.
  /// Trying to detect "still live" here instead was racy: a regenerate has an
  /// await window before streaming starts, and a switch inside it would drop
  /// the just-armed seed.
  void stashVariantSeedForBackground() {
    final outgoing = variantActiveChatId;
    final seed = _pendingVariantSeed;
    final mid = _pendingVariantMessageId;
    if (outgoing != null && seed != null && mid != null) {
      _backgroundVariantSeedByChat[outgoing] = seed;
      _backgroundVariantMessageIdByChat[outgoing] = mid;
    }
    clearVariantSeed();
  }

  /// Called when a chat becomes visible again. If it had a background
  /// regenerate still in flight, move its stashed seed back to the
  /// visible-chat fields so the now-foreground final answer folds normally.
  void restoreVariantSeedForChat(String? chatId) {
    if (chatId == null) return;
    final seed = _backgroundVariantSeedByChat.remove(chatId);
    final mid = _backgroundVariantMessageIdByChat.remove(chatId);
    if (seed != null && mid != null) {
      _pendingVariantSeed = seed;
      _pendingVariantMessageId = mid;
    }
  }

  /// Fold the archived previous answer(s) onto [message] as pager variants,
  /// from the visible-chat seed unless an override is given. Returns true when
  /// a fold actually happened — a caller holding a stashed background seed uses
  /// this to know it is safe to evict (a skipped fold means the seed must be
  /// kept, or the only archived answer is lost).
  bool foldRegenVariantOnto(
    Map<String, String> message, {
    List<Map<String, dynamic>>? seedOverride,
    String? messageIdOverride,
  }) {
    final seed = seedOverride ?? _pendingVariantSeed;
    if (seed == null) return false;
    final String? expectMid = messageIdOverride ?? _pendingVariantMessageId;
    final String? mid = message['messageId'];
    if (mid == null || mid != expectMid) return false;
    if ((message['text'] ?? '') == 'Thinking...') return false;
    ChatUiHelpers.writeVariants(
      message: message,
      seed: seed,
      current: ChatUiHelpers.variantSnapshotOf(message),
    );
    return true;
  }

  /// Fold the stashed background variant onto [message] — a mutable String view
  /// of chat [chatId]'s finished assistant row. In the storage-rebuild fallback
  /// the synthesized row has no messageId, so stamp it with the turn's stashed
  /// id (it IS this turn's assistant message) to make the fold's id guard
  /// match. On a real fold the row carries the new 'variants'/'activeVariant'
  /// (the caller copies them back into its own row) and the stash is evicted;
  /// evicting only on success keeps the archived answer when the fold is
  /// skipped. Returns whether it folded.
  bool foldBackgroundVariantOnto(String chatId, Map<String, String> message) {
    final seed = _backgroundVariantSeedByChat[chatId];
    final mid = _backgroundVariantMessageIdByChat[chatId];
    final existing = message['messageId'];
    if (mid != null && (existing == null || existing.isEmpty)) {
      message['messageId'] = mid;
    }
    final folded = foldRegenVariantOnto(
      message,
      seedOverride: seed,
      messageIdOverride: mid,
    );
    if (folded) {
      _backgroundVariantSeedByChat.remove(chatId);
      _backgroundVariantMessageIdByChat.remove(chatId);
    }
    return folded;
  }
}
