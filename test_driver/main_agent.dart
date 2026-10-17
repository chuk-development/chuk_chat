// Entry point for the agent driver (docs/AGENT_DRIVER.md).
//
// The same app as lib/main.dart, plus the Flutter Driver extension and the
// `ext.chuk.agent.*` service extensions. An AI agent drives it through the
// MCP server in tool/agent_driver. Debug builds only.
//
// Do not start this file by hand with your normal data folders. The MCP
// server starts it with its own XDG folders under _scratch/agent_home, so
// the app does not overwrite the login in ~/.local/share/dev.chuk.chat.

import 'package:flutter/widgets.dart';
import 'package:flutter_driver/driver_extension.dart';

import 'package:chuk_chat/main.dart' as app;

import 'agent_extensions.dart';

Future<void> main() async {
  // Must come before the app creates its binding.
  enableFlutterDriverExtension(
    finders: <FinderExtension>[AgentFinderExtension()],
    // The agent types with the driver `enter_text` command. A real keyboard
    // does not reach the app while the driver extension runs.
    enableTextEntryEmulation: true,
  );
  registerAgentServiceExtensions();
  // A blinking caret makes two screenshots of the same screen differ. With
  // this debug flag the caret is drawn solid and has no blink timer.
  EditableText.debugDeterministicCursor = true;
  await app.main();
}
