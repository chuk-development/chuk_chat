# Share sheet (Android)

Content shared INTO the app from the system share sheet.

- **"Chuk Chat" in the app row.** `share/ShareReceiverActivity.kt` takes
  `ACTION_SEND` / `ACTION_SEND_MULTIPLE` (text, images, `application/*`). It has
  no UI: it forwards the text and the content URIs (with their read grants) to
  `MainActivity` in the app's own task and finishes. No second Flutter engine.
- **Every agent as a contact** (Direct Share, Agents build only).
  `lib/pages/agents_share_targets.dart` publishes up to 8 visible agents, main
  agent first, as long-lived sharing shortcuts. The icon is the agent's face,
  painted by `lib/services/share/share_target_icon.dart` in adaptive-icon
  layout (face inside the middle 72/108). Android adds the app badge itself.
  `res/xml/shortcuts.xml` declares the share target and category
  `dev.chuk.chat.category.SHARE_TARGET`. A plain build publishes an empty set,
  so contacts left by an Agents build of the same package go away.
- **Bridge.** `share/ShareBridge.kt`, channel `chuk/share`: `takeShare`,
  `setShareTargets`, callback `shareAvailable`. Files are copied to
  `cacheDir/shared/<uuid>/` (max 200 MB each); only `content://` URIs.
- **Routing.** `ShareIntentService.incoming` holds the share until a screen
  takes it. No agent: `RootWrapperMobile` opens a new chat with text and files
  in the composer (in the Agents build the shell first brings Chats to the
  front). Agent: the shell opens that agent's thread, parks the text
  (`AgentsThreadComposer.prefill`) and the files (`parkFiles`); the chat screen
  takes both. Nothing is sent automatically.

Not done: iOS (needs a Share Extension and `INSendMessageIntent` donations),
and files on the tablet/desktop layout (`chat_ui_desktop.dart` takes only the
text prefill).

Test without the sheet:
`adb shell am start -a android.intent.action.SEND -t text/plain --es android.intent.extra.TEXT hi -n dev.chuk.chat/.share.ShareReceiverActivity`.
Published contacts: `adb shell dumpsys shortcut | grep share_`.
