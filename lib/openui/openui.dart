/// OpenUI Lang in chuk_chat: native widgets for model-written UI.
///
/// Import this file from host code. Component files import the single
/// parts they need. See docs/OPENUI.md.
library;

// The vendored packages mark their API experimental.
// ignore_for_file: experimental_member_use

export 'package:openui/openui.dart' show ToolExecutor;
export 'package:openui_core/openui_core.dart' show OpenUIError, ToolResult;

export 'package:chuk_chat/openui/openui_actions.dart';
export 'package:chuk_chat/openui/openui_component.dart';
export 'package:chuk_chat/openui/openui_library.dart';
export 'package:chuk_chat/openui/openui_props.dart';
export 'package:chuk_chat/openui/openui_theme.dart';
export 'package:chuk_chat/openui/openui_view.dart';
