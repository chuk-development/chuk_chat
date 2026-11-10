// lib/widgets/chat_reference_picker.dart
//
// The "Reference a chat" picker: a centred dialog (max 480 px, docs/
// DESIGN.md 14.6) with a search field and the user's other chats. The pick
// becomes a read-only snapshot attachment (ChatReferenceService). Opened
// from the chat's attach menu, never from the composer text.

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/services/chat_reference_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/app_notification.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// The chats that can be referenced from [currentChatId]: every other plain
/// chat that is not locked, newest first.
List<StoredChat> referenceableChats(
  List<StoredChat> all, {
  String? currentChatId,
}) {
  final out = all
      .where(
        (c) =>
            c.id != currentChatId &&
            !c.isLocked &&
            !ChatOrigin.isAgentsThread(c.id),
      )
      .toList();
  out.sort(
    (a, b) =>
        (b.updatedAt ?? b.createdAt).compareTo(a.updatedAt ?? a.createdAt),
  );
  return out;
}

/// Shows the picker and returns the snapshot attachment of the chosen chat,
/// or null (cancelled, or the chat could not be loaded; a notice says so).
/// The caller adds it to the turn's attached files.
Future<AttachedFile?> pickChatReference(
  BuildContext context, {
  String? currentChatId,
  Future<AttachedFile?> Function(String chatId) load =
      ChatReferenceService.loadAttachment,
}) async {
  final chats = referenceableChats(
    ChatStorageService.savedChats,
    currentChatId: currentChatId,
  );
  final chatId = await showDialog<String>(
    context: context,
    builder: (_) => ChatReferencePicker(chats: chats),
  );
  if (chatId == null || !context.mounted) return null;
  AttachedFile? file;
  try {
    file = await load(chatId);
  } catch (_) {
    file = null;
  }
  if (file == null && context.mounted) {
    final l =
        AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));
    AppNotifications.show(context, l.chatReferenceLoadFailed);
  }
  return file;
}

/// The dialog. Pops with the picked chat id.
class ChatReferencePicker extends StatefulWidget {
  const ChatReferencePicker({super.key, required this.chats});

  final List<StoredChat> chats;

  @override
  State<ChatReferencePicker> createState() => _ChatReferencePickerState();
}

class _ChatReferencePickerState extends State<ChatReferencePicker> {
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<StoredChat> get _filtered {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return widget.chats;
    return widget.chats
        .where(
          (c) =>
              ChatReferenceService.chatTitle(c).toLowerCase().contains(query),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final l =
        AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));
    final theme = Theme.of(context);
    final m3 = theme.m3;
    final chats = _filtered;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l.chatReferenceAction, style: theme.textTheme.titleLarge),
              const SizedBox(height: 16),
              TextField(
                controller: _search,
                autofocus: false,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: l.chatReferenceSearchHint,
                  prefixIcon: const AppIcon(Icons.search, size: 20),
                  filled: true,
                  fillColor: m3.surfaceContainer,
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(999),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: chats.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Text(
                          l.chatReferenceEmpty,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: m3.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: chats.length,
                        itemBuilder: (context, i) {
                          final chat = chats[i];
                          final title = ChatReferenceService.chatTitle(chat);
                          return ListTile(
                            key: ValueKey<String>('chat-ref-${chat.id}'),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            leading: AppIcon(
                              Icons.chat_bubble_outline,
                              size: 20,
                              color: m3.onSurfaceVariant,
                            ),
                            title: Text(
                              title.isEmpty ? '…' : title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => Navigator.of(context).pop(chat.id),
                          );
                        },
                      ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    MaterialLocalizations.of(context).cancelButtonLabel,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
