// lib/utils/ask_user_args.dart
//
// Argument helpers shared by the ask_user tool (tool_executor.dart) and its
// card (message_bubble/tools.dart), so both read a call the same way.

/// Reads ask_user's `multiple` flag. Models send it as a bool or as the
/// string "true"; anything else is a single choice.
bool askUserIsMultiple(Object? raw) =>
    raw == true || (raw is String && raw.trim().toLowerCase() == 'true');
