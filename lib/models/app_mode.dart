import 'package:flutter/foundation.dart';

import 'package:chuk_chat/platform_config.dart';

/// Top-level runtime mode of the app. CoWork lives in the SAME app as Chat;
/// a top-left switcher toggles between the two. See docs/COWORK_BUILD_PLAN.md.
enum AppMode { chat, cowork }

/// The live app mode, held here rather than in a single widget's state so the
/// pieces that are far from the switcher — the connectors page opened from
/// Settings, and the model-awareness prompt built in the tool handler — read
/// the same source of truth. The root wrappers own the switcher and write to
/// it; everyone else listens or reads.
final ValueNotifier<AppMode> appModeNotifier = ValueNotifier<AppMode>(
  AppMode.chat,
);

/// Whether CoWork is both built in and currently selected. CoWork-only
/// connectors (which duplicate a built-in or need command execution) are
/// offered only when this is true.
bool get isCoworkActive =>
    kFeatureCoWork && appModeNotifier.value == AppMode.cowork;
