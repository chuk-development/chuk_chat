import 'package:flutter/foundation.dart';

/// Top-level runtime mode of the app. CoWork lives in the SAME app as Chat;
/// a top-left switcher toggles between the two. See docs/COWORK_BUILD_PLAN.md.
enum AppMode { chat, cowork }

/// The live mode, readable from the service layer.
///
/// The shells keep their own `_mode` widget state for rendering, but the prompt
/// builder runs far below the widget tree and needs to know the mode to gate
/// `cowork_only` skills. [CoWorkModeSwitcher] mirrors every toggle into this
/// notifier, so a synchronous `appMode.value` read at prompt-build time is
/// always current. Defaults to [AppMode.chat].
final ValueNotifier<AppMode> appMode = ValueNotifier<AppMode>(AppMode.chat);
